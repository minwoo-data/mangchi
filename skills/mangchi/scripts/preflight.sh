#!/usr/bin/env bash
# mangchi Phase 0 preflight (R1 only).
#
# Usage:
#   bash skills/mangchi/scripts/preflight.sh <target-file>
#
# Flags via env vars (set by the orchestrator from CLI flags):
#   FORCE=1                 bypass the 2000 LoC / 200KB guard
#   ONLY_AXES=a,b           value of --only-axes (comma-separated)
#   INCLUDE_AXES=a,b        value of --include-axes (comma-separated)
#   START_AXIS=<axis>       value of --start-axis (default correctness)
#   NO_VERIFY=1             --no-verify
#   ALLOW_SELF_REVIEW=1     --allow-self-review
#   FORCE_ACCEPT_THRESHOLD  default 2
#   GATE_CMD                value of --gate
#   REFINEMENT_ROOT         default docs/refinement/mangchi
#   MANGCHI_PYTHON          interpreter to use (default: first working python3 / python)
#   MANGCHI_CODEX_BIN       Codex CLI to probe (default: codex; the same binary codex-run.sh runs)
#
# Exit codes: 0 ready, 1 hard failure (message on stderr).
# On success prints KEY=VALUE lines (SLUG, DIR, EXT, LOC, BYTES, CODEX,
# SECURITY_SENSITIVE, STATEFUL_HINT) for the orchestrator to consume.
# Codex-missing routing (interactive y/N, hard refusal on security-sensitive
# filenames) stays in SKILL.md §"Codex 부재 시 동작" - this script only reports.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANGCHI_VERSION=0.4.0
FILE="${1:-}"
[ -n "$FILE" ] || { echo "[ERROR] usage: preflight.sh <target-file>" >&2; exit 1; }

fail=0
err() { echo "[ERROR] $*" >&2; fail=1; }
warn() { echo "[WARN] $*" >&2; }

# ── Step 1: environment (Bash / git / Python / PyYAML / Codex) ──
[ "${BASH_VERSINFO[0]}" -ge 4 ] || err "Bash 4+ required (declare -A). Current: ${BASH_VERSION}. macOS: brew install bash. Windows: Git Bash 4.4+ or WSL."
command -v git >/dev/null 2>&1 || err "git not in PATH (diff measurement requires it)"
PY=""
# Probe each candidate: a Windows Store "python3" alias is on PATH but only prints an install hint.
for c in ${MANGCHI_PYTHON:+"$MANGCHI_PYTHON"} python3 python; do
  command -v "$c" >/dev/null 2>&1 || continue
  "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 || continue
  PY="$c"; break
done
[ -n "$PY" ] || err "Python 3.8+ not found (YAML parsing). Set MANGCHI_PYTHON if it is not on PATH."
# codex-run.sh validates every Codex answer with PyYAML, so the probe is not optional.
[ -z "${SKIP_ENV_CHECK:-}" ] || warn "SKIP_ENV_CHECK is no longer supported and is ignored: scripts/codex-run.sh always validates Codex answers with PyYAML."
if [ -n "$PY" ]; then
  "$PY" -c "import yaml" 2>/dev/null || err "PyYAML missing. Install: $PY -m pip install pyyaml"
fi
CODEX=0
CODEX_BIN="${MANGCHI_CODEX_BIN:-codex}"
if command -v "$CODEX_BIN" >/dev/null 2>&1; then
  # scripts/codex-run.sh runs this binary with -s read-only, -C, --output-last-message and -c model_reasoning_effort.
  CODEX_VER="$("$CODEX_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$CODEX_VER" ] || [ "$(printf '%s\n%s\n' 0.125.0 "$CODEX_VER" | sort -V | head -1)" != 0.125.0 ]; then
    err "Codex CLI >= 0.125.0 required (read-only sandbox flags), found '${CODEX_VER:-unknown}' at $CODEX_BIN. Update: npm install -g @openai/codex@latest"
  else
    CODEX=1
  fi
else
  warn "Codex CLI missing ($CODEX_BIN). See SKILL.md §'Codex 부재 시 동작' for routing."
fi
[ "$fail" -eq 0 ] || exit 1
json_str() { "$PY" -c 'import json, sys; sys.stdout.write(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

# ── Step 2: input validity + path normalisation + credential refusal ──
FILE="${FILE//\\//}"   # Windows backslashes -> slashes (Git Bash)
[ -f "$FILE" ] || { echo "[ERROR] File not found: $FILE" >&2; exit 1; }
# The target is copied into the session dir and pasted into every Codex prompt: a credential file
# (secrets.yaml, credentials.json, id_rsa, .npmrc, *.env, ...) is refused before anything is copied.
bash "$HERE/codex-run.sh" check-target "$FILE" || { echo "[ERROR] mangchi does not refine credential files." >&2; exit 1; }

# ── Step 3: size guard ──
LOC=$(wc -l < "$FILE" | tr -d ' ')
BYTES=$(wc -c < "$FILE" | tr -d ' ')
if { [ "$LOC" -gt 2000 ] || [ "$BYTES" -gt 204800 ]; } && [ -z "${FORCE:-}" ]; then
  echo "[ERROR] File exceeds limits (LoC=$LOC, bytes=$BYTES). Use --force to override (Codex context window may still reject)." >&2
  exit 1
fi

# ── Step 4: axis coverage warning (2-PASS termination path) ──
contains() { case ",$1," in *",$2,"*) return 0;; *) return 1;; esac; }
if [ -n "${ONLY_AXES:-}" ]; then
  if ! { contains "$ONLY_AXES" correctness && contains "$ONLY_AXES" security; }; then
    warn "--only-axes excludes correctness or security. 2-PASS termination DISABLED. Converge via R5 cap or --gate."
  fi
fi

# ── Step 5: security-sensitive filename (self-review hard refusal input) ──
SECURITY_SENSITIVE=0
case "$(basename "$FILE")" in
  *auth*|*security*|*crypto*|*password*|*token*|*secret*|*sanitiz*|*permission*|*acl*) SECURITY_SENSITIVE=1;;
esac
if [ "$CODEX" -eq 0 ] && [ "$SECURITY_SENSITIVE" -eq 1 ]; then
  echo "[ERROR] Self-review mode is refused on security-sensitive files. Install Codex or use /triad." >&2
  exit 1
fi

# ── Step 6: robustness hint (heuristic only - never auto-enables the axis) ──
STATEFUL_HINT=0
if grep -Eiq 'threading|asyncio|async def|await |Lock\(|mutex|transaction|commit\(|rollback|\bINSERT\b|\bUPDATE\b|\bDELETE\b|session\.|cursor\.|fetch\(|requests\.|httpx|state_machine|status *=' "$FILE"; then
  STATEFUL_HINT=1
  if ! contains "${INCLUDE_AXES:-}" robustness; then
    echo "[HINT] stateful code detected — consider --include-axes=robustness" >&2
  fi
fi

# ── Step 7: slug + working dir + legacy-path warning ──
compute_slug() {
  local s="$1"
  s="${s#./}"
  s=$(printf '%s' "$s" | sed -E 's#[/ ]#-#g; s#[^A-Za-z0-9_-]#-#g')
  case "$s" in [0-9]*|.*) s="_$s";; esac
  [ -n "$s" ] || s="unnamed-$(date +%s)"
  printf '%s' "$s"
}
SLUG=$(compute_slug "$FILE")
ROOT="${REFINEMENT_ROOT:-docs/refinement/mangchi}"
DIR="$ROOT/$SLUG"
mkdir -p "$DIR" || { echo "[ERROR] cannot create $DIR" >&2; exit 1; }
OLD_DIR="docs/refinement/$SLUG"
if [ -d "$OLD_DIR" ] && [ ! -L "$OLD_DIR" ]; then
  warn "Legacy path detected: $OLD_DIR. New runs use $DIR. Move manually if continuing an old session."
fi

# ── Step 8: working copy + snapshot + state.json ──
# The extension comes from the file name, not the path (./Makefile, src/v1.2/handler), and keeps to
# the characters codex-run.sh accepts in updated.<ext>; anything else becomes txt.
BASE="${FILE##*/}"
EXT="${BASE##*.}"
[ "$EXT" != "$BASE" ] || EXT="txt"
case "$EXT" in ''|*[!A-Za-z0-9_-]*) EXT="txt" ;; esac
if [ -f "$DIR/state.json" ]; then
  # An existing session's working copy holds its edits: never overwrite it.
  warn "state.json already exists in $DIR - working copy and state not overwritten (use --continue $SLUG)."
else
  cp "$FILE" "$DIR/updated.$EXT" || { echo "[ERROR] cannot copy $FILE to $DIR/updated.$EXT" >&2; exit 1; }
  cp "$FILE" "$DIR/source-snapshot.$EXT" || { echo "[ERROR] cannot copy $FILE to $DIR/source-snapshot.$EXT" >&2; exit 1; }
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  INC_JSON=$(printf '%s' "${INCLUDE_AXES:-}" | awk -F, 'BEGIN{ORS=""} {for(i=1;i<=NF;i++) if($i!=""){printf "%s\"%s\"", (n++?",":""), $i}}')
  cat > "$DIR/state.json" <<JSON || { echo "[ERROR] cannot write $DIR/state.json" >&2; exit 1; }
{
  "schema_version": 1,
  "mangchi_version": "$MANGCHI_VERSION",
  "slug": "$SLUG",
  "target_basename": $(json_str "$BASE"),
  "started_at": "$NOW",
  "self_review_mode": false,
  "no_verify_mode": $([ -n "${NO_VERIFY:-}" ] && echo true || echo false),
  "axes_opt_in": [$INC_JSON],
  "start_axis": "${START_AXIS:-correctness}",
  "gate_cmd": $([ -n "${GATE_CMD:-}" ] && json_str "$GATE_CMD" || echo null),
  "rounds": [],
  "issues": [],
  "codex_tokens_total": 0,
  "forced_accept_count": 0,
  "force_accept_threshold": ${FORCE_ACCEPT_THRESHOLD:-2},
  "last_invalid_codex_output": null,
  "status": "active",
  "termination_reason": null
}
JSON
fi

echo "SLUG=$SLUG"
echo "DIR=$DIR"
echo "EXT=$EXT"
echo "LOC=$LOC"
echo "BYTES=$BYTES"
echo "CODEX=$CODEX"
echo "SECURITY_SENSITIVE=$SECURITY_SENSITIVE"
echo "STATEFUL_HINT=$STATEFUL_HINT"
