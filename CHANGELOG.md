# Changelog

All notable changes to the Mangchi plugin are documented here.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

## [0.2.2] — 2026-04-17

Docs release — adds Case Study B to evidence base. No code or algorithm
changes.

### Added
- **Case Study B** in `skills/mangchi/CASE-STUDIES-v2.md` — parallel
  4-session sweep on a Python Flask backend (~42 modules audited,
  4 concurrent main agents + 1 supervisor). 2 real production bugs
  landed via mangchi depth phase: concurrent state-store race
  (mutate-outside-RLock on two entry points) and API contract drift
  with silent alert-dispatch failure. 29% signal rate (2 of 7 CONVERGED
  → src/ patch) documented as honest mature-codebase expectation, with
  the 5 non-patches explicitly valued as "no-op audit stamps" rather
  than noise.
- **Operational note** on multi-session parallel execution — mangchi is
  single-worktree by design; N concurrent sessions require an external
  supervisor pattern to catch branch-contamination events. Two such
  events caught during this run.

## [0.2.1] — 2026-04-17

Adoption polish release. Same algorithm, safer defaults, clearer docs.

### Changed
- **Default `--force-accept-threshold` changed from 1 to 2** (adoption-friendly).
  `=1` (strict, abort-on-first) preserved as opt-in for security/crypto code.
  Rationale: pre-release review showed first-run users hitting abort on a
  single debatable REJECT — defeats the "iterative" promise of the tool.
- **Description frontmatter compressed** from ~600 chars to ~260 chars.
  Catalogue browsers see a readable summary, details in body.
- **Phase 0 renumbered** cleanly 1–7 (was 1,2,3,4,5,4,5,6 after an earlier
  insertion — caught by pre-release review).
- **Phase 0 consolidated preflight** — Bash 4+ / git / Python 3.8+ / PyYAML /
  Codex all checked up front with actionable remediation per failure, instead
  of mid-Phase-0 surprise.
- **Flag surface split into Essential (5) + Advanced (collapsible)**.
  First-time users see only `<file>`, `--apply=original`, `--gate`,
  `--continue`, `--stop`. Advanced behind `<details>` toggle.

### Removed (YAGNI)
- **`--gate-every-round`** — no realistic use case; running pytest after every
  round is cost-prohibitive and `--gate` at termination already exists.
- **`--force-round`** — second cap on the same concept as the 180K context
  window; soft 80K cap merged into the single hard 180K guard.
- **`--dry-run`** — duplicated the `round-1.prompt.txt` artifact, which is
  already produced by any real run.
- **`--axes=+necessity` legacy alias** — pre-1.0 tool has no users to
  maintain compat for. `--include-axes=necessity` is now the only form.

### Added
- **Soft coverage floor (R4→R5)**: if `correctness` or `security` hasn't run
  by R4 (and isn't excluded by `--only-axes`), R5 auto-assigns the missing
  axis. Final guard against "easy axes only" gaming.
- **Security-sensitive filename refusal in self-review mode**: filenames
  matching `auth|security|crypto|password|token|secret|sanitiz|permission|acl`
  refuse self-review entirely, even with `--allow-self-review`. The
  adversarial guard matters most on these exact files.

### Fixed
- **Frontmatter / TL;DR / Phase 7 doc drift** on FORCED_ACCEPT threshold
  (description said 1, TL;DR said 3, Phase 7 said `force_accept_threshold`
  with default 1 — now all agree on 2).
- **Changelog entry in SKILL body** for FORCED_ACCEPT corrected from
  stale "≥ 3 abort" wording.

## [0.2.0] — 2026-04-16

Schema v1 — adversarial guarantee hardening. Backwards-incompatible output
schema; legacy sessions detected via `state.json.schema_version` and warned.

### Added
- **Verification loop (Phase 6)** — Codex re-reviews every Claude REJECT on a
  second call. `AGREE` closes the issue; `DISAGREE` carries the issue into the
  next round as a forward agenda item.
- **FORCED_ACCEPT mechanism** — two consecutive `DISAGREE` on the same issue
  flips to forced acceptance (system-promoted, not Claude's choice).
- **`--force-accept-threshold=N`** — strict abort-on-first (default 1) vs
  permissive (N > 1). Strict preserves adversarial integrity at the cost of
  occasionally aborting on small legitimate disagreements.
- **ACCEPT git-diff verification (Phase 5)** — each ACCEPTed issue's `locus`
  must actually be touched in the diff (±5 fuzz factor); "no-op ACCEPT" is
  detected and carried forward, excluded from convergence counting.
- **REJECT citation hard error** — REJECT reason without `file:LINE` or
  test-name citation triggers validation failure (never silently flipped to
  ACCEPT).
- **Pre-flight guards**:
  - Bash 4+ check
  - File size limits (≤2000 LoC, ≤200KB unless `--force`)
  - `--only-axes` 2-PASS coverage warning (disables PASS termination if
    correctness or security is excluded)
  - Windows path normalization (backslash → slash)
- **Token budget** — per-round pre-send estimate (≥80K abort,
  `--force-round` bypass), per-call context window (≥180K hard abort),
  cumulative (≥150K warn, ≥500K abort).
- **Shell-injection-safe Codex calls** — strict tempfile + stdin pattern,
  `cat file >>` for all dynamic content. Prompt must never be passed via
  argv.
- **New flags**: `--only-axes`, `--include-axes`, `--start-axis`, `--gate`,
  `--gate-every-round`, `--no-verify`, `--allow-self-review`, `--force`,
  `--force-round`, `--dry-run`, `--force-accept-threshold`.
- **`INDEX.md`** — regenerated every round with round-by-round summary table.
- **`axes.md` schema block** — single source of truth for output YAML format
  (verdict, issue, verify shapes).
- **`necessity` axis** — moved to opt-in via `--include-axes=necessity`
  (default 5 axes). Rationale: `necessity` is a removal/refactor judgment,
  closer to greenfield than refinement.
- **Directory namespace** — artifacts now under
  `docs/refinement/mangchi/<slug>/` (separated from `triad`'s
  `docs/refinement/<slug>/`). Legacy path detected and warned.

### Changed
- **Stop conditions rewritten**. Old: 2-PASS / 30%-diff convergence / cap.
  New: 2 verified rounds / 2-PASS (with min axis coverage) / R5 cap /
  optional `--gate` / manual `--stop`. The 30%-diff ratio rule is removed
  entirely (it was gameable — one-char edit in R2 would trigger it).
- **YAML schema unified** to `schema_version: 1`:
  - `verdict` enum: `PASS | REVISE` (removed `BLOCK`).
  - `severity` casing: `HIGH | MEDIUM | LOW` (was lowercase).
  - Issue identifier: new required `id` field (int, round-unique).
  - `locus` field is now the source-of-truth for both REJECT verification and
    ACCEPT diff verification.
- **Phase 2 Codex invocation** — no longer accepts prompt via argv; must use
  `$CODEX < "$PROMPT_FILE"` only. Heredoc must be quoted (`<<'EOF'`).
- **Self-review fallback** — no longer silent. In TTY, the user is asked to
  confirm; in non-TTY, auto-abort. Self-review mode disables verify loop AND
  FORCED_ACCEPT (explicitly documented as "adversarial guarantee
  forfeited").
- **R1 axis selection** — default remains `correctness` but is now
  overridable with `--start-axis=<axis>`.
- **Axis precedence** (R2+): explicit ordering
  `same-axis-ban > carryover-disagree > signal-heuristic` (was ambiguous in
  v1).
- **Description in SKILL frontmatter** fully rewritten to reflect new stop
  conditions, verify loop, and Codex-required note.

### Removed
- **`verdict: BLOCK`** enum value (use `REVISE` + `severity: HIGH` instead).
- **`DEFER` decision** from Claude's Phase 4 choices (use `--continue` across
  rounds or `--stop` + follow-up session instead).
- **Diff-ratio convergence rule** (30% threshold was gameable).

### Fixed
- **Shell injection vector** in the Codex prompt path (v1 passed
  `codex exec "$PROMPT"` — a file containing backticks or `$(...)` in string
  literals or docstrings would trigger shell expansion at the wrong layer).
  v2 forbids argv entirely and uses tempfile + stdin.
- **Directory collision with `triad`** (both wrote to
  `docs/refinement/<slug>/`). Now namespaced.

### Known Gaps
- **Single-file scope** unchanged; cross-file architectural issues still out
  of scope.
- **Codex CLI still required** for intended behavior — self-review mode
  degrades the skill to approximately linter quality.
- **Token-economy assumption** (Claude abundant, Codex scarce) — inverted
  for ChatGPT-Plus-heavy users; pumasi may suit that case better.
- **`±5` locus heuristic** for no-op ACCEPT detection can false-negative on
  refactors that move the locus outside the window. Documented in SKILL.md
  Known Limits.
- **Citation truth** — Claude's `file:LINE` is format-validated but content
  not verified against the actual code; `--gate "<pytest>"` is the only
  hard counter.

### Migration Notes
- Sessions from v0.1.x continue to load on `--continue <slug>`, but:
  - `state.json.schema_version` will be absent — a warning is printed.
  - Old `docs/refinement/<slug>/` path is detected; new runs use
    `docs/refinement/mangchi/<slug>/`. No automatic migration.
  - Old `verdict: BLOCK` → treated as `REVISE + severity: HIGH` during resume.
- **CASE-STUDIES.md is legacy evidence** — the 23-bug / 9-file batch was
  produced under v0.1.x. New-design empirical cases must be re-accumulated.

## [0.1.0] — 2026-04-15

Initial public release.

### Added
- Core `/mangchi <file>` command with 7-phase workflow
- Five fixed review axes: `correctness`, `security`, `readability`,
  `performance`, `design`
- Axis rotation enforcement (no two adjacent rounds use the same axis)
- Three termination conditions: 2-PASS streak / 30% diff convergence /
  5-round hard cap
- Safe-by-default write policy: original file untouched unless
  `--apply=original` is passed
- Per-round audit trail: Codex prompt + response + main-agent decisions +
  diff stats preserved under `docs/refinement/<slug>/`
- Subagent-unavailable fallback: main agent performs a local review pass
  with the same axis prompt if Codex call fails, tagged in the round log
- Bundled reference materials: axis prompts, round/converged templates,
  usage examples, first real-world case study

### Known Gaps
- Single-file scope; does not coordinate edits across multiple files
- Cannot find cross-file architectural issues
- Requires Codex CLI (graceful fallback exists but loses the cross-model
  review value)
- Best on files in the 100–500 LoC range; smaller → low signal, larger →
  context pressure and dropping accept rates

### Case Studies
- See `skills/mangchi/CASE-STUDIES.md` for the OCR pipeline hardening batch
  (9 files, 23 real bugs caught including prompt-injection and European
  currency parsing corruption)
