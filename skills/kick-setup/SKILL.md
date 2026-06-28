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

<golden_rule>
ALWAYS ask the user through the AskUserQuestion tool — never a plain-text
question. A prose question ends your turn and makes setup feel broken. This
includes free-form values like the host or username: put them through
AskUserQuestion (the user types their answer in the answer field). Batch the
unknowns into ONE call. Use warm, simple words a beginner would understand — no
jargon, short sentences. AskUserQuestion ALWAYS offers a free-text answer, so
make the options only the real alternatives — never add an "I'll type it myself"
option; instead phrase the prompt "pick one below, or type your own."
</golden_rule>

<flow>
Run from the project directory.

1. **Existing config?** If `.claude/kick.local.json` already exists and the user
   didn't pass `--refresh`, use AskUserQuestion to offer: reconfigure / just
   refresh / cancel.

2. **Collect connection — one AskUserQuestion call, friendly wording** (skip on
   `--refresh`). First detect what you can so you ask less: scan `~/.ssh` for
   private keys, default the port to 22, default the workspace root to
   `~/kick-workspaces`. Then ask only the unknowns in a single batched call, e.g.:
   - "Where does your always-on computer live?" — its address, like an IP
     (`203.0.113.5`) or a name (`myserver.com`). → KICK_HOST
   - "What name do you log in with there?" — e.g. `ubuntu`. → KICK_USER
   - "Which key should I use to unlock it?" — offer the keys you found in `~/.ssh`
     as the options. → KICK_KEY
   - Only ask about the port or workspace folder if the user wants to change the
     defaults (offer "use the default" as the first option).
   Never ask for any of these in prose. If you need anything from the user at any
   later step, it also goes through AskUserQuestion.

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
