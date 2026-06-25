#!/usr/bin/env bash
# Shared helpers for the /kick skill. Source this; don't execute it.
# All functions are prefixed k_ to avoid clobbering the caller's namespace.

set -o pipefail

KICK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KICK_SKILL_DIR="$(dirname "$KICK_LIB_DIR")"
KICK_CONFIG_REL=".claude/kick.local.json"

# ---- output -----------------------------------------------------------------
# Status markers the SKILL.md orchestrator parses to decide ask/alert/proceed.
k_ok()    { printf 'KICK_OK: %s\n'    "$*"; }
k_info()  { printf 'KICK_INFO: %s\n'  "$*"; }
k_ask()   { printf 'KICK_ASK: %s\n'   "$*"; }   # needs a user decision
k_alert() { printf 'KICK_ALERT: %s\n' "$*" >&2; }  # blocked / needs attention
k_fatal() { printf 'KICK_FATAL: %s\n' "$*" >&2; exit 1; }

# ---- path encoding (mirrors Claude Code: non-alnum -> '-') -------------------
k_encode_path() { python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9]","-",sys.argv[1]))' "$1"; }

# ---- config (project-local, gitignored JSON) --------------------------------
k_config_path() { printf '%s/%s\n' "${1:-$PWD}" "$KICK_CONFIG_REL"; }

k_config_get() {
  # k_config_get <key> [project_dir] ; prints value or empty
  local key="$1" proj="${2:-$PWD}" cfg
  cfg="$(k_config_path "$proj")"
  [ -f "$cfg" ] || return 1
  python3 - "$cfg" "$key" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
v=d
for part in sys.argv[2].split("."):
    if isinstance(v,dict) and part in v: v=v[part]
    else: sys.exit(1)
print(v if not isinstance(v,(dict,list)) else json.dumps(v))
PY
}

k_config_set() {
  # k_config_set <project_dir> <key=value> [key=value ...]
  local proj="$1"; shift
  local cfg; cfg="$(k_config_path "$proj")"
  mkdir -p "$(dirname "$cfg")"
  python3 - "$cfg" "$@" <<'PY'
import json,os,sys
cfg=sys.argv[1]
d={}
if os.path.isfile(cfg):
    try: d=json.load(open(cfg))
    except Exception: d={}
for pair in sys.argv[2:]:
    k,_,v=pair.partition("=")
    # Coerce all-digit values to int so numeric compares (e.g. generation) work.
    d[k]=int(v) if v.isdigit() else v
json.dump(d,open(cfg,"w"),indent=2)
os.chmod(cfg,0o600)
PY
}

# k_config_merge_json <project_dir> <json-fragment>
# Deep-merges a JSON object into the config. Use this for NESTED state
# (checkpoints, remotes) — k_config_set only writes flat scalar keys.
k_config_merge_json() {
  local proj="$1" frag="$2" cfg; cfg="$(k_config_path "$proj")"
  mkdir -p "$(dirname "$cfg")"
  python3 - "$cfg" "$frag" <<'PY'
import json,os,sys
cfg,frag=sys.argv[1],sys.argv[2]
d={}
if os.path.isfile(cfg):
    try: d=json.load(open(cfg))
    except Exception: d={}
def merge(a,b):
    for k,v in b.items():
        if isinstance(v,dict) and isinstance(a.get(k),dict): merge(a[k],v)
        else: a[k]=v
merge(d,json.loads(frag))
json.dump(d,open(cfg,"w"),indent=2)
os.chmod(cfg,0o600)
PY
}

# Ensure the config file is ignored by git (prefer .git/info/exclude so we
# never touch a tracked .gitignore the user may have opinions about).
k_ensure_gitignored() {
  local proj="$1" rel="$KICK_CONFIG_REL"
  if git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    local exclude; exclude="$(git -C "$proj" rev-parse --git-path info/exclude)"
    if ! git -C "$proj" check-ignore -q "$rel" 2>/dev/null; then
      mkdir -p "$(dirname "$exclude")"
      printf '%s\n' "$rel" >> "$exclude"
    fi
    git -C "$proj" check-ignore -q "$rel" 2>/dev/null
  fi
}

# ---- ssh --------------------------------------------------------------------
# Build the ssh base command from config values held in env:
#   KICK_HOST KICK_USER KICK_PORT KICK_KEY
k_ssh() {
  local opts=(-o BatchMode=yes -o ConnectTimeout=8
              -o StrictHostKeyChecking=accept-new)
  [ -n "${KICK_KEY:-}" ]  && opts+=(-i "$KICK_KEY")
  [ -n "${KICK_PORT:-}" ] && opts+=(-p "$KICK_PORT")
  ssh "${opts[@]}" "${KICK_USER}@${KICK_HOST}" "$@"
}

k_scp() {
  # k_scp <local> <remote-relative-or-abs>
  local opts=(-o BatchMode=yes -o ConnectTimeout=8
              -o StrictHostKeyChecking=accept-new)
  [ -n "${KICK_KEY:-}" ]  && opts+=(-i "$KICK_KEY")
  [ -n "${KICK_PORT:-}" ] && opts+=(-P "$KICK_PORT")
  scp "${opts[@]}" "$1" "${KICK_USER}@${KICK_HOST}:$2"
}

k_reachable() { k_ssh true >/dev/null 2>&1; }

# ---- submodules -------------------------------------------------------------
# git bundle does NOT capture submodule working trees. If this repo has any,
# tar their directories into submodules.tar.gz so the remote gets real files,
# and warn the user. No-op when there are no submodules.
k_snapshot_submodules() {
  local proj="$1" stage="$2"
  [ -f "$proj/.gitmodules" ] || return 0
  local paths; paths="$(git -C "$proj" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')"
  [ -n "$paths" ] || return 0
  ( cd "$proj" && printf '%s\n' "$paths" | tr '\n' '\0' \
      | tar --null -czf "$stage/submodules.tar.gz" -T - ) 2>/dev/null || true
  k_alert "Submodules detected ($(printf '%s' "$paths" | tr '\n' ' ')). Their working trees are shipped as files, but submodule git history isn't — commit inside a submodule won't round-trip."
}

# ---- divergence -------------------------------------------------------------
# A cheap deterministic digest of the working tree: HEAD + porcelain status +
# the full diff. Detects uncommitted drift, not just commit moves. For non-git
# dirs, falls back to a hash of the file listing (weaker — no content).
k_worktree_digest() {
  local proj="${1:-$PWD}"
  if git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    { git -C "$proj" rev-parse HEAD 2>/dev/null
      git -C "$proj" status --porcelain -z 2>/dev/null
      git -C "$proj" diff HEAD --binary 2>/dev/null
    } | shasum -a 256 | cut -d' ' -f1
  else
    ( cd "$proj" 2>/dev/null && find . -type f -not -path './.git/*' | sort ) \
      | shasum -a 256 | cut -d' ' -f1
  fi
}

# Tip uuid of a session transcript (last line's uuid), for checkpointing.
k_transcript_tip() {
  # k_transcript_tip <transcript.jsonl>
  [ -f "$1" ] || return 0
  python3 - "$1" <<'PY'
import json,sys
tip=""
for line in open(sys.argv[1],encoding="utf-8",errors="surrogatepass"):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    if isinstance(o,dict) and o.get("uuid"): tip=o["uuid"]
print(tip)
PY
}

# ---- misc -------------------------------------------------------------------
# Hash of all lockfiles present, for drift detection. Empty if none.
k_lockfile_hash() {
  local proj="${1:-$PWD}"
  ( cd "$proj" 2>/dev/null || return 0
    local files=() f
    for f in package-lock.json yarn.lock pnpm-lock.yaml poetry.lock \
             requirements.txt Gemfile.lock go.sum Cargo.lock composer.lock; do
      [ -f "$f" ] && files+=("$f")
    done
    [ ${#files[@]} -eq 0 ] && return 0
    cat "${files[@]}" 2>/dev/null | shasum -a 256 | cut -d' ' -f1 )
}
