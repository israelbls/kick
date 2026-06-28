#!/usr/bin/env bash
# setup.sh — one-time (per project) warm-up + verification for /kick.
#
# Orchestrated by SKILL.md. Connection params arrive via environment:
#   KICK_HOST KICK_USER [KICK_PORT] KICK_KEY KICK_REMOTE_ROOT
# Secrets policy (after the orchestrator asks the user):
#   KICK_SECRETS_MODE = all | none | list   (list -> newline KICK_SECRETS_LIST)
#
# Usage:
#   setup.sh --check-only     run the bridges, change nothing, report status
#   setup.sh                  full warm-up + write .claude/kick.local.json
#   setup.sh --refresh        lighter re-sync of an already-set-up project
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$LIB_DIR/common.sh"

PROJECT_DIR="${KICK_PROJECT_DIR:-$PWD}"
MODE_CHECK=0; MODE_REFRESH=0
case "${1:-}" in
  --check-only) MODE_CHECK=1 ;;
  --refresh)    MODE_REFRESH=1 ;;
esac

# ---- load connection (from config on --refresh, else from env) -------------
if [ "$MODE_REFRESH" = "1" ]; then
  KICK_HOST="$(k_config_get host "$PROJECT_DIR")" || k_fatal "no config — run '/kick-setup' first"
  KICK_USER="$(k_config_get user "$PROJECT_DIR")"
  KICK_PORT="$(k_config_get port "$PROJECT_DIR" 2>/dev/null || true)"
  KICK_KEY="$(k_config_get key "$PROJECT_DIR")"
  REMOTE_PROJECT_DIR="$(k_config_get remote_project_dir "$PROJECT_DIR")"
  REMOTE_ENC="$(k_config_get remote_enc "$PROJECT_DIR")"
else
  : "${KICK_HOST:?host required}" "${KICK_USER:?user required}" "${KICK_KEY:?ssh key required}"
  KICK_REMOTE_ROOT="${KICK_REMOTE_ROOT:-\$HOME/kick-workspaces}"
fi
export KICK_HOST KICK_USER KICK_PORT KICK_KEY

REPO_BASENAME="$(basename "$PROJECT_DIR")"
IS_GIT=0; LOCAL_SHA=""; BRANCH=""
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  IS_GIT=1
  LOCAL_SHA="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
  BRANCH="$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi

# ---- bridges ----------------------------------------------------------------
bridge_ssh() {
  if k_reachable; then k_ok "SSH reachable (${KICK_USER}@${KICK_HOST})"; return 0; fi
  # Classify: is the host up at all?
  if k_ssh -o PreferredAuthentications=none true 2>&1 | grep -qiE 'permission denied|publickey'; then
    k_ask "SSH reached the host but auth failed. Confirm the key path, or add your public key to the remote (ssh-copy-id), then retry."
  else
    k_alert "Could not reach ${KICK_HOST}. Check the host/port, VPN, and that the box is up."
  fi
  return 2
}

bridge_claude_auth() {
  # ~/.local/bin (the native installer's target) isn't on the non-interactive
  # SSH PATH, so add it before probing. New Claude Code prints JSON
  # ("loggedIn": true); older builds print human text — accept both.
  local out; out="$(k_ssh 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; claude auth status 2>&1 || true')"
  if printf '%s' "$out" | grep -qiE 'logged in|authenticated|active account|"?loggedin"?[[:space:]]*:[[:space:]]*true'; then
    k_ok "Remote is logged into Claude"
    return 0
  fi
  k_ask "The remote isn't logged into Claude. SSH in and run 'claude auth login' (follow the device-code link), then retry. Required for phone Remote Control."
  return 3
}

bridge_prereqs() {
  local rc=0 out
  out="$(k_ssh 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"; for b in git bash claude; do command -v $b >/dev/null 2>&1 && echo "have:$b" || echo "miss:$b"; done; echo "ccver:$(claude --version 2>/dev/null | head -1)"; for p in npm pnpm yarn pip3 poetry bundle go cargo composer; do command -v $p >/dev/null 2>&1 && echo "pm:$p"; done')"
  printf '%s\n' "$out" | grep -q 'miss:claude' && { k_alert "Remote has no 'claude' CLI. Install it: curl -fsSL https://claude.ai/install.sh | bash"; rc=4; }
  printf '%s\n' "$out" | grep -q 'miss:git'    && { k_alert "Remote has no 'git'."; rc=4; }
  local ccver; ccver="$(printf '%s\n' "$out" | sed -n 's/^ccver://p')"
  if [ -n "$ccver" ]; then
    local lver; lver="$(claude --version 2>/dev/null | head -1)"
    k_info "Remote Claude Code: $ccver (local: $lver)"
    # Compare the leading semver. If the remote is OLDER than local, offer to
    # update it — resuming a transcript on an older CC can mis-parse newer fields.
    local rsem lsem older
    rsem="$(printf '%s' "$ccver" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
    lsem="$(printf '%s' "$lver"  | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
    if [ -n "$rsem" ] && [ -n "$lsem" ] && [ "$rsem" != "$lsem" ]; then
      older="$(printf '%s\n%s\n' "$rsem" "$lsem" | sort -V | head -1)"
      if [ "$older" = "$rsem" ]; then
        k_ask "Remote Claude Code ($rsem) is older than local ($lsem). Recommend updating it before resuming — SSH in and run 'claude install latest' (or 'curl -fsSL https://claude.ai/install.sh | bash'), then retry."
        rc=5
      fi
    fi
  fi
  [ "$rc" = "0" ] && k_ok "Remote prerequisites present"
  return "$rc"
}

run_checks() {
  local rc=0
  bridge_ssh        || rc=$?
  [ "$rc" = "0" ] || return "$rc"
  bridge_claude_auth || rc=$?
  [ "$rc" = "0" ] || return "$rc"
  bridge_prereqs    || rc=$?
  return "$rc"
}

# ---- secret detection -------------------------------------------------------
detect_secrets() {
  [ "$IS_GIT" = "1" ] || return 0
  local globs='\.env$|\.env\.|\.pem$|\.key$|^\.npmrc$|^\.netrc$|credentials'
  git -C "$PROJECT_DIR" ls-files --others --ignored --exclude-standard 2>/dev/null \
    | grep -iE "$globs" || true
}

# ---- build the staging payload ---------------------------------------------
build_payload() {
  local stage="$1" mode="$2"   # mode: warm | refresh
  mkdir -p "$stage"
  if [ "$IS_GIT" = "1" ]; then
    if [ "$mode" = "warm" ]; then
      git -C "$PROJECT_DIR" bundle create "$stage/code.bundle" --all >/dev/null 2>&1
    else
      local base; base="$(k_config_get remote_head_sha "$PROJECT_DIR" 2>/dev/null || true)"
      if [ -n "$base" ] && [ "$base" != "$LOCAL_SHA" ] && git -C "$PROJECT_DIR" cat-file -e "$base^{commit}" 2>/dev/null; then
        git -C "$PROJECT_DIR" bundle create "$stage/code.bundle" "$base..HEAD" --branches >/dev/null 2>&1 || \
          git -C "$PROJECT_DIR" bundle create "$stage/code.bundle" --all >/dev/null 2>&1
      fi
    fi
    git -C "$PROJECT_DIR" diff HEAD --binary > "$stage/working.patch" 2>/dev/null || true
    git -C "$PROJECT_DIR" diff --cached --name-only > "$stage/staged-files.txt" 2>/dev/null || true
    # untracked, non-ignored
    ( cd "$PROJECT_DIR" && git ls-files --others --exclude-standard -z \
        | tar --null -czf "$stage/untracked.tar.gz" -T - ) 2>/dev/null || true
    k_snapshot_submodules "$PROJECT_DIR" "$stage"
  else
    tar -czf "$stage/tree.tar.gz" \
      --exclude='.git' --exclude='node_modules' --exclude='.venv' \
      --exclude='dist' --exclude='build' --exclude='target' --exclude='.next' \
      -C "$PROJECT_DIR" . 2>/dev/null || true
  fi

  # secrets
  if [ "${KICK_SECRETS_MODE:-none}" != "none" ]; then
    local list
    if [ "${KICK_SECRETS_MODE}" = "all" ]; then list="$(detect_secrets)"; else list="${KICK_SECRETS_LIST:-}"; fi
    if [ -n "$list" ]; then
      ( cd "$PROJECT_DIR" && printf '%s\n' "$list" | tr '\n' '\0' \
          | tar --null -czf "$stage/carry.tar.gz" -T - ) 2>/dev/null || true
    fi
  fi

  # install plan
  build_install_plan > "$stage/install-plan.sh"
}

build_install_plan() {
  echo '#!/usr/bin/env bash'
  echo 'set -e'
  [ -f "$PROJECT_DIR/package-lock.json" ] && echo 'command -v npm >/dev/null && npm ci'
  [ -f "$PROJECT_DIR/pnpm-lock.yaml" ]    && echo 'command -v pnpm >/dev/null && pnpm install --frozen-lockfile'
  [ -f "$PROJECT_DIR/yarn.lock" ]         && echo 'command -v yarn >/dev/null && yarn install --frozen-lockfile'
  [ -f "$PROJECT_DIR/poetry.lock" ]       && echo 'command -v poetry >/dev/null && poetry install'
  { [ -f "$PROJECT_DIR/requirements.txt" ] && [ ! -f "$PROJECT_DIR/poetry.lock" ]; } && echo 'command -v pip3 >/dev/null && pip3 install -r requirements.txt'
  [ -f "$PROJECT_DIR/Gemfile.lock" ]      && echo 'command -v bundle >/dev/null && bundle install'
  [ -f "$PROJECT_DIR/go.mod" ]            && echo 'command -v go >/dev/null && go mod download'
  [ -f "$PROJECT_DIR/Cargo.lock" ]        && echo 'command -v cargo >/dev/null && cargo fetch'
  echo 'echo "install-plan done"'
}

write_land_env() {
  local stage="$1" mode="$2"
  cat > "$stage/land.env" <<EOF
MODE=$mode
REMOTE_PROJECT_DIR=$REMOTE_PROJECT_DIR
REMOTE_ENC=$REMOTE_ENC
SID=__setup__
IS_GIT=$IS_GIT
TARGET_SHA=$LOCAL_SHA
BRANCH=$BRANCH
RUN_INSTALL=1
LAUNCH=0
EOF
}

ship_and_land() {
  local stage="$1"
  local remote_stage=".kick-staging/$REPO_BASENAME"
  k_ssh "mkdir -p $remote_stage"
  # tar the staging dir and stream it over, then unpack remotely.
  ( cd "$stage" && tar -czf - . ) | k_ssh "tar -xzf - -C $remote_stage"
  k_scp "$KICK_SKILL_DIR/kick-land.sh" "$remote_stage/kick-land.sh"
  k_ssh "cd $remote_stage && bash kick-land.sh"
}

# ============================================================================
if [ "$MODE_CHECK" = "1" ]; then
  run_checks; exit $?
fi

# Resolve remote paths (needs a one-shot expansion of $HOME on the remote root)
if [ "$MODE_REFRESH" != "1" ]; then
  REMOTE_ROOT_ABS="$(k_ssh "eval echo $KICK_REMOTE_ROOT" 2>/dev/null | tr -d '\r')"
  [ -n "$REMOTE_ROOT_ABS" ] || k_fatal "could not resolve remote workspace root"
  REMOTE_PROJECT_DIR="$REMOTE_ROOT_ABS/$REPO_BASENAME"
  REMOTE_ENC="$(k_encode_path "$REMOTE_PROJECT_DIR")"
fi

# Re-run the gates before mutating anything.
run_checks || k_fatal "preflight bridges not satisfied — resolve the items above and retry"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kick-setup.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [ "$MODE_REFRESH" = "1" ]; then
  k_info "refreshing warm state on remote"
  build_payload "$STAGE" refresh
  write_land_env "$STAGE" warm
  # Only run installs if the lockfile actually changed.
  NEW_HASH="$(k_lockfile_hash "$PROJECT_DIR")"
  OLD_HASH="$(k_config_get lockfile_hash "$PROJECT_DIR" 2>/dev/null || true)"
  [ "$NEW_HASH" = "$OLD_HASH" ] && sed -i.bak 's/^RUN_INSTALL=1/RUN_INSTALL=0/' "$STAGE/land.env" && rm -f "$STAGE/land.env.bak"
  ship_and_land "$STAGE"
  k_config_set "$PROJECT_DIR" "remote_head_sha=$LOCAL_SHA" "lockfile_hash=$NEW_HASH"
  k_ok "refresh complete"
  exit 0
fi

k_info "warming remote at $REMOTE_PROJECT_DIR"
build_payload "$STAGE" warm
write_land_env "$STAGE" warm
ship_and_land "$STAGE"

# machine-level tool notes (detect + instruct only). -I skips binaries and the
# excludes keep us out of build artifacts and subagent worktrees, which would
# otherwise spew thousands of "Binary file … matches" lines.
TOOLS="$(grep -rhoIE \
  --exclude-dir=.git --exclude-dir=.claude --exclude-dir=node_modules \
  --exclude-dir=build --exclude-dir=.gradle --exclude-dir=dist \
  --exclude-dir=.next --exclude-dir=.venv --exclude-dir=target \
  '\b(ffmpeg|convert|psql|mysql|redis-cli|docker|pandoc|wkhtmltopdf|sox|tesseract)\b' \
  "$PROJECT_DIR" 2>/dev/null | sort -u | tr '\n' ' ' || true)"
[ -n "$TOOLS" ] && k_info "Machine tools seen in project (verify on remote): $TOOLS"

# persist config
PORT_VAL="${KICK_PORT:-22}"
k_config_set "$PROJECT_DIR" \
  "host=$KICK_HOST" "user=$KICK_USER" "port=$PORT_VAL" "key=$KICK_KEY" \
  "remote_project_dir=$REMOTE_PROJECT_DIR" "remote_enc=$REMOTE_ENC" \
  "remote_head_sha=$LOCAL_SHA" "lockfile_hash=$(k_lockfile_hash "$PROJECT_DIR")" \
  "secrets_mode=${KICK_SECRETS_MODE:-none}"
k_ensure_gitignored "$PROJECT_DIR" && k_ok ".claude/kick.local.json written and gitignored" \
  || k_info "config written (not a git repo, so nothing to gitignore)"

k_ok "Setup complete — run /kick anytime to hand off the current session."
