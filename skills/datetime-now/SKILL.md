---
name: datetime-now
description: Get the current gateway date and time by calling the datetime tool.
---

# Current Date and Time

Use this skill to retrieve the current time from the gateway.

## Steps

1. Call the local MCP tool `local__datetime` with no arguments.
2. Return the ISO 8601 timestamp to the user.

## Notes

- The timestamp is provided by the gateway's built-in `datetime` MCP function.
