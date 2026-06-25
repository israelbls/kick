---
name: kick
description: "Hand off (push) the current Claude Code session to your own remote server so it survives closing your laptop and you can drive it from your phone. Use when the user says kick, push, hand off, or send this session to the server. Setup is a separate command: /kick-setup. Bring it back with /kick-pull; check state with /kick-status."
argument-hint: "[--refresh] [--dry-run]"
allowed-tools:
  - Read
  - Bash
  - AskUserQuestion
---

<objective>
Push the *current* session — working tree (including uncommitted changes) plus
the conversation at its exact position — onto the user's already-set-up remote
server, then resume it there under Remote Control so they can keep going from
their phone after closing the laptop.

This is the fast, everyday command. It assumes `/kick-setup` already warmed the
remote. The heavy lifting lives in `lib/kick.sh`; your job is to run it, read
its `KICK_*:` status lines, and surface anything that needs the user.
</objective>

<status_markers>
- `KICK_OK:`    success; relay it.
- `KICK_INFO:`  progress; summarize.
- `KICK_ALERT:` wrong but the run may continue; surface with the fix.
- `KICK_FATAL:` aborted; explain why and what to do next.
</status_markers>

<flow>
Run from the project directory.

1. Run it (pass through any flags the user gave):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/lib/kick.sh        # or: --refresh, or --dry-run
   ```
   `--dry-run` shows exactly what would ship (payload size, file counts, the
   resume command) without transferring or launching — good before the first
   real handoff. `--refresh` re-syncs new commits / reinstalls deps first.
2. If it prints `KICK_FATAL: no kick config` — tell the user to run
   `/kick-setup` first. Do **not** attempt any setup work here.
3. On `KICK_ALERT:` about dependency drift — relay the one-line suggestion to run
   `/kick --refresh`, but the kick already succeeded.
4. On `KICK_OK:` — give the user the Remote Control session name and the steps:
   open the Claude app → Remote sessions → pick that name. Remind them the local
   session is now duplicated remotely, so they should stop typing here to avoid
   divergence — and that `/kick-pull` brings the remote's work back later.
</flow>

<notes>
- Session id is auto-detected as the newest transcript in this project's
  `~/.claude/projects/<encoded>/` dir. Override with `KICK_SID=…` if needed.
- The remote process runs under `tmux` (fallback `nohup`) so it survives the SSH
  connection closing.
- Everything is project-local: config in `.claude/kick.local.json`, gitignored.
</notes>
