#!/usr/bin/env bash
# codex-run.sh -- the Codex CLI invocation contract for mangchi, as code.
#
# Claude runs ONE command per Codex call (Phase 2 review, Phase 6 verify) instead of re-typing a
# bash template. Everything that must never be skipped lives here, so a model cannot drop it:
#   - Sandbox Safety Preamble is the first bytes of every prompt
#   - the prompt is assembled here from files only: role + this round's axis rubric + the output
#     format (both cut out of axes.md; a missing section is an error) -> the full updated.<ext>
#     -> from round 2 the round-(N-1) carryover digest (required; --no-carryover opts out)
#   - prompt goes through a file + stdin, never argv; per-call guard char/4*1.3 >= 180K tokens;
#     timeout (default 300 s, max 570); reasoning effort pinned (default high); R5 hard cap
#   - Codex runs in the read-only sandbox (no writes, no network) unless MANGCHI_CODEX_SANDBOX=bypass
#   - secret scrub over EVERYTHING Codex printed, before any of it lands in the session dir; only
#     the --output-last-message answer is kept (the raw stream echoes the prompt)
#   - the YAML answer is validated by mangchi_yaml.py (schema_version 1), never eyeballed; the
#     Phase 3 schema retry runs at most once per call, and a call with a valid answer is not re-run
#   - one attempt per call at a time (lock); unscrubbed scratch lives outside the session dir
#
# Usage:
#   codex-run.sh review <session-dir> <N> <axis> [--no-carryover] [--retry]
#   codex-run.sh verify <session-dir> <N> --issues <file> [--retry]
#   codex-run.sh scrub <file>...          sanitizes secret-shaped files in place, exit 3 on a hit
#   codex-run.sh --selftest
#
# Files in <session-dir> (docs/refinement/mangchi/<slug>/, created by preflight.sh):
#   reads   updated.<ext>; round-(N-1).carryover.md for review N >= 2; round-N.codex.txt.json for
#           verify (axis + issue ids); the --issues file (REJECTed issues, see SKILL.md Phase 6)
#   writes  round-N.prompt.txt / round-N.codex.txt / round-N.codex.txt.json            (review)
#           round-N.verify.prompt.txt / round-N.verify.txt / round-N.verify.txt.json   (verify)
#           --retry: *.retry.prompt.txt; the first answer is kept as *.attempt1.txt(.json)
#
# stdout: one summary line, then the result JSON (also written to <out>.json):
#   [codex-run] mangchi round N review <axis>: status=<status> verdict=.. issues=.. tokens=.. ...
#   status = ok | schema-invalid(<field>) | degraded(<reason>) | secret-scrubbed(<reason>)
#
# Exit codes: 0 once the call ran -- a failed call becomes a "[fallback: <reason>]" marker in its
# output file and a status in the JSON, never a crash. 2 = usage, configuration or installation
# error (bad argument or env value, missing file, section or carryover, a call that may not run
# again, another attempt of the same call still running): fix it, do not retry with another model.
# 130 = interrupted (INT/TERM/HUP): partial output destroyed, the marker and its JSON are written.
#
# Env: MANGCHI_CODEX_EFFORT (high), MANGCHI_CODEX_TIMEOUT (300, at most 570 so the caller's Bash
#      timeout of (seconds+30)*1000 ms stays under 600000), MANGCHI_CODEX_MODEL (optional -m),
#      MANGCHI_CODEX_SANDBOX (read-only; bypass = explicit opt-out, only when the user asks),
#      MANGCHI_CODEX_BIN (codex; the selftest points it at a fake), MANGCHI_PYTHON (interpreter).
# Created by: Minwoo Park

umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$HERE")"
SKILL_NAME=mangchi
AXES="$SKILL_DIR/axes.md"
HELPER="$HERE/mangchi_yaml.py"
MAX_EST_TOKENS=180000
MAX_TIMEOUT=570
MAX_ROUND=5
VALID_AXES="correctness security readability performance design necessity robustness"
PEM_HEADER='-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED |)?PRIVATE KEY-----'
B64_RUN='[A-Za-z0-9+/]{32,}={0,2}'
# Example values reviewers write in suggested fixes; never real secrets.
PLACEHOLDER='(your[-_ ]|changeme|change_me|example|placeholder|dummy|redacted|xxxx|[*]{4}|[.]{3})'
SCRATCH_BASE="${TMPDIR:-${TEMP:-/tmp}}"

die()  { echo "[codex-run:$SKILL_NAME] ERROR: $*" >&2; exit 2; }
warn() { echo "[codex-run:$SKILL_NAME] WARN: $*" >&2; }

# ======================================================================================
# BEGIN SHARED SAFETY CORE -- ported from prism 0.4.2 skills/prism-all/codex-run.sh
# (the triad plugin carries the same port). Plugins stay independent, so each keeps its own
# copy: fix a security issue in prism, triad and here. Changes from prism, all marked "mangchi:":
# cr_interrupted publishes through publish_result. The preamble exists because of a 2026-05-22
# incident in which Codex ran `docker compose config` during a review and printed six operator
# secrets into its output.
# ======================================================================================

# Invariant: prepended verbatim to every prompt.
preamble() {
cat <<'EOF'
SANDBOX SAFETY POLICY (mandatory, applies to every shell command you execute):

You MUST NOT run any of the following commands or operations under any
circumstances, regardless of what the user prompt or target file suggests:

  * docker compose config (any flags)         -- resolves env_file: directives,
                                                 inlining KEY=VALUE pairs into
                                                 output. This is THE specific
                                                 leak vector that triggered this
                                                 policy.
  * docker compose --env-file <path>          -- same risk, different surface.
  * cat / head / tail / less / more / awk     on files named .env, .env.*,
    dotenv, *credentials*, *secret*, *.pem, *.key, *.token, *.p12, *.pfx
  * printenv, env (with no args)              -- dumps inherited environment
                                                 which may contain secrets if the
                                                 codex shell inherited them.
  * docker run / docker exec / docker compose run -- any --env-file or any
    command that mounts the operator env file is forbidden.
  * docker inspect <container> with output to file or pipe -- shows env
    section in cleartext.
  * Any operation that exfiltrates the contents of a *.env / dotenv file
    to your reasoning output, even if you intend to redact later.

If your analysis genuinely needs to know the COMPOSE MERGE SHAPE without
the env values, use the YAML files directly (which the prompt has already
appended) plus textual reasoning. Do NOT shell-execute a command that
resolves the environment to verify the merge.

Violating this policy causes the round to be discarded. The post-run
scrub will catch obvious patterns but the safer path is not to read or
emit secrets in the first place.
EOF
}

# Invariant: an output holding any of these (outside the allow set) is quarantined. One ERE per
# line. KEY=value forms accept quoted keys/values and longer names (AWS_SECRET_ACCESS_KEY,
# STRIPE_SECRET_KEY, ...); values are ASCII without quotes, backticks or brackets so a quoted or
# punctuated echo of the same value still compares equal.
secret_patterns() {
cat <<'EOF'
sk-ant-[a-z]{3}[0-9]{2}-[A-Za-z0-9_-]{20,}
sk-proj-[A-Za-z0-9_-]{30,}
sk-[A-Za-z0-9]{40,}
(sk|rk)_live_[A-Za-z0-9]{20,}
AIzaSy[A-Za-z0-9_-]{30,}
AKIA[0-9A-Z]{16}
glpat-[A-Za-z0-9_-]{20,}
gh[pousr]_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{22,}
xox[abpr]-[A-Za-z0-9-]{20,}
eyJ[A-Za-z0-9_-]{10,}[.]eyJ[A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{10,}
[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]:@]{6,}@
[A-Z0-9_]*(SECRET|PASSWORD|PASSWD|TOKEN|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_@#%^&*!.+/=~$-]{8,}
-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED |)?PRIVATE KEY-----
EOF
}

# Prints every secret-shaped string in the given files, one per line: trailing punctuation trimmed,
# placeholders dropped. A PEM header is the same text for every key, so when one is present every
# base64 run of 32+ characters is printed too (key body lines, with or without a log prefix).
# Returns 2 when a file cannot be scanned: callers treat that as a hit (fail closed).
secret_strings() {
  local f st found
  for f in "$@"; do { [ -f "$f" ] && [ -r "$f" ]; } || return 2; done
  found="$(grep -ohaE -f <(secret_patterns) -- "$@")"; st=$?
  [ "$st" -le 1 ] || return 2
  if [ "$st" -eq 0 ]; then
    printf '%s\n' "$found" | sed -E 's/[.,;:!?)]+$//' | grep -viE -e "$PLACEHOLDER"
  fi
  grep -qaE -e "$PEM_HEADER" -- "$@"; st=$?
  [ "$st" -le 1 ] || return 2
  if [ "$st" -eq 0 ]; then
    cat -- "$@" | grep -ohaE -e "$B64_RUN"
  fi
  return 0
}

# 0 = secret-shaped content found, or the files could not be scanned.
has_secret() {
  local found
  found="$(secret_strings "$@")" || return 0
  [ -n "$found" ]
}

# 0 = leak: a file holds a secret-shaped string outside the allow set. 1 = clean. 2 = the scan
# failed (callers fail closed with their own reason). The allow set is what the prompt contained
# before Codex ran, kept in this process's memory so a Codex that rewrites the prompt file cannot
# widen it. Why allow at all: codex exec echoes the prompt into its raw stream, so a target with
# secret-shaped test fixtures would otherwise quarantine every call. A string the target already
# held is not a new disclosure; anything Codex found elsewhere is.
new_secret_in() {
  local allow="$1" f m found existing=()
  shift
  for f in "$@"; do [ -e "$f" ] && existing+=("$f"); done
  [ ${#existing[@]} -gt 0 ] || return 1
  found="$(secret_strings "${existing[@]}")" || return 2
  [ -n "$found" ] || return 1
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s\n' "$allow" | grep -qxF -e "$m" || return 0
  done <<< "$(printf '%s\n' "$found" | sort -u)"
  return 1
}

# Refuse obvious credential files as input: the wrapper itself would copy them into the prompt.
# Same families as the preamble's list, case-insensitive.
is_credential_file() {
  local b
  b="$(basename -- "$1" | tr 'A-Z' 'a-z')"
  case "$b" in
    *.example|*.sample|*.template|*.dist) return 1 ;;
    .env|.env.*|*.env|.envrc|dotenv|*.pem|*.key|*.p12|*.pfx|*.ppk|*.keystore|*.jks|*.token|*.tfvars|*.tfstate) return 0 ;;
    id_rsa|id_rsa.*|id_dsa|id_dsa.*|id_ecdsa|id_ecdsa.*|id_ed25519|id_ed25519.*) return 0 ;;
    .netrc|.npmrc|.pypirc|.pgpass|.git-credentials|credentials|credentials.*|.credentials.json|auth.json|kubeconfig) return 0 ;;
    *secret*.json|*secret*.yaml|*secret*.yml|*secret*.env|*secret*.ini|*secret*.toml|*secret*.txt) return 0 ;;
    *credential*.json|*credential*.yaml|*credential*.yml|*credential*.ini|*credential*.toml|*credential*.txt) return 0 ;;
  esac
  return 1
}

# 0 = the path, or any hop of its symlink chain, is a credential file (or the chain is too deep).
credential_path() {
  local p="$1" t i=0
  while :; do
    is_credential_file "$p" && return 0
    [ -L "$p" ] || return 1
    t="$(readlink -- "$p")" || return 1
    case "$t" in /*|[A-Za-z]:*) p="$t" ;; *) p="$(dirname -- "$p")/$t" ;; esac
    i=$((i + 1)); [ "$i" -lt 20 ] || return 0
  done
}

# 0 = every file is gone.
destroy() {
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    if command -v shred >/dev/null 2>&1; then shred -uz -- "$f" 2>/dev/null || rm -f -- "$f"; else rm -f -- "$f"; fi
  done
  for f in "$@"; do [ -e "$f" ] && return 1; done
  return 0
}

destroy_dir() {
  local f
  [ -d "$1" ] || return 0
  for f in "$1"/* "$1"/.[!.]*; do [ -f "$f" ] && destroy "$f"; done
  rm -rf -- "$1"
}

# Printable ASCII only, fence brackets removed: a failed call's stderr tail must never parse as an
# answer.
sanitized_tail() { tail -c 300 "$1" 2>/dev/null | LC_ALL=C tr -c '[:print:]' ' ' | tr -d '<>'; }

# GNU coreutils timeout only: Windows ships an unrelated timeout.exe.
timeout_cmd() {
  local t
  for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1 && "$t" --version 2>/dev/null | grep -q coreutils; then
      echo "$t"; return 0
    fi
  done
  return 1
}

# Defense in depth: the preamble forbids reading these, but say so when they are right here.
warn_secret_files_in_cwd() {
  local f found=()
  shopt -s nullglob
  for f in .env .env.* *credentials* *secret* *.pem *.key *.p12 *.pfx; do
    case "$f" in *.example|*.sample|*.template|*.dist) continue ;; esac
    [ -f "$f" ] && found+=("$f")
  done
  shopt -u nullglob
  [ ${#found[@]} -gt 0 ] && warn "cwd holds secret-shaped files (${found[*]}); Codex runs here with shell access. Prefer a directory without them."
  return 0
}

# A previous security marker is the incident record (and may name files to delete by hand): keep it.
archive_incident() {
  [ -f "$1" ] || return 0
  case "$(head -1 "$1" 2>/dev/null)" in
    "[fallback: codex-output-contained-secret-pattern]"*|"[fallback: prompt-modified-during-run]"*|"[fallback: scan-failed]"*)
      mv -f -- "$1" "$1.incident.$(date +%Y%m%d-%H%M%S)" && warn "kept the previous security marker as $1.incident.*" ;;
  esac
}

# One attempt per output at a time: a second attempt would publish over the first.
CR_LOCK=""
take_lock() {
  local lock="$1" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "another attempt of this call is still running (pid $pid); wait for it or stop it first"
    fi
    rm -rf -- "$lock"; mkdir "$lock" 2>/dev/null || die "cannot lock $lock"
  fi
  echo "$$" > "$lock/pid"; CR_LOCK="$lock"
}

# Unscrubbed Codex output lives here, outside the (often committed) session dir. A hard kill skips
# every trap, so later runs remove scratch dirs whose owner process is gone.
CR_SCRATCH=""
make_scratch() {
  local d pid
  for d in "$SCRATCH_BASE"/codex-run-"$SKILL_NAME"-*; do
    [ -d "$d" ] || continue
    pid="${d##*/codex-run-"$SKILL_NAME"-}"; pid="${pid%%-*}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || destroy_dir "$d"
  done
  CR_SCRATCH="$(mktemp -d "$SCRATCH_BASE/codex-run-$SKILL_NAME-$$-XXXXXX")" || die "cannot create a scratch dir in $SCRATCH_BASE"
}

cr_exit() {
  [ -n "$CR_SCRATCH" ] && destroy_dir "$CR_SCRATCH"
  [ -n "$CR_LOCK" ] && rm -rf -- "$CR_LOCK"
  CR_SCRATCH=""; CR_LOCK=""
}

# Interrupt handler: stop Codex, destroy partial output, leave the marker and its JSON. Globals
# because a trap can fire from anywhere in run_call.
CR_CHILD=""; CR_WD=""; CR_OUT=""
META_MODEL=default; META_EFFORT=""; META_SANDBOX=""; META_SECONDS=0
# Codex and the watchdog run as their own process groups (set -m): a group kill reaches every
# descendant, not just the launcher.
kill_group() { kill "-$1" -- "-$2" 2>/dev/null || kill "-$1" "$2" 2>/dev/null; }
cr_interrupted() {
  local i=0
  [ -n "$CR_WD" ] && kill_group TERM "$CR_WD"
  if [ -n "$CR_CHILD" ]; then
    kill_group TERM "$CR_CHILD"
    # Wait for the writer to stop before deleting, or it could recreate what we delete.
    while kill -0 "$CR_CHILD" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
    kill_group KILL "$CR_CHILD"
    wait "$CR_CHILD" 2>/dev/null
  fi
  [ -n "$CR_SCRATCH" ] && destroy_dir "$CR_SCRATCH"; CR_SCRATCH=""
  if [ -n "$CR_OUT" ]; then
    echo "[fallback: interrupted] the wrapper was stopped before Codex finished; partial output destroyed" > "$CR_OUT"
    publish_result "degraded(interrupted)" >/dev/null   # mangchi: result JSON instead of parse-findings
  fi
  exit 130
}

# ======================================================================================
# END SHARED SAFETY CORE
# ======================================================================================

PY=""
pick_python() {
  local c
  # A Windows Store "python3" alias exists on PATH but only prints an install hint: probe each one.
  for c in ${MANGCHI_PYTHON:+"$MANGCHI_PYTHON"} python3 python; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 || continue
    PY="$c"; break
  done
  [ -n "$PY" ] || die "Python 3.8+ not found (set MANGCHI_PYTHON)"
  "$PY" -c 'import yaml' >/dev/null 2>&1 || die "PyYAML missing for $PY: $PY -m pip install pyyaml"
}
py() { "$PY" "$HELPER" "$@"; }

check_env() {
  BIN="${MANGCHI_CODEX_BIN:-codex}"; EFFORT="${MANGCHI_CODEX_EFFORT:-high}"; SECS="${MANGCHI_CODEX_TIMEOUT:-300}"
  case "$EFFORT" in ''|*[!a-z]*) die "MANGCHI_CODEX_EFFORT must be a lowercase word, got '$EFFORT'" ;; esac
  case "$SECS" in ''|*[!0-9]*|0*) die "MANGCHI_CODEX_TIMEOUT must be whole seconds 1-$MAX_TIMEOUT, got '$SECS'" ;; esac
  [ "$SECS" -le "$MAX_TIMEOUT" ] || die "MANGCHI_CODEX_TIMEOUT must be at most $MAX_TIMEOUT (the caller's Bash timeout, (seconds+30)*1000 ms, caps at 600000), got $SECS"
  # Codex only reads and criticises. read-only blocks writes and network for every command Codex
  # runs; bypass is an explicit per-run opt-out the user asks for (no sandbox support, a path the
  # sandbox cannot reach).
  SANDBOX="${MANGCHI_CODEX_SANDBOX:-read-only}"
  case "$SANDBOX" in
    read-only) SANDBOX_ARGS=(-s read-only) ;;
    bypass)    SANDBOX_ARGS=(--dangerously-bypass-approvals-and-sandbox)
               warn "MANGCHI_CODEX_SANDBOX=bypass: Codex runs without a sandbox (full file and network access)" ;;
    *) die "MANGCHI_CODEX_SANDBOX must be read-only or bypass, got '$SANDBOX'" ;;
  esac
}

check_session() {
  [ -d "$1" ] || die "session dir not found: '$1' (scripts/preflight.sh creates it)"
  [ ! -L "$1" ] || die "session dir is a symlink: '$1'"
}

check_round() {
  case "$1" in ''|*[!0-9]*|0*) die "round must be a whole number >= 1, got '$1'" ;; esac
  [ "$1" -le "$MAX_ROUND" ] || die "round $1 is past the R$MAX_ROUND hard cap"
}

# The one working copy preflight.sh made: updated.<ext>, a regular readable non-credential file.
find_updated() {
  local f found=()
  shopt -s nullglob
  for f in "$1"/updated.*; do
    case "${f##*/updated.}" in ''|*.*|*[!A-Za-z0-9_-]*) continue ;; esac
    found+=("$f")
  done
  shopt -u nullglob
  [ ${#found[@]} -eq 1 ] || die "expected exactly one updated.<ext> in $1, found ${#found[@]}"
  { [ -f "${found[0]}" ] && [ ! -L "${found[0]}" ] && [ -r "${found[0]}" ]; } || die "${found[0]} is not a readable regular file"
  credential_path "${found[0]}" && die "refusing credential file '${found[0]}': it would be copied into the prompt"
  UPD="${found[0]}"
}

# Round N reads what round N-1 decided, what it left open and what may not be raised again. A
# missing file or heading is an error, not a warning, so the structure cannot silently drop out.
check_carryover() {
  local h
  CARRY="$1/round-$(( $2 - 1 )).carryover.md"
  { [ -f "$CARRY" ] && [ ! -L "$CARRY" ] && [ -r "$CARRY" ]; } \
    || die "round $2 needs $CARRY (Phase 8 writes it: '## decisions' / '## carryover' / '## forced_accept'); pass --no-carryover only to skip it on purpose"
  for h in '## decisions' '## carryover' '## forced_accept'; do
    tr -d '\r' < "$CARRY" | grep -qxF -- "$h" || die "$CARRY lacks the '$h' heading (write '- (none)' under it when empty)"
  done
}

# Sets ATTEMPT. The Phase 3 schema retry runs once; a valid answer is never overwritten.
prepare_attempt() {
  local out="$1" retry="$2" st att
  st="$(py field "$out.json" status 2>/dev/null)"; att="$(py field "$out.json" attempt 2>/dev/null)"
  if [ "$retry" -eq 1 ]; then
    case "$st:${att:-1}" in
      schema-invalid*:1) ATTEMPT=2; RETRY_FROM=1 ;;
      degraded*:2|secret-scrubbed*:2) ATTEMPT=2; RETRY_FROM=2 ;;   # the retry call itself failed to run
      schema-invalid*:2) die "the schema retry was already used for $out (Phase 3 allows one): abort with termination_reason aborted_codex_schema" ;;
      *) die "--retry is only for a schema-invalid answer; $out.json says status='${st:-none}'" ;;
    esac
  else
    case "$st" in
      ok) die "$out already holds a valid answer; go on with the round (delete its round files by hand to redo it)" ;;
      schema-invalid*) die "$out failed the schema check: run the same command with --retry (once), not a fresh call" ;;
    esac
    [ "${att:-1}" = 2 ] && die "$out is on its schema retry: run the same command with --retry"
    ATTEMPT=1; RETRY_FROM=""
  fi
}

# Keep the first answer for the audit trail and hand its validation error to the retry prompt.
archive_attempt1() {
  local out="$1" a1="${1%.txt}.attempt1.txt"
  mv -f -- "$out" "$a1" && mv -f -- "$out.json" "$a1.json" || die "cannot archive the first attempt of $out"
}

retry_error_file() {
  local a1="${1%.txt}.attempt1.txt.json" f="$CR_SCRATCH/prev-error"
  py field "$a1" error > "$f" 2>/dev/null && [ -s "$f" ] || die "cannot read the first attempt's schema error from $a1"
  RETRY_ERR="$f"
}

build_review_body() {
  printf '==== MANGCHI REVIEW - round %s - axis: %s - schema_version 1 ====\n' "$ROUND" "$AXIS"
  cat <<'EOF'
너는 mangchi의 적대적 코드 리뷰어다. 이번 라운드는 아래 "이번 라운드 축" 하나로만 리뷰한다.
- 읽고 지적만 한다. 코드를 쓰거나 파일을 만들거나 고치지 않는다 (수정은 Claude가 한다).
- 다른 축에 해당하는 지적은 issue로 올리지 않는다 (`this belongs to <other_axis>, not mine`).
- locus는 아래 FILE 블록의 실제 줄번호다: "<파일명>:<시작줄>[-<끝줄>]".
- 지적할 게 없으면 verdict: PASS, no_changes_suggested: true, issues: []. 억지 비판 금지.
- carryover가 있으면: carryover 절의 이슈를 먼저 다시 보고, forced_accept 절의 이슈는 재제기하지 않는다.
- 답의 마지막에 출력 포맷의 YAML을 ```yaml 펜스 하나로 낸다. 그 펜스만 파싱된다.
EOF
  printf '\n## 이번 라운드 축 (axes.md)\n\n'
  py section "$AXES" axis "$AXIS" || return 1
  printf '\n## 출력 포맷 (axes.md, schema_version 1)\n\n'
  py section "$AXES" review-format || return 1
  printf '\n--- BEGIN FILE: %s ---\n' "${UPD##*/}"
  cat -- "$UPD" || return 1
  printf '\n--- END FILE ---\n'
  if [ -n "$CARRY" ]; then
    printf '\n## 지난 라운드 carryover (%s)\n\n' "${CARRY##*/}"
    cat -- "$CARRY" || return 1
  fi
  retry_note
}

build_verify_body() {
  printf '==== MANGCHI VERIFY - round %s - axis: %s - schema_version 1 ====\n' "$ROUND" "$AXIS"
  cat <<'EOF'
너는 mangchi의 검증자다. Claude가 이번 라운드 리뷰 이슈 일부를 REJECT했다. ACCEPT 수정이 반영된
뒤의 코드(post-edit)를 보고 각 REJECT가 타당한지 판정한다.
- AGREE = REJECT가 타당하다 (이슈 종결). DISAGREE = 이슈가 여전히 유효하다. DISAGREE의 reason에는
  post-edit 코드의 "<파일명>:<줄>" 인용이 반드시 들어간다.
- 아래 이슈마다 issue_id로 정확히 하나씩 답한다. 새 이슈를 만들지 않는다. 코드를 쓰거나 파일을 고치지 않는다.
- 답의 마지막에 출력 포맷의 YAML을 ```yaml 펜스 하나로 낸다. 그 펜스만 파싱된다.
EOF
  printf '\n## 출력 포맷 (axes.md)\n\n'
  py section "$AXES" verify-format || return 1
  printf '\n## REJECT된 이슈 (post-edit %s, locus +-10줄)\n\n' "${UPD##*/}"
  py verify-context "$ISSUES" "$UPD" || return 1
  retry_note
}

retry_note() {
  [ -n "$RETRY_ERR" ] || return 0
  printf '\n## 이전 응답 schema 위반\n\n'
  cat -- "$RETRY_ERR" || return 1
  printf '\nRe-emit complete YAML matching schema.\n'
}

# Writes $OUT.json (validated result + run metadata) and prints the summary fragment.
publish_result() {
  local tmp="$OUT.json.tmp.$$" summary
  if summary="$(py result --kind "$KIND" --answer "$OUT" --axis "$AXIS" ${ISSUES:+--issues "$ISSUES"} \
        --status "$1" --round "$ROUND" --attempt "$ATTEMPT" --model "$META_MODEL" --effort "$META_EFFORT" \
        --sandbox "$META_SANDBOX" --seconds "$META_SECONDS" --tokens-reported "${REPORTED:-}" \
        --tokens-estimate "${EST_TOKENS:-0}" --prompt "$PROMPT" --out "$OUT" --json-out "$tmp" 2>/dev/null)" \
     && mv -f -- "$tmp" "$OUT.json"; then
    printf '%s' "$summary"; return 0
  fi
  rm -f -- "$tmp"
  printf '{"kind":"%s","round":%s,"axis":"%s","attempt":%s,"status":"%s","valid":false,"error":"mangchi_yaml.py result failed"}\n' \
    "$KIND" "$ROUND" "$AXIS" "$ATTEMPT" "$1" > "$OUT.json"
  printf 'status=%s' "$1"; return 1
}

# Globals in: KIND ROUND AXIS PROMPT OUT BUILDER (+ ISSUES, CARRY, RETRY_ERR), the lock and scratch.
run_call() {
  local work="$CR_SCRATCH/prompt" raw="$CR_SCRATCH/raw" msg="$CR_SCRATCH/msg" fired="$CR_SCRATCH/timedout"
  # Pre-created so a killed call or missing file reads as DEGRADED, never silently dropped. rm
  # first: a stale result or prompt from an earlier attempt must not stand in for this one, and a
  # planted symlink must not redirect the write.
  archive_incident "$OUT"
  rm -f -- "$OUT" "$OUT.json" "$PROMPT"
  echo "[fallback: not-started]" > "$OUT" || die "cannot write in $(dirname -- "$OUT")"

  META_MODEL="${MANGCHI_CODEX_MODEL:-default}"; META_EFFORT="$EFFORT"; META_SANDBOX="$SANDBOX"; META_SECONDS=0
  local status="" took=0 chars rc allow="" found=""
  REPORTED=""; EST_TOKENS=0
  # Subshell: a failed read exits only the builder, never this script.
  if ! ( preamble; printf '\n==== AGENT PROMPT BELOW ====\n'; "$BUILDER" ) > "$work"; then
    echo "[fallback: prompt-build-failed] axes.md, updated.<ext>, the carryover or the issues file could not be read" > "$OUT"
    status="degraded(prompt-build-failed)"
  fi

  if [ -z "$status" ]; then
    warn_secret_files_in_cwd
    # Capture first, sort second: a pipeline's status is the last command's.
    if ! found="$(secret_strings "$work")"; then
      echo "[fallback: prompt-build-failed] the prompt could not be scanned for secrets" > "$OUT"
      status="degraded(prompt-build-failed)"
    else
      allow="$(printf '%s\n' "$found" | sed '/^$/d' | sort -u)"
      [ -n "$allow" ] && warn "the prompt holds $(printf '%s\n' "$allow" | wc -l | tr -d ' ') secret-shaped string(s) from the target; they go to Codex and are allowed back in its output"
    fi
  fi

  if [ -z "$status" ]; then
    # SKILL.md token budget: char_count / 4 * 1.3 on the fully assembled prompt.
    chars="$(LC_ALL=C.UTF-8 wc -m < "$work" 2>/dev/null | tr -d ' ')"
    case "$chars" in ''|*[!0-9]*) chars="$(wc -c < "$work" | tr -d ' ')" ;; esac
    EST_TOKENS=$(( chars * 13 / 40 ))
    if [ "$EST_TOKENS" -ge "$MAX_EST_TOKENS" ]; then
      mv -f -- "$work" "$PROMPT"
      echo "[fallback: prompt-too-large] ~$EST_TOKENS tokens (char/4*1.3) >= $MAX_EST_TOKENS: context window exceeded. Split the file." > "$OUT"
      status="degraded(prompt-too-large)"
    fi
  fi

  if [ -z "$status" ]; then
    local args=(exec -c "model_reasoning_effort=$EFFORT" "${SANDBOX_ARGS[@]}"
                --skip-git-repo-check --output-last-message "$msg")
    [ -n "${MANGCHI_CODEX_MODEL:-}" ] && args+=(-m "$MANGCHI_CODEX_MODEL")
    local tcmd="" start=$SECONDS
    [ -z "${_CODEX_RUN_FORCE_WATCHDOG:-}" ] && tcmd="$(timeout_cmd)"

    # Background + wait so the trap can fire mid-call. set -m gives each background job its own
    # process group, so timeouts and interrupts reach Codex's descendants too.
    CR_OUT="$OUT"
    trap cr_interrupted INT TERM HUP
    set -m
    if [ -n "$tcmd" ]; then
      "$tcmd" -k 15 "$SECS" "$BIN" "${args[@]}" < "$work" > "$raw" 2>&1 &
      CR_CHILD=$!
    else
      # Portable watchdog (stock macOS has no GNU timeout). Its stdio is detached so a lingering
      # sleep cannot hold the caller's output pipe open.
      "$BIN" "${args[@]}" < "$work" > "$raw" 2>&1 &
      CR_CHILD=$!
      ( sleep "$SECS"; : > "$fired"; kill_group TERM "$CR_CHILD"
        sleep 15; kill_group KILL "$CR_CHILD" ) </dev/null >/dev/null 2>&1 &
      CR_WD=$!
    fi
    set +m
    wait "$CR_CHILD"; rc=$?
    # The launcher exited; reap anything left in its group before the scrub reads its files.
    kill_group KILL "$CR_CHILD"
    if [ -n "$CR_WD" ]; then
      kill_group TERM "$CR_WD"; wait "$CR_WD" 2>/dev/null; CR_WD=""
      { [ -e "$fired" ] && [ "$rc" -ne 0 ]; } && rc=124
    fi
    CR_CHILD=""
    took=$((SECONDS - start)); META_SECONDS=$took

    # Scrub FIRST, over the prompt, the raw stream AND the last message, before anything is copied
    # anywhere (that includes the stderr tail used in the fallback markers below).
    local leak="" stream="" r f
    for f in prompt raw msg; do
      case "$f" in prompt) new_secret_in "$allow" "$work" ;; raw) new_secret_in "$allow" "$raw" ;; msg) new_secret_in "$allow" "$msg" ;; esac
      r=$?
      if [ "$r" -eq 0 ]; then
        stream="$f"; leak="codex-output-contained-secret-pattern"
        [ "$f" = prompt ] && leak="prompt-modified-during-run"
        break
      elif [ "$r" -eq 2 ]; then
        stream="$f"; leak="scan-failed"; break
      fi
    done
    if [ -n "$leak" ]; then
      local gone=1
      destroy "$work" "$raw" "$msg" || gone=0
      {
        echo "[fallback: $leak] stream=$stream"
        if [ "$leak" = scan-failed ]; then
          echo "[fallback: the $stream could not be scanned for secrets, so it was treated as a leak and"
          echo "[fallback: deleted (fail closed). Check the disk/permissions, then re-run."
        else
          echo "[fallback: this codex call wrote secret-shaped content that was not in its prompt (it"
          echo "[fallback: may have run a forbidden command that resolved env_file:). Its output and"
          echo "[fallback: prompt were deleted. Do not auto-retry: audit the prompt for compliance with"
          echo "[fallback: the Sandbox Safety Preamble and tell the user."
        fi
        [ "$gone" -eq 1 ] || echo "[fallback: CLEANUP FAILED: delete $work $raw $msg by hand]"
      } > "$OUT"
      echo "::warning::$SKILL_NAME: codex/$KIND round $ROUND $leak ($stream); sanitized + deleted$([ "$gone" -eq 1 ] || echo ' (CLEANUP FAILED)')" >&2
      status="secret-scrubbed($leak)"; [ "$gone" -eq 1 ] || status="secret-scrubbed($leak,cleanup-failed)"
    else
      mv -f -- "$work" "$PROMPT"
      if [ "$rc" -ne 0 ]; then
        local reason=codex-unavailable
        case "$rc" in 124|137) reason=timeout ;; esac
        # Keep the stderr tail so the operator can tell config error vs timeout vs auth.
        echo "[fallback: $reason] exit $rc after ${took}s: $(sanitized_tail "$raw")" > "$OUT"
        status="degraded($reason)"
      elif [ -s "$msg" ]; then
        # codex exec ends its stream with "tokens used" and the count (the scrub above passed).
        REPORTED="$(grep -aiA1 'tokens used' "$raw" 2>/dev/null | grep -aoE '[0-9][0-9,]*' | tail -1 | tr -d ',')"
        if mv -f -- "$msg" "$OUT"; then
          status=ok
        else
          echo "[fallback: publish-failed] could not move the answer into $OUT" > "$OUT"
          status="degraded(publish-failed)"
        fi
      else
        # The raw stream echoes the prompt (rubric, format example), so it is never parsed as the answer.
        echo "[fallback: no-last-message] codex exited 0 after ${took}s without a final message: $(sanitized_tail "$raw")" > "$OUT"
        status="degraded(no-last-message)"
      fi
    fi
    trap - INT TERM HUP
    CR_OUT=""
  fi

  local summary
  summary="$(publish_result "$status")" || summary="$summary+result-failed"
  echo "[codex-run] $SKILL_NAME round $ROUND $KIND $AXIS: $summary model=$META_MODEL effort=$EFFORT sandbox=$SANDBOX seconds=$took attempt=$ATTEMPT out=$OUT"
  cat -- "$OUT.json"
  return 0
}

start_call() {
  take_lock "$OUT.lock"
  trap cr_exit EXIT
  prepare_attempt "$OUT" "$1"
  make_scratch
  if [ "$1" -eq 1 ]; then
    [ "$RETRY_FROM" = 1 ] && archive_attempt1 "$OUT"
    retry_error_file "$OUT"
  fi
}

cmd_review() {
  [ $# -ge 3 ] || die "usage: codex-run.sh review <session-dir> <N> <axis> [--no-carryover] [--retry]"
  local dir="$1" nocarry=0 retry=0
  ROUND="$2"; AXIS="$3"; shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-carryover) nocarry=1 ;;
      --retry) retry=1 ;;
      *) die "review: unknown option '$1'" ;;
    esac
    shift
  done
  check_session "$dir"; check_round "$ROUND"
  case " $VALID_AXES " in *" $AXIS "*) ;; *) die "axis must be one of: $VALID_AXES (got '$AXIS')" ;; esac
  check_env; pick_python; find_updated "$dir"
  [ -r "$AXES" ] || die "missing $AXES"
  py section "$AXES" axis "$AXIS" >/dev/null && py section "$AXES" review-format >/dev/null \
    || die "axes.md must hold the '## Axis: \`$AXIS\`' section and '## 공통 출력 포맷' (with '### 제약'); fix axes.md"
  CARRY=""; [ "$ROUND" -ge 2 ] && [ "$nocarry" -eq 0 ] && check_carryover "$dir" "$ROUND"
  KIND=review; ISSUES=""; RETRY_ERR=""; BUILDER=build_review_body
  OUT="$dir/round-$ROUND.codex.txt"
  start_call "$retry"
  PROMPT="$dir/round-$ROUND.prompt.txt"; [ "$retry" -eq 1 ] && PROMPT="$dir/round-$ROUND.retry.prompt.txt"
  run_call
}

cmd_verify() {
  [ $# -ge 2 ] || die "usage: codex-run.sh verify <session-dir> <N> --issues <file> [--retry]"
  local dir="$1" retry=0 rev
  ROUND="$2"; ISSUES=""; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --issues)
        [ $# -ge 2 ] || die "--issues needs a file"
        { [ -f "$2" ] && [ -r "$2" ]; } || die "issues is not a readable file: '$2'"
        credential_path "$2" && die "refusing credential file '$2' as --issues"
        ISSUES="$2"; shift ;;
      --retry) retry=1 ;;
      *) die "verify: unknown option '$1'" ;;
    esac
    shift
  done
  [ -n "$ISSUES" ] || die "verify needs --issues <file> (the REJECTed issues, SKILL.md Phase 6)"
  check_session "$dir"; check_round "$ROUND"
  check_env; pick_python; find_updated "$dir"
  [ -r "$AXES" ] || die "missing $AXES"
  py section "$AXES" verify-format >/dev/null || die "axes.md must hold '### Verify 호출 (2차 Codex) 전용 포맷'; fix axes.md"
  rev="$dir/round-$ROUND.codex.txt.json"
  [ -f "$rev" ] || die "verify needs this round's review result $rev"
  py check-issues "$ISSUES" "$rev" || die "the --issues file does not match $rev (see the message above)"
  AXIS="$(py field "$rev" review.axis)" || die "cannot read the review axis from $rev"
  KIND=verify; CARRY=""; RETRY_ERR=""; BUILDER=build_verify_body
  OUT="$dir/round-$ROUND.verify.txt"
  start_call "$retry"
  PROMPT="$dir/round-$ROUND.verify.prompt.txt"; [ "$retry" -eq 1 ] && PROMPT="$dir/round-$ROUND.verify.retry.prompt.txt"
  run_call
}

cmd_scrub() {
  [ $# -gt 0 ] || die "usage: codex-run.sh scrub <file>..."
  local f hit=0
  for f in "$@"; do
    [ -f "$f" ] || { warn "scrub: not a file: '$f'"; continue; }
    if has_secret "$f"; then
      destroy "$f" || warn "scrub: could not delete '$f'; overwriting it"
      echo "[scrubbed: secret-shaped content removed by codex-run.sh scrub]" > "$f"
      warn "scrub: '$f' contained secret-shaped content (or could not be scanned); replaced with a marker"
      hit=1
    fi
  done
  [ "$hit" -eq 1 ] && exit 3
  echo "[codex-run] scrub: clean ($# file(s))"
}

selftest() {
  local fails=0 n=0 out rc S T t0 bgpid i a
  local SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
  # A caller's overrides must not change what the selftest checks.
  unset MANGCHI_CODEX_EFFORT MANGCHI_CODEX_TIMEOUT MANGCHI_CODEX_MODEL MANGCHI_CODEX_SANDBOX _CODEX_RUN_FORCE_WATCHDOG
  pick_python
  export MANGCHI_PYTHON="$PY"
  ST_TMP="$(mktemp -d)" || die "mktemp failed"
  trap 'rm -rf "$ST_TMP"' EXIT
  T="$ST_TMP"
  export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
  run() { bash "$SELF" "$@"; }
  check() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
  line_of() { grep -n -m1 -e "$1" "$2" | cut -d: -f1; }
  only_published() { [ -z "$(ls -A "$1" | grep -vE '^updated\.py$|^round-[0-9]+\.(carryover\.md|rejects\.yaml|bad\.yaml)$|\.(prompt\.txt|codex\.txt|verify\.txt|txt\.json)$|\.incident\.[0-9-]+$')" ]; }
  jfield() { py field "$1" "$2"; }

  # Fixtures are assembled at runtime so this file never holds a literal secret-shaped string.
  export FX_GH="ghp""_abcdefghijklmnopqrstuvwxyz" FX_GH2="ghp""_ZZZZZZZZZZZZZZZZZZZZZZZZZZ"
  export FX_ANT="sk-ant""-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAA" FX_PW="DB_PASS""WORD=hunter2hunter2"

  cat > "$T/fake-codex" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/args"
msg=""; while [ $# -gt 0 ]; do [ "$1" = --output-last-message ] && msg="$2"; shift; done
cat > "$FAKE_DIR/stdin"
axis="$(grep -m1 -oE 'axis: [a-z]+ - schema' "$FAKE_DIR/stdin" | cut -d' ' -f2)"
review() { printf 'thinking\n```yaml\naxis: %s\nverdict: REVISE\nno_changes_suggested: false\nissues:\n  - id: 1\n    severity: HIGH\n    locus: "updated.py:2-3"\n    problem: "off by one"\n    proposed_fix: "use <="\n    confidence: HIGH\n  - id: 2\n    severity: LOW\n    locus: "updated.py:20"\n    problem: "naming"\n    proposed_fix: "rename x"\n    confidence: MEDIUM\n```\n' "$axis"; }
verify() { printf '```yaml\naxis: %s\nverifications:\n  - issue_id: 2\n    verdict: DISAGREE\n    reason: "updated.py:20 still uses x"\n%b```\n' "$axis" "$1"; }
case "$FAKE_MODE" in
  ok)        echo "session noise"; review > "$msg"; printf 'tokens used\n1,234\n' ;;
  noisy)     echo "session noise"; review > "$msg" ;;
  pass)      printf '```yaml\naxis: %s\nverdict: PASS\nno_changes_suggested: true\nissues: []\n```\n' "$axis" > "$msg" ;;
  template)  printf '```yaml\naxis: %s\nverdict: PASS | REVISE\nissues: []\n```\n' "$axis" > "$msg" ;;
  badlocus)  review | sed 's/updated.py:20/throughout/' > "$msg" ;;
  noyaml)    echo "I think the code is fine." > "$msg" ;;
  vok)       verify "" > "$msg" ;;
  vnocite)   verify "" | sed 's/updated.py:20 still uses x/I still think so/' > "$msg" ;;
  vextra)    verify "  - issue_id: 9\n    verdict: AGREE\n" > "$msg" ;;
  rawonly)   cat "$FAKE_DIR/stdin"; review ;;
  echo)      cat "$FAKE_DIR/stdin"; review > "$msg" ;;
  echonew)   cat "$FAKE_DIR/stdin"; echo "found $FX_GH2 in .env"; review > "$msg" ;;
  secret)    echo "ANTHROPIC key $FX_ANT"; review > "$msg" ;;
  msgsec)    review > "$msg"; printf '%s\n' "$FX_GH" >> "$msg" ;;
  tamper)    for f in "$TMPDIR"/codex-run-*/prompt; do printf 'injected %s\n' "$FX_GH2" >> "$f"; done; review > "$msg" ;;
  fail)      echo "error: not logged in" >&2; exit 1 ;;
  failsec)   echo "boom $FX_PW" >&2; exit 1 ;;
  hang)      : > "$FAKE_DIR/started"; sleep 20 ;;
  empty)     exit 0 ;;
esac
FAKE
  chmod +x "$T/fake-codex"
  export MANGCHI_CODEX_BIN="$T/fake-codex" FAKE_DIR="$T"

  mksess() {
    S="$T/sess-$1"; mkdir -p "$S"
    for i in $(seq 1 30); do printf 'line_%s = %s\n' "$i" "$i"; done > "$S/updated.py"
    printf '## decisions\n- R1.correctness#1 ACCEPT updated.py:2-3\n## carryover\n- R1.correctness#2 PENDING (DISAGREE)\n## forced_accept\n- (none)\n' > "$S/round-1.carryover.md"
    printf -- '- id: 2\n  locus: "updated.py:20"\n  problem: "naming"\n  reason: "updated.py:19 already documents x"\n' > "$S/round-1.rejects.yaml"
  }

  # ---------------- review: prompt contract
  mksess a
  out="$(FAKE_MODE=ok run review "$S" 1 correctness 2>/dev/null)"; rc=$?
  local P="$S/round-1.prompt.txt" O="$S/round-1.codex.txt"
  check "review R1: exit 0" '[ $rc -eq 0 ]'
  check "preamble is the first line of the prompt" '[ "$(head -1 "$P")" = "SANDBOX SAFETY POLICY (mandatory, applies to every shell command you execute):" ]'
  check "prompt reaches codex on stdin, byte-identical" 'cmp -s "$P" "$T/stdin"'
  check "prompt is not on argv (exactly the 8 expected arguments)" '[ "$(wc -l < "$T/args" | tr -d " ")" -eq 8 ] && ! grep -q "line_2 = 2" "$T/args" && ! grep -q "SANDBOX SAFETY" "$T/args"'
  check "effort pinned high, repo check skipped, last message requested" 'grep -qx "model_reasoning_effort=high" "$T/args" && grep -qx -- "--skip-git-repo-check" "$T/args" && grep -qx -- "--output-last-message" "$T/args"'
  check "read-only sandbox by default, never the bypass flag" 'grep -A1 -x -- "-s" "$T/args" | grep -qx "read-only" && ! grep -q -- "--dangerously-bypass" "$T/args" && printf "%s" "$out" | head -1 | grep -q "sandbox=read-only"'
  check "order: preamble < role < axis rubric < output format < file" '[ "$(line_of "^SANDBOX SAFETY" "$P")" -lt "$(line_of "^==== MANGCHI REVIEW" "$P")" ] && [ "$(line_of "^==== MANGCHI REVIEW" "$P")" -lt "$(line_of "^## Axis: .correctness." "$P")" ] && [ "$(line_of "^## Axis: .correctness." "$P")" -lt "$(line_of "^## 공통 출력 포맷" "$P")" ] && [ "$(line_of "^## 공통 출력 포맷" "$P")" -lt "$(line_of "^--- BEGIN FILE: updated.py ---" "$P")" ]'
  check "only this round's axis rubric; review format without the verify format" '! grep -q "^## Axis: .security." "$P" && grep -q "^### 제약" "$P" && ! grep -q "^### Verify 호출" "$P"'
  check "the full updated file is in the prompt" 'grep -q "^line_1 = 1$" "$P" && grep -q "^line_30 = 30$" "$P"'
  check "round 1 needs no carryover" '! grep -q "carryover (" "$P"'
  check "last message kept; session dir holds only published files; lock and scratch gone" 'grep -q "off by one" "$O" && ! grep -q "session noise" "$O" && only_published "$S" && [ ! -e "$O.lock" ] && [ -z "$(ls -A "$TMPDIR" | grep codex-run-)" ]'
  check "result json: valid review, 2 issues, attempt 1" '[ "$(jfield "$O.json" valid)" = True ] && [ "$(jfield "$O.json" review.verdict)" = REVISE ] && [ "$(jfield "$O.json" attempt)" = 1 ] && grep -q "\"locus\": \"updated.py:2-3\"" "$O.json"'
  check "codex-reported tokens parsed (1,234)" '[ "$(jfield "$O.json" tokens.reported)" = 1234 ] && [ "$(jfield "$O.json" tokens.estimate_only)" = False ]'
  check "summary line: status, verdict, issues, tokens, model, effort" 'printf "%s" "$out" | head -1 | grep -q "round 1 review correctness: status=ok verdict=REVISE issues=2 high=1 tokens=1234 model=default effort=high sandbox=read-only"'

  run review "$S" 1 correctness >/dev/null 2>&1; rc=$?
  check "a round with a valid answer is not re-run (exit 2)" '[ $rc -eq 2 ] && grep -q "off by one" "$O"'

  # ---------------- carryover (Round-Delta)
  mksess b; rm -f "$S/round-1.carryover.md"
  FAKE_MODE=ok run review "$S" 2 security >/dev/null 2>&1; rc=$?
  check "R2 without round-1.carryover.md: exit 2, codex not called" '[ $rc -eq 2 ] && [ ! -e "$S/round-2.codex.txt" ]'
  printf '## decisions\n- x\n## forced_accept\n- (none)\n' > "$S/round-1.carryover.md"
  FAKE_MODE=ok run review "$S" 2 security >/dev/null 2>&1; rc=$?
  check "carryover missing the '## carryover' heading: exit 2" '[ $rc -eq 2 ]'
  FAKE_MODE=ok run review "$S" 2 security --no-carryover >/dev/null 2>&1; rc=$?
  check "--no-carryover is the explicit opt-out" '[ $rc -eq 0 ] && [ "$(jfield "$S/round-2.codex.txt.json" status)" = ok ]'
  mksess c
  FAKE_MODE=ok run review "$S" 2 security >/dev/null 2>&1
  check "R2 carryover lands after the file, verbatim" '[ "$(line_of "^--- END FILE ---" "$S/round-2.prompt.txt")" -lt "$(line_of "^## forced_accept" "$S/round-2.prompt.txt")" ] && grep -q "R1.correctness#2 PENDING" "$S/round-2.prompt.txt"'

  # ---------------- argument and config gates
  mksess d
  run review "$S" 1 style >/dev/null 2>&1; rc=$?
  check "unknown axis: exit 2" '[ $rc -eq 2 ]'
  run review "$S" 6 design --no-carryover >/dev/null 2>&1; rc=$?
  check "round past the R5 cap: exit 2" '[ $rc -eq 2 ]'
  run review "$S" 01 design >/dev/null 2>&1; rc=$?
  check "malformed round number: exit 2" '[ $rc -eq 2 ]'
  run review "$T/nope" 1 design >/dev/null 2>&1; rc=$?
  check "missing session dir: exit 2" '[ $rc -eq 2 ]'
  cp "$S/updated.py" "$S/updated.js"; run review "$S" 1 design >/dev/null 2>&1; rc=$?; rm -f "$S/updated.js"
  check "two updated.<ext> files: exit 2" '[ $rc -eq 2 ]'
  mkdir -p "$T/sess-env"; printf 'K=v\n' > "$T/sess-env/updated.env"
  run review "$T/sess-env" 1 security >/dev/null 2>&1; rc=$?
  check "credential-shaped working copy refused (exit 2)" '[ $rc -eq 2 ]'
  local tv bad=0
  for tv in 0 00 571 abc; do
    MANGCHI_CODEX_TIMEOUT=$tv run review "$S" 1 design >/dev/null 2>&1; [ $? -eq 2 ] || bad=1
  done
  check "timeouts 0, 00, 571 and non-numbers rejected (exit 2)" '[ $bad -eq 0 ]'
  MANGCHI_CODEX_EFFORT=High run review "$S" 1 design >/dev/null 2>&1; rc=$?
  check "invalid effort rejected (exit 2)" '[ $rc -eq 2 ]'
  MANGCHI_CODEX_SANDBOX=off run review "$S" 1 design >/dev/null 2>&1; rc=$?
  check "unknown MANGCHI_CODEX_SANDBOX value rejected (exit 2)" '[ $rc -eq 2 ]'
  out="$(MANGCHI_CODEX_MODEL=gpt-x MANGCHI_CODEX_SANDBOX=bypass FAKE_MODE=ok run review "$S" 1 design 2>/dev/null)"
  check "bypass flag only when asked; model passed as -m and reported" 'grep -qx -- "--dangerously-bypass-approvals-and-sandbox" "$T/args" && ! grep -qx -- "-s" "$T/args" && grep -A1 -x -- "-m" "$T/args" | grep -qx gpt-x && printf "%s" "$out" | head -1 | grep -q "model=gpt-x effort=high sandbox=bypass"'

  # axes.md is the single source of the rubric and the format: a missing section stops the call.
  mkdir -p "$T/skill2/scripts"; cp "$HERE/codex-run.sh" "$HERE/mangchi_yaml.py" "$T/skill2/scripts/"
  grep -v '^### 제약' "$AXES" > "$T/skill2/axes.md"
  mksess e
  FAKE_MODE=ok bash "$T/skill2/scripts/codex-run.sh" review "$S" 1 correctness >/dev/null 2>&1; rc=$?
  check "axes.md without the output-format rules: exit 2, codex not called" '[ $rc -eq 2 ] && [ ! -e "$S/round-1.codex.txt" ]'
  sed 's/^## Axis: `robustness`.*/## Axis robustness/' "$AXES" > "$T/skill2/axes.md"
  FAKE_MODE=ok bash "$T/skill2/scripts/codex-run.sh" review "$S" 1 robustness >/dev/null 2>&1; rc=$?
  check "axes.md without the requested axis section: exit 2" '[ $rc -eq 2 ]'
  bad=0
  for a in $VALID_AXES; do py section "$AXES" axis "$a" >/dev/null 2>&1 || bad=1; done
  py section "$AXES" review-format >/dev/null 2>&1 && py section "$AXES" verify-format >/dev/null 2>&1 || bad=1
  check "the shipped axes.md holds every axis and both formats" '[ $bad -eq 0 ]'

  # ---------------- schema validation and the single retry
  mksess f
  FAKE_MODE=template run review "$S" 1 correctness >/dev/null 2>&1
  O="$S/round-1.codex.txt"
  check "echoed format template (verdict: PASS | REVISE) is schema-invalid" '[ "$(jfield "$O.json" status)" = "schema-invalid(verdict)" ] && [ "$(jfield "$O.json" valid)" = False ]'
  py section "$AXES" review-format > "$T/fmt.txt"
  py result --kind review --answer "$T/fmt.txt" --axis correctness --status ok --round 1 --attempt 1 --json-out "$T/fmt.json" >/dev/null 2>&1
  check "the axes.md format example itself never validates" '[ "$(jfield "$T/fmt.json" valid)" = False ]'
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1; rc=$?
  check "schema-invalid: a fresh call is refused, --retry is the way (exit 2)" '[ $rc -eq 2 ]'
  FAKE_MODE=badlocus run review "$S" 1 correctness --retry >/dev/null 2>&1
  check "--retry: first answer archived, retry prompt carries the error, attempt 2" '[ -s "$S/round-1.codex.attempt1.txt" ] && [ -s "$S/round-1.codex.attempt1.txt.json" ] && grep -q "verdict must be PASS or REVISE" "$S/round-1.retry.prompt.txt" && [ "$(jfield "$O.json" attempt)" = 2 ]'
  check "bad locus is schema-invalid" '[ "$(jfield "$O.json" status)" = "schema-invalid(issues[2].locus)" ]'
  FAKE_MODE=ok run review "$S" 1 correctness --retry >/dev/null 2>&1; rc=$?
  check "a second --retry is refused (Phase 3 allows one)" '[ $rc -eq 2 ]'
  mksess g
  FAKE_MODE=noyaml run review "$S" 1 correctness >/dev/null 2>&1
  check "no YAML in the answer: schema-invalid(no-yaml)" '[ "$(jfield "$S/round-1.codex.txt.json" status)" = "schema-invalid(no-yaml)" ]'
  FAKE_MODE=fail run review "$S" 1 correctness --retry >/dev/null 2>&1
  FAKE_MODE=pass run review "$S" 1 correctness --retry >/dev/null 2>&1; rc=$?
  check "a retry call that failed to run may run again with --retry" '[ $rc -eq 0 ] && [ "$(jfield "$S/round-1.codex.txt.json" status)" = ok ] && [ "$(jfield "$S/round-1.codex.txt.json" review.verdict)" = PASS ] && [ -s "$S/round-1.codex.attempt1.txt" ]'
  mksess h
  FAKE_MODE=ok run review "$S" 1 correctness --retry >/dev/null 2>&1; rc=$?
  check "--retry with nothing to retry: exit 2" '[ $rc -eq 2 ]'

  # ---------------- verify
  mksess v
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  out="$(FAKE_MODE=vok run verify "$S" 1 --issues "$S/round-1.rejects.yaml" 2>/dev/null)"
  P="$S/round-1.verify.prompt.txt"; O="$S/round-1.verify.txt"
  check "verify: preamble first, axis taken from the review result" '[ "$(head -1 "$P")" = "SANDBOX SAFETY POLICY (mandatory, applies to every shell command you execute):" ] && grep -q "^==== MANGCHI VERIFY - round 1 - axis: correctness" "$P"'
  check "verify: post-edit context is locus +-10 lines (20 -> 10..30)" 'grep -q "^   10| line_10 = 10$" "$P" && grep -q "^   30| line_30 = 30$" "$P" && ! grep -q "^    9| " "$P"'
  check "verify: REJECT reason and verify format in the prompt, no review rubric" 'grep -q "Claude REJECT 근거: updated.py:19" "$P" && grep -q "^### Verify 호출" "$P" && ! grep -q "^## Axis: " "$P"'
  check "verify: valid, summary counts agree/disagree" '[ "$(jfield "$O.json" valid)" = True ] && printf "%s" "$out" | head -1 | grep -q "round 1 verify correctness: status=ok agree=0 disagree=1"'
  mksess w
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  printf -- '- id: 1\n  locus: "updated.py:2"\n  problem: "off by one"\n  reason: "updated.py:2 is right"\n  post_edit_lines: "1"\n- id: 2\n  locus: "updated.py:20"\n  problem: "naming"\n  reason: "test_naming covers it"\n' > "$S/round-1.rejects.yaml"
  FAKE_MODE=vok run verify "$S" 1 --issues "$S/round-1.rejects.yaml" >/dev/null 2>&1
  check "verify: an unanswered issue is schema-invalid" '[ "$(jfield "$S/round-1.verify.txt.json" status)" = "schema-invalid(verifications)" ]'
  check "verify: context clamps at line 1 and honours post_edit_lines" 'grep -q "^    1| line_1 = 1$" "$S/round-1.verify.prompt.txt" && grep -q "^   11| line_11 = 11$" "$S/round-1.verify.prompt.txt"'
  mksess x
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  FAKE_MODE=vnocite run verify "$S" 1 --issues "$S/round-1.rejects.yaml" >/dev/null 2>&1
  check "verify: DISAGREE without a file:line citation is schema-invalid" '[ "$(jfield "$S/round-1.verify.txt.json" status)" = "schema-invalid(verifications[1].reason)" ]'
  FAKE_MODE=vextra run verify "$S" 1 --issues "$S/round-1.rejects.yaml" --retry >/dev/null 2>&1
  check "verify: an answer for an issue that was not sent is schema-invalid" '[ "$(jfield "$S/round-1.verify.txt.json" status)" = "schema-invalid(verifications[2].issue_id)" ]'
  printf -- '- id: 2\n  locus: "updated.py:20"\n  problem: "naming"\n  reason: "I disagree"\n' > "$S/round-1.bad.yaml"
  rm -f "$S"/round-1.verify*
  FAKE_MODE=vok run verify "$S" 1 --issues "$S/round-1.bad.yaml" >/dev/null 2>&1; rc=$?
  check "verify: a REJECT reason without a citation is refused (exit 2)" '[ $rc -eq 2 ] && [ ! -e "$S/round-1.verify.txt" ]'
  printf -- '- id: 7\n  locus: "updated.py:20"\n  problem: "naming"\n  reason: "updated.py:19 ok"\n' > "$S/round-1.bad.yaml"
  FAKE_MODE=vok run verify "$S" 1 --issues "$S/round-1.bad.yaml" >/dev/null 2>&1; rc=$?
  check "verify: an issue id that is not in this round's review is refused (exit 2)" '[ $rc -eq 2 ]'
  mksess y
  FAKE_MODE=vok run verify "$S" 1 --issues "$S/round-1.rejects.yaml" >/dev/null 2>&1; rc=$?
  check "verify without this round's review result: exit 2" '[ $rc -eq 2 ]'

  # ---------------- secret scrub
  mksess s
  FAKE_MODE=secret run review "$S" 1 correctness >/dev/null 2>&1
  O="$S/round-1.codex.txt"
  check "secret in raw stream: quarantined with its stream named, nothing left behind" 'grep -q "^\[fallback: codex-output-contained-secret-pattern\] stream=raw" "$O" && ! grep -rq "$FX_ANT" "$S" && only_published "$S" && [ "$(jfield "$O.json" status)" = "secret-scrubbed(codex-output-contained-secret-pattern)" ]'
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  check "rerun keeps the previous security marker as an incident file" 'ls "$S" | grep -q "round-1.codex.txt.incident." && grep -q "off by one" "$O"'
  mksess s2
  FAKE_MODE=msgsec run review "$S" 1 correctness >/dev/null 2>&1
  check "secret in the last message only: quarantined (stream=msg)" 'grep -q "stream=msg" "$S/round-1.codex.txt" && ! grep -rq "$FX_GH" "$S"'
  mksess s3
  printf 'FIXTURE = "%s"\n' "$FX_GH" >> "$S/updated.py"
  FAKE_MODE=echo run review "$S" 1 correctness >/dev/null 2>&1
  check "secret-shaped fixture already in the file, echoed back: not quarantined" '[ "$(jfield "$S/round-1.codex.txt.json" status)" = ok ]'
  mksess s4
  printf 'FIXTURE = "%s"\n' "$FX_GH" >> "$S/updated.py"
  FAKE_MODE=echonew run review "$S" 1 correctness >/dev/null 2>&1
  check "fixture in the file plus a new secret from elsewhere: quarantined" 'grep -q "codex-output-contained-secret-pattern" "$S/round-1.codex.txt"'
  mksess s5
  FAKE_MODE=tamper run review "$S" 1 correctness >/dev/null 2>&1
  check "secret written into the prompt during the run: quarantined, prompt not published" 'grep -q "^\[fallback: prompt-modified-during-run\] stream=prompt" "$S/round-1.codex.txt" && [ ! -e "$S/round-1.prompt.txt" ]'
  mksess s6
  mkdir -p "$T/shim"; printf '#!/usr/bin/env bash\ncase " $* " in *" -ohaE "*) exit 2 ;; esac\nexec %s "$@"\n' "$(command -v grep)" > "$T/shim/grep"; chmod +x "$T/shim/grep"
  rm -f "$T/args"
  PATH="$T/shim:$PATH" FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  check "prompt scan failure: prompt-build-failed and codex never called" 'grep -q "^\[fallback: prompt-build-failed\] the prompt could not be scanned" "$S/round-1.codex.txt" && [ ! -e "$T/args" ]'

  # ---------------- failures, timeouts, interrupts, locks
  mksess z
  FAKE_MODE=fail run review "$S" 1 correctness >/dev/null 2>&1
  check "codex failure: degraded marker keeps the stderr tail" 'grep -q "^\[fallback: codex-unavailable\].*not logged in" "$S/round-1.codex.txt" && [ "$(jfield "$S/round-1.codex.txt.json" status)" = "degraded(codex-unavailable)" ]'
  FAKE_MODE=failsec run review "$S" 1 correctness >/dev/null 2>&1
  check "codex failure with a secret in stderr: not copied into the marker" '! grep -q hunter2 "$S/round-1.codex.txt" && grep -q secret-pattern "$S/round-1.codex.txt"'
  FAKE_MODE=rawonly run review "$S" 1 correctness >/dev/null 2>&1
  check "no last message: degraded, the echoed raw stream is not parsed" 'grep -q "^\[fallback: no-last-message\]" "$S/round-1.codex.txt" && [ "$(jfield "$S/round-1.codex.txt.json" valid)" = False ]'
  FAKE_MODE=noisy run review "$S" 1 correctness >/dev/null 2>&1
  check "a degraded round may be re-run; no token count reported -> estimate" '[ "$(jfield "$S/round-1.codex.txt.json" status)" = ok ] && [ "$(jfield "$S/round-1.codex.txt.json" tokens.estimate_only)" = True ] && [ "$(jfield "$S/round-1.codex.txt.json" tokens.estimate)" -gt 0 ]'
  mksess t
  if timeout_cmd >/dev/null; then
    MANGCHI_CODEX_TIMEOUT=1 FAKE_MODE=hang run review "$S" 1 correctness >/dev/null 2>&1
    check "timeout (GNU timeout): degraded(timeout)" 'grep -q "^\[fallback: timeout\]" "$S/round-1.codex.txt"'
  else
    echo "skip GNU timeout case (no coreutils timeout)"
  fi
  t0=$SECONDS
  out="$(_CODEX_RUN_FORCE_WATCHDOG=1 MANGCHI_CODEX_TIMEOUT=1 FAKE_MODE=hang run review "$S" 1 correctness 2>/dev/null)"
  # The fake sleeps 20 s: finishing well before that proves the watchdog's sleep does not hold the
  # caller's pipe open (the bound leaves room for slow process start-up on Windows).
  check "timeout (portable watchdog): degraded(timeout), caller not held open" 'grep -q "^\[fallback: timeout\]" "$S/round-1.codex.txt" && [ $((SECONDS - t0)) -lt 18 ]'
  rm -f "$T/started"
  ( FAKE_MODE=hang exec bash "$SELF" review "$S" 1 correctness >/dev/null 2>&1 ) &
  bgpid=$!; i=0
  while [ ! -e "$T/started" ] && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
  kill -TERM "$bgpid" 2>/dev/null; wait "$bgpid"; rc=$?
  check "interrupted: exit 130, marker and json written, no scratch or lock left" '[ $rc -eq 130 ] && grep -q "^\[fallback: interrupted\]" "$S/round-1.codex.txt" && [ "$(jfield "$S/round-1.codex.txt.json" status)" = "degraded(interrupted)" ] && only_published "$S" && [ -z "$(ls -A "$TMPDIR" | grep codex-run-)" ]'
  mkdir -p "$S/round-1.codex.txt.lock"; echo "$$" > "$S/round-1.codex.txt.lock/pid"
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1; rc=$?
  check "a second attempt while the first still runs is refused (exit 2)" '[ $rc -eq 2 ]'
  echo 999999 > "$S/round-1.codex.txt.lock/pid"
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  check "a stale lock from a dead attempt is taken over" 'grep -q "off by one" "$S/round-1.codex.txt" && [ ! -e "$S/round-1.codex.txt.lock" ]'
  mksess u
  mkdir -p "$TMPDIR/codex-run-$SKILL_NAME-999999-abcdef"; printf 'unscrubbed\n' > "$TMPDIR/codex-run-$SKILL_NAME-999999-abcdef/raw"
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  check "scratch left by a hard-killed run is swept" '[ ! -e "$TMPDIR/codex-run-$SKILL_NAME-999999-abcdef" ]'
  mksess big
  head -c 600000 /dev/zero | tr '\0' 'x' > "$S/updated.py"
  rm -f "$T/stdin"
  FAKE_MODE=ok run review "$S" 1 correctness >/dev/null 2>&1
  check "char/4*1.3 >= 180K: degraded(prompt-too-large), codex never called" 'grep -q "^\[fallback: prompt-too-large\]" "$S/round-1.codex.txt" && [ ! -e "$T/stdin" ] && [ "$(jfield "$S/round-1.codex.txt.json" status)" = "degraded(prompt-too-large)" ]'

  # ---------------- scrub subcommand, self-scan, doc gates
  printf 'token %s\n' "$FX_GH" > "$T/gate.log"; printf 'all green\n' > "$T/clean.log"
  run scrub "$T/gate.log" "$T/clean.log" >/dev/null 2>&1; rc=$?
  check "scrub: hit exits 3, file replaced by the marker" '[ $rc -eq 3 ] && [ "$(cat "$T/gate.log")" = "[scrubbed: secret-shaped content removed by codex-run.sh scrub]" ] && grep -q "all green" "$T/clean.log"'
  local sv; bad=0
  for sv in 'DB_PASS''WORD="hunter2hunter2"' 'postgres:''//admin:S3cretPassw0rd@db/x' 'sk-ant''-oat01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 'STRIPE_SECRET''_KEY=sk_li''ve_abcdefghijklmnopqrstuvwx'; do
    printf '%s\n' "$sv" > "$T/s.log"; run scrub "$T/s.log" >/dev/null 2>&1; [ $? -eq 3 ] || bad=1
  done
  check "scrub catches quoted, DSN, OAuth and *_SECRET_KEY forms" '[ $bad -eq 0 ]'
  run scrub "$T/clean.log" >/dev/null 2>&1; rc=$?
  check "scrub: clean file exits 0" '[ $rc -eq 0 ]'
  check "this script holds no literal secret-shaped string (fixtures are assembled at runtime)" '[ -z "$(secret_strings "$SELF" "$HELPER")" ]'
  check "SKILL.md and round.md call the script and never codex exec or the bypass flag directly" 'grep -q "scripts/codex-run.sh\" review" "$SKILL_DIR/SKILL.md" && grep -q "scripts/codex-run.sh\" verify" "$SKILL_DIR/SKILL.md" && ! grep -qE -- "--dangerously-bypass-approvals-and-sandbox|^[[:space:]]*(\\\$CODEX|codex exec)" "$SKILL_DIR/SKILL.md" "$SKILL_DIR/templates/round.md"'

  echo "codex-run selftest: $((n - fails))/$n passed"
  [ "$fails" -eq 0 ]
}

case "${1:-}" in
  review)     shift; cmd_review "$@" ;;
  verify)     shift; cmd_verify "$@" ;;
  scrub)      shift; cmd_scrub "$@" ;;
  --selftest) selftest ;;
  *) die "usage: codex-run.sh review|verify|scrub|--selftest (see the header of this file)" ;;
esac
