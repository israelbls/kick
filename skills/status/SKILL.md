---
name: status
description: "Show the state of a /kick session handoff: where the baton is (laptop or remote), whether the remote advanced, whether the laptop diverged, and what a /kick:pull would bring. Read-only. Use when the user asks about kick status, where the session is, or what's pending to pull."
argument-hint: "[--json]"
allowed-tools:
  - Read
  - Bash
---

<objective>
Cheap, read-only status for the `/kick:push` handoff. One SSH round-trip. Reports the
baton location + generation, whether the remote advanced (commits / files /
turns), whether the laptop diverged since the last kick, and the verdict for a
pull. Logic is in `lib/status.sh`.
</objective>

<flow>
Run from the project directory:
```
bash ${CLAUDE_PLUGIN_ROOT}/lib/status.sh        # add --json for machine output
```
Relay the verdict line plus the baton / remote-ahead / divergence summary. If it
prints `KICK_FATAL: no kick config` — tell the user to run `/kick:setup` first.
</flow>
