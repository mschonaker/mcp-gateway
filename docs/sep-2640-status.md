# SEP-2640 (Skills Extension) — Status

Reference date: **2026-11-15**. Key claims in this document were re-checked
against the GitHub API and modelcontextprotocol.io on that date. This space
moves fast; trust the links more than this file.

Short answer: SEP-2640 is now a formal MCP extension, harnesses are actively
implementing it, and OpenCode's maintainers laid the groundwork on 2026-11-10.

## 1. It is standardized: SEP-2640

- SEP-2640 "Skills Extension" (`io.modelcontextprotocol/skills`) is **Final** —
  PR merged 2026-09-13. Extension stage: Beta, against protocol revision
  2026-07-28.
- It defines exactly what this gateway implements: the `skill://` URI scheme,
  `skills/list`, `skills/get`, files served via `resources/read`, SHA-256
  digests per file, and optional `resources/directory/read`. This gateway
  implements it in `lib/mcp_gateway/skills.ex`, `lib/mcp_gateway/upstream.ex`,
  and `lib/mcp_gateway/router.ex`.
- Home: [modelcontextprotocol/ext-skills](https://github.com/modelcontextprotocol/ext-skills),
  maintained by the Skills Over MCP Working Group.

## 2. OpenCode tickets

No open ticket exists right now, but the trail is clear:

| Item | State | Note |
|------|-------|------|
| [#12100 Load skills over MCP](https://github.com/anomalyco/opencode/issues/12100) | closed | Opened Feb 2026, pre-SEP. Auto-closed as stale. |
| [#48937 MCP client rework](https://github.com/anomalyco/opencode/pull/48937) | merged 2026-09-14 | Explicitly listed "Skills over MCP (SEP-2640)" as *not in this PR*. |
| [#52298 SEP-2640 client implementation](https://github.com/anomalyco/opencode/pull/52298) | closed unmerged | Community PR, 657 lines. Registered served skills in the skill registry with server-namespaced IDs and digest verification. No maintainer reply; killed by the automated cleanup bot (>1 month old, <2 reactions) on 2026-10-30. |
| [#62982 MCP SDK 2.4.0](https://github.com/anomalyco/opencode/pull/62982) | **merged 2026-11-10** | Ships the official `SkillsClient` into the tree. Body: *"This PR doesn't use it; client support comes in a follow-up."* |

The SDK with the extension is in main and a follow-up is promised. A code
search for `SkillsClient`, `skills/list`, and `io.modelcontextprotocol/skills`
in the repo finds **no consumer yet**.

## 3. Which harnesses implement it

From the official
[client matrix](https://modelcontextprotocol.io/extensions/client-matrix) and
the [implementations list](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/implementations.md):

| Maturity | Clients |
|----------|---------|
| **v1 (full)** | fast-agent (`/skills add` installs served skills), MCPJam Inspector, mcpc (Apify CLI), vitehub, harness |
| **Partial** | ChatGPT (snapshot import at plugin submission only), MCP Inspector, Microsoft Agent Framework (.NET main, unreleased) |
| **In progress** | Goose (PR #12724), Agno, Cherry Studio, Hermes Agent, **opencode** (#52298, reopenable on request) |
| **Planned** | VS Code / GitHub Copilot ([#338300](https://github.com/microsoft/vscode/issues/338300)), Codex ([openai/codex#48000](https://github.com/openai/codex/issues/48000), issue only) |
| **Dormant code** | Claude Code: reports from 2026-11-13 found an implementation behind feature gate `tengu_mcp_skills`, default off. Public requests: [claude-code#106550](https://github.com/anthropics/claude-code/issues/106550), [claude-ai-mcp#1160](https://github.com/anthropics/claude-ai-mcp/issues/1160). Anthropic prototyped it internally per the SEP. |

Server side is ahead: Hugging Face, Cloudflare, n8n, Outline, Google MCP
Toolbox, Salesforce, and DoiT already serve v1 skills. The TypeScript SDK
(v2.4.0), FastMCP (v4.1.2), C#, and Python SDKs ship the extension.

## 4. Loading skills in OpenCode today

- **Config: no.** The `skills` array accepts local paths and HTTP catalog
  URLs only. No MCP entry exists.
- **Plugin: none shipped.** The OpenCode plugin API can add tools, so a shim
  that reads `skill://` URIs over MCP and injects the body is writable today.
  But the SEP explicitly says a bare `resources/read` is transport, **not** a
  skill load: a compliant loader must go through the host's skill-loading path
  with digest verification and approval. That is why #52298 touched core
  (`skill.ts`, `mcp/client.ts`) instead of living as a plugin.
- **Practical bridge:** most servers that publish skills over MCP also publish
  an HTTP catalog or a git folder, so mirroring to
  `~/.config/opencode/skills/` remains the working path.

## Verdict

Wait, don't build. OpenCode merged the SDK dependency on 2026-11-10 with an
explicit promise of a follow-up PR. To accelerate it, comment on
[#52298](https://github.com/anomalyco/opencode/pull/52298) to request a
reopen, or open a fresh feature issue referencing the "client support comes in
a follow-up" line in #62982.

What this gateway already guarantees on the server side: aggregated, collision-
free `skill://` URIs across upstreams, pass-through digests (content is byte
identical, so published SHA-256 digests remain verifiable), `-32602` for
unknown URIs, and extension advertisement only while some upstream actually
serves skills.

## References

Official sources:

- [SEP-2640 specification](https://modelcontextprotocol.io/seps/2640)
- [Skills extension overview](https://modelcontextprotocol.io/extensions/skills/overview)
- [Client support matrix](https://modelcontextprotocol.io/extensions/client-matrix)
- [ext-skills implementations list](https://github.com/modelcontextprotocol/ext-skills/blob/main/docs/implementations.md)
- [OpenCode skills docs](https://opencode.ai/docs/skills/)
- OpenCode tickets: issues/PRs 12100, 48937, 52298, 62982 in `anomalyco/opencode`

Secondary sources (used for the Claude Code feature-gate claim and maturity
audits, not independently confirmed):

- harnessnotes.com audit (2026-10-17)
- aicrier.com on the Claude Code gate (2026-11-13)
- ss33.ai usage guide (2026-10-30)
