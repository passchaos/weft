#!/usr/bin/env bash
# External-client interoperability smoke test.
#
# The script builds the minimal hello servers and drives them with curl and,
# when available, nghttp. Missing optional clients are reported as SKIP rather
# than failing the run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

HTTP1_PORT="${WEFT_HTTP1_PORT:-28081}"
H2C_PORT="${WEFT_H2C_PORT:-28082}"
PIDS=()

cleanup() {
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

skip() {
    printf 'SKIP: %s\n' "$*"
}

wait_for_port() {
    local port="$1"
    local attempts=100
    while (( attempts > 0 )); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
            exec 3>&- 2>/dev/null || true
            return 0
        fi
        sleep 0.05
        attempts=$((attempts - 1))
    done
    return 1
}

echo "== build hello servers =="
zig build build-hello-server build-h2-hello-server -Doptimize=ReleaseFast

echo "== start HTTP/1.1 and h2c servers =="
WEFT_PORT="$HTTP1_PORT" ./zig-out/bin/hello-server &
PIDS+=("$!")
WEFT_PORT="$H2C_PORT" ./zig-out/bin/h2-hello-server &
PIDS+=("$!")

wait_for_port "$HTTP1_PORT" || fail "HTTP/1.1 server did not start"
wait_for_port "$H2C_PORT" || fail "h2c server did not start"

echo "== curl HTTP/1.1 =="
body="$(curl -fsS "http://127.0.0.1:${HTTP1_PORT}/")"
[[ "$body" == "Hello, World!" ]] || fail "unexpected HTTP/1.1 body: $body"
echo "PASS: curl HTTP/1.1"

echo "== curl h2c prior knowledge =="
if curl --http2-prior-knowledge -fsS "http://127.0.0.1:${H2C_PORT}/" >/tmp/weft-h2c-body 2>/tmp/weft-h2c-err; then
    body="$(cat /tmp/weft-h2c-body)"
    [[ "$body" == "Hello, World!" ]] || fail "unexpected h2c body: $body"
    echo "PASS: curl h2c"
else
    skip "curl does not support --http2-prior-knowledge ($(head -1 /tmp/weft-h2c-err 2>/dev/null || true))"
fi

echo "== nghttp h2c =="
if command -v nghttp >/dev/null 2>&1; then
    timeout 10 nghttp -v "http://127.0.0.1:${H2C_PORT}/" >/tmp/weft-nghttp 2>&1 || {
        cat /tmp/weft-nghttp >&2
        fail "nghttp request failed"
    }
    grep -q "Hello, World!" /tmp/weft-nghttp || fail "nghttp did not receive the expected body"
    echo "PASS: nghttp h2c"
else
    skip "nghttp is not installed"
fi

echo "== h2spec h2c =="
if command -v h2spec >/dev/null 2>&1; then
    if h2spec -h 127.0.0.1 -p "$H2C_PORT" --timeout 2 >/tmp/weft-h2spec 2>&1; then
        echo "PASS: h2spec"
    else
        tail -40 /tmp/weft-h2spec >&2
        fail "h2spec reported failures"
    fi
else
    skip "h2spec is not installed"
fi

echo "== HTTP/3 =="
if command -v curl >/dev/null 2>&1 && curl --version | grep -qi 'HTTP3'; then
    skip "no HTTP/3 hello server is built by this script yet"
else
    skip "curl has no HTTP/3 support and no HTTP/3 client is installed"
fi

echo "interop smoke test complete"
