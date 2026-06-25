---
name: kick-pull
description: "Bring a session that was handed off with /kick back to the laptop: pull the remote's new commits, uncommitted changes, new/deleted files, and the grown conversation so the laptop mirrors it. Use when the user says pull back, bring it back, return the session, or sync from the server. Stops the remote session by default."
argument-hint: "[--dry-run] [--code-only|--convo-only] [--keep-remote] [--fork]"
allowed-tools:
  - Read
  - Bash
  - AskUserQuestion
---

<objective>
The return leg of `/kick`. Fetches everything the remote agent did — code (new
commits, uncommitted changes, new/deleted files) and the grown conversation
(transcript + subagents + tool-results + tasks) — so the laptop becomes an exact
mirror and the user can `claude --resume <id>` locally. Heavy lifting is in
`lib/pull.sh`; the careful laptop-side apply (with mandatory backup) is in
`lib/apply-pull.sh`.
</objective>

<status_markers>
`KICK_OK:` success · `KICK_INFO:` progress · `KICK_ASK:` needs a user decision ·
`KICK_ALERT:` wrong but may continue · `KICK_FATAL:` aborted.
</status_markers>

<flow>
Run from the project directory.

1. Run it (pass through flags):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/lib/pull.sh        # --dry-run --code-only --convo-only --keep-remote --fork
   ```
   `--dry-run` reports what would come back (commits, turns, size) + a
   clean/diverged verdict, transfers nothing.
2. **Divergence gate (exit code 10 + `KICK_ASK:`).** If both the laptop and the
   remote advanced since the kick, pull.sh stops WITHOUT applying and prints
   `KICK_STAGE=<path>` plus the reasons. Use AskUserQuestion to let the user pick:
   - `remote-wins` — back up local work (`refs/kick/pre-pull-*` ref + git stash +
     a timestamped transcript copy), then mirror the remote.
   - `fork` — land the cloud session under a NEW id and the remote code on a new
     branch; local stays untouched.
   - `abort` — do nothing.
   Then apply the chosen option with the staged payload:
   ```
   KICK_PULL_CHOICE=<remote-wins|fork> CHOICE=<same> STAGE=<the KICK_STAGE path> \
   PROJECT_DIR="$PWD" bash ${CLAUDE_PLUGIN_ROOT}/lib/apply-pull.sh
   ```
   (For `abort`, do nothing.) A clean pull or `--fork` needs no prompt — pull.sh
   applies directly.
3. On `KICK_OK:` — tell the user to resume locally with the printed
   `claude --resume <id>`. If it was a remote-wins, name the backup locations.
4. The remote session is stopped by default once the baton returns; `--keep-remote`
   leaves it running (and warns it will re-diverge).
5. If it prints `KICK_FATAL: no kick config` — tell the user to run `/kick-setup`
   first.
</flow>
