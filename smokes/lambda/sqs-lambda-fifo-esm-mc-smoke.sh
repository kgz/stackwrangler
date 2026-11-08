#!/usr/bin/env bash
# SQS FIFO ESM + ScalingConfig.MaximumConcurrency (#499):
# - Within a MessageGroupId, invokes stay serial and preserve send order
# - Distinct MessageGroupIds may run concurrently up to MaximumConcurrency
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
P="awsbox-fifo-mc-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWSBOX_IAM_ENDPOINT="$EP"
export AWSBOX_REGION="$REGION"
export AWSBOX_FIFO_MC_PREFIX="$P"
export AWSBOX_FIFO_MC_KEEP="$KEEP"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

python3 -c 'import boto3, botocore' 2>/dev/null || fail "python3 boto3 required (pip install boto3)"

export PYTHONUNBUFFERED=1
python3 -u - <<'PY'
import io
import json
import os
import sys
import time
import zipfile

import boto3
from botocore.config import Config

EP = os.environ["AWSBOX_IAM_ENDPOINT"]
REGION = os.environ["AWSBOX_REGION"]
KEEP = os.environ.get("AWSBOX_FIFO_MC_KEEP", "0") == "1"
P = os.environ["AWSBOX_FIFO_MC_PREFIX"]

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
FN = f"{P}-fn"
BUCKET = f"{P}-bkt"
Q_NAME = f"{P}-q.fifo"
DLQ_NAME = f"{P}-dlq.fifo"
GROUPS = ("A", "B", "C")
PER_GROUP = 3
MC = 3
SLEEP_MS = 4000

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
            lam.delete_function(FunctionName=f)
        except Exception:
            pass
    for q in qurls:
        try:
            sqs.delete_queue(QueueUrl=q)
        except Exception:
            pass
    for r in roles:
        try:
            for p in iam.list_attached_role_policies(RoleName=r).get("AttachedPolicies", []):
                iam.detach_role_policy(RoleName=r, PolicyArn=p["PolicyArn"])
            for p in iam.list_role_policies(RoleName=r).get("PolicyNames", []):
                iam.delete_role_policy(RoleName=r, PolicyName=p)
            iam.delete_role(RoleName=r)
        except Exception:
            pass
    for b in buckets:
        try:
            for obj in s3.list_objects_v2(Bucket=b).get("Contents") or []:
                s3.delete_object(Bucket=b, Key=obj["Key"])
            s3.delete_bucket(Bucket=b)
        except Exception:
            pass


def zip_js(source: str) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("index.js", source)
    return buf.getvalue()


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
    try:
        iam.create_role(RoleName=name, AssumeRolePolicyDocument=json.dumps(trust))
    except iam.exceptions.EntityAlreadyExistsException:
        pass
    roles.append(name)
    iam.put_role_policy(
        RoleName=name,
        PolicyName=f"{name}-inline",
        PolicyDocument=json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [{"Effect": "Allow", "Action": actions, "Resource": "*"}],
            }
        ),
    )
    return iam.get_role(RoleName=name)["Role"]["Arn"]


def wait_active(fn_name: str) -> None:
    deadline = time.time() + 60
    while time.time() < deadline:
        st = lam.get_function(FunctionName=fn_name)["Configuration"].get("State")
        if st == "Active":
            return
        time.sleep(1)
    fail(f"function {fn_name} not Active")


try:
    role_arn = mk_role(
        ROLE,
        ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "s3:*", "logs:*"],
    )
    s3.create_bucket(Bucket=BUCKET)
    buckets.append(BUCKET)

    handler = f"""
const {{ S3Client, PutObjectCommand }} = require("@aws-sdk/client-s3");
const c = new S3Client({{ region: process.env.AWS_REGION || "us-east-1", forcePathStyle: true }});
exports.handler = async (event) => {{
  const rec = event.Records[0];
  const body = String(rec.body || "");
  const parts = body.split(":");
  const group = parts[0] || "unknown";
  const seq = parts[1] || "0";
  const keyBase = group + "/" + seq;
  const start = Date.now();
  await c.send(new PutObjectCommand({{
    Bucket: process.env.BUCKET, Key: "start/" + keyBase, Body: String(start),
  }}));
  await new Promise((r) => setTimeout(r, {SLEEP_MS}));
  await c.send(new PutObjectCommand({{
    Bucket: process.env.BUCKET, Key: "end/" + keyBase, Body: String(Date.now()),
  }}));
}};
"""
    zip_bytes = zip_js(handler)
    lam.create_function(
        FunctionName=FN,
        Runtime="nodejs20.x",
        Role=role_arn,
        Handler="index.handler",
        Code={"ZipFile": zip_bytes},
        Timeout=60,
        Environment={"Variables": {"BUCKET": BUCKET}},
    )
    fns.append(FN)
    wait_active(FN)

    dlq = sqs.create_queue(
        QueueName=DLQ_NAME,
        Attributes={"FifoQueue": "true", "ContentBasedDeduplication": "true"},
    )["QueueUrl"]
    qurls.append(dlq)
    dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq, AttributeNames=["QueueArn"])["Attributes"][
        "QueueArn"
    ]
    q = sqs.create_queue(
        QueueName=Q_NAME,
        Attributes={
            "FifoQueue": "true",
            "ContentBasedDeduplication": "true",
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
        FunctionName=FN,
        EventSourceArn=qarn,
        BatchSize=1,
        Enabled=True,
        ScalingConfig={"MaximumConcurrency": MC},
    )
    uuids.append(mapping["UUID"])

    expected = len(GROUPS) * PER_GROUP
    for group in GROUPS:
        for seq in range(PER_GROUP):
            sqs.send_message(
                QueueUrl=q,
                MessageBody=f"{group}:{seq}",
                MessageGroupId=group,
            )

    deadline = time.time() + 180
    ends = 0
    while time.time() < deadline:
        ends = len(s3.list_objects_v2(Bucket=BUCKET, Prefix="end/").get("Contents") or [])
        if ends >= expected:
            break
        time.sleep(2)
    if ends < expected:
        fail(f"expected {expected} completed invocations, got {ends}")

    def read_markers(prefix: str) -> dict[str, dict[str, int]]:
        out: dict[str, dict[str, int]] = {g: {} for g in GROUPS}
        for obj in s3.list_objects_v2(Bucket=BUCKET, Prefix=prefix).get("Contents") or []:
            key = obj["Key"]  # start/A/0
            parts = key.split("/")
            if len(parts) != 3:
                continue
            _, group, seq_s = parts
            if group not in out:
                continue
            body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode()
            out[group][int(seq_s)] = int(body)
        return out

    starts = read_markers("start/")
    ends_m = read_markers("end/")

    intervals: list[tuple[int, int]] = []
    for group in GROUPS:
        if set(starts[group]) != set(range(PER_GROUP)):
            fail(f"group {group}: missing start markers {starts[group]}")
        if set(ends_m[group]) != set(range(PER_GROUP)):
            fail(f"group {group}: missing end markers {ends_m[group]}")
        ordered_starts = [starts[group][i] for i in range(PER_GROUP)]
        if ordered_starts != sorted(ordered_starts):
            fail(
                f"group {group}: start times out of send order: "
                f"{list(enumerate(ordered_starts))}"
            )
        for i in range(PER_GROUP):
            s_ms = starts[group][i]
            e_ms = ends_m[group][i]
            if e_ms < s_ms:
                fail(f"group {group} seq {i}: end before start")
            intervals.append((s_ms, e_ms))
            if i + 1 < PER_GROUP:
                next_start = starts[group][i + 1]
                if next_start < e_ms:
                    fail(
                        f"group {group}: seq {i + 1} started at {next_start} "
                        f"before seq {i} ended at {e_ms} (FIFO group overlap)"
                    )
        ok(f"group {group}: {PER_GROUP} msgs serial + in order")

    events: list[tuple[int, int]] = []
    for s_ms, e_ms in intervals:
        events.append((s_ms, 1))
        events.append((e_ms, -1))
    events.sort(key=lambda x: (x[0], x[1]))
    cur = 0
    peak = 0
    for _, delta in events:
        cur += delta
        if cur > peak:
            peak = cur
    if peak > MC:
        fail(f"in-flight peak {peak} exceeded MaximumConcurrency={MC}")
    if peak < 2:
        fail(
            f"expected cross-group concurrency ≥ 2 under MaximumConcurrency={MC}, got peak={peak}"
        )
    ok(f"cross-group peak in-flight={peak} (2..{MC})")

    dlq_attrs = sqs.get_queue_attributes(
        QueueUrl=dlq,
        AttributeNames=[
            "ApproximateNumberOfMessages",
            "ApproximateNumberOfMessagesNotVisible",
        ],
    )["Attributes"]
    dlq_n = int(dlq_attrs.get("ApproximateNumberOfMessages", "0")) + int(
        dlq_attrs.get("ApproximateNumberOfMessagesNotVisible", "0")
    )
    if dlq_n > 0:
        fail(f"DLQ not empty: {dlq_n}")

    ok("sqs-lambda-fifo-esm-mc-smoke")
finally:
    cleanup()
PY
