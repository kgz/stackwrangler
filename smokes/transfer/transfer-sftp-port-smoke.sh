#!/usr/bin/env bash
# awsbox up drops a leftover compose sftp container on the emulator port (#371)
# and stops, before compose, when something else holds that port.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
# shellcheck disable=SC1091
source "$ROOT/bin/awsbox"

PREFIX="awsbox-371-sftp-port"
NAMES=(
	"$PREFIX-other"
	"$PREFIX-localstack-1"
	"$PREFIX-sftp-1"
	"$PREFIX-foreign"
	"$PREFIX-wrong-image"
	"$PREFIX-ours"
)
PY_PID=""
CHECK_OUT=""
CHECK_RC=0

cleanup() {
	[[ -n "$PY_PID" ]] && kill "$PY_PID" >/dev/null 2>&1 || true
	docker rm -f "${NAMES[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

die() {
	echo "transfer-sftp-port-smoke: $*" >&2
	[[ -n "$CHECK_OUT" ]] && printf '%s\n' "$CHECK_OUT" >&2
	exit 1
}

pick_port() {
	local p="$1" n
	for n in $(seq 0 40); do
		if ! ss -H -ltn "sport = :$p" 2>/dev/null | grep -q . \
			&& ! docker ps --format '{{.Ports}}' | grep -q "127.0.0.1:${p}->"; then
			printf '%s\n' "$p"
			return 0
		fi
		p=$((p + 1))
	done
	die "no free port from $1"
}

wait_published() {
	local name="$1" port="$2" i
	for i in $(seq 1 25); do
		if docker inspect --format '{{json .NetworkSettings.Ports}}' "$name" | grep -q "\"HostPort\":\"${port}\""; then
			return 0
		fi
		sleep 0.1
	done
	die "port ${port} not published on ${name}"
}

run_holder() {
	local name="$1" port="$2"
	shift 2
	docker run -d --name "$name" --pull=never -p "127.0.0.1:${port}:9" "$@" alpine:3.20 sleep 300 >/dev/null
	wait_published "$name" "$port"
}

run_atmoz() {
	local name="$1" port="$2"
	shift 2
	docker run -d --name "$name" --pull=never -p "127.0.0.1:${port}:22" "$@" atmoz/sftp:alpine smoke:smokepass:1001:1001:upload >/dev/null
	wait_published "$name" "$port"
}

call_check() {
	local port="$1"
	set +e
	CHECK_OUT="$(AWSBOX_SFTP_HOST_PORT="$port" free_sftp_host_port 2>&1)"
	CHECK_RC=$?
	set -e
}

assert_rc() {
	local want="$1"
	[[ "$CHECK_RC" -eq "$want" ]] || die "exit ${CHECK_RC}, want ${want}"
}

assert_grep() {
	local pat="$1"
	grep -q -e "$pat" <<<"$CHECK_OUT" || die "missing /${pat}/"
}

running() {
	docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx true
}

gone() {
	if docker inspect "$1" >/dev/null 2>&1; then
		die "expected ${1} to be removed"
	fi
}

got="$(
	ROOT="$(mktemp -d)"
	printf 'AWSBOX_SFTP_HOST_PORT=23111\n' >"$ROOT/.env"
	unset AWSBOX_SFTP_HOST_PORT
	sftp_host_port
	rm -rf "$ROOT"
)"
[[ "$got" == "23111" ]] || die "sftp_host_port from .env got ${got}"

port="$(pick_port 22971)"
run_holder "$PREFIX-other" "$port"
call_check "$port"
assert_rc 1
assert_grep "$PREFIX-other"
assert_grep "AWSBOX_SFTP_HOST_PORT"
assert_grep "Created"
running "$PREFIX-other" || die "other holder was removed"
docker rm -f "$PREFIX-other" >/dev/null

port="$(pick_port "$port")"
run_holder "$PREFIX-localstack-1" "$port" --label com.docker.compose.service=localstack
call_check "$port"
assert_rc 0
running "$PREFIX-localstack-1" || die "localstack holder was removed"
docker rm -f "$PREFIX-localstack-1" >/dev/null

OUR_PROJECT="$(compose_project_name)"
[[ -n "$OUR_PROJECT" ]] || die "compose project name"
[[ "$OUR_PROJECT" != "other-project" ]] || die "unexpected compose project name"

port="$(pick_port "$port")"
run_holder "$PREFIX-sftp-1" "$port"
call_check "$port"
assert_rc 1
assert_grep "$PREFIX-sftp-1"
assert_grep "Created"
running "$PREFIX-sftp-1" || die "name-only sftp container was removed"
docker rm -f "$PREFIX-sftp-1" >/dev/null

port="$(pick_port "$port")"
run_atmoz "$PREFIX-foreign" "$port" \
	--label com.docker.compose.service=sftp \
	--label com.docker.compose.project=other-project
call_check "$port"
assert_rc 1
assert_grep "$PREFIX-foreign"
running "$PREFIX-foreign" || die "other project's sftp container was removed"
docker rm -f "$PREFIX-foreign" >/dev/null

port="$(pick_port "$port")"
run_holder "$PREFIX-wrong-image" "$port" \
	--label com.docker.compose.service=sftp \
	--label com.docker.compose.project="$OUR_PROJECT"
call_check "$port"
assert_rc 1
assert_grep "$PREFIX-wrong-image"
running "$PREFIX-wrong-image" || die "non-atmoz sftp container was removed"
docker rm -f "$PREFIX-wrong-image" >/dev/null

port="$(pick_port "$port")"
run_atmoz "$PREFIX-ours" "$port" \
	--label com.docker.compose.service=sftp \
	--label com.docker.compose.project="$OUR_PROJECT"
call_check "$port"
assert_rc 0
assert_grep "removing leftover sftp container ${PREFIX}-ours"
gone "$PREFIX-ours"

keep_port="$(pick_port $((port + 1)))"
run_atmoz "$PREFIX-ours" "$keep_port" \
	--label com.docker.compose.service=sftp \
	--label com.docker.compose.project="$OUR_PROJECT"
emu_port="$(pick_port $((keep_port + 1)))"
call_check "$emu_port"
assert_rc 0
running "$PREFIX-ours" || die "this project's sftp on another port was removed"
docker rm -f "$PREFIX-ours" >/dev/null

py_port="$(pick_port $((emu_port + 1)))"
python3 - "$py_port" <<'PY' &
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
time.sleep(60)
PY
PY_PID=$!
for _ in $(seq 1 25); do
	if ss -H -ltn "sport = :${py_port}" 2>/dev/null | grep -q .; then
		break
	fi
	sleep 0.1
done
ss -H -ltn "sport = :${py_port}" 2>/dev/null | grep -q . || die "python did not bind ${py_port}"
call_check "$py_port"
assert_rc 1
assert_grep "${py_port}"
assert_grep "AWSBOX_SFTP_HOST_PORT"
kill "$PY_PID" >/dev/null 2>&1 || true
PY_PID=""

echo "transfer-sftp-port-smoke: ok"
