#!/usr/bin/env bash
# apply-pull.sh — apply a pulled-back payload to the LAPTOP. Careful by design:
# it is NOT kick-land.sh (whose blind `git reset --hard` is fine on a throwaway
# remote, fatal on your real laptop). Takes a mandatory backup before any
# overwrite and refuses to proceed if the backup can't be made.
#
# Env in:
#   PROJECT_DIR  STAGE  CHOICE(clean|remote-wins|fork)  [NEW_SID]
# Reads STAGE/back.env (REMOTE_SHA, BRANCH, IS_GIT, SID) and the config.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$LIB_DIR/common.sh"

: "${PROJECT_DIR:?}" "${STAGE:?}" "${CHOICE:?}"
CODE="${CODE:-1}"; CONVO="${CONVO:-1}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
# shellcheck disable=SC1091
. "$STAGE/back.env"
: "${SID:?}" "${IS_GIT:=0}" "${REMOTE_SHA:=}"

REMOTE_PROJECT_DIR="$(k_config_get remote_project_dir "$PROJECT_DIR")"
LOCAL_ENC="$(k_encode_path "$PROJECT_DIR")"
TS="$(date -u +%Y%m%d-%H%M%S)"
OUT_SID="$SID"; [ "$CHOICE" = "fork" ] && OUT_SID="${NEW_SID:?fork needs NEW_SID}"

# ---- backup (mandatory for remote-wins) ------------------------------------
backup() {
  [ "$IS_GIT" = "1" ] || return 0
  local sha; sha="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$sha" ]; then
    git -C "$PROJECT_DIR" update-ref "refs/kick/pre-pull-$TS" "$sha" \
      || k_fatal "could not create backup ref — refusing to overwrite local work"
  fi
  # stash uncommitted work (untracked included); ok if nothing to stash
  git -C "$PROJECT_DIR" stash push -u -m "kick-pre-pull-$TS" >/dev/null 2>&1 || true
  k_info "backed up local work to refs/kick/pre-pull-$TS (+ git stash)"
}

# ---- code apply -------------------------------------------------------------
apply_code() {
  [ "$CODE" = "1" ] || return 0
  if [ "$IS_GIT" != "1" ]; then
    if [ -f "$STAGE/tree.tar.gz" ]; then tar -xzf "$STAGE/tree.tar.gz" -C "$PROJECT_DIR"; fi
    return 0
  fi
  cd "$PROJECT_DIR"
  if [ -f "$STAGE/code.bundle" ]; then
    git fetch -q "$STAGE/code.bundle" '+refs/heads/*:refs/remotes/kick-pull/*' 2>/dev/null || true
  fi

  if [ "$CHOICE" = "fork" ]; then
    # Non-destructive: drop the remote's commits on a new branch, leave the
    # working tree and current branch untouched. User merges by hand.
    if [ -n "$REMOTE_SHA" ] && git cat-file -e "$REMOTE_SHA^{commit}" 2>/dev/null; then
      git branch "kick-pull-fork-$TS" "$REMOTE_SHA" 2>/dev/null \
        && k_ok "remote code is on branch kick-pull-fork-$TS (working tree left as-is)"
    else
      k_alert "fork: remote commit $REMOTE_SHA not available locally; only the conversation was forked."
    fi
    return 0
  fi

  # clean / remote-wins: make the laptop mirror the remote tree.
  if [ -n "$REMOTE_SHA" ] && git cat-file -e "$REMOTE_SHA^{commit}" 2>/dev/null; then
    git reset -q --hard "$REMOTE_SHA"
  else
    k_alert "remote HEAD $REMOTE_SHA not present after fetch — leaving local HEAD; applying patch only."
  fi
  # clear stale untracked-non-ignored (protects gitignored deps + secrets)
  git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do rm -f "$f"; done || true
  if [ -s "$STAGE/working.patch" ]; then
    git apply --whitespace=nowarn "$STAGE/working.patch" \
      || k_alert "remote working.patch did not apply cleanly — your backup stash is intact (refs/kick/pre-pull-$TS); inspect $STAGE/working.patch"
  fi
  for extra in untracked.tar.gz submodules.tar.gz; do
    if [ -f "$STAGE/$extra" ]; then tar -xzf "$STAGE/$extra" -C "$PROJECT_DIR"; fi
  done
  if [ -s "$STAGE/staged-files.txt" ]; then
    while IFS= read -r f; do [ -n "$f" ] && git add -- "$f" 2>/dev/null || true; done < "$STAGE/staged-files.txt" || true
  fi
}

# ---- conversation apply -----------------------------------------------------
apply_convo() {
  [ "$CONVO" = "1" ] || return 0
  [ -d "$STAGE/raw" ] || { k_alert "no transcript in payload; skipping conversation."; return 0; }
  # Back up the local transcript before overwriting it. A fork writes to a NEW
  # sid and never touches the original, so it needs no backup; every other
  # choice (clean / remote-wins) replaces this SID's transcript, so save it —
  # even a "clean" pull discards the local '/kick' ceremony turns.
  local localtx="$CLAUDE_HOME/projects/$LOCAL_ENC/$SID.jsonl"
  if [ "$CHOICE" != "fork" ] && [ -f "$localtx" ]; then
    cp "$localtx" "$localtx.kick-bak-$TS"
    k_info "local transcript backed up to $localtx.kick-bak-$TS"
  fi
  local txout="$STAGE/transformed"; mkdir -p "$txout"
  local newsid_arg=(); [ "$CHOICE" = "fork" ] && newsid_arg=(--new-sid "$OUT_SID")
  python3 "$LIB_DIR/snapshot_session.py" --session-id "$SID" \
    --from-cwd "$REMOTE_PROJECT_DIR" --to-cwd "$PROJECT_DIR" \
    --out "$txout" --claude-home "$STAGE/raw" ${newsid_arg[@]+"${newsid_arg[@]}"} \
    || k_fatal "failed to transform the pulled transcript"
  # place it (delete-then-copy this SID only; leave other projects alone)
  rm -rf "$CLAUDE_HOME/projects/$LOCAL_ENC/$OUT_SID" \
         "$CLAUDE_HOME/projects/$LOCAL_ENC/$OUT_SID.jsonl" \
         "$CLAUDE_HOME/tasks/$OUT_SID"
  mkdir -p "$CLAUDE_HOME/projects" "$CLAUDE_HOME/tasks"
  cp -R "$txout/claude-home/projects/." "$CLAUDE_HOME/projects/" 2>/dev/null || true
  [ -d "$txout/claude-home/tasks" ] && cp -R "$txout/claude-home/tasks/." "$CLAUDE_HOME/tasks/" 2>/dev/null || true

  # Give the pulled session a human-readable title so it's easy to spot in the
  # `/resume` picker, `claude --resume`, and the terminal title. Claude stores a
  # session's display name as a 'custom-title' JSONL line (plus a matching
  # 'agent-name'); appending fresh ones makes the most-recent — authoritative —
  # title ours. These lines carry no `uuid`, so they don't affect the tip.
  local placed="$CLAUDE_HOME/projects/$LOCAL_ENC/$OUT_SID.jsonl"
  if [ ! -f "$placed" ]; then
    k_alert "placed transcript not found at $placed — skipped titling."
    return 0
  fi
  local title="${KICK_PULL_NAME:-$(basename "$PROJECT_DIR") (pulled $(date '+%Y-%m-%d %H:%M'))}"
  if KICK_TITLE="$title" KICK_TITLE_SID="$OUT_SID" KICK_PLACED="$placed" python3 <<'PY'
import json,os
p=os.environ["KICK_PLACED"]; title=os.environ["KICK_TITLE"]; sid=os.environ["KICK_TITLE_SID"]
with open(p,"a",encoding="utf-8") as f:
    f.write(json.dumps({"type":"custom-title","customTitle":title,"sessionId":sid})+"\n")
    f.write(json.dumps({"type":"agent-name","agentName":title,"sessionId":sid})+"\n")
PY
  then
    k_info "named the pulled session: $title"
    echo "OUT_TITLE=$title"
  else
    k_alert "could not write the session title to $placed (non-fatal — resume by id still works)."
  fi
}

# ---- run --------------------------------------------------------------------
[ "$CHOICE" = "remote-wins" ] && backup
apply_code
apply_convo
echo "OUT_SID=$OUT_SID"
echo "APPLIED_SHA=${REMOTE_SHA}"
k_ok "applied pull (choice=$CHOICE) as session $OUT_SID"
