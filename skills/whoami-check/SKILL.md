---
name: whoami-check
description: Diagnose the current authenticated identity by calling the gateway whoami tool.
---

# Who Am I Check

Use this skill to confirm which identity the MCP gateway sees for the current session.

## Steps

1. Call the local MCP tool `local__whoami` with no arguments.
2. Report the returned email and diagnostic fields to the user.
3. If the call fails or identity is missing, report that authentication or gateway session state may be invalid.

## Notes

- This skill relies on the gateway's built-in `whoami` MCP function.
