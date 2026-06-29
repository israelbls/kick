#!/usr/bin/env bash
# status.sh — where's the baton, has the remote advanced, has the laptop
# diverged, and what would a pull bring. One SSH round-trip; read-only.
#
# Usage: status.sh [--json]
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$LIB_DIR/common.sh"

PROJECT_DIR="${KICK_PROJECT_DIR:-$PWD}"
JSON=0; [ "${1:-}" = "--json" ] && JSON=1

CFG="$(k_config_path "$PROJECT_DIR")"
[ -f "$CFG" ] || k_fatal "no kick config here — run '/kick-setup' first."
KICK_HOST="$(k_config_get host "$PROJECT_DIR")"
KICK_USER="$(k_config_get user "$PROJECT_DIR")"
KICK_PORT="$(k_config_get port "$PROJECT_DIR" 2>/dev/null || true)"
KICK_KEY="$(k_config_get key "$PROJECT_DIR")"
REMOTE_PROJECT_DIR="$(k_config_get remote_project_dir "$PROJECT_DIR")"
REMOTE_ENC="$(k_config_get remote_enc "$PROJECT_DIR")"
RC_NAME="$(k_config_get rc_name "$PROJECT_DIR" 2>/dev/null || true)"
ACTIVE="$(k_config_get active_side "$PROJECT_DIR" 2>/dev/null || echo laptop)"
GEN="$(k_config_get generation "$PROJECT_DIR" 2>/dev/null || echo 0)"
BASE_SHA="$(k_config_get "checkpoints.$GEN.head_sha" "$PROJECT_DIR" 2>/dev/null || true)"
CP_TIP="$(k_config_get "checkpoints.$GEN.tip_uuid" "$PROJECT_DIR" 2>/dev/null || true)"
CP_DIGEST="$(k_config_get "checkpoints.$GEN.worktree_digest" "$PROJECT_DIR" 2>/dev/null || true)"
SID="$(k_config_get "checkpoints.$GEN.sid" "$PROJECT_DIR" 2>/dev/null || true)"
export KICK_HOST KICK_USER KICK_PORT KICK_KEY

LOCAL_ENC="$(k_encode_path "$PROJECT_DIR")"
[ -n "$SID" ] || SID="$(ls -t "$HOME/.claude/projects/$LOCAL_ENC"/*.jsonl 2>/dev/null | head -1 | xargs -I{} basename {} .jsonl)"

# ---- local divergence (no network) -----------------------------------------
DIVERGED=0; REASONS=""; CONVO_ADVANCED=0
NOW_TIP="$(k_transcript_tip "$HOME/.claude/projects/$LOCAL_ENC/$SID.jsonl")"
NOW_DIGEST="$(k_worktree_digest "$PROJECT_DIR")"
NOW_HEAD="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
# Conversation moving past the kick is expected '/kick' ceremony, not divergence
# (see pull.sh) — informational only. Only code/worktree changes truly diverge.
[ -n "$CP_TIP" ]    && [ "$NOW_TIP" != "$CP_TIP" ]       && CONVO_ADVANCED=1
[ -n "$BASE_SHA" ]  && [ -n "$NOW_HEAD" ] && [ "$NOW_HEAD" != "$BASE_SHA" ] && { DIVERGED=1; REASONS="$REASONS commits"; }
[ -n "$CP_DIGEST" ] && [ "$NOW_DIGEST" != "$CP_DIGEST" ] && { DIVERGED=1; REASONS="$REASONS worktree"; }

# ---- remote probe (one round-trip) -----------------------------------------
R_AHEAD="?"; R_DIRTY="?"; R_TURNS="?"; R_ALIVE="?"; REACH=1
if k_reachable; then
  probe="$(k_ssh "cd $(printf %q "$REMOTE_PROJECT_DIR") 2>/dev/null && \
    echo ahead=\$(git rev-list --count $(printf %q "$BASE_SHA")..HEAD 2>/dev/null) && \
    echo dirty=\$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') && \
    echo turns=\$(grep -c '\"type\":\"user\"' \$HOME/.claude/projects/$(printf %q "$REMOTE_ENC")/$(printf %q "$SID").jsonl 2>/dev/null) ; \
    tmux has-session -t $(printf %q "$RC_NAME") 2>/dev/null && echo alive=yes || echo alive=no")"
  R_AHEAD="$(printf '%s\n' "$probe" | sed -n 's/^ahead=//p')"
  R_DIRTY="$(printf '%s\n' "$probe" | sed -n 's/^dirty=//p')"
  R_TURNS="$(printf '%s\n' "$probe" | sed -n 's/^turns=//p')"
  R_ALIVE="$(printf '%s\n' "$probe" | sed -n 's/^alive=//p')"
else
  REACH=0
fi

# Did the remote grow the conversation past what the laptop has? (compare turn
# counts; '?'/empty are treated as 0 so a probe miss never claims growth.)
LOCAL_TURNS="$(grep -c '"type":"user"' "$HOME/.claude/projects/$LOCAL_ENC/$SID.jsonl" 2>/dev/null || echo 0)"
CONVO_PULL=0
case "$R_TURNS" in ''|'?') : ;; *) [ "${R_TURNS:-0}" -gt "${LOCAL_TURNS:-0}" ] 2>/dev/null && CONVO_PULL=1 ;; esac

# ---- verdict ----------------------------------------------------------------
VERDICT="clean pull"
if [ "$REACH" = "0" ]; then VERDICT="remote unreachable (local view only)"
elif [ "$DIVERGED" = "1" ]; then VERDICT="DIVERGED (code) — pull will ask you and back up local work"
elif [ "${R_AHEAD:-0}" = "0" ] && [ "${R_DIRTY:-0}" = "0" ] && [ "$CONVO_PULL" = "0" ]; then VERDICT="nothing to pull"
fi

if [ "$JSON" = "1" ]; then
  printf '{"active_side":"%s","generation":%s,"session":"%s","reachable":%s,"diverged":%s,"diverge_reasons":"%s","remote_commits_ahead":"%s","remote_dirty_files":"%s","remote_turns":"%s","remote_session_alive":"%s","verdict":"%s"}\n' \
    "$ACTIVE" "$GEN" "$SID" "$REACH" "$DIVERGED" "${REASONS# }" "$R_AHEAD" "$R_DIRTY" "$R_TURNS" "$R_ALIVE" "$VERDICT"
  exit 0
fi

k_info "baton:          $ACTIVE  (generation $GEN)"
k_info "session:        $SID"
k_info "remote:         ${KICK_USER}@${KICK_HOST}  (session alive: $R_ALIVE)"
k_info "remote ahead:   ${R_AHEAD} commit(s), ${R_DIRTY} uncommitted file(s), ~${R_TURNS} turn(s) (laptop has ~${LOCAL_TURNS})"
[ "$CONVO_PULL" = "1" ] && k_info "conversation:   remote has new turns to pull"
if [ "$DIVERGED" = "1" ]; then k_alert "laptop CODE diverged since last kick:${REASONS} (pull will ask + back up)"
elif [ "$CONVO_ADVANCED" = "1" ]; then k_info "laptop: only the local transcript moved (expected '/kick' ceremony) — a pull is clean"
else k_info "laptop: in sync with the last handoff"; fi
k_ok "verdict: $VERDICT"
