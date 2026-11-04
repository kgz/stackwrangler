#!/usr/bin/env bash
# ReservedConcurrentExecutions (PutFunctionConcurrency):
# - reserved=1 + two concurrent sync invokes → one TooManyRequestsException (429)
# - reserved=0 → every sync invoke throttled
# - SQS ESM: in-flight never exceeds reserved; throttled msgs stay on queue (not DLQ
#   before maxReceiveCount)
# ScalingConfig.MaximumConcurrency vs reserved ("lower wins") is NOT asserted —
# LocalEmu does not enforce MaximumConcurrency at poll time ([#453](https://github.com/kgz/awsl/issues/453)).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-${STACKWRANGLER_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${AWSBOX_REGION:-${STACKWRANGLER_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
TS="$(date +%s)"
P="awsbox-rc-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWSBOX_IAM_ENDPOINT="$EP"
export AWSBOX_REGION="$REGION"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

python3 -c 'import boto3, botocore' 2>/dev/null || fail "python3 boto3 required (pip install boto3)"

# Cleanup is owned by the python driver (resources listed via env KEEP).
export AWSBOX_RC_PREFIX="$P"
export AWSBOX_RC_KEEP="$KEEP"

python3 - <<'PY'
import io
import json
import os
import sys
import threading
import time
import zipfile
import concurrent.futures

import boto3
import botocore
from botocore.config import Config

EP = os.environ["AWSBOX_IAM_ENDPOINT"]
REGION = os.environ["AWSBOX_REGION"]
KEEP = os.environ.get("AWSBOX_RC_KEEP", "0") == "1"
P = os.environ["AWSBOX_RC_PREFIX"]

# Concurrent invoke must not retry 429 — botocore's default backoff waits out the
# in-flight reserved slot and turns a real throttle into a late success.
NO_RETRY = Config(retries={"max_attempts": 0}, max_pool_connections=20)

kw = dict(
    endpoint_url=EP,
    region_name=REGION,
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
)
lam = boto3.client("lambda", config=NO_RETRY, **kw)
iam = boto3.client("iam", **kw)
sqs = boto3.client("sqs", **kw)
s3 = boto3.client("s3", **kw)

ROLE = f"{P}-role"
FN_DIRECT = f"{P}-direct"
FN_ESM = f"{P}-esm"
BUCKET = f"{P}-bkt"
Q_NAME = f"{P}-q"
DLQ_NAME = f"{P}-dlq"

uuids: list[str] = []
fns: list[str] = []
qurls: list[str] = []
roles: list[str] = []
buckets: list[str] = []


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"ok: {msg}")


def cleanup() -> None:
    if KEEP:
        print(f"KEEP=1 — leaving resources under prefix {P}")
        return
    for u in uuids:
        try:
            lam.delete_event_source_mapping(UUID=u)
        except Exception:
            pass
    for f in fns:
        try:
            lam.delete_function_concurrency(FunctionName=f)
        except Exception:
            pass
        try:
            lam.delete_function(FunctionName=f)
        except Exception:
            pass
    for q in qurls:
        try:
            sqs.delete_queue(QueueUrl=q)
        except Exception:
            pass
    for b in buckets:
        try:
            for cont in s3.list_objects_v2(Bucket=b).get("Contents") or []:
                s3.delete_object(Bucket=b, Key=cont["Key"])
            s3.delete_bucket(Bucket=b)
        except Exception:
            pass
    for r in roles:
        try:
            iam.delete_role_policy(RoleName=r, PolicyName="inline")
        except Exception:
            pass
        try:
            iam.delete_role(RoleName=r)
        except Exception:
            pass


def zip_js(source: str) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr("index.js", source.encode())
    return buf.getvalue()


def wait_active(name: str, timeout: int = 90) -> None:
    deadline = time.time() + timeout
    state = "Pending"
    while time.time() < deadline:
        state = lam.get_function(FunctionName=name)["Configuration"]["State"]
        if state == "Active":
            return
        time.sleep(1)
    fail(f"{name} never Active (state={state})")


def mk_role(name: str, actions: list[str]) -> str:
    trust = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": "lambda.amazonaws.com"},
                "Action": "sts:AssumeRole",
            }
        ],
    }
    iam.create_role(RoleName=name, AssumeRolePolicyDocument=json.dumps(trust))
    roles.append(name)
    iam.put_role_policy(
        RoleName=name,
        PolicyName="inline",
        PolicyDocument=json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {"Effect": "Allow", "Action": actions, "Resource": "*"}
                ],
            }
        ),
    )
    return f"arn:aws:iam::000000000000:role/{name}"


def mk_fn(name: str, zip_bytes: bytes, role_arn: str, timeout: int = 60, env: dict | None = None) -> None:
    args = dict(
        FunctionName=name,
        Runtime="nodejs18.x",
        Role=role_arn,
        Handler="index.handler",
        Code={"ZipFile": zip_bytes},
        Timeout=timeout,
    )
    if env is not None:
        args["Environment"] = {"Variables": env}
    lam.create_function(**args)
    fns.append(name)
    wait_active(name)


def lambda_client() -> object:
    return boto3.client("lambda", config=NO_RETRY, **kw)


try:
    role_arn = mk_role(
        ROLE,
        ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "s3:*", "logs:*"],
    )

    # ---- direct invoke: reserved=1 concurrent → one 429 ----
    slow = (
        "exports.handler = async () => {"
        "  await new Promise((r) => setTimeout(r, 8000));"
        "  return { ok: true };"
        "};"
    )
    mk_fn(FN_DIRECT, zip_js(slow), role_arn, timeout=60)
    # warm so cold-start does not serialize the two concurrent invokes
    warm = lam.invoke(FunctionName=FN_DIRECT, Payload=b"{}")
    if warm.get("StatusCode") != 200:
        fail(f"warm invoke StatusCode={warm.get('StatusCode')}")
    lam.put_function_concurrency(FunctionName=FN_DIRECT, ReservedConcurrentExecutions=1)
    got = lam.get_function_concurrency(FunctionName=FN_DIRECT).get("ReservedConcurrentExecutions")
    if got != 1:
        fail(f"get_function_concurrency expected 1 got {got}")

    barrier = threading.Barrier(2)

    def sync_invoke(idx: int) -> dict:
        cl = lambda_client()
        barrier.wait()
        t0 = time.time()
        try:
            r = cl.invoke(FunctionName=FN_DIRECT, Payload=b"{}")
            return {
                "i": idx,
                "ok": True,
                "status": r.get("StatusCode"),
                "elapsed": time.time() - t0,
            }
        except botocore.exceptions.ClientError as e:
            err = e.response.get("Error", {})
            meta = e.response.get("ResponseMetadata", {})
            return {
                "i": idx,
                "ok": False,
                "code": err.get("Code"),
                "http": meta.get("HTTPStatusCode"),
                "elapsed": time.time() - t0,
            }

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = [f.result() for f in [pool.submit(sync_invoke, i) for i in range(2)]]

    oks = [r for r in results if r.get("ok")]
    throttled = [
        r
        for r in results
        if (not r.get("ok"))
        and r.get("code") == "TooManyRequestsException"
        and r.get("http") == 429
    ]
    if len(oks) != 1 or len(throttled) != 1:
        fail(f"reserved=1 concurrent expected 1 ok + 1×429, got {results}")
    ok("reserved=1: one sync invoke ok, one TooManyRequestsException (429)")

    # ---- reserved=0 throttles every sync invoke ----
    lam.put_function_concurrency(FunctionName=FN_DIRECT, ReservedConcurrentExecutions=0)
    got0 = lam.get_function_concurrency(FunctionName=FN_DIRECT).get("ReservedConcurrentExecutions")
    if got0 != 0:
        fail(f"get_function_concurrency expected 0 got {got0}")
    for i in range(2):
        try:
            lam.invoke(FunctionName=FN_DIRECT, Payload=b"{}")
            fail(f"reserved=0 invoke {i} unexpectedly succeeded")
        except botocore.exceptions.ClientError as e:
            err = e.response.get("Error", {})
            http = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            if err.get("Code") != "TooManyRequestsException" or http != 429:
                fail(f"reserved=0 expected TooManyRequestsException/429 got {err} http={http}")
    ok("reserved=0: every sync invoke TooManyRequestsException (429)")

    # ---- SQS ESM: in-flight ≤ reserved; no early DLQ ----
    s3.create_bucket(Bucket=BUCKET)
    buckets.append(BUCKET)
    esm_js = """
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const c = new S3Client({ region: process.env.AWS_REGION || "us-east-1", forcePathStyle: true });
exports.handler = async (event) => {
  const id = event.Records[0].messageId;
  const start = Date.now();
  await c.send(new PutObjectCommand({
    Bucket: process.env.BUCKET, Key: "start/" + id, Body: String(start),
  }));
  await new Promise((r) => setTimeout(r, 5000));
  await c.send(new PutObjectCommand({
    Bucket: process.env.BUCKET, Key: "end/" + id, Body: String(Date.now()),
  }));
};
"""
    mk_fn(FN_ESM, zip_js(esm_js), role_arn, timeout=60, env={"BUCKET": BUCKET})
    lam.put_function_concurrency(FunctionName=FN_ESM, ReservedConcurrentExecutions=1)

    dlq = sqs.create_queue(QueueName=DLQ_NAME)["QueueUrl"]
    qurls.append(dlq)
    dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq, AttributeNames=["QueueArn"])["Attributes"][
        "QueueArn"
    ]
    q = sqs.create_queue(
        QueueName=Q_NAME,
        Attributes={
            "VisibilityTimeout": "60",
            "RedrivePolicy": json.dumps(
                {"deadLetterTargetArn": dlq_arn, "maxReceiveCount": 5}
            ),
        },
    )["QueueUrl"]
    qurls.append(q)
    qarn = sqs.get_queue_attributes(QueueUrl=q, AttributeNames=["QueueArn"])["Attributes"][
        "QueueArn"
    ]
    mapping = lam.create_event_source_mapping(
        FunctionName=FN_ESM,
        EventSourceArn=qarn,
        BatchSize=1,
        Enabled=True,
    )
    uuids.append(mapping["UUID"])

    for i in range(3):
        sqs.send_message(QueueUrl=q, MessageBody=f"msg-{i}")

    deadline = time.time() + 120
    ends = 0
    while time.time() < deadline:
        ends = len(s3.list_objects_v2(Bucket=BUCKET, Prefix="end/").get("Contents") or [])
        if ends >= 3:
            break
        time.sleep(2)
    if ends < 3:
        fail(f"ESM: expected 3 completed invocations, got {ends}")

    starts: list[tuple[str, int]] = []
    ends_l: list[tuple[str, int]] = []
    for obj in s3.list_objects_v2(Bucket=BUCKET, Prefix="start/").get("Contents") or []:
        body = s3.get_object(Bucket=BUCKET, Key=obj["Key"])["Body"].read().decode()
        starts.append((obj["Key"].rsplit("/", 1)[-1], int(body)))
    for obj in s3.list_objects_v2(Bucket=BUCKET, Prefix="end/").get("Contents") or []:
        body = s3.get_object(Bucket=BUCKET, Key=obj["Key"])["Body"].read().decode()
        ends_l.append((obj["Key"].rsplit("/", 1)[-1], int(body)))

    intervals: list[tuple[int, int]] = []
    end_by_id = dict(ends_l)
    for mid, start_ms in starts:
        end_ms = end_by_id.get(mid)
        if end_ms is None:
            fail(f"ESM: missing end marker for {mid}")
        intervals.append((start_ms, end_ms))

    events: list[tuple[int, int]] = []
    for start_ms, end_ms in intervals:
        events.append((start_ms, 1))
        events.append((end_ms, -1))
    # Ends (-1) before starts (+1) at equal ms so serial handoffs don't false-fail.
    events.sort(key=lambda x: (x[0], x[1]))
    cur = 0
    max_conc = 0
    for _, delta in events:
        cur += delta
        if cur > max_conc:
            max_conc = cur
    if max_conc > 1:
        fail(f"ESM: in-flight concurrency {max_conc} exceeded reserved=1")
    ok(f"ESM reserved=1: max in-flight={max_conc} (≤1)")

    dlq_attrs = sqs.get_queue_attributes(
        QueueUrl=dlq,
        AttributeNames=[
            "ApproximateNumberOfMessages",
            "ApproximateNumberOfMessagesNotVisible",
        ],
    )["Attributes"]
    dlq_visible = int(dlq_attrs.get("ApproximateNumberOfMessages", "0"))
    dlq_hidden = int(dlq_attrs.get("ApproximateNumberOfMessagesNotVisible", "0"))
    if dlq_visible + dlq_hidden > 0:
        fail(
            f"ESM: throttled messages must not hit DLQ before maxReceiveCount "
            f"(dlq visible={dlq_visible} hidden={dlq_hidden})"
        )
    ok("ESM reserved=1: DLQ empty (throttled msgs returned to source queue)")

    print(
        "note: ScalingConfig.MaximumConcurrency vs reserved (lower wins) not asserted — "
        "LocalEmu stores MaximumConcurrency but does not enforce it at poll time "
        "([#453](https://github.com/kgz/awsl/issues/453))"
    )
    ok("lambda-reserved-concurrency-smoke")
finally:
    cleanup()
PY
