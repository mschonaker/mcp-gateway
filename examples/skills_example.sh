#!/usr/bin/env bash
# Skills extension (SEP-2640) walkthrough. Self-contained: starts its own
# gateway on :4410 with the skills-enabled echo upstream, asserts every step,
# and stops. Needs only a clone plus elixir on PATH.
# Usage: bash examples/skills_example.sh   (override port with PORT=...)

set -euo pipefail
cd "$(dirname "$0")/.."

port="${PORT:-4410}"
url="http://localhost:$port/mcp"
ct='Content-Type: application/json'
ac='Accept: application/json'
log=/tmp/mcp_skills_gw.log

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; tail -5 "$log" 2>/dev/null; exit 1; }

export PORT="$port"
export MCP_UPSTREAMS="[{\"name\":\"echo\",\"command\":\"elixir\",\"args\":[\"$(pwd)/priv/fake_mcp_server.exs\"]}]"

mix run --no-halt > "$log" 2>&1 &
gw=$!
trap 'kill $gw 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  curl -sf --connect-timeout 1 --max-time 2 -o /dev/null "http://localhost:$port/health" && break
  sleep 1
done

post() {
  curl -s --max-time 30 -X POST "$url" -H "$ct" -H "$ac" -H "Mcp-Session-Id: $session" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"$2\",\"params\":$3}"
}

session=$(curl -s --max-time 20 -D - -o /tmp/mcp_skills_init.json -X POST "$url" -H "$ct" -H "$ac" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"example","version":"0"}}}' \
  | tr -d '\r' | grep -i '^mcp-session-id' | awk '{print $2}')
[ -n "$session" ] || fail "initialize: no session id"

echo "== 1. initialize advertises the extension because the echo upstream serves skills"
jq -e '.result.capabilities.extensions["io.modelcontextprotocol/skills"]' /tmp/mcp_skills_init.json > /dev/null || fail "extension not advertised"
pass "capability advertisement"

echo "== 2. skills/list: namespaced URI + manifest with digests (queues through handshake)"
post 2 skills/list '{}' > /tmp/mcp_skills_list.json
jq -e '.result.skills[0].uri == "skill://echo__greet/SKILL.md"' /tmp/mcp_skills_list.json > /dev/null || fail "skills/list uri"
jq -e '[.result.skills[0].resources[].digest] | all(startswith("sha256:"))' /tmp/mcp_skills_list.json > /dev/null || fail "manifest digests"
pass "skills/list"

echo "== 3. skills/get known uri"
post 3 skills/get '{"uri":"skill://echo__greet/SKILL.md"}' \
  | jq -e '.result.skill.frontmatter.name == "echo__greet"' > /dev/null || fail "skills/get"
pass "skills/get"

echo "== 4. skills/get unknown uri is a -32602 protocol error"
post 4 skills/get '{"uri":"skill://echo__nope/SKILL.md"}' \
  | jq -e '.error.code == -32602' > /dev/null || fail "skills/get unknown"
pass "unknown uri error"

echo "== 5. resources/read bytes hash to the published digest"
post 5 resources/read '{"uri":"skill://echo__greet/references/usage.md"}' > /tmp/mcp_skills_read.json
jq -e '.result.contents[0].text | test("friendly tone")' /tmp/mcp_skills_read.json > /dev/null || fail "resources/read text"
python3 - <<'PYEOF' || fail "digest verification"
import json, hashlib
d = json.load(open('/tmp/mcp_skills_read.json'))
c = d['result']['contents'][0]
computed = 'sha256:' + hashlib.sha256(c['text'].encode()).hexdigest()
listed = json.load(open('/tmp/mcp_skills_list.json'))['result']['skills'][0]['resources']
published = next(f['digest'] for f in listed if f['uri'] == c['uri'])
assert computed == published, f"{computed} != {published}"
PYEOF
pass "digest integrity"

echo "== 6. resources/list catalogs every skill file"
post 6 resources/list '{}' | jq -e '.result.resources | length == 2' > /dev/null || fail "resources/list"
pass "resources/list"

kill $gw; trap - EXIT
rm -f /tmp/mcp_skills_init.json /tmp/mcp_skills_list.json /tmp/mcp_skills_read.json
echo
echo "ALL SKILLS CHECKS PASSED - extension advertised, aggregated, namespaced, digest-verified."
