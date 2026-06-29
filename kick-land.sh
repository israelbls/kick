#!/usr/bin/env bash
# kick-land.sh — idempotent remote receiver for the /kick skill.
#
# Runs ON THE REMOTE. Reads land.env from the staging dir (its own dir),
# reconstructs the working tree and session state, optionally installs
# dependencies, and optionally launches the resumed session under tmux.
#
# Used in two modes:
#   warm  — first-time provisioning (clone repo, install, place session)
#   delta — a fast kick (apply today's diff + latest transcript, launch)
#
# Re-running is safe: warm re-syncs an existing clone; delta resets the
# tree to the snapshot every time.
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STAGE_DIR"

[ -f land.env ] || { echo "KICK_FATAL: land.env missing in $STAGE_DIR" >&2; exit 1; }
# shellcheck disable=SC1091
. ./land.env

: "${MODE:?}" "${REMOTE_PROJECT_DIR:?}" "${REMOTE_ENC:?}" "${SID:?}"
IS_GIT="${IS_GIT:-1}"
RUN_INSTALL="${RUN_INSTALL:-0}"
LAUNCH="${LAUNCH:-0}"
TARGET_SHA="${TARGET_SHA:-}"
BRANCH="${BRANCH:-}"
RC_NAME="${RC_NAME:-kick-$SID}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"

log() { printf 'KICK_INFO: %s\n' "$*"; }

# ---- 1. reconstruct the working tree ---------------------------------------
reconstruct_git() {
  mkdir -p "$(dirname "$REMOTE_PROJECT_DIR")"
  if [ ! -d "$REMOTE_PROJECT_DIR/.git" ]; then
    [ -f code.bundle ] || { echo "KICK_FATAL: no code.bundle for fresh clone" >&2; exit 1; }
    log "cloning repository into $REMOTE_PROJECT_DIR"
    git clone -q "$STAGE_DIR/code.bundle" "$REMOTE_PROJECT_DIR"
  fi
  cd "$REMOTE_PROJECT_DIR"

  # Bring in any new commits the laptop made since the last sync.
  if [ -f "$STAGE_DIR/code.bundle" ]; then
    log "fetching commits from bundle"
    git fetch -q "$STAGE_DIR/code.bundle" '+refs/heads/*:refs/heads/kick-incoming/*' 2>/dev/null || true
  fi

  if [ -n "$TARGET_SHA" ] && git cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null; then
    git reset -q --hard "$TARGET_SHA"
  elif [ -n "$BRANCH" ] && git rev-parse -q --verify "kick-incoming/$BRANCH" >/dev/null 2>&1; then
    git reset -q --hard "kick-incoming/$BRANCH"
  else
    echo "KICK_ALERT: could not place HEAD at the laptop's commit — history may have diverged; run '/kick --refresh'" >&2
  fi

  # Remove untracked files left over from a previous kick so a file deleted on
  # the laptop doesn't linger here. Only untracked-AND-non-ignored files are
  # touched, so gitignored deps (node_modules) and carried secrets (.env) are
  # safe — never a blind 'git clean'.
  if [ "${CLEAN_UNTRACKED:-0}" = "1" ]; then
    log "clearing stale untracked files"
    git ls-files --others --exclude-standard -z \
      | while IFS= read -r -d '' f; do rm -f "$f"; done || true
  fi

  # Apply the laptop's uncommitted changes onto that commit.
  if [ -s "$STAGE_DIR/working.patch" ]; then
    log "applying uncommitted changes"
    git apply --whitespace=nowarn "$STAGE_DIR/working.patch" \
      || echo "KICK_ALERT: working.patch did not apply cleanly — inspect $STAGE_DIR/working.patch" >&2
  fi
  # Best-effort restage of what was staged on the laptop.
  if [ -s "$STAGE_DIR/staged-files.txt" ]; then
    while IFS= read -r f; do [ -n "$f" ] && git add -- "$f" 2>/dev/null || true; done < "$STAGE_DIR/staged-files.txt" || true
  fi
}

reconstruct_tar() {
  mkdir -p "$REMOTE_PROJECT_DIR"
  if [ -f "$STAGE_DIR/tree.tar.gz" ]; then
    log "unpacking working tree"
    tar -xzf "$STAGE_DIR/tree.tar.gz" -C "$REMOTE_PROJECT_DIR"
  fi
}

if [ "$IS_GIT" = "1" ]; then reconstruct_git; else reconstruct_tar; fi

# Untracked files and carried secrets land on top of the tree.
for extra in untracked.tar.gz carry.tar.gz submodules.tar.gz; do
  if [ -f "$STAGE_DIR/$extra" ]; then
    log "restoring $extra"
    tar -xzf "$STAGE_DIR/$extra" -C "$REMOTE_PROJECT_DIR"
  fi
done

# ---- 2. place the session state --------------------------------------------
if [ -d "$STAGE_DIR/claude-home" ]; then
  log "placing session transcript and task state"
  mkdir -p "$CLAUDE_HOME/projects" "$CLAUDE_HOME/tasks"
  # Refresh just this session's dirs; leave other projects untouched.
  rm -rf "$CLAUDE_HOME/projects/$REMOTE_ENC/$SID" \
         "$CLAUDE_HOME/projects/$REMOTE_ENC/$SID.jsonl" \
         "$CLAUDE_HOME/tasks/$SID"
  cp -R "$STAGE_DIR/claude-home/projects/." "$CLAUDE_HOME/projects/" 2>/dev/null || true
  cp -R "$STAGE_DIR/claude-home/tasks/."    "$CLAUDE_HOME/tasks/"    2>/dev/null || true
fi

# ---- 3. dependencies (warm / refresh only) ---------------------------------
if [ "$RUN_INSTALL" = "1" ] && [ -f "$STAGE_DIR/install-plan.sh" ]; then
  log "installing project dependencies"
  ( cd "$REMOTE_PROJECT_DIR" && bash "$STAGE_DIR/install-plan.sh" ) \
    || echo "KICK_ALERT: dependency install reported errors — see output above" >&2
fi

# ---- 4. resume THIS session under Remote Control so the phone/web app can ---
#         drive it WITH the laptop's conversation context -----------------------
# We resume the transferred transcript with `claude --remote-control <name>
# --resume <sid> "<prompt>"`. Two things that look optional are mandatory:
#   1. An INITIAL PROMPT. Without it, --resume aborts with "No deferred tool
#      marker found in the resumed session" (that marker only exists in
#      Anthropic's native teleport). Passing any prompt makes it resume the
#      full transcript normally and register for Remote Control.
#   2. The interactive client must OWN a pty and must NOT have its stdout
#      redirected to a file — the TUI exits instantly if it does. So we run it
#      in a bare tmux pane and read status by capturing the pane, never a log.
# Result: the app session has the entire prior conversation (verified), unlike
# the old fresh-server launch which started context-free sessions.
if [ "$LAUNCH" = "1" ]; then
  export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
  CLAUDE_BIN="$(command -v claude || true)"
  [ -n "$CLAUDE_BIN" ] || { echo "KICK_FATAL: 'claude' not found on remote PATH (looked in ~/.local/bin, ~/bin, PATH)" >&2; exit 1; }

  # Trust the workspace headlessly so the client doesn't block on the dialog.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$REMOTE_PROJECT_DIR" <<'PY' || echo "KICK_ALERT: could not set workspace trust automatically" >&2
import json,os,sys
p=os.path.expanduser("~/.claude.json"); proj=sys.argv[1]
d=json.load(open(p)) if os.path.isfile(p) else {}
d.setdefault("projects",{}).setdefault(proj,{})["hasTrustDialogAccepted"]=True
json.dump(d,open(p,"w"),indent=2)
PY
  fi

  APP_NAME="$(basename "$REMOTE_PROJECT_DIR")"
  # The bootstrap prompt both satisfies the "provide a prompt" requirement and
  # gives whoever opens the app a visible confirmation the handoff carried over.
  BOOT_PROMPT="You've been handed off from my laptop mid-conversation. In one short line, confirm you have our full prior context, then wait for my next instruction."

  if ! command -v tmux >/dev/null 2>&1; then
    echo "KICK_ALERT: tmux not found on the remote — the interactive Remote Control client needs a pty. Install tmux (e.g. 'sudo apt install -y tmux') and re-kick." >&2
  else
    tmux has-session -t "$RC_NAME" 2>/dev/null && tmux kill-session -t "$RC_NAME" || true
    tmux new-session -d -s "$RC_NAME" -x 220 -y 50
    RC_CMD="export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$PATH\"; cd $(printf %q "$REMOTE_PROJECT_DIR") && exec $CLAUDE_BIN --remote-control $(printf %q "$APP_NAME") --resume $(printf %q "$SID") $(printf %q "$BOOT_PROMPT")"
    tmux send-keys -t "$RC_NAME" "$RC_CMD" Enter

    # Poll the pane until it registers (resume + first turn can take a while).
    URL=""; STATUS="unclear"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 4
      PANE="$(tmux capture-pane -t "$RC_NAME" -p 2>/dev/null || true)"
      if printf '%s' "$PANE" | grep -qiE 'remote.control is active|/rc active'; then
        URL="$(printf '%s\n' "$PANE" | grep -aoE 'https://claude\.ai/code/[A-Za-z0-9._/?=&%+-]*' | head -1)"
        STATUS="live"; break
      elif printf '%s' "$PANE" | grep -qiE 'No deferred tool marker'; then STATUS="marker"; break
      elif printf '%s' "$PANE" | grep -qiE 'enable remote control|select login method|authorize|oauth'; then STATUS="enable"; break
      fi
      tmux has-session -t "$RC_NAME" 2>/dev/null || { STATUS="exited"; break; }
    done

    case "$STATUS" in
      live)   echo "KICK_OK: Remote Control live as '$APP_NAME' WITH your full conversation context. Open the Claude app (Code tab) or: ${URL:-claude.ai/code}" ;;
      marker) echo "KICK_ALERT: resume hit the deferred-marker error despite a bootstrap prompt — attach to inspect: ssh in and 'tmux attach -t $RC_NAME'." >&2 ;;
      enable) echo "KICK_ALERT: this server needs a ONE-TIME Remote Control enable. SSH in, run 'claude remote-control' once (answer y, approve the browser link), then re-kick." >&2 ;;
      exited) echo "KICK_ALERT: the Remote Control client exited during startup — attach to see why: ssh in and 'tmux attach -t $RC_NAME' (or it may have already finished)." >&2 ;;
      *)      echo "KICK_ALERT: Remote Control client started but status is unclear — attach with: ssh in and 'tmux attach -t $RC_NAME'." >&2 ;;
    esac
  fi
fi

echo "KICK_OK: land complete (mode=$MODE)"
