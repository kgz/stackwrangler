#!/usr/bin/env bash
# Start an Open Design run attached to a project conversation (visible in OD UI).
#
# Usage:
#   ./bin/od-design-run.sh --issue 4 "Design AWS console frame…"
#   ./bin/od-design-run.sh --new-conversation "#4 Console shell" "Design ..."
#   ./bin/od-design-run.sh -f prompt.md
#
# Env (optional):
#   OD_PROJECT          default: 2ce89424-6266-4cc3-a273-3b68c3049183 (awsbox-console)
#   OD_CONVERSATION     default: main project conversation
#   OD_DAEMON_URL       default: http://127.0.0.1:7456
#   OD_WEB_URL          default: http://127.0.0.1:7456
#   OD_AGENT_ID         default: cursor-agent
#   OD_MODEL            default: auto
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${OD_PROJECT:-2ce89424-6266-4cc3-a273-3b68c3049183}"
CONVERSATION="${OD_CONVERSATION:-eb1c88fa-e9f5-4667-829a-9044c48f472c}"
DAEMON="${OD_DAEMON_URL:-http://127.0.0.1:7456}"
WEB="${OD_WEB_URL:-http://127.0.0.1:7456}"
AGENT="${OD_AGENT_ID:-cursor-agent}"
MODEL="${OD_MODEL:-auto}"

ISSUE=""
NEW_CONV_TITLE=""
PROMPT_FILE=""
PROMPT=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--issue)
			ISSUE="${2:?}"
			shift 2
			;;
		--new-conversation)
			NEW_CONV_TITLE="${2:?}"
			shift 2
			;;
		-f|--file)
			PROMPT_FILE="${2:?}"
			shift 2
			;;
		-h|--help)
			sed -n '2,20p' "$0"
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
		*)
			break
			;;
	esac
done

if [[ -n "$PROMPT_FILE" ]]; then
	PROMPT="$(cat "$PROMPT_FILE")"
elif [[ $# -gt 0 ]]; then
	PROMPT="$*"
else
	echo "Provide a prompt message or -f prompt.md" >&2
	exit 1
fi

if ! curl -sf --max-time 2 "$DAEMON/api/daemon/status" >/dev/null; then
	echo "Open Design daemon not reachable at $DAEMON" >&2
	echo "Start it: cd ~/tools/open-design/deploy && docker compose -f docker-compose.yml -f docker-compose.wsl.yml up -d" >&2
	exit 1
fi

if [[ -n "$NEW_CONV_TITLE" ]]; then
	CONVERSATION="$(
		curl -sf -X POST "$DAEMON/api/projects/$PROJECT/conversations" \
			-H 'Content-Type: application/json' \
			-d "$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "sessionMode": "design"}))' "$NEW_CONV_TITLE")" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["conversation"]["id"])'
	)"
	echo "Created conversation: $CONVERSATION"
fi

if [[ -n "$ISSUE" ]]; then
	"$ROOT/bin/board-status.sh" designing "$ISSUE"
fi

response="$(
	PROMPT="$PROMPT" PROJECT="$PROJECT" CONVERSATION="$CONVERSATION" AGENT="$AGENT" MODEL="$MODEL" DAEMON="$DAEMON" python3 <<'PY'
import json
import os
import time
import uuid
from urllib import request

prompt = os.environ["PROMPT"]
project = os.environ["PROJECT"]
conversation = os.environ["CONVERSATION"]
agent = os.environ["AGENT"]
model = os.environ.get("MODEL", "").strip()
daemon = os.environ["DAEMON"]
now = int(time.time() * 1000)

user_message_id = str(uuid.uuid4())
assistant_message_id = str(uuid.uuid4())

def api(method: str, path: str, body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode()
    req = request.Request(
        f"{daemon}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if body is not None else {},
    )
    with request.urlopen(req) as resp:
        return json.loads(resp.read().decode())

api(
    "PUT",
    f"/api/projects/{project}/conversations/{conversation}/messages/{user_message_id}",
    {"role": "user", "content": prompt, "createdAt": now},
)
api(
    "PUT",
    f"/api/projects/{project}/conversations/{conversation}/messages/{assistant_message_id}",
    {
        "role": "assistant",
        "content": "",
        "agentId": agent,
        "agentName": agent,
        "runStatus": "queued",
        "startedAt": now,
        "createdAt": now,
    },
)

run_body = {
    "projectId": project,
    "conversationId": conversation,
    "assistantMessageId": assistant_message_id,
    "message": prompt,
    "currentPrompt": prompt,
    "agentId": agent,
}
if model:
    run_body["model"] = model

run = api(
    "POST",
    "/api/runs",
    run_body,
)

api(
    "PUT",
    f"/api/projects/{project}/conversations/{conversation}/messages/{assistant_message_id}",
    {
        "agentId": agent,
        "runId": run["runId"],
        "runStatus": "queued",
        "createdAt": now,
    },
)

print(json.dumps({"runId": run["runId"], "conversationId": run.get("conversationId") or conversation}))
PY
)"

run_id="$(echo "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["runId"])')"
conv_id="$(echo "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("conversationId") or "")')"

watch_url="$WEB/projects/$PROJECT/conversations/${conv_id:-$CONVERSATION}"

echo "Run started: $run_id"
echo "Model:       $MODEL"
echo "Watch live:  $watch_url"
echo "Project:     $PROJECT"
echo "Conversation: ${conv_id:-$CONVERSATION}"
