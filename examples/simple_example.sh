#!/usr/bin/env bash
# Simple example: compile, build the release, serve one stdio MCP upstream,
# and exercise the full path over HTTP. Every step is asserted; any failure
# stops the script with exit code 1.

set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
bin="$root/_build/prod/rel/mcp_gateway/bin/mcp_gateway"
log=/tmp/mcp_gateway_example.log
port="${PORT:-4400}"
url="http://localhost:$port/mcp"

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  [ -f "$log" ] && tail -5 "$log"
  exit 1
}

echo "== compile (dev, test, prod) with warnings as errors"
for env in dev test prod; do
  MIX_ENV=$env mix compile --warnings-as-errors > /dev/null || fail "compile $env"
done
pass "compile"

echo "== build release"
rel_out=$(MIX_ENV=prod mix release --overwrite 2>&1) || { echo "$rel_out" | tail -5; fail "release build"; }
pass "release build"

echo "== start release on port $port with one elixir stdio upstream"
export PORT=$port
export MCP_UPSTREAMS="[{\"name\":\"echo\",\"command\":\"elixir\",\"args\":[\"$root/priv/fake_mcp_server.exs\"]}]"
"$bin" start > "$log" 2>&1 &
gw=$!
trap 'kill $gw 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  curl -s --connect-timeout 1 --max-time 2 -o /dev/null "http://localhost:$port/health" && break
  sleep 1
done
curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://localhost:$port/health" | grep -q 200 \
  || fail "health endpoint"
pass "release boot (this exercises the child-PATH fix: a release-spawned elixir upstream)"

echo "== initialize: session id and protocol version"
session=$(curl -s --max-time 15 -D - -o "$log.init.json" -X POST "$url" \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"example","version":"0"}}}' \
  | tr -d '\r' | grep -i '^mcp-session-id' | awk '{print $2}')
[ -n "$session" ] || fail "initialize produced no session id"
jq -e '.result.protocolVersion == "2025-03-26"' < "$log.init.json" > /dev/null || fail "initialize result"
pass "initialize + Mcp-Session-Id"

echo "== tools/list: gateway queues until the upstream handshake completes"
curl -s --max-time 30 -X POST "$url" -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H "Mcp-Session-Id: $session" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq -e '[.result.tools[].name] | index("echo__echo")' > /dev/null || fail "tools/list"
pass "tools/list (namespaced echo__echo)"

echo "== tools/call: JSON-RPC routed to the stdio upstream and back"
curl -s --max-time 15 -X POST "$url" -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H "Mcp-Session-Id: $session" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo__echo","arguments":{"text":"simple example"}}}' \
  | jq -e '.result.content[0].text == "echo:echo:simple example"' > /dev/null || fail "tools/call"
pass "tools/call round trip"

echo "== SSE negotiation when the client accepts event-stream"
curl -s --max-time 15 -X POST "$url" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Mcp-Session-Id: $session" -d '{"jsonrpc":"2.0","id":4,"method":"ping"}' \
  | grep -q '^event: message' || fail "SSE framing"
pass "SSE response"

echo "== notifications return 202"
code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST "$url" \
  -H 'Content-Type: application/json' -H "Mcp-Session-Id: $session" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')
[ "$code" = "202" ] || fail "notification expected 202, got $code"
pass "202 notification"

echo "== DELETE terminates the session; later calls get 404"
code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X DELETE "$url" -H "Mcp-Session-Id: $session")
[ "$code" = "200" ] || fail "DELETE expected 200, got $code"
code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST "$url" \
  -H 'Content-Type: application/json' -H "Mcp-Session-Id: $session" -d '{"jsonrpc":"2.0","id":5,"method":"ping"}')
[ "$code" = "404" ] || fail "post-DELETE expected 404, got $code"
pass "session termination"

kill $gw
trap - EXIT
rm -f "$log.init.json"
echo
echo "ALL STEPS PASSED - release build, boot, handshake, call, SSE, sessions."
