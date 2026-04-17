# Mangchi — Case Studies (schema v1 / v0.2.x)

> Evidence from mangchi runs using **schema_version 1** (verification loop,
> FORCED_ACCEPT, diff-verified ACCEPT, shell-safe tempfile+stdin). Distinct
> from `CASE-STUDIES.md` which documents v0.1.x legacy-schema runs.

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
