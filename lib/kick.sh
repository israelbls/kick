#!/usr/bin/env bash
# kick.sh — the fast path. Ship today's delta + the current session, resume.
#
# Assumes /kick:setup already warmed the remote. Does as little as possible.
#
# Usage:
#   kick.sh            snapshot current session, ship delta, resume remotely
#   kick.sh --refresh  run the warm re-sync first (new commits / deps), then kick
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$LIB_DIR/common.sh"

PROJECT_DIR="${KICK_PROJECT_DIR:-$PWD}"
DO_REFRESH=0; DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --refresh) DO_REFRESH=1 ;;
    --dry-run) DRY_RUN=1 ;;
  esac
done

# ---- 1. load config (missing -> stop, no work) -----------------------------
CFG="$(k_config_path "$PROJECT_DIR")"
[ -f "$CFG" ] || k_fatal "no kick config here — run '/kick:setup' first."

KICK_HOST="$(k_config_get host "$PROJECT_DIR")"
KICK_USER="$(k_config_get user "$PROJECT_DIR")"
KICK_PORT="$(k_config_get port "$PROJECT_DIR" 2>/dev/null || true)"
KICK_KEY="$(k_config_get key "$PROJECT_DIR")"
REMOTE_PROJECT_DIR="$(k_config_get remote_project_dir "$PROJECT_DIR")"
REMOTE_ENC="$(k_config_get remote_enc "$PROJECT_DIR")"
export KICK_HOST KICK_USER KICK_PORT KICK_KEY

# ---- 2. optional refresh first (skipped on dry-run) ------------------------
if [ "$DO_REFRESH" = "1" ] && [ "$DRY_RUN" = "0" ]; then
  k_info "refreshing warm state before kicking"
  KICK_PROJECT_DIR="$PROJECT_DIR" bash "$LIB_DIR/setup.sh" --refresh
fi

# ---- 3. cheap reachability ping --------------------------------------------
if k_reachable; then
  k_info "remote reachable (${KICK_USER}@${KICK_HOST})"
elif [ "$DRY_RUN" = "1" ]; then
  k_alert "remote not reachable right now — dry-run continues, but a real kick would stop here."
else
  k_fatal "remote unreachable — check the network/box, or re-run '/kick:setup'."
fi

# ---- 4. identify the live session ------------------------------------------
LOCAL_ENC="$(k_encode_path "$PROJECT_DIR")"
PROJ_TRANSCRIPTS="$HOME/.claude/projects/$LOCAL_ENC"
SID="${KICK_SID:-}"
if [ -z "$SID" ]; then
  # newest transcript in this project's dir = the active session
  SID="$(ls -t "$PROJ_TRANSCRIPTS"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl)"
fi
[ -n "$SID" ] || k_fatal "no session transcript found for this project ($PROJ_TRANSCRIPTS)."
k_info "session: $SID"

IS_GIT=0; LOCAL_SHA=""; BRANCH=""
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  IS_GIT=1
  LOCAL_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
  BRANCH="$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kick.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# ---- 5. snapshot today's code delta (small) --------------------------------
if [ "$IS_GIT" = "1" ]; then
  REMOTE_SHA="$(k_config_get remote_head_sha "$PROJECT_DIR" 2>/dev/null || true)"
  if [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" != "$LOCAL_SHA" ] \
       && git -C "$PROJECT_DIR" cat-file -e "$REMOTE_SHA^{commit}" 2>/dev/null; then
    git -C "$PROJECT_DIR" bundle create "$STAGE/code.bundle" "$REMOTE_SHA..HEAD" --branches >/dev/null 2>&1 || true
  fi
  git -C "$PROJECT_DIR" diff HEAD --binary > "$STAGE/working.patch" 2>/dev/null || true
  git -C "$PROJECT_DIR" diff --cached --name-only > "$STAGE/staged-files.txt" 2>/dev/null || true
  ( cd "$PROJECT_DIR" && git ls-files --others --exclude-standard -z \
      | tar --null -czf "$STAGE/untracked.tar.gz" -T - ) 2>/dev/null || true
  k_snapshot_submodules "$PROJECT_DIR" "$STAGE"
else
  tar -czf "$STAGE/tree.tar.gz" --exclude='.git' --exclude='node_modules' \
    --exclude='.venv' --exclude='dist' --exclude='build' --exclude='.next' \
    -C "$PROJECT_DIR" . 2>/dev/null || true
fi

# ---- 6. snapshot the current session ---------------------------------------
python3 "$LIB_DIR/snapshot_session.py" \
  --session-id "$SID" --local-cwd "$PROJECT_DIR" \
  --remote-cwd "$REMOTE_PROJECT_DIR" --out "$STAGE" \
  || k_fatal "failed to snapshot the session transcript"

# ---- 7. land.env ------------------------------------------------------------
HOST_SHORT="$(hostname -s 2>/dev/null || echo host)"
RC_NAME="kick-${HOST_SHORT}-${SID:0:8}"
cat > "$STAGE/land.env" <<EOF
MODE=delta
REMOTE_PROJECT_DIR=$REMOTE_PROJECT_DIR
REMOTE_ENC=$REMOTE_ENC
SID=$SID
IS_GIT=$IS_GIT
TARGET_SHA=$LOCAL_SHA
BRANCH=$BRANCH
RUN_INSTALL=0
LAUNCH=1
CLEAN_UNTRACKED=1
RC_NAME=$RC_NAME
EOF

# ---- 7b. dry-run: report what *would* ship, then stop ----------------------
if [ "$DRY_RUN" = "1" ]; then
  SIZE="$(du -sh "$STAGE" 2>/dev/null | cut -f1)"
  NFILES="$(find "$STAGE" -type f | wc -l | tr -d ' ')"
  HAS_BUNDLE="no"; [ -f "$STAGE/code.bundle" ] && HAS_BUNDLE="yes"
  PATCH_BYTES="$(wc -c < "$STAGE/working.patch" 2>/dev/null | tr -d ' ' || echo 0)"
  k_info "DRY RUN — nothing was transferred or launched."
  k_info "  session:        $SID"
  k_info "  remote target:  ${KICK_USER}@${KICK_HOST}:$REMOTE_PROJECT_DIR"
  k_info "  new commits:    $HAS_BUNDLE"
  k_info "  uncommitted:    ${PATCH_BYTES} bytes of tracked changes"
  k_info "  payload:        $SIZE across $NFILES files"
  k_info "  would resume:   claude --remote-control '$RC_NAME' --resume $SID"
  k_ok "Dry run complete. Run '/kick:push' (no flag) to actually hand off."
  exit 0
fi

# ---- 8. ship + land ---------------------------------------------------------
REMOTE_STAGE=".kick-staging/$(basename "$PROJECT_DIR")-$SID"
k_ssh "mkdir -p $REMOTE_STAGE"
( cd "$STAGE" && tar -czf - . ) | k_ssh "tar -xzf - -C $REMOTE_STAGE"
k_scp "$KICK_SKILL_DIR/kick-land.sh" "$REMOTE_STAGE/kick-land.sh"
k_ssh "cd $REMOTE_STAGE && bash kick-land.sh"

# ---- 9. update state + record handoff checkpoint + drift check -------------
[ -n "$LOCAL_SHA" ] && k_config_set "$PROJECT_DIR" "remote_head_sha=$LOCAL_SHA"

# Record where the laptop stood at this handoff so a later '/kick:pull' can tell
# whether the laptop diverged. Baton moves to the remote; bump the generation.
TIP_UUID="$(k_transcript_tip "$PROJ_TRANSCRIPTS/$SID.jsonl")"
WT_DIGEST="$(k_worktree_digest "$PROJECT_DIR")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GEN="$(k_config_get generation "$PROJECT_DIR" 2>/dev/null || echo 0)"
GEN=$(( GEN + 1 ))
k_config_set "$PROJECT_DIR" "active_side=remote" "generation=$GEN" "rc_name=$RC_NAME"
k_config_merge_json "$PROJECT_DIR" "$(printf '{"checkpoints":{"%s":{"side":"laptop","sid":"%s","head_sha":"%s","tip_uuid":"%s","worktree_digest":"%s","rc_name":"%s","ts":"%s"}}}' \
  "$GEN" "$SID" "$LOCAL_SHA" "$TIP_UUID" "$WT_DIGEST" "$RC_NAME" "$TS")"

NEW_HASH="$(k_lockfile_hash "$PROJECT_DIR")"
OLD_HASH="$(k_config_get lockfile_hash "$PROJECT_DIR" 2>/dev/null || true)"
if [ -n "$NEW_HASH" ] && [ "$NEW_HASH" != "$OLD_HASH" ]; then
  k_alert "Dependencies changed since setup — run '/kick:push --refresh' to reinstall them on the remote."
fi

# ---- 10. attach instructions ------------------------------------------------
k_ok "Kicked. Open the Claude app → Remote sessions → '$RC_NAME' to keep going from your phone."
