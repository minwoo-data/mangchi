# Changelog

All notable changes to the Mangchi plugin are documented here.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

## [0.4.1] - 2026-10-14

`/mangchi` runs the skill directly. The duplicate `commands/mangchi.md` is gone:
it listed a second `mangchi` entry (~70 always-on tokens) and its body (~4.6k
tokens) was read on top of SKILL.md on every invocation.

### Changed
- `skills/mangchi/SKILL.md` frontmatter gains `user-invocable: true`, the
  command's `argument-hint` and `allowed-tools`.
- What only the command file had moved into SKILL.md:
  - no-argument AskUserQuestion menu (JSON unchanged), `ARGUMENTS:` handling,
    `*.md` -> `/triad` warning, `--axes=+necessity` alias, the legacy
    (`schema_version` absent) warning and the 0.3.x migration steps
    -> new `### 인자 해석 (/mangchi 호출)` under `## 트리거`;
  - "Claude never skips a review round" -> `## 핵심 불변식` #8;
  - output expectations (CONVERGED.md, INDEX.md, snapshot diff, how to replace
    the original) -> a paragraph after `## 파일 구조`.
- Already in SKILL.md, so not duplicated: the flag table, prerequisites
  (preflight), the other invariants, termination, degraded / `secret-scrubbed`
  handling and `--after-incident`, full file never elided, `R{n}.{axis}#{id}`,
  `carried:` re-verify.
- `.claude-plugin/plugin.json` drops `"commands": "./commands/"`.
- `codex-run.sh` doc gate scans any `commands/*.md` that is added back; a new
  `entry_gate` selftest check fails if SKILL.md loses `user-invocable`, the
  argument-hint, the argument section or the menu, or plugin.json points at
  `commands/` again.

## [0.4.0] - 2026-10-14

The Codex invocation contract becomes code, and Codex loses its unsandboxed
shell. Same review algorithm, same YAML `schema_version` 1.

### Security
- **Codex runs in the read-only sandbox.** 0.3.x called
  `codex exec --dangerously-bypass-approvals-and-sandbox` and argued that was
  fine because mangchi only asks Codex to read - but the flag gave every shell
  command Codex chose to run full file and network access. Codex now runs with
  `-s read-only` (reads allowed, writes and network blocked).
  `MANGCHI_CODEX_SANDBOX=bypass` is an explicit per-run opt-out, only when the
  user asks.
- **Sandbox Safety Preamble + secret scrub**, ported from prism 0.4.2 (the same
  shared core triad 0.3.0 carries): every prompt starts with the policy that
  forbids `docker compose config`, env dumps and reading credential files (the
  2026-05-22 leak vector), and everything Codex printed - raw stream, final
  answer, a prompt rewritten mid-run - is scanned before anything reaches
  `docs/refinement/mangchi/<slug>/`. A secret-shaped string that was not in the
  prompt quarantines the call (`status=secret-scrubbed(...)`, outputs
  destroyed, never auto-retried). Credential-shaped working copies are refused.
- Unscrubbed Codex output lives only in a temp scratch dir outside the session
  dir (swept if a run is hard-killed); one attempt per call at a time (lock).

### Added
- **`skills/mangchi/scripts/codex-run.sh`** - `review <dir> <N> <axis>`,
  `verify <dir> <N> --issues <file>`, `scrub <file>...`, `--selftest`. It
  assembles the prompt from files only (role + the round's axis rubric and the
  output format cut out of `axes.md` by section - a missing section is exit 2 -
  then the full `updated.<ext>`, then from round 2 the required
  `round-(N-1).carryover.md`), sends it via tempfile + stdin, pins effort high,
  applies the 300 s timeout and the `char/4*1.3 >= 180K` guard, keeps only the
  `--output-last-message` answer, and enforces the R5 cap. Output: one summary
  line + a result JSON next to each answer (`round-N.codex.txt.json`).
- **`skills/mangchi/scripts/mangchi_yaml.py`** - the Phase 3 / Phase 6 schema
  rules as code (was prose the model applied by eye): axis must equal the
  call's axis, enums, `file:LINE` locus, unique ids; verify must answer every
  REJECTed issue exactly once and cite `file:line` on DISAGREE. Also builds the
  verify context (post-edit `updated.<ext>` ±10 lines, clamped,
  `post_edit_lines` override) and checks the REJECT file (Phase 4 citation rule
  is now a hard exit 2, not just an instruction).
- **Single schema retry counted by the script** - `--retry` once per call; a
  second `--retry` or a fresh call after `schema-invalid` is exit 2. The first
  answer is kept as `round-N.codex.attempt1.txt`.
- **Round carryover file** - Phase 8 writes `round-N.carryover.md`
  (`## decisions` / `## carryover` / `## forced_accept`); round N+1 refuses to
  run without it (`--no-carryover` to opt out on purpose), so the FORCED_ACCEPT
  "do not re-raise" list cannot silently drop out of the prompt.
- Token accounting from Codex's own `tokens used` line when present
  (`tokens.estimate_only: false`), else the estimate.
- `.gitattributes` keeps `*.sh` / `*.py` LF on Windows clones.

### Fixed
- **preflight.sh path normalisation deleted every `/`** - `${FILE//\//}`
  (a backslash lost in an earlier heredoc) turned `src/routes/auth.py` into
  `srcroutesauth.py`, so preflight failed on any path with a directory. Now
  `${FILE//\\//}` (backslashes to slashes, as the comment always said).
- **preflight.sh picked the Windows Store `python3` stub** and then reported
  "PyYAML missing" even with PyYAML installed under `python`. Each candidate
  (`MANGCHI_PYTHON`, `python3`, `python`) is now probed for a working 3.8+.
- preflight.sh requires Codex CLI >= 0.125.0 (sandbox flags).
- **Doc drift left over from 0.2.1**: `templates/round.md` still had the 80K
  per-round guard + `--force-round`, `forced_accept_count >= 3`, and "correctness
  + security 중 최소 1회"; `commands/mangchi.md` still listed `--force-round`,
  `--dry-run`, `--gate-every-round` and threshold default 1; READMEs said
  `--gate-every-round` / default 1; `usage.md` and `converged.md` said 80K;
  `converged.md` used termination-reason names that `state-schema.md` does not
  have; `state-schema.md` still had `gate_every_round` / `force_round_rounds`.
  All now match SKILL.md (180K per call, threshold default 2, correctness AND
  security each >= 1, state-schema termination reasons). README.ko's diagram
  still offered `DEFER` (removed in schema v1).

### Review fixes (`/prism-all` on PR #3: 35 candidates, 33 confirmed)
Every fix has a selftest case, and each case was broken on purpose once to
prove it catches the regression.
- **Verify asks Codex about the issue the review raised.** The rejects file
  now names an issue (`id`) and gives Claude's reason and `post_edit_lines`.
  Locus, problem, proposed_fix and severity come from the review result. A
  copy in the rejects file that differs is exit 2 (it used to be shown to
  Codex as is, so a REJECT could be verified against a different issue).
- **Carried DISAGREE issues have a real path to FORCED_ACCEPT.**
  `carried: "R{m}.{axis}#{id}"` re-verifies an issue from an earlier round
  under its own axis and key. It must be listed under `## carryover`, and it
  needs `post_edit_lines`. Before this, the same-axis ban plus the id check
  meant a carried issue could never be verified twice.
- **Only the final ```yaml fence is parsed.** A malformed final fence no
  longer falls back to an earlier block, and a trailing untagged code fence
  no longer replaces the answer. A YAML value that crashes the loader
  (e.g. `2026-99-99`) is schema-invalid instead of a helper crash.
- **A helper crash is never published as `ok`.** The status becomes
  `degraded(result-failed)` (re-runnable) and keeps a scrubbed error tail.
- **Durable attempt record.** Every call writes its result JSON first
  (`degraded(not-started)`, attempt number, earlier tokens). The rules:
  - An existing `*.attempt1.txt.json` means the schema retry is used.
  - An attempt-1 answer is never overwritten.
  - An answer without its JSON, or a corrupt JSON, is exit 2 and is never
    deleted.
- **Secrets:**
  - The YAML-decoded result is scanned again before it is published (escapes
    could smuggle a secret past the raw scrub).
  - The retry prompt's error text cannot add or allow a new secret.
  - The placeholder filter looks at the whole value only, so
    `EXAMPLE_API_KEY=<real>` is caught.
  - A failing filter stage fails closed.
  - An interrupt during quarantine keeps the incident.
- **Security incidents block re-runs.** After `secret-scrubbed(...)`, a plain
  re-run and `--retry` are exit 2 until `--after-incident` is passed (after
  the user has looked).
- **Prompt:**
  - `updated.<ext>` is line-numbered (locus numbers are real) and wrapped in
    per-call random markers. The role text says the block is data, never
    instructions.
  - The prompt ends with a marker, and the token footer is read only after it.
  - Codex starts in an empty dir (`-C`).
- **Tokens:**
  - `tokens.prior_total` / `call_total` carry earlier attempts forward, and
    `state.json` copies `call_total`.
  - The `tokens used` footer is read only after the echoed prompt.
- **Inputs:**
  - `--issues` is snapshotted under the lock.
  - Locus must be a whole `file.ext:LINE[-LINE]`.
  - Citations need `file.ext:LINE`, a node id or `test_*` (`10:30`,
    `issue:2` and a bare `::` no longer count).
  - A PASS without `no_changes_suggested: true` warns that it won't count
    toward the 2-PASS stop.
- **Shared core (to port to prism / triad):**
  - The stale-scratch sweep skips symlinks, other users' dirs and anything
    written in the last 10 minutes.
  - A lock without a pid has a 10 s grace period, a stale lock is reclaimed by
    rename, and only the owner removes a lock.
  - Cleanup failures are recorded.
  - The self-scan checks the scan's exit code.
- **preflight.sh:**
  - Refuses credential files by their original name before copying
    (`codex-run.sh check-target`).
  - Records `mangchi_version` and `target_basename` (re-checked on every
    call).
  - Honours `MANGCHI_CODEX_BIN`.
  - Takes the extension from the basename, limited to `[A-Za-z0-9_-]`
    (else `txt`), and checks each copy.
  - Never overwrites an existing session's working copy.
  - `SKIP_ENV_CHECK` is removed (ignored with a warning). codex-run.sh always
    needs PyYAML.
- The doc gate also covers `commands/mangchi.md`, the READMEs and `usage.md`.

### Migrating a 0.3.x session
`codex-run.sh` refuses a session whose `state.json` has no `mangchi_version`
and prints these steps:
1. Move aside any `round-N.codex.txt` that has no `.json`. That round is
   reviewed again.
2. Write `round-(N-1).carryover.md` for the next round from `state.json`:
   `## decisions`, `## carryover` with PENDING issues as `R{n}.{axis}#{id}`,
   and `## forced_accept`.
3. Add `"mangchi_version": "0.4.0"`.

## [0.3.1] - 2026-10-13

Axis-ownership cleanup + SKILL.md diet + version sync. No schema change
(`schema_version` stays 1).

### Changed
- **Concurrency has one owner: `robustness`.** `correctness` no longer lists
  "레이스 조건" (moved to its do-not-flag list with a pointer to robustness);
  `security` keeps TOCTOU only when the attacker controls the timing and says
  so explicitly. Previously the same race could land in three axes and the
  signal was split.
- **readability vs design disambiguated** - function length / arity / nesting
  stay in `readability`; `design`'s SRP item is now "mixed responsibilities
  only", with a note that length alone is not an SRP finding.
- **Phase 0 preflight is a real script** - `skills/mangchi/scripts/preflight.sh`
  (env check, size guard, axis-coverage warning, security-sensitive refusal
  when Codex is absent, slug + dir + `updated.*` / snapshot / `state.json`
  init). SKILL.md keeps a 5-line summary and the invocation; flags are passed
  as env vars (`FORCE`, `ONLY_AXES`, `INCLUDE_AXES`, `START_AXIS`, `GATE_CMD`,
  `NO_VERIFY`, `FORCE_ACCEPT_THRESHOLD`, `REFINEMENT_ROOT`, `SKIP_ENV_CHECK`).
- **SKILL.md 683 → ~380 lines** without dropping a rule: state.json schema →
  `references/state-schema.md`; Known Limits → `references/known-limits.md`
  (3-bullet summary stays); INDEX.md template → `templates/index.md`; the
  in-body "Changelog (이 SKILL 자체)" section removed (this file is the SSOT);
  Codex-call invariants folded into Phase 2 (were duplicated in a separate
  section); Phase 3/6 code blocks replaced by the equivalent prose contract;
  the self-declared-duplicate "축 로테이션 규칙" section folded into Phase 1.
- **Version sync** - `plugin.json` / `marketplace.json` were still 0.2.2 while
  this changelog already had 0.3.0 (robustness axis). Both now 0.3.1; the
  description mentions the two opt-in axes.

### Added
- **Robustness hint in preflight** - if the target contains stateful markers
  (`threading|asyncio|await|Lock(|transaction|commit(|rollback|INSERT|UPDATE|
  DELETE|session.|cursor.|fetch(|requests.|httpx|state_machine|status =`) the
  script prints `[HINT] stateful code detected — consider
  --include-axes=robustness`. It never auto-enables the axis.

### Notes
- 0.3.0 (robustness axis) was recorded here on 2026-04-21 but never
  reflected in the manifests - this release closes that gap.

## [0.3.0] - 2026-04-21

### Added
- **`robustness` axis (opt-in)** - seventh review axis probing runtime failure
  modes. One reviewer round covers 4 orthogonal sub-axes that must each be
  walked: concurrency, failure & recovery, data integrity, state transitions.
  Sub-axes with no realistic signal for the target are explicitly marked
  `N/A - <reason>` rather than skipped silently.
- **`--include-axes=robustness`** flag - parallel to `--include-axes=necessity`.
  Both opt-in axes can be combined: `--include-axes=necessity,robustness`.

### Rationale
- `correctness` asks "does it meet its contract on the happy path?" -
  `robustness` asks the orthogonal "does it survive adversarial runtime?".
  Past case studies had runtime-failure findings being mis-filed under
  `correctness` (single-thread race) or `security` (TOCTOU), losing signal.
- Opt-in rather than default because pure/stateless code (formatters, pure
  functions, deterministic parsers) has zero realistic robustness signal -
  forcing a round on every target would burn tokens for no reason.
- Sub-axis enumeration forced per round: each finding must name a concrete
  scenario (which input, which timing, which second actor) - "race condition
  might exist" findings are auto-demoted to `severity: LOW`.

### Schema
- No schema_version bump. Reuses v1 YAML output format unchanged. Only the
  `axes.md` content grows.

## [0.2.2] - 2026-04-17

Docs release - adds Case Study B to evidence base. No code or algorithm
changes.

### Added
- **Case Study B** in `skills/mangchi/CASE-STUDIES-v2.md` - parallel
  4-session sweep on a Python Flask backend (~42 modules audited,
  4 concurrent main agents + 1 supervisor). 2 real production bugs
  landed via mangchi depth phase: concurrent state-store race
  (mutate-outside-RLock on two entry points) and API contract drift
  with silent alert-dispatch failure. 29% signal rate (2 of 7 CONVERGED
  → src/ patch) documented as honest mature-codebase expectation, with
  the 5 non-patches explicitly valued as "no-op audit stamps" rather
  than noise.
- **Operational note** on multi-session parallel execution - mangchi is
  single-worktree by design; N concurrent sessions require an external
  supervisor pattern to catch branch-contamination events. Two such
  events caught during this run.

## [0.2.1] - 2026-04-17

Adoption polish release. Same algorithm, safer defaults, clearer docs.

### Changed
- **Default `--force-accept-threshold` changed from 1 to 2** (adoption-friendly).
  `=1` (strict, abort-on-first) preserved as opt-in for security/crypto code.
  Rationale: pre-release review showed first-run users hitting abort on a
  single debatable REJECT - defeats the "iterative" promise of the tool.
- **Description frontmatter compressed** from ~600 chars to ~260 chars.
  Catalogue browsers see a readable summary, details in body.
- **Phase 0 renumbered** cleanly 1-7 (was 1,2,3,4,5,4,5,6 after an earlier
  insertion - caught by pre-release review).
- **Phase 0 consolidated preflight** - Bash 4+ / git / Python 3.8+ / PyYAML /
  Codex all checked up front with actionable remediation per failure, instead
  of mid-Phase-0 surprise.
- **Flag surface split into Essential (5) + Advanced (collapsible)**.
  First-time users see only `<file>`, `--apply=original`, `--gate`,
  `--continue`, `--stop`. Advanced behind `<details>` toggle.

### Removed (YAGNI)
- **`--gate-every-round`** - no realistic use case; running pytest after every
  round is cost-prohibitive and `--gate` at termination already exists.
- **`--force-round`** - second cap on the same concept as the 180K context
  window; soft 80K cap merged into the single hard 180K guard.
- **`--dry-run`** - duplicated the `round-1.prompt.txt` artifact, which is
  already produced by any real run.
- **`--axes=+necessity` legacy alias** - pre-1.0 tool has no users to
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
  with default 1 - now all agree on 2).
- **Changelog entry in SKILL body** for FORCED_ACCEPT corrected from
  stale "≥ 3 abort" wording.

## [0.2.0] - 2026-04-16

Schema v1 - adversarial guarantee hardening. Backwards-incompatible output
schema; legacy sessions detected via `state.json.schema_version` and warned.

### Added
- **Verification loop (Phase 6)** - Codex re-reviews every Claude REJECT on a
  second call. `AGREE` closes the issue; `DISAGREE` carries the issue into the
  next round as a forward agenda item.
- **FORCED_ACCEPT mechanism** - two consecutive `DISAGREE` on the same issue
  flips to forced acceptance (system-promoted, not Claude's choice).
- **`--force-accept-threshold=N`** - strict abort-on-first (default 1) vs
  permissive (N > 1). Strict preserves adversarial integrity at the cost of
  occasionally aborting on small legitimate disagreements.
- **ACCEPT git-diff verification (Phase 5)** - each ACCEPTed issue's `locus`
  must actually be touched in the diff (±5 fuzz factor); "no-op ACCEPT" is
  detected and carried forward, excluded from convergence counting.
- **REJECT citation hard error** - REJECT reason without `file:LINE` or
  test-name citation triggers validation failure (never silently flipped to
  ACCEPT).
- **Pre-flight guards**:
  - Bash 4+ check
  - File size limits (≤2000 LoC, ≤200KB unless `--force`)
  - `--only-axes` 2-PASS coverage warning (disables PASS termination if
    correctness or security is excluded)
  - Windows path normalization (backslash → slash)
- **Token budget** - per-round pre-send estimate (≥80K abort,
  `--force-round` bypass), per-call context window (≥180K hard abort),
  cumulative (≥150K warn, ≥500K abort).
- **Shell-injection-safe Codex calls** - strict tempfile + stdin pattern,
  `cat file >>` for all dynamic content. Prompt must never be passed via
  argv.
- **New flags**: `--only-axes`, `--include-axes`, `--start-axis`, `--gate`,
  `--gate-every-round`, `--no-verify`, `--allow-self-review`, `--force`,
  `--force-round`, `--dry-run`, `--force-accept-threshold`.
- **`INDEX.md`** - regenerated every round with round-by-round summary table.
- **`axes.md` schema block** - single source of truth for output YAML format
  (verdict, issue, verify shapes).
- **`necessity` axis** - moved to opt-in via `--include-axes=necessity`
  (default 5 axes). Rationale: `necessity` is a removal/refactor judgment,
  closer to greenfield than refinement.
- **Directory namespace** - artifacts now under
  `docs/refinement/mangchi/<slug>/` (separated from `triad`'s
  `docs/refinement/<slug>/`). Legacy path detected and warned.

### Changed
- **Stop conditions rewritten**. Old: 2-PASS / 30%-diff convergence / cap.
  New: 2 verified rounds / 2-PASS (with min axis coverage) / R5 cap /
  optional `--gate` / manual `--stop`. The 30%-diff ratio rule is removed
  entirely (it was gameable - one-char edit in R2 would trigger it).
- **YAML schema unified** to `schema_version: 1`:
  - `verdict` enum: `PASS | REVISE` (removed `BLOCK`).
  - `severity` casing: `HIGH | MEDIUM | LOW` (was lowercase).
  - Issue identifier: new required `id` field (int, round-unique).
  - `locus` field is now the source-of-truth for both REJECT verification and
    ACCEPT diff verification.
- **Phase 2 Codex invocation** - no longer accepts prompt via argv; must use
  `$CODEX < "$PROMPT_FILE"` only. Heredoc must be quoted (`<<'EOF'`).
- **Self-review fallback** - no longer silent. In TTY, the user is asked to
  confirm; in non-TTY, auto-abort. Self-review mode disables verify loop AND
  FORCED_ACCEPT (explicitly documented as "adversarial guarantee
  forfeited").
- **R1 axis selection** - default remains `correctness` but is now
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
  `codex exec "$PROMPT"` - a file containing backticks or `$(...)` in string
  literals or docstrings would trigger shell expansion at the wrong layer).
  v2 forbids argv entirely and uses tempfile + stdin.
- **Directory collision with `triad`** (both wrote to
  `docs/refinement/<slug>/`). Now namespaced.

### Known Gaps
- **Single-file scope** unchanged; cross-file architectural issues still out
  of scope.
- **Codex CLI still required** for intended behavior - self-review mode
  degrades the skill to approximately linter quality.
- **Token-economy assumption** (Claude abundant, Codex scarce) - inverted
  for ChatGPT-Plus-heavy users; pumasi may suit that case better.
- **`±5` locus heuristic** for no-op ACCEPT detection can false-negative on
  refactors that move the locus outside the window. Documented in SKILL.md
  Known Limits.
- **Citation truth** - Claude's `file:LINE` is format-validated but content
  not verified against the actual code; `--gate "<pytest>"` is the only
  hard counter.

### Migration Notes
- Sessions from v0.1.x continue to load on `--continue <slug>`, but:
  - `state.json.schema_version` will be absent - a warning is printed.
  - Old `docs/refinement/<slug>/` path is detected; new runs use
    `docs/refinement/mangchi/<slug>/`. No automatic migration.
  - Old `verdict: BLOCK` → treated as `REVISE + severity: HIGH` during resume.
- **CASE-STUDIES.md is legacy evidence** - the 23-bug / 9-file batch was
  produced under v0.1.x. New-design empirical cases must be re-accumulated.

## [0.1.0] - 2026-04-15

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
- Best on files in the 100-500 LoC range; smaller → low signal, larger →
  context pressure and dropping accept rates

### Case Studies
- See `skills/mangchi/CASE-STUDIES.md` for the OCR pipeline hardening batch
  (9 files, 23 real bugs caught including prompt-injection and European
  currency parsing corruption)
