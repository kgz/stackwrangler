#!/usr/bin/env bash
# ECS awsvpc + official PHP image: AWS SDK for PHP trusts injected https
# AWS_ENDPOINT_URL via PHP_INI_SCAN_DIR / zz-awsbox-ca.ini (#771). No CA baked
# into the image — only the SDK for the probe.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
CLUSTER="awsbox-ecs-php-ca-${TS}"
FAMILY="awsbox-ecs-php-ca-${TS}"
ROLE="awsbox-ecs-php-ca-${TS}"
TABLE="awsbox_ecs_php_ca_${TS}"
KEEP="${AWSBOX_PHP_CA_KEEP:-0}"
IMAGE="awsbox-ecs-php-ca:${TS}"
TMP="$(mktemp -d)"
TASK_ARN=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && { rm -rf "$TMP"; return 0; }
	if [[ -n "$TASK_ARN" ]]; then
		aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	fi
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name allow-ddb >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
	docker rmi "$IMAGE" >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Official PHP CLI + SDK only (no CA / php.ini overrides in the image).
cat >"$TMP/Dockerfile" <<'EOF'
FROM php:8.3-cli
RUN apt-get update && apt-get install -y --no-install-recommends git unzip \
	&& rm -rf /var/lib/apt/lists/* \
	&& curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
WORKDIR /app
RUN composer require aws/aws-sdk-php:^3.300 --no-interaction
COPY probe.php /app/probe.php
EOF

cat >"$TMP/probe.php" <<'EOF'
<?php
require '/app/vendor/autoload.php';

use Aws\DynamoDb\DynamoDbClient;
use Aws\Exception\AwsException;

$endpoint = getenv('AWS_ENDPOINT_URL') ?: '';
$scan = getenv('PHP_INI_SCAN_DIR') ?: '';
$cainfo = (string) ini_get('curl.cainfo');
$cafile = (string) ini_get('openssl.cafile');

$out = [
	'endpoint' => $endpoint,
	'phpIniScan' => $scan,
	'curlCainfo' => $cainfo,
	'opensslCafile' => $cafile,
];

if (!str_starts_with($endpoint, 'https://')) {
	fwrite(STDERR, 'FAIL: AWS_ENDPOINT_URL not https: ' . $endpoint . "\n");
	exit(2);
}
if (!str_contains($scan, '/etc/awsbox/php')) {
	fwrite(STDERR, 'FAIL: PHP_INI_SCAN_DIR missing /etc/awsbox/php: ' . $scan . "\n");
	exit(2);
}
if (!str_contains($cainfo, 'ca-bundle.crt') || !str_contains($cafile, 'ca-bundle.crt')) {
	fwrite(STDERR, 'FAIL: php.ini CA paths unset: curl.cainfo=' . $cainfo . ' openssl.cafile=' . $cafile . "\n");
	exit(2);
}

$table = getenv('PROBE_TABLE') ?: '';
// Endpoint comes from injected AWS_ENDPOINT_URL; pass explicitly so older
// SDK minors still dial https (CA trust is what we are proving).
$client = new DynamoDbClient([
	'version' => 'latest',
	'region' => getenv('AWS_REGION') ?: getenv('AWS_DEFAULT_REGION') ?: 'us-east-1',
	'endpoint' => $endpoint,
]);

try {
	$result = $client->getItem([
		'TableName' => $table,
		'Key' => ['pk' => ['S' => 'probe']],
	]);
	$val = $result['Item']['payload']['S'] ?? '';
	if ($val !== 'php-ca-ok') {
		fwrite(STDERR, 'FAIL: unexpected item: ' . json_encode($result->toArray()) . "\n");
		exit(3);
	}
	$out['ok'] = true;
	$out['payload'] = $val;
	echo json_encode($out), "\n";
	exit(0);
} catch (AwsException $e) {
	fwrite(STDERR, 'FAIL: DynamoDB GetItem: ' . $e->getMessage() . "\n");
	exit(4);
} catch (Throwable $e) {
	fwrite(STDERR, 'FAIL: ' . $e->getMessage() . "\n");
	exit(5);
}
EOF

echo "Building $IMAGE (php:8.3-cli + aws-sdk-php)…"
docker build -t "$IMAGE" "$TMP" >/dev/null

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name allow-ddb --policy-document "$(TABLE="$TABLE" REGION="$REGION" python3 -c '
import json, os
t, r = os.environ["TABLE"], os.environ["REGION"]
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["dynamodb:GetItem"],
    "Resource": f"arn:aws:dynamodb:{r}:*:table/{t}",
  }],
}))
')" >/dev/null

aws dynamodb create-table \
	--table-name "$TABLE" \
	--attribute-definitions AttributeName=pk,AttributeType=S \
	--key-schema AttributeName=pk,KeyType=HASH \
	--billing-mode PAY_PER_REQUEST >/dev/null

st=""
for _ in $(seq 1 30); do
	st="$(aws dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
[[ "$st" == "ACTIVE" ]] || fail "table not ACTIVE"

aws dynamodb put-item \
	--table-name "$TABLE" \
	--item '{"pk":{"S":"probe"},"payload":{"S":"php-ca-ok"}}' >/dev/null

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

CDEFS="$(IMAGE="$IMAGE" TABLE="$TABLE" python3 -c '
import json, os
print(json.dumps([{
  "name": "probe",
  "image": os.environ["IMAGE"],
  "essential": True,
  "memory": 256,
  "environment": [{"name": "PROBE_TABLE", "value": os.environ["TABLE"]}],
  "command": ["php", "/app/probe.php"],
}]))
')"

aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities FARGATE \
	--network-mode awsvpc \
	--cpu 256 --memory 512 \
	--task-role-arn "$ROLE_ARN" \
	--container-definitions "$CDEFS" \
	>/dev/null

SUBNET="$(aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text)"
SG="$(aws ec2 describe-security-groups --query 'SecurityGroups[0].GroupId' --output text)"
[[ -n "$SUBNET" && "$SUBNET" != "None" && -n "$SG" && "$SG" != "None" ]] || {
	fail "need at least one subnet + security group (run ./smokes/compute/ecs-smoke.sh once)"
}
NET="awsvpcConfiguration={subnets=[${SUBNET}],securityGroups=[${SG}],assignPublicIp=ENABLED}"

TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type FARGATE \
		--network-configuration "$NET" \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || fail "RunTask returned no taskArn"
echo "TASK_ARN=${TASK_ARN}"

NAME=""
for _ in $(seq 1 90); do
	NAME="$(docker ps -a --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1)"
	[[ -n "$NAME" ]] && break
	sleep 1
done
[[ -n "$NAME" ]] || fail "task container not found"

running="true"
exit_code=""
for _ in $(seq 1 120); do
	exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null || true)"
	running="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || true)"
	if [[ "$running" == "false" ]]; then
		break
	fi
	sleep 1
done
LOGS="$(docker logs "$NAME" 2>&1 || true)"
echo "ProbeLogs<<EOF"
echo "$LOGS"
echo "EOF"
[[ "$running" == "false" ]] || fail "probe still running"
[[ "$exit_code" == "0" ]] || fail "probe exit=${exit_code}"
echo "$LOGS" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' \
	|| fail "probe JSON missing ok"
echo "$LOGS" | grep -q 'php-ca-ok' || fail "probe missing payload"

echo "OK: ecs php endpoint CA (#771)"
