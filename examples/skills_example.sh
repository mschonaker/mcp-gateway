#!/usr/bin/env bash
# Skills extension walkthrough (SEP-2640) against a running gateway.
# Assumes the echo upstream (priv/fake_mcp_server.exs) is configured.
# Usage: bash examples/skills_example.sh [url]

set -euo pipefail
URL="${1:-http://localhost:4000/mcp}"
CT='Content-Type: application/json'
AC='Accept: application/json'

session=$(curl -s --max-time 20 -D - -o /tmp/mcp-skills-init.json -X POST "$URL" -H "$CT" -H "$AC" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}' \
  | tr -d '\r' | grep -i '^mcp-session-id' | awk '{print $2}')

post() {
  curl -s --max-time 30 -X POST "$URL" -H "$CT" -H "$AC" -H "Mcp-Session-Id: $session" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"$2\",\"params\":$3}"
}

echo "== 1. initialize: gateway advertises the skills extension because an upstream serves skills"
jq '.result.capabilities' /tmp/mcp-skills-init.json

echo "== 2. skills/list: aggregated entries, URIs namespaced by server, manifests with digests"
post 2 skills/list '{}' | jq '.result'

echo "== 3. skills/get: one entry by URI (adjust echo__greet if your server name differs)"
post 3 skills/get '{"uri":"skill://echo__greet/SKILL.md"}' | jq '.result.skill.frontmatter'

echo "== 4. skills/get unknown: protocol error -32602, which is how clients stop loading"
post 4 skills/get '{"uri":"skill://echo__does-not-exist/SKILL.md"}' | jq '.error'

echo "== 5. resources/read: skill content is served as a resource"
post 5 resources/read '{"uri":"skill://echo__greet/references/usage.md"}' > /tmp/mcp-skills-read.json
jq '.result.contents[0]' /tmp/mcp-skills-read.json

echo "== 6. integrity: the bytes just read must hash to the digest published in the manifest"
post 6 skills/list '{}' > /tmp/mcp-skills-list.json
python3 - <<'EOF'
import json, hashlib
read = json.load(open('/tmp/mcp-skills-read.json'))['result']['contents'][0]
skills = json.load(open('/tmp/mcp-skills-list.json'))['result']['skills']
published = next(f['digest'] for s in skills for f in s['resources'] if f['uri'] == read['uri'])
computed = 'sha256:' + hashlib.sha256(read['text'].encode()).hexdigest()
print(f'published: {published}')
print(f'computed : {computed}')
assert computed == published, 'DIGEST MISMATCH'
print('DIGEST OK')
EOF

echo "== 7. resources/list: every skill file is cataloged"
post 7 resources/list '{}' | jq '[.result.resources[].uri]'

echo
echo "SKILLS WALKTHROUGH COMPLETE"
