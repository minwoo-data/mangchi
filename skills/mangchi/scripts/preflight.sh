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
#   SKIP_ENV_CHECK=1        skip the PyYAML probe (CI images that parse YAML elsewhere)
#
# Exit codes: 0 ready, 1 hard failure (message on stderr).
# On success prints KEY=VALUE lines (SLUG, DIR, EXT, LOC, BYTES, CODEX,
# SECURITY_SENSITIVE, STATEFUL_HINT) for the orchestrator to consume.
# Codex-missing routing (interactive y/N, hard refusal on security-sensitive
# filenames) stays in SKILL.md §"Codex 부재 시 동작" - this script only reports.
set -u

FILE="${1:-}"
[ -n "$FILE" ] || { echo "[ERROR] usage: preflight.sh <target-file>" >&2; exit 1; }

fail=0
err() { echo "[ERROR] $*" >&2; fail=1; }
warn() { echo "[WARN] $*" >&2; }

# ── Step 1: environment (Bash / git / Python / PyYAML / Codex) ──
[ "${BASH_VERSINFO[0]}" -ge 4 ] || err "Bash 4+ required (declare -A). Current: ${BASH_VERSION}. macOS: brew install bash. Windows: Git Bash 4.4+ or WSL."
command -v git >/dev/null 2>&1 || err "git not in PATH (diff measurement requires it)"
PY=""
if command -v python3 >/dev/null 2>&1; then PY=python3; elif command -v python >/dev/null 2>&1; then PY=python; fi
[ -n "$PY" ] || err "Python 3.8+ not found (YAML parsing)"
if [ -n "$PY" ] && [ -z "${SKIP_ENV_CHECK:-}" ]; then
  "$PY" -c "import yaml" 2>/dev/null || err "PyYAML missing. Install: pip install pyyaml"
fi
CODEX=0
if command -v codex >/dev/null 2>&1; then CODEX=1; else warn "Codex CLI missing. See SKILL.md §'Codex 부재 시 동작' for routing."; fi
[ "$fail" -eq 0 ] || exit 1

# ── Step 2: input validity + path normalisation ──
FILE="${FILE//\//}"   # Windows backslashes -> slashes (Git Bash)
[ -f "$FILE" ] || { echo "[ERROR] File not found: $FILE" >&2; exit 1; }

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
mkdir -p "$DIR"
OLD_DIR="docs/refinement/$SLUG"
if [ -d "$OLD_DIR" ] && [ ! -L "$OLD_DIR" ]; then
  warn "Legacy path detected: $OLD_DIR. New runs use $DIR. Move manually if continuing an old session."
fi

# ── Step 8: working copy + snapshot + state.json ──
EXT="${FILE##*.}"
[ "$EXT" != "$FILE" ] || EXT="txt"
cp "$FILE" "$DIR/updated.$EXT"
cp "$FILE" "$DIR/source-snapshot.$EXT"
if [ ! -f "$DIR/state.json" ]; then
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  INC_JSON=$(printf '%s' "${INCLUDE_AXES:-}" | awk -F, 'BEGIN{ORS=""} {for(i=1;i<=NF;i++) if($i!=""){printf "%s\"%s\"", (n++?",":""), $i}}')
  cat > "$DIR/state.json" <<JSON
{
  "schema_version": 1,
  "slug": "$SLUG",
  "started_at": "$NOW",
  "self_review_mode": false,
  "no_verify_mode": $([ -n "${NO_VERIFY:-}" ] && echo true || echo false),
  "axes_opt_in": [$INC_JSON],
  "start_axis": "${START_AXIS:-correctness}",
  "gate_cmd": $([ -n "${GATE_CMD:-}" ] && printf '"%s"' "$GATE_CMD" || echo null),
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
else
  warn "state.json already exists in $DIR - not overwritten (use --continue $SLUG)."
fi

echo "SLUG=$SLUG"
echo "DIR=$DIR"
echo "EXT=$EXT"
echo "LOC=$LOC"
echo "BYTES=$BYTES"
echo "CODEX=$CODEX"
echo "SECURITY_SENSITIVE=$SECURITY_SENSITIVE"
echo "STATEFUL_HINT=$STATEFUL_HINT"
