---
name: kick-setup
description: "One-time setup for the /kick session-handoff tool: connect to your remote server, log it into Claude, warm the repo + dependencies, carry secrets, and write a gitignored project config. Use when the user says set up kick, configure the remote, or connect a server for handoff. Run this before /kick."
argument-hint: "[--refresh]"
allowed-tools:
  - Read
  - Bash
  - AskUserQuestion
---

<objective>
One-time, per-project setup that leaves the remote server "warm" so later
`/kick` calls are fast. Verifies the whole chain (SSH, remote `claude` login,
prerequisites), clones the repo to the server, installs deps, carries secrets,
and writes a gitignored config at `<project>/.claude/kick.local.json`. Slow and
thorough by design. Heavy lifting is in `lib/setup.sh`.
</objective>

<status_markers>
`KICK_OK:` success · `KICK_INFO:` progress · `KICK_ASK:` needs a user decision
(stop, surface it, retry) · `KICK_ALERT:` wrong but may continue · `KICK_FATAL:`
aborted.
</status_markers>

<flow>
Run from the project directory.

1. **Existing config?** If `.claude/kick.local.json` already exists and the user
   didn't pass `--refresh`, ask whether to reconfigure or just refresh.

2. **Collect connection** with AskUserQuestion (skip on `--refresh`): remote host
   (and port if not 22), remote user, SSH key path (default `~/.ssh/id_ed25519`),
   remote workspace root (default `~/kick-workspaces`).

3. **Run the bridges (no changes yet):**
   ```
   KICK_HOST=… KICK_USER=… KICK_PORT=… KICK_KEY=… KICK_REMOTE_ROOT=… \
     bash ${CLAUDE_PLUGIN_ROOT}/lib/setup.sh --check-only
   ```
   - `KICK_ASK:` (auth failed / not logged into Claude / remote Claude Code older
     than local) — relay the exact instructions, wait for the user to confirm,
     then re-run the check. `claude auth login` is a hard gate. The version
     update is a strong recommendation — let the user decide, then re-check.
   - `KICK_ALERT:` for a missing remote `claude`/`git` — relay the install command
     and wait.

4. **Secrets.** Once checks pass, detect gitignored secret files and ask
   (AskUserQuestion): carry all / pick / skip. Set `KICK_SECRETS_MODE`
   (`all|list|none`) and, for `list`, `KICK_SECRETS_LIST` (newline-separated).

5. **Warm the remote:**
   ```
   KICK_HOST=… KICK_USER=… KICK_PORT=… KICK_KEY=… KICK_REMOTE_ROOT=… \
   KICK_SECRETS_MODE=… [KICK_SECRETS_LIST=…] \
     bash ${CLAUDE_PLUGIN_ROOT}/lib/setup.sh
   ```
   Relay any machine-tool notes it surfaces. Finish on `KICK_OK:` — then tell the
   user they can now run `/kick` anytime.

For `--refresh`: skip steps 1-2, run `setup.sh --refresh`.
</flow>
