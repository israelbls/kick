# kick — move a Claude Code session between your laptop and your own server

Hand off the **current** Claude Code session — working tree (including
uncommitted changes) plus the conversation at its exact position — to your own
always-on server, drive it from your phone, and bring it back. Four commands,
all sharing the scripts under `lib/`.

## Install

This repo is a Claude Code plugin **and** its own marketplace. In Claude Code:

```
/plugin marketplace add https://github.com/israelbls/kick.git
/plugin install kick@kick-tools
```

Use the full HTTPS URL (the `owner/repo` shorthand clones over SSH, which needs a
GitHub SSH key + `github.com` in your `known_hosts`). Update later with
`/plugin update kick@kick-tools`.

Once installed, the four skills are invoked through the plugin (e.g.
`/kick:kick-setup`, `/kick:kick`, `/kick:kick-pull`, `/kick:kick-status`).

**Requirements:** an always-on Linux server you can reach over SSH, logged into
Claude (`claude auth login`) once. The plugin needs `git`, `bash`, and a package
manager on that server; `python3` and `git` locally.

## Four commands

| Command | When | What it does |
|---------|------|--------------|
| `/kick-setup` | once per project | Verifies SSH + remote `claude` login + prerequisites, clones the repo to the server, installs deps, carries secrets, writes a gitignored config. Slow, thorough. `--refresh` for a lighter re-sync. |
| `/kick` | leaving the laptop | Ships today's delta (uncommitted diff + transcript) onto the warm server, sets workspace trust, and **resumes this exact conversation under Remote Control** so it appears in the Claude app with full context. Fast. `--refresh` re-syncs commits/deps first; `--dry-run` previews. |
| `/kick-pull` | back at the laptop | Brings the remote's code + grown conversation back so the laptop mirrors it; then `claude --resume <id>`. Stops the remote session. |
| `/kick-status` | anytime | Where the baton is, whether the remote advanced, whether you diverged, what a pull would bring. `--json` for scripting. |

**`/kick-pull` flags:** `--dry-run` (preview + verdict, transfers nothing), `--code-only` / `--convo-only` (partial), `--keep-remote` (don't stop the remote), `--fork` (land the cloud session under a new id + branch instead of overwriting). On true divergence (you advanced locally *and* on the remote), pull asks you — `remote-wins` / `fork` / `abort` — and always backs up local work first (`refs/kick/pre-pull-*`, a git stash, and a timestamped transcript copy).

**The baton:** each handoff flips an `active_side` and bumps a `generation`, recording a checkpoint (transcript tip, HEAD, worktree digest). That's how `pull`/`status` know whether the laptop diverged. Restore a backup with `git stash pop` / `git reset --hard refs/kick/pre-pull-<ts>` / copy the `.kick-bak-<ts>` transcript back.

## Where things live

- Config: `<project>/.claude/kick.local.json` — host, user, port, **SSH key by
  path** (never the key itself), remote project dir, head sha, lockfile hash,
  secrets policy. Mode `600`, auto-added to `.git/info/exclude`.
- Remote staging: `~/.kick-staging/<project>-<sid>/` on the server.
- Remote session log: `~/.claude/kick-<sid>.log` on the server.

## Reading the output

Scripts print machine-readable status lines:

- `KICK_OK:` — success.
- `KICK_INFO:` — progress.
- `KICK_ASK:` — needs your decision (e.g. SSH auth, `claude auth login`, a
  version-update recommendation). Resolve it, then retry.
- `KICK_ALERT:` — something's off but the run continues degraded.
- `KICK_FATAL:` — aborted; the message says why.

## Attaching from your phone

After `/kick`, open the Claude app → **Code tab** (or **claude.ai/code**) and
pick the session — named after your project. `/kick` resumes the transferred
transcript with `claude --remote-control <name> --resume <id> "<prompt>"` under
`tmux`, so the session appears in the app **with the full conversation context**
and survives the SSH connection closing. (The bootstrap prompt is required: a
bare `--resume` aborts with a "deferred marker" error, and the interactive
client must own its `tmux` pane — it exits if its output is redirected.)

**One-time per server:** the *first* time, Remote Control must be enabled
interactively — SSH in and run `claude remote-control` once, answer `y`, and
approve the browser link (a one-time `sessions`-scope OAuth). After that, `/kick`
brings it up automatically. If a kick reports it needs enabling, that's why.

**What carries over:** your **code and uncommitted changes** are on the server,
**and the conversation itself** — the app session resumes this exact chat with
full context, so you can keep going from your phone right where you left off.
When you're back at the laptop, `/kick-pull` brings the grown conversation (and
any edits made on the phone) home.

## Troubleshooting

- **`no kick config` →** run `/kick-setup` first. `/kick` never sets up.
- **Remote unreachable →** check the box/network; re-run `/kick-setup` if the
  host changed.
- **Remote not logged into Claude →** SSH in, run `claude auth login`, follow the
  device-code link, retry. Required for Remote Control.
- **Kill a stuck remote session →** `ssh <box> 'tmux kill-session -t <rc-name>'`.
- **See what the remote session is doing →** `ssh <box> 'tail -f ~/.claude/kick-<sid>.log'`.
- **Dependencies changed →** `/kick` warns; run `/kick --refresh` to reinstall.

## Known limitations (v1)

- Machine-level tools (ffmpeg, psql, …) are detected and reported, not installed.
- Submodule working trees ship as files, but submodule git history doesn't.
- Anthropic native cloud isn't a target (its teleport drops uncommitted work).
- Remote Control needs a one-time interactive enable per server (see above), and
  `tmux` on the remote (the interactive client needs a pty).
- The app resumes the conversation as a normal `--resume`, so it continues from
  the transcript's last turn — it doesn't reconstruct an in-flight tool call
  that was mid-execution when you kicked.
