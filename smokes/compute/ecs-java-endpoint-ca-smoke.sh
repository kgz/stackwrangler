#!/usr/bin/env bash
# ECS awsvpc + official JDK image: AWS SDK for Java trusts injected https
# AWS_ENDPOINT_URL via JAVA_TOOL_OPTIONS PKCS12 truststore (#771). No CA baked
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
CLUSTER="awsbox-ecs-java-ca-${TS}"
FAMILY="awsbox-ecs-java-ca-${TS}"
ROLE="awsbox-ecs-java-ca-${TS}"
TABLE="awsbox_ecs_java_ca_${TS}"
KEEP="${AWSBOX_JAVA_CA_KEEP:-0}"
IMAGE="awsbox-ecs-java-ca:${TS}"
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

# Maven resolves the AWS SDK graph; image still has no LocalEmu CA / truststore.
cat >"$TMP/pom.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
	xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
	xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
	<modelVersion>4.0.0</modelVersion>
	<groupId>awsbox.smoke</groupId>
	<artifactId>ecs-java-ca</artifactId>
	<version>1.0</version>
	<properties>
		<maven.compiler.release>17</maven.compiler.release>
		<project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
		<aws.sdk.version>2.29.45</aws.sdk.version>
	</properties>
	<dependencies>
		<dependency>
			<groupId>software.amazon.awssdk</groupId>
			<artifactId>dynamodb</artifactId>
			<version>${aws.sdk.version}</version>
		</dependency>
		<dependency>
			<groupId>software.amazon.awssdk</groupId>
			<artifactId>apache-client</artifactId>
			<version>${aws.sdk.version}</version>
		</dependency>
	</dependencies>
	<build>
		<plugins>
			<plugin>
				<groupId>org.apache.maven.plugins</groupId>
				<artifactId>maven-jar-plugin</artifactId>
				<version>3.4.2</version>
				<configuration>
					<archive>
						<manifest>
							<mainClass>Probe</mainClass>
						</manifest>
					</archive>
				</configuration>
			</plugin>
			<plugin>
				<groupId>org.apache.maven.plugins</groupId>
				<artifactId>maven-shade-plugin</artifactId>
				<version>3.6.0</version>
				<executions>
					<execution>
						<phase>package</phase>
						<goals><goal>shade</goal></goals>
						<configuration>
							<createDependencyReducedPom>false</createDependencyReducedPom>
							<transformers>
								<transformer implementation="org.apache.maven.plugins.shade.resource.ManifestResourceTransformer">
									<mainClass>Probe</mainClass>
								</transformer>
							</transformers>
						</configuration>
					</execution>
				</executions>
			</plugin>
		</plugins>
	</build>
</project>
EOF

mkdir -p "$TMP/src/main/java"
cat >"$TMP/src/main/java/Probe.java" <<'EOF'
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemResponse;
import java.net.URI;
import java.util.Map;

public class Probe {
  public static void main(String[] args) {
    String endpoint = System.getenv().getOrDefault("AWS_ENDPOINT_URL", "");
    String javaOpts = System.getenv().getOrDefault("JAVA_TOOL_OPTIONS", "");
    if (!endpoint.startsWith("https://")) {
      System.err.println("FAIL: AWS_ENDPOINT_URL not https: " + endpoint);
      System.exit(2);
    }
    if (!javaOpts.contains("trustStore=/etc/awsbox/certs/truststore.p12")) {
      System.err.println("FAIL: JAVA_TOOL_OPTIONS missing trustStore: " + javaOpts);
      System.exit(2);
    }
    String table = System.getenv().getOrDefault("PROBE_TABLE", "");
    String region = System.getenv().getOrDefault("AWS_REGION",
        System.getenv().getOrDefault("AWS_DEFAULT_REGION", "us-east-1"));
    String rel = System.getenv().getOrDefault("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "");
    String full = System.getenv().getOrDefault("AWS_CONTAINER_CREDENTIALS_FULL_URI", "");
    if (rel.isEmpty() && full.isEmpty()) {
      System.err.println("FAIL: no container credentials URI in env");
      System.exit(2);
    }
    // Dial injected AWS_ENDPOINT_URL explicitly; truststore is what we prove.
    // Retry briefly — task-role creds endpoint can lag container start.
    Exception last = null;
    for (int i = 0; i < 30; i++) {
      try (DynamoDbClient client = DynamoDbClient.builder()
          .region(Region.of(region))
          .endpointOverride(URI.create(endpoint))
          .build()) {
        GetItemResponse resp = client.getItem(GetItemRequest.builder()
            .tableName(table)
            .key(Map.of("pk", AttributeValue.builder().s("probe").build()))
            .build());
        AttributeValue payload = resp.item().get("payload");
        String val = payload == null ? "" : payload.s();
        if (!"java-ca-ok".equals(val)) {
          System.err.println("FAIL: unexpected item payload: " + val);
          System.exit(3);
        }
        System.out.println("{\"ok\":true,\"payload\":\"" + val + "\",\"endpoint\":\"" + endpoint + "\"}");
        return;
      } catch (Exception e) {
        last = e;
        String msg = String.valueOf(e.getMessage());
        if (!msg.contains("credentials") && !msg.contains("Credentials")) {
          break;
        }
        try { Thread.sleep(1000); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); }
      }
    }
    System.err.println("FAIL: DynamoDB GetItem: " + last);
    if (last != null) last.printStackTrace(System.err);
    System.err.println("credRel=" + rel + " credFull=" + full);
    System.exit(4);
  }
}
EOF

cat >"$TMP/Dockerfile" <<'EOF'
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package

FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /src/target/ecs-java-ca-1.0.jar /app/probe.jar
EOF

echo "Building $IMAGE (eclipse-temurin + aws sdk shade)…"
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
	--item '{"pk":{"S":"probe"},"payload":{"S":"java-ca-ok"}}' >/dev/null

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

CDEFS="$(IMAGE="$IMAGE" TABLE="$TABLE" python3 -c '
import json, os
print(json.dumps([{
  "name": "probe",
  "image": os.environ["IMAGE"],
  "essential": True,
  "memory": 512,
  "environment": [{"name": "PROBE_TABLE", "value": os.environ["TABLE"]}],
  "command": ["java", "-jar", "/app/probe.jar"],
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
for _ in $(seq 1 180); do
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
echo "$LOGS" | grep -q 'java-ca-ok' || fail "probe missing payload"

echo "OK: ecs java endpoint CA (#771)"
