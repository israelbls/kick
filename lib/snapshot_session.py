#!/usr/bin/env python3
"""Snapshot a live Claude Code session for transfer to a remote machine.

Locates the session transcript, its subagent transcripts, tool-result
sidecar files, and task state; copies them atomically into a staging
tree that mirrors the remote ~/.claude layout; trims a half-written
final line; strips stale locks; and rewrites the machine-specific `cwd`
field from the local project path to the remote project path.

Only the top-level `cwd` field is rewritten — message bodies are left
untouched on purpose (a blanket string replace would corrupt history).

Output tree (under --out):
    claude-home/projects/<REMOTE_ENC>/<SID>.jsonl
    claude-home/projects/<REMOTE_ENC>/<SID>/subagents/*
    claude-home/projects/<REMOTE_ENC>/<SID>/tool-results/*
    claude-home/tasks/<SID>/*            (minus *.lock)

Emits a one-line JSON summary on stdout for the caller to parse.
"""
import argparse
import json
import os
import re
import shutil
import sys


def encode_path(path: str) -> str:
    """Mirror Claude Code's project-dir encoding: non-alnum -> '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def rewrite_cwd_stream(src_path: str, dst_path: str, from_cwd: str,
                       to_cwd: str, old_sid: str = "", new_sid: str = "") -> dict:
    """Copy a JSONL transcript line by line, rewriting the top-level cwd.

    Direction-agnostic: every top-level `cwd == from_cwd` becomes `to_cwd`.
    When new_sid is given, every top-level `sessionId == old_sid` is remapped
    too (used by --fork). Returns counts. A trailing line that fails to parse is
    dropped (append-only; the last partial line is never load-bearing). A
    non-final unparseable line is preserved verbatim so history is never
    silently corrupted.
    """
    with open(src_path, "r", encoding="utf-8", errors="surrogatepass") as fh:
        lines = fh.readlines()

    rewritten = 0
    dropped_tail = 0
    out_lines = []
    last_idx = len(lines) - 1

    for idx, line in enumerate(lines):
        stripped = line.rstrip("\n")
        if not stripped.strip():
            continue
        try:
            obj = json.loads(stripped)
        except json.JSONDecodeError:
            if idx == last_idx:
                dropped_tail += 1
                continue
            # Mid-file and unparseable: keep as-is rather than corrupt.
            out_lines.append(stripped)
            continue
        if isinstance(obj, dict) and obj.get("cwd") == from_cwd:
            obj["cwd"] = to_cwd
            rewritten += 1
        if new_sid and isinstance(obj, dict) and obj.get("sessionId") == old_sid:
            obj["sessionId"] = new_sid
        out_lines.append(json.dumps(obj, ensure_ascii=False))

    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    with open(dst_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out_lines))
        if out_lines:
            fh.write("\n")

    return {"cwd_rewrites": rewritten, "dropped_tail_lines": dropped_tail,
            "lines": len(out_lines)}


def rewrite_meta(src_path: str, dst_path: str, from_cwd: str,
                 to_cwd: str) -> None:
    """Copy a subagent .meta.json, rewriting a cwd field if present."""
    try:
        with open(src_path, "r", encoding="utf-8") as fh:
            obj = json.load(fh)
        if isinstance(obj, dict) and obj.get("cwd") == from_cwd:
            obj["cwd"] = to_cwd
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        with open(dst_path, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False)
    except (json.JSONDecodeError, OSError):
        # Unparseable meta: copy verbatim.
        shutil.copy2(src_path, dst_path)


def main() -> int:
    ap = argparse.ArgumentParser(description="Snapshot a Claude Code session.")
    ap.add_argument("--session-id", required=True)
    # Direction-agnostic source/dest project paths. Old names kept as aliases.
    ap.add_argument("--from-cwd", "--local-cwd", dest="from_cwd", required=True,
                    help="Project path the transcript currently has in `cwd`.")
    ap.add_argument("--to-cwd", "--remote-cwd", dest="to_cwd", required=True,
                    help="Project path to rewrite `cwd` to.")
    ap.add_argument("--out", required=True, help="Staging directory.")
    ap.add_argument("--claude-home", default=os.path.expanduser("~/.claude"),
                    help="Source ~/.claude to read the session from.")
    ap.add_argument("--new-sid", default="",
                    help="Rename the session to this id (for --fork).")
    ap.add_argument("--print-tip", action="store_true",
                    help="Also print the transcript's tip uuid in the summary.")
    args = ap.parse_args()

    sid = args.session_id
    out_sid = args.new_sid or sid
    from_cwd = args.from_cwd.rstrip("/")
    to_cwd = args.to_cwd.rstrip("/")
    from_enc = encode_path(from_cwd)
    to_enc = encode_path(to_cwd)

    proj_dir = os.path.join(args.claude_home, "projects", from_enc)
    transcript = os.path.join(proj_dir, f"{sid}.jsonl")
    if not os.path.isfile(transcript):
        print(json.dumps({"ok": False,
                          "error": f"transcript not found: {transcript}"}))
        return 1

    out_proj = os.path.join(args.out, "claude-home", "projects", to_enc)
    os.makedirs(out_proj, exist_ok=True)

    # Atomic-ish read: copy to a temp file first so a concurrent flush by the
    # live session can't hand us a half-line mid-read, then transform.
    tmp_transcript = os.path.join(args.out, f".{sid}.raw.jsonl")
    shutil.copy2(transcript, tmp_transcript)
    out_transcript = os.path.join(out_proj, f"{out_sid}.jsonl")
    summary = rewrite_cwd_stream(tmp_transcript, out_transcript,
                                 from_cwd, to_cwd, sid, args.new_sid)
    os.remove(tmp_transcript)

    sidecar = os.path.join(proj_dir, sid)
    sub_count = tr_count = 0
    if os.path.isdir(sidecar):
        # Subagent transcripts: rewrite cwd in .jsonl, smart-copy .meta.json.
        sub_src = os.path.join(sidecar, "subagents")
        if os.path.isdir(sub_src):
            sub_dst = os.path.join(out_proj, out_sid, "subagents")
            os.makedirs(sub_dst, exist_ok=True)
            for name in os.listdir(sub_src):
                s = os.path.join(sub_src, name)
                d = os.path.join(sub_dst, name)
                if name.endswith(".jsonl"):
                    rewrite_cwd_stream(s, d, from_cwd, to_cwd, sid, args.new_sid)
                    sub_count += 1
                elif name.endswith(".meta.json"):
                    rewrite_meta(s, d, from_cwd, to_cwd)
                else:
                    shutil.copy2(s, d)
        # Tool-result sidecars: copy verbatim (referenced by id in transcript).
        tr_src = os.path.join(sidecar, "tool-results")
        if os.path.isdir(tr_src):
            tr_dst = os.path.join(out_proj, out_sid, "tool-results")
            shutil.copytree(tr_src, tr_dst, dirs_exist_ok=True)
            tr_count = len(os.listdir(tr_src))

    # Task state: copy everything except lock files.
    tasks_src = os.path.join(args.claude_home, "tasks", sid)
    task_count = 0
    if os.path.isdir(tasks_src):
        tasks_dst = os.path.join(args.out, "claude-home", "tasks", out_sid)
        os.makedirs(tasks_dst, exist_ok=True)
        for name in os.listdir(tasks_src):
            if name.endswith(".lock"):
                continue
            shutil.copy2(os.path.join(tasks_src, name),
                         os.path.join(tasks_dst, name))
            task_count += 1

    result = {
        "ok": True,
        "session_id": sid,
        "out_session_id": out_sid,
        "from_enc": from_enc,
        "to_enc": to_enc,
        "transcript_lines": summary["lines"],
        "cwd_rewrites": summary["cwd_rewrites"],
        "dropped_tail_lines": summary["dropped_tail_lines"],
        "subagent_transcripts": sub_count,
        "tool_results": tr_count,
        "task_files": task_count,
    }
    if args.print_tip:
        tip = ""
        with open(out_transcript, encoding="utf-8", errors="surrogatepass") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(o, dict) and o.get("uuid"):
                    tip = o["uuid"]
        result["tip_uuid"] = tip
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
