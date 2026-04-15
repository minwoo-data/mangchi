# Changelog

All notable changes to the Mangchi plugin are documented here.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

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
