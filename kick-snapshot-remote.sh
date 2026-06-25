#!/usr/bin/env bash
# kick-snapshot-remote.sh — builds the "pull back" payload ON THE REMOTE.
#
# scp'd into the remote staging dir (like kick-land.sh) and run there. Reads
# pull.env (shipped alongside) and writes the payload into its own dir, which
# the laptop then streams back. Deliberately needs NO python on the remote:
# raw transcript files travel back as-is and the laptop does the cwd-rewrite
# with its already-tested snapshot_session.py.
set -euo pipefail

STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STAGE_DIR"
[ -f pull.env ] || { echo "KICK_FATAL: pull.env missing" >&2; exit 1; }
# shellcheck disable=SC1091
. ./pull.env
: "${REMOTE_PROJECT_DIR:?}" "${REMOTE_ENC:?}" "${SID:?}" "${BASE_SHA:=}"
CODE="${CODE:-1}"; CONVO="${CONVO:-1}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
log() { printf 'KICK_INFO: %s\n' "$*"; }

REMOTE_SHA=""; BRANCH=""; IS_GIT=0
if git -C "$REMOTE_PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  IS_GIT=1
  REMOTE_SHA="$(git -C "$REMOTE_PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
  BRANCH="$(git -C "$REMOTE_PROJECT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi

COMMITS_AHEAD=0
# ---- code payload -----------------------------------------------------------
if [ "$CODE" = "1" ]; then
  if [ "$IS_GIT" = "1" ]; then
    if [ -n "$BASE_SHA" ] && [ "$BASE_SHA" != "$REMOTE_SHA" ] \
         && git -C "$REMOTE_PROJECT_DIR" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
      git -C "$REMOTE_PROJECT_DIR" bundle create "$STAGE_DIR/code.bundle" "$BASE_SHA..HEAD" --branches >/dev/null 2>&1 || true
      COMMITS_AHEAD="$(git -C "$REMOTE_PROJECT_DIR" rev-list --count "$BASE_SHA..HEAD" 2>/dev/null || echo 0)"
    fi
    git -C "$REMOTE_PROJECT_DIR" diff HEAD --binary > "$STAGE_DIR/working.patch" 2>/dev/null || true
    git -C "$REMOTE_PROJECT_DIR" diff --cached --name-only > "$STAGE_DIR/staged-files.txt" 2>/dev/null || true
    ( cd "$REMOTE_PROJECT_DIR" && git ls-files --others --exclude-standard -z \
        | tar --null -czf "$STAGE_DIR/untracked.tar.gz" -T - ) 2>/dev/null || true
    if [ -f "$REMOTE_PROJECT_DIR/.gitmodules" ]; then
      local_paths="$(git -C "$REMOTE_PROJECT_DIR" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')"
      [ -n "$local_paths" ] && ( cd "$REMOTE_PROJECT_DIR" && printf '%s\n' "$local_paths" | tr '\n' '\0' \
          | tar --null -czf "$STAGE_DIR/submodules.tar.gz" -T - ) 2>/dev/null || true
    fi
  else
    tar -czf "$STAGE_DIR/tree.tar.gz" --exclude='.git' --exclude='node_modules' \
      --exclude='.venv' --exclude='dist' --exclude='build' --exclude='.next' \
      -C "$REMOTE_PROJECT_DIR" . 2>/dev/null || true
  fi
fi

# ---- conversation payload (raw; laptop rewrites cwd) ------------------------
TURNS=0; FOUND_SID="$SID"
if [ "$CONVO" = "1" ]; then
  proj="$CLAUDE_HOME/projects/$REMOTE_ENC"
  src="$proj/$SID.jsonl"
  if [ ! -f "$src" ]; then
    # fall back to the newest transcript in this project's dir
    newest="$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1 || true)"
    [ -n "$newest" ] && { src="$newest"; FOUND_SID="$(basename "$newest" .jsonl)"; }
  fi
  if [ -f "$src" ]; then
    log "collecting transcript $FOUND_SID"
    mkdir -p "$STAGE_DIR/raw/projects/$REMOTE_ENC" "$STAGE_DIR/raw/tasks"
    cp "$src" "$STAGE_DIR/raw/projects/$REMOTE_ENC/$FOUND_SID.jsonl"
    [ -d "$proj/$FOUND_SID" ] && cp -R "$proj/$FOUND_SID" "$STAGE_DIR/raw/projects/$REMOTE_ENC/"
    [ -d "$CLAUDE_HOME/tasks/$FOUND_SID" ] && cp -R "$CLAUDE_HOME/tasks/$FOUND_SID" "$STAGE_DIR/raw/tasks/"
    TURNS="$(grep -c '"type":"user"' "$src" 2>/dev/null || echo 0)"
  else
    echo "KICK_ALERT: no remote transcript found in $proj" >&2
  fi
fi

# ---- back.env (consumed by the laptop applier) + manifest ------------------
cat > "$STAGE_DIR/back.env" <<EOF
REMOTE_SHA=$REMOTE_SHA
BRANCH=$BRANCH
IS_GIT=$IS_GIT
SID=$FOUND_SID
EOF

cat > "$STAGE_DIR/pull-manifest.json" <<EOF
{
  "remote_sha": "$REMOTE_SHA",
  "branch": "$BRANCH",
  "sid": "$FOUND_SID",
  "commits_ahead": $COMMITS_AHEAD,
  "turns": $TURNS,
  "is_git": $IS_GIT
}
EOF
log "snapshot built (commits_ahead=$COMMITS_AHEAD, turns=$TURNS)"
echo "KICK_OK: remote snapshot ready"
