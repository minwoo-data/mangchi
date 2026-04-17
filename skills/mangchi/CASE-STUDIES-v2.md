# Mangchi — Case Studies (schema v1 / v0.2.x)

> Evidence from mangchi runs using **schema_version 1** (verification loop,
> FORCED_ACCEPT, diff-verified ACCEPT, shell-safe tempfile+stdin). Distinct
> from `CASE-STUDIES.md` which documents v0.1.x legacy-schema runs.

---

## Case Study B — Parallel 4-Session Sweep on a Python Backend

**Target**: Same Python Flask backend referenced in Case Study 1 (v0.1.x),
broadened beyond the single validator in Case Study A. Four subsystems
audited concurrently via git worktrees: security/core (auth, rate-limit,
session-keyed batch state store, usage-tracking/alerting), OCR/receipts/
matching pipeline, statement/vendor/export/docs, and a scheduler. ~42
modules across 30+ source files.

**Purpose**: measure mangchi at parallel-execution scale — 4 concurrent
main agents, each running triad breadth → mangchi depth on its subsystem.
Does convergence hold? Do real patches land? What's the operational cost?

**Environment**:
- Mangchi: v0.2.1 (schema v1)
- Main agents: 4 × Claude Opus 4.7 (1M context), one per subsystem
- Codex CLI: default model (tempfile+stdin)
- Mode: triad breadth (read-only) → mangchi depth (updated-only)
- Supervisor session: 5th Claude monitoring branch state and merge orchestration

### Headline numbers

| Metric | Value |
|---|---|
| Parallel main sessions | 4 (+ 1 supervisor) |
| Triad breadth reviews | 42+ modules |
| Modules escalated to mangchi depth | 7 |
| **Src/ patches landed from mangchi** | **2 of 7 (29%)** |
| Non-actionable CONVERGED | 5 of 7 (71%) |
| Wall-clock (per session, parallel) | ~4h |
| Total session-hours | ~16 |
| Real production bugs caught by mangchi depth | 2 (concurrency, API drift) |

### Bugs landed

**Bug 1 — Concurrent state store: mutate outside RLock boundary**

A session-keyed batch state store used `threading.RLock`. Most mutations
were properly locked, but two entry points had mutations outside the lock
scope:

- `_ensure_batch_id` generated a UUID and wrote it to `session_obj[batch_id]`
  before entering the lock. Two concurrent uploads for the same new session
  key each generated a UUID — only one survived, orphaning the other's
  downstream results.
- `clear()` computed the new batch id inside the lock but performed the
  `session_obj[batch_id] = new_id` assignment AFTER releasing. A concurrent
  `append_result` could recreate the just-cleared slot with a stale id.

Unit tests were single-threaded; neither race could reach the window.
Mangchi's correctness+security axis rotation surfaced both in round-1
convergence. Fix: move mutations into the lock scope (RLock allows
re-entry, so wrapping check-and-set was safe).

**Bug 2 — Silent failure in alert dispatch (API contract drift)**

An alert-dispatch helper with signature `(subject: str, detail: str)` was
invoked elsewhere as `send_..._alert(title=..., body=...)`. Python raised
`TypeError`, but the caller wrapped the alert in
`try/except Exception: logger.warning(...)` — so the exception was logged
and swallowed. Effect: operator alert emails stopped reaching recipients
silently. Tests passed (no failure-branch coverage); code review had
missed it across multiple reads.

Mangchi's depth round forced a signature review on the module and
converged on both the kwargs rename AND a sibling cost-counter race on
the same module — two fixes in one convergence round.

### Non-actionable CONVERGED (5 of 7)

Five additional modules (auth-guard, admin-audit route, admin-users route,
email-service, pending-employee-service) converged to "no patch needed".
Each CONVERGED report contains Codex's initial candidate finding, the
main agent's verification against live code, and explicit reasoning for
why no single-file patch applies. Examples:

- auth-guard: role-check path was correct; the "race-free permission
  caching" suspicion verified as a non-issue.
- email-service: HTML injection candidate verified as already escaped at
  output boundary.
- pending-employee-service: name-normalization "mismatch" was documented
  casing asymmetry elsewhere — intentional.

This is **not** a failure mode — these CONVERGED reports are written
evidence that the modules are sound under the audited axes. Adopters
should expect and value the no-op outcome; it's how a clean module earns
its audit stamp without fabricated diffs.

### Cross-session orchestration — what we learned

Running 4 mangchi sessions in parallel exposed operational concerns
unique to multi-session scale:

- **Branch contamination**: one session's `git add` on a shared worktree
  scooped up a sibling session's uncommitted triad docs into its own
  commit. Mangchi is single-worktree by design; parallel execution
  requires a supervisor monitoring `git worktree list` + `git status`
  at ~5-minute intervals.
- **Zero-commit session**: one of four target branches never received a
  commit — its intended triad output ended up on a sibling branch via
  the same `git add` contamination event. Content reached main via the
  sibling's merge; branch name no longer matched its content, but the
  actual work was preserved.
- **Convergence-time variance**: wall-clock per session varied ~2h to
  4.5h. A naive "wait for all sessions to finish before merging" policy
  left 60+ uncommitted files at risk in one session for 40+ minutes.
  An auto-merge-on-idle-commit supervisor pattern (3-minute idle threshold)
  reduced risk but added orchestration work.

### What mangchi did NOT find (Case Study B–specific)

- **Branch-hygiene bugs** — not a mangchi feature; supervisor-level concern.
- **Session contamination events** — detected only via outside-session
  observation of file mtimes and `git worktree list`.
- **Aggregate "same-class bug across N files" patterns** — e.g., all
  services forgetting to flush audit buffers on shutdown. Mangchi is
  single-file by design; pattern synthesis happened at the triad
  PATTERNS layer, not by mangchi itself.

### What surprised us

- **Signal rate is a feature, not a deficiency.** On a codebase that had
  already received multiple review passes, 29% actionable rate means
  7 CONVERGED → 2 src/ patches. The 5 non-patches are themselves useful:
  written proof that under the audited axes, the module is sound. A
  higher actionable rate on mature code would suggest the tool is
  fabricating changes; 29% is the honest signal.
- **Concurrency bugs slip past everything except depth+axis-rotation.**
  Both race conditions had existed through code reviews AND a full test
  suite that never exercised concurrent paths. Mangchi surfaced both in
  round-1 convergence on the correctness axis — before security was even
  scheduled.
- **Parallel session count is not free.** 4 × 4h = 16 session-hours for
  2 real patches = 8h per patch. A single-session sequential sweep would
  have been ~8h wall-clock for the same 2 patches. Parallel gains
  wall-clock time, costs coordination. Pick based on deadline pressure.

### Reproducibility

Per-module artifacts preserved under `docs/refinement/mangchi/<slug>/`:
- `source-snapshot.py`, `round-N.prompt.txt`, `round-N.codex.txt`,
  `round-N.md`, `CONVERGED.md`

Per-session aggregate at `docs/refinement/session-burn/<session-id>/`:
- `PATTERNS-X.md` synthesis across the session's file scope
- Individual `round-1.md` triad reviews

### Key takeaways for Case Study B

- **Mangchi scales to parallel sessions**, but requires supervisor-level
  orchestration for branch discipline. The tool is single-worktree by
  design; running N concurrent sessions is an adopter choice about
  coordination, not a mangchi feature.
- **29% signal rate on mature code is correct behavior.** If your
  codebase is already review-audited, expect most CONVERGED reports to
  be "no patch"; that's evidence of audit quality, not tool weakness.
- **Two unique classes mangchi uniquely surfaced this round**:
  concurrency via axis-rotation (correctness → security on the same
  state-mutating module) and silent API-contract drift via signature
  review in depth phase. Neither had been caught by prior review passes.

---

## Case Study A — 4-Tool Adversarial Bench on a Security Validator

**Target**: `src/security/file_validator.py` — Flask upload pipeline validator
(126 LoC, Python 3.11). Responsibilities: extension whitelist, magic-byte
verification, filename sanitization, zip-bomb defense on xlsx.

**Purpose**: empirically compare mangchi against three sibling Claude Code
tools on a shared target, measuring issue overlap, uniqueness, and cost.
Also: verify mangchi v0.2.1 converges cleanly on a fresh target after the
adoption-polish changes.

**Environment**:
- Mangchi: v0.2.1 (schema v1, post-polish defaults)
- Codex CLI: 0.120.0 (gpt-4o-mini default; tempfile+stdin invocation)
- Compared against: `/review-devil`, `/review-all` (4-agent synthesis), `/triad` (3-lens, code-mode, read-only; running in main-local-pass fallback)
- All tools given identical input file content, no pre-hints about known issues.

---

## Findings per tool

### `/review-devil` — 14 findings (4 CRITICAL, 5 HIGH, 4 MEDIUM, 1 LOW)

Adversarial single-pass. Found attack surfaces mangchi did NOT prioritize in
the correctness+security axes:
- **C1** — polyglot bypass (GIFAR-style: valid JPEG header + hostile tail)
- **C2** — `is_allowed_file` tricks (null byte, double ext, RTL override, trailing dot/space)
- **C3** — `fitz.open` on attacker-controlled PDF without size cap / subprocess isolation / timeout → PyMuPDF CVEs are in-process
- **C4** — `validate_xlsx_safe` trusts `info.file_size` (attacker-written zip header)

### `/review-all` — 16 findings synthesized across 4 agents

Generic breadth. Recapitulated `/review-devil`'s xlsx magic ambiguity (3
agents converged) plus architecture-oriented items:
- No central `validate_upload()` entry point (composition hazard)
- `_XLSX_MAX_*` should be in `config.json` per project standards
- HEIC check loose (both too loose and too strict)
- `logger.warning("[WARN] ...")` duplicates level prefix
- `get_pdf_page_count` exception swallowing too broad

### `/triad` — 3-lens findings (code mode, read-only)

Lens-distinct output. Unique contributions not raised by any other tool:
- **LLM lens**: implicit call-order contract between `is_allowed_file` and `verify_file_magic` is undocumented — future LLM-written callers will bypass
- **LLM lens**: `get_pdf_page_count` returning `None` has ambiguous fail-open/fail-closed contract
- **Architect lens**: MAGIC_BYTES dict + WebP/HEIC branches are asymmetric — new format additions will split between two spots
- **EndUser lens**: function naming prefix inconsistent (`is_` / `verify_` / `validate_` / `sanitize_` / `get_`)
- **EndUser lens**: `sanitize_filename` UUID-prefix rationale missing from docstring (why, not just what)

### `/mangchi` (v0.2.1) — 2 rounds, 3 real fixes applied

Full iterative workflow. Ran correctness → security axes. **All fixes actually
applied to the file** (not just recommendations):

| Round | Axis | Issue | Severity | Decision | Applied |
|-------|------|-------|----------|----------|---------|
| R1 | correctness | HEIC brand check too loose + too strict | MEDIUM | ACCEPT | ✓ |
| R1 | correctness | `validate_xlsx_safe` lacks workbook structure check | LOW | ACCEPT | ✓ |
| R2 | security | **Zip Slip** — archive members with `/`, `..`, `C:` not rejected | MEDIUM | ACCEPT | ✓ |

Zip Slip (R2#1) was **unique to mangchi** — no other tool explicitly flagged
archive-member path traversal despite this being a known vector for xlsx
uploads on security-critical paths.

Termination: **2 consecutive verified rounds** — all ACCEPTs diff-verified
within locus ±5, zero DISAGREE (verify loop skipped both rounds since REJECT
count was 0 on both).

---

## Cross-tool overlap matrix

| Issue | devil | review-all | triad | mangchi |
|-------|:-----:|:----------:|:-----:|:-------:|
| Polyglot / tail-payload bypass | ✅ | — | — | — |
| `is_allowed_file` trick vectors | ✅ | — | — | — |
| PyMuPDF on untrusted PDF | ✅ | ⚠️ partial | — | — |
| ZIP header `file_size` trust (zip bomb) | ✅ | ⚠️ partial | — | — |
| xlsx magic ambiguity (PK\\x03\\x04) | ✅ | ✅ | — | ✅ (fixed) |
| HEIC brand check weak | ✅ | ✅ | — | ✅ (fixed) |
| No unified `validate_upload` entry point | — | ✅ | ✅ (Architect lens) | — |
| `_XLSX_MAX_*` belongs in config.json | — | ✅ | ✅ (Architect lens) | — |
| Call-order contract undocumented | — | — | ✅ (LLM lens, unique) | — |
| `get_pdf_page_count` fail-open/closed ambiguous | — | — | ✅ (LLM lens, unique) | — |
| Function naming prefix inconsistent | — | — | ✅ (EndUser lens, unique) | — |
| Zip Slip (archive member path traversal) | — | — | — | ✅ (unique, fixed) |

**Read**: each column has unique finds. No tool is redundant; each earns
its row in the comparison. Review-devil and review-all overlap most on
critical security items; triad uniquely surfaces maintainability/docs gaps;
mangchi uniquely surfaced Zip Slip AND *applied the fix*.

---

## Cost

| Tool | Calls | Tokens / subagents | Wall time | Applied fixes |
|------|-------|---------------------|-----------|---------------|
| `/review-devil` | 1 Claude agent | Claude only | ~45s | 0 (report only) |
| `/review-all` | 4 Claude agents + main synthesis | Claude only | ~3min | 0 (report only) |
| `/triad` (3 lens, 1 round) | 3 Claude agents + main synthesis | Claude only | ~3min (main-local-pass in test env) | 0 (read-only, code mode) |
| `/mangchi` (R1 + R2, 0 REJECTs → verify skipped) | 2 Codex calls + Claude edits | **8,186 Codex tokens** + Claude | ~2min | 3 ✓ |

Mangchi's Codex spend was 6% of its 500K cumulative budget. The verify loop
would have doubled Codex cost if any REJECT had occurred; in this run both
rounds had 100% ACCEPT rate so verify was auto-skipped — a v0.2.0-design
optimization paying off.

---

## Decision guidance (when to use which)

Based on this bench:

- **`/review-devil`** — cheapest, fastest adversarial scan. Best when you
  want the top-3 attack surfaces before wasting time on other reviews.
  Downside: no synthesis with other angles, no fixes applied.
- **`/review-all`** — broad, synthesized, good first-look for a PR. Best
  when you want "one report, multiple angles" without running a workflow.
  Downside: verbosity; includes low-signal items; no fixes applied.
- **`/triad`** — only tool that surfaces LLM-caller contract gaps and
  naming/docs issues, uniquely useful for **documents that future Claudes
  will read** (CLAUDE.md, rules files, ADRs) or **public code APIs**
  where human + LLM audiences both matter. 3-4× the cost of `/review-all`.
  Downside: overkill for one-shot code review; no fixes applied.
- **`/mangchi`** — the only tool that **actually applies fixes** with
  diff verification and adversarial convergence. Use when you want the
  file to end up *different and better*, not just receive a report.
  Unique capability: Zip Slip-style cross-cut security issues surface
  from the axis rotation that generic reviewers miss. Downside: Codex
  CLI required; 2-5× the token cost of `/review-all`.

**Combination play**: `/review-all` for broad survey → `/mangchi` on the
2-3 files flagged as highest-risk. This bench shows the tools are
complementary, not redundant.

---

## Weaknesses discovered in mangchi v0.2.1 during this run

Honest reporting:

1. **Limited axis coverage**: mangchi terminated after 2 rounds
   (correctness + security) due to 2-consecutive-verified-rounds condition.
   Readability / performance / design axes never ran. On this file, `/triad`
   and `/review-all` found real design/readability issues that mangchi
   would have needed 3+ more rounds to reach. Mangchi's convergence is
   honest — there's nothing left *in the axes it ran* — but it's not the
   same as "nothing left anywhere."

2. **No polyglot detection**: `/review-devil` found polyglot bypass (C1);
   mangchi did not surface it in the correctness or security axis runs.
   Polyglot is adversarial-thinking, and Codex's review axis prompts are
   rubric-driven — this is a known limitation of rubric reviews vs
   open-ended adversarial scanning.

3. **PyMuPDF CVE surface**: `/review-devil` flagged `fitz.open` as a
   CVE-adjacent risk; mangchi did not. Same reason — Codex focuses on
   the code visible in-file and doesn't reason about third-party
   library CVE history without prompting.

**Implication**: for security-critical files, run `/review-devil` first to
catch adversarial-thinking items that rubric-based mangchi won't surface,
then run mangchi to actually fix what it can cleanly address.

---

## Final state

- **Bugs fixed**: 3 (HEIC brand matching, xlsx structural check, Zip Slip)
- **File changes**: +30 / -4 lines (non-whitespace)
- **Codex tokens**: 8,186
- **Claude subagents (across all 4 tools)**: 8 (1 devil + 4 review-all + 3 triad)
- **Unique-to-mangchi contribution**: Zip Slip detection + applied fix

Original `src/security/file_validator.py` was updated with the 3 mangchi
fixes. Outstanding items (polyglot defense, PyMuPDF isolation,
`validate_upload` entry point, config.json migration) logged for separate
work — they cross file boundaries or require architectural decisions that
are outside mangchi's single-file scope.

---

## Methodology notes (for reproducibility)

- All 4 tools given identical file content as input; no hints.
- `/triad` was executed in `[fallback: main-local-pass]` mode because the
  Agent tool was not exposed in the test session. This may slightly reduce
  cross-lens independence vs a true parallel subagent run.
- Mangchi ran with v0.2.1 defaults: `--force-accept-threshold=2`, no
  `--only-axes`, no `--start-axis` override.
- Token counts reported directly from Codex CLI `tokens used` response
  footer (both rounds).
- Overlap matrix built from manual comparison; items marked "partial"
  where a tool mentioned adjacent concerns but didn't hit the specific
  failure mode.
