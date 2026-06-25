#!/usr/bin/env bash
# pull.sh — bring the cloud session back to the laptop (the return leg).
#
# Fetches the remote's code + conversation, detects divergence against the last
# /kick checkpoint, and either applies cleanly or stops to let the orchestrator
# ask the user. The actual apply is done by apply-pull.sh (careful, backs up).
#
# Usage: pull.sh [--dry-run] [--code-only|--convo-only] [--keep-remote] [--fork]
# Exit 10 == divergence needs a user decision (orchestrator re-runs apply-pull.sh).
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$LIB_DIR/common.sh"

PROJECT_DIR="${KICK_PROJECT_DIR:-$PWD}"
DRY=0; CODE=1; CONVO=1; KEEP_REMOTE=0; FORK=0
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;; --code-only) CONVO=0 ;; --convo-only) CODE=0 ;;
  --keep-remote) KEEP_REMOTE=1 ;; --fork) FORK=1 ;;
esac; done

CFG="$(k_config_path "$PROJECT_DIR")"
[ -f "$CFG" ] || k_fatal "no kick config here — run '/kick-setup' first."
KICK_HOST="$(k_config_get host "$PROJECT_DIR")"
KICK_USER="$(k_config_get user "$PROJECT_DIR")"
KICK_PORT="$(k_config_get port "$PROJECT_DIR" 2>/dev/null || true)"
KICK_KEY="$(k_config_get key "$PROJECT_DIR")"
REMOTE_PROJECT_DIR="$(k_config_get remote_project_dir "$PROJECT_DIR")"
REMOTE_ENC="$(k_config_get remote_enc "$PROJECT_DIR")"
RC_NAME="$(k_config_get rc_name "$PROJECT_DIR" 2>/dev/null || true)"
GEN="$(k_config_get generation "$PROJECT_DIR" 2>/dev/null || echo 0)"
BASE_SHA="$(k_config_get "checkpoints.$GEN.head_sha" "$PROJECT_DIR" 2>/dev/null || true)"
CP_TIP="$(k_config_get "checkpoints.$GEN.tip_uuid" "$PROJECT_DIR" 2>/dev/null || true)"
CP_DIGEST="$(k_config_get "checkpoints.$GEN.worktree_digest" "$PROJECT_DIR" 2>/dev/null || true)"
export KICK_HOST KICK_USER KICK_PORT KICK_KEY

# ---- reachability -----------------------------------------------------------
if k_reachable; then k_info "remote reachable (${KICK_USER}@${KICK_HOST})"
elif [ "$DRY" = "1" ]; then k_alert "remote unreachable — dry-run can't inspect it."; exit 0
else k_fatal "remote unreachable — check the box/network."; fi

# ---- identify the session + detect LOCAL divergence -------------------------
LOCAL_ENC="$(k_encode_path "$PROJECT_DIR")"
SID="$(k_config_get "checkpoints.$GEN.sid" "$PROJECT_DIR" 2>/dev/null || true)"
[ -n "$SID" ] || SID="$(ls -t "$HOME/.claude/projects/$LOCAL_ENC"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl)"
[ -n "$SID" ] || k_fatal "can't determine the session id; was this project ever kicked?"

DIVERGED=0; REASONS=""
NOW_TIP="$(k_transcript_tip "$HOME/.claude/projects/$LOCAL_ENC/$SID.jsonl")"
NOW_DIGEST="$(k_worktree_digest "$PROJECT_DIR")"
NOW_HEAD="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
[ -n "$CP_TIP" ]    && [ "$NOW_TIP" != "$CP_TIP" ]       && { DIVERGED=1; REASONS="$REASONS local-conversation-advanced"; }
[ -n "$BASE_SHA" ]  && [ -n "$NOW_HEAD" ] && [ "$NOW_HEAD" != "$BASE_SHA" ] && { DIVERGED=1; REASONS="$REASONS local-commits"; }
[ -n "$CP_DIGEST" ] && [ "$NOW_DIGEST" != "$CP_DIGEST" ] && { DIVERGED=1; REASONS="$REASONS local-worktree-changed"; }

# ---- quiesce + snapshot the remote -----------------------------------------
REMOTE_STAGE=".kick-staging/pull-$(basename "$PROJECT_DIR")-$SID"
if [ "$DRY" = "0" ] && [ "$KEEP_REMOTE" = "0" ] && [ -n "$RC_NAME" ]; then
  k_ssh "tmux kill-session -t $(printf %q "$RC_NAME") 2>/dev/null || true"
  k_info "stopped remote session '$RC_NAME' (quiescing before snapshot)"
fi
k_ssh "mkdir -p $REMOTE_STAGE"
cat > /tmp/kick-pull.env.$$ <<EOF
REMOTE_PROJECT_DIR=$REMOTE_PROJECT_DIR
REMOTE_ENC=$REMOTE_ENC
SID=$SID
BASE_SHA=$BASE_SHA
CODE=$CODE
CONVO=$CONVO
EOF
k_scp /tmp/kick-pull.env.$$ "$REMOTE_STAGE/pull.env"; rm -f /tmp/kick-pull.env.$$
k_scp "$KICK_SKILL_DIR/kick-snapshot-remote.sh" "$REMOTE_STAGE/kick-snapshot-remote.sh"
k_ssh "cd $REMOTE_STAGE && bash kick-snapshot-remote.sh"

# ---- stream the payload back ------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kick-pull.XXXXXX")"
k_ssh "cd $REMOTE_STAGE && tar -czf - ." | tar -xzf - -C "$STAGE"

# ---- dry-run: report + stop -------------------------------------------------
if [ "$DRY" = "1" ]; then
  COMMITS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("commits_ahead",0))' "$STAGE/pull-manifest.json" 2>/dev/null || echo '?')"
  TURNS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("turns",0))' "$STAGE/pull-manifest.json" 2>/dev/null || echo '?')"
  SIZE="$(du -sh "$STAGE" 2>/dev/null | cut -f1)"
  k_info "DRY RUN — nothing was applied."
  k_info "  session:     $SID"
  k_info "  would bring: $COMMITS new commit(s), ~$TURNS conversation turn(s), payload $SIZE"
  if [ "$DIVERGED" = "1" ]; then k_alert "DIVERGED (${REASONS# }) — a real pull would ask you and back up local work first."
  else k_ok "Clean pull available. Run '/kick-pull' to apply."; fi
  rm -rf "$STAGE"; exit 0
fi

# ---- decide choice ----------------------------------------------------------
CHOICE="clean"
if [ "$FORK" = "1" ]; then CHOICE="fork"
elif [ "$DIVERGED" = "1" ]; then
  if [ -n "${KICK_PULL_CHOICE:-}" ]; then CHOICE="$KICK_PULL_CHOICE"
  else
    # Hand control back to the orchestrator to ask the user.
    echo "KICK_STAGE=$STAGE"
    echo "KICK_DIVERGE_REASONS=${REASONS# }"
    k_ask "Local work has advanced since you kicked (${REASONS# }). The remote also advanced. Choose: 'remote-wins' (back up local, then mirror the remote), 'fork' (land the cloud session under a new id, keep local untouched), or 'abort'. Re-run apply with KICK_PULL_CHOICE=<choice> KICK_STAGE=$STAGE."
    exit 10
  fi
fi
[ "$CHOICE" = "abort" ] && { k_info "aborted; nothing applied. Payload kept at $STAGE"; exit 0; }

# ---- apply ------------------------------------------------------------------
NEW_SID=""; [ "$CHOICE" = "fork" ] && NEW_SID="$(python3 -c 'import uuid;print(uuid.uuid4())')"
out="$(PROJECT_DIR="$PROJECT_DIR" STAGE="$STAGE" CHOICE="$CHOICE" NEW_SID="$NEW_SID" \
      CODE="$CODE" CONVO="$CONVO" bash "$LIB_DIR/apply-pull.sh")"
printf '%s\n' "$out"
APPLIED_SHA="$(printf '%s\n' "$out" | sed -n 's/^APPLIED_SHA=//p')"
OUT_SID="$(printf '%s\n' "$out" | sed -n 's/^OUT_SID=//p')"

# ---- flip the baton ---------------------------------------------------------
NEW_HEAD="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "$APPLIED_SHA")"
NEW_TIP="$(k_transcript_tip "$HOME/.claude/projects/$LOCAL_ENC/${OUT_SID:-$SID}.jsonl")"
NEW_DIGEST="$(k_worktree_digest "$PROJECT_DIR")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GEN2=$(( GEN + 1 ))
[ -n "$NEW_HEAD" ] && [ "$CHOICE" != "fork" ] && k_config_set "$PROJECT_DIR" "remote_head_sha=$NEW_HEAD"
k_config_set "$PROJECT_DIR" "active_side=laptop" "generation=$GEN2"
k_config_merge_json "$PROJECT_DIR" "$(printf '{"checkpoints":{"%s":{"side":"laptop","sid":"%s","head_sha":"%s","tip_uuid":"%s","worktree_digest":"%s","ts":"%s"}}}' \
  "$GEN2" "${OUT_SID:-$SID}" "$NEW_HEAD" "$NEW_TIP" "$NEW_DIGEST" "$TS")"

# ---- stop remote (default) + report ----------------------------------------
if [ "$KEEP_REMOTE" = "1" ]; then
  k_alert "Left the remote session running (--keep-remote); further phone work will re-diverge."
fi
k_ssh "rm -rf $REMOTE_STAGE" 2>/dev/null || true
rm -rf "$STAGE"
k_ok "Pulled. Resume locally with:  claude --resume ${OUT_SID:-$SID}"
