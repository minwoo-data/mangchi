---
name: mangchi
description: "Iterative cross-model code refinement — Claude edits, Codex reviews one axis at a time with verification loop, until the code converges."
argument-hint: "<file> [--apply=original] [--only-axes=a,b] [--include-axes=necessity] [--start-axis=security] [--gate \"cmd\"] [--no-verify] [--allow-self-review] [--force] [--force-round] [--force-accept-threshold=N] [--dry-run] | --continue <slug> | --stop <slug>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /mangchi Command (v2)

Harden a single code file through iterative cross-model review. Claude writes
and decides; Codex CLI critiques one axis at a time (correctness / security /
readability / performance / design; `necessity` opt-in) AND verifies Claude's
REJECTs on a second pass. Terminates on verified convergence, PASS streak (with
minimum axis coverage), or hard cap.

## Parse Arguments

Inspect `$ARGUMENTS` to determine the action:

| Argument Pattern | Action |
|---|---|
| `<file>` | Start a new refinement session on `<file>` (read/write on `docs/refinement/mangchi/<slug>/updated.*` only, original untouched) |
| `<file> --apply=original` | Same as above, BUT also Edit the original file after each round |
| `<file> --only-axes=a,b,c` | Restrict axis rotation to the given subset (replaces default five) |
| `<file> --include-axes=necessity` | Default five + opt-in axis (currently only `necessity`) |
| `<file> --start-axis=<axis>` | Use `<axis>` for R1 instead of default `correctness` |
| `<file> --gate "<cmd>"` | Require external command (e.g. `pytest -x`) exit 0 before CONVERGED |
| `<file> --gate-every-round "<cmd>"` | Run gate at every round (not just termination) |
| `<file> --no-verify` | Skip Phase 6 Codex verification of Claude's REJECTs (adversarial guarantee lost) |
| `<file> --allow-self-review` | Do not prompt for self-review on missing Codex (CI use) |
| `<file> --force` | Bypass pre-flight size limits (>2000 LoC / >200KB) |
| `<file> --force-round` | Bypass per-round 80K token estimate cap for one round |
| `<file> --force-accept-threshold=N` | FORCED_ACCEPT abort threshold (default 1 = strict) |
| `<file> --dry-run` | Print R1 prompt without calling Codex |
| `--continue <slug>` | Resume an in-progress session from `docs/refinement/mangchi/<slug>/state.json` |
| `--stop <slug>` | Force-close the named session, produce CONVERGED.md with current state |
| (no argument) | Show interactive menu (see below) |

Legacy alias `--axes=+necessity` is still accepted for one version (maps to `--include-axes=necessity`).

## No Argument Provided

**EXECUTE:** Call the AskUserQuestion tool with the following JSON:

```json
{
  "questions": [
    {
      "question": "Which file do you want to harden?",
      "header": "Mangchi (망치)",
      "options": [
        {"label": "Enter file path", "description": "Provide a path to an existing code file (e.g., src/services/auth.py)"},
        {"label": "Continue session", "description": "Resume an in-progress mangchi session — you'll be asked for the slug next"},
        {"label": "Stop session", "description": "Force-close an in-progress session and write CONVERGED.md"}
      ],
      "multiSelect": false
    }
  ]
}
```

After the user selects and provides the file path or slug, re-run this command
with the resolved argument string.

## Prerequisites (check before execute)

1. **Bash 4+** — required for `declare -A`. Check with `[ "${BASH_VERSINFO[0]}" -ge 4 ] || abort`.
2. **Codex CLI installed** — run `command -v codex || echo missing`.
   - If missing in interactive TTY: prompt the user with recommendation
     (install Codex or use `/triad`) before falling back to self-review.
   - If missing in non-interactive env: auto-abort (unless `--allow-self-review`).
3. **Target file exists** — `test -f "<file>"` before starting a new session.
4. **Pre-flight size limits** — abort if file >2000 LoC or >200KB unless
   `--force` passed.
5. **2-PASS coverage warning** — if `--only-axes` excludes correctness AND
   security, warn the user that 2-consecutive-PASS termination is disabled
   (only R5 cap or `--gate` can terminate).

## Execute

Read the skill file, then follow its workflow exactly:

1. Read `${CLAUDE_PLUGIN_ROOT}/skills/mangchi/SKILL.md`
2. Follow SKILL.md's workflow (Phase 0 through Phase 9) with the user's
   argument string: `$ARGUMENTS`
3. Respect SKILL.md's hard invariants:
   - Codex never writes code (only critiques in YAML schema_version 1)
   - Claude never skips a review round
   - Axis rotation enforced — no adjacent-round repeats
   - Original file never modified unless `--apply=original` explicitly passed
   - Codex calls use tempfile + stdin only (shell-injection-safe — never
     pass prompt as argv)
   - REJECT requires `file:LINE` citation (hard validation error otherwise)
4. Preserve per-round audit trail under
   `docs/refinement/mangchi/<slug>/` as documented (new namespace, separates
   from `triad`)
5. Terminate on any of:
   - Two consecutive verified rounds (all ACCEPTs diff-verified, 0 DISAGREE)
   - Two consecutive `PASS + no_changes_suggested` — **requires
     correctness AND security to have been executed at least once**
   - R5 hard cap
   - `--gate "<cmd>"` exit 0 (when conditions 1–3 are met)
   - Explicit `--stop`
   - Abort: token budget / FORCED_ACCEPT ≥ threshold / schema retry fail /
     context window

## Output expectations

On success, the user should be able to:
- Review `docs/refinement/mangchi/<slug>/CONVERGED.md` for a summary of all
  decisions (including verify results and forced accepts)
- Read `INDEX.md` (regenerated every round) for a quick round-by-round table
- Diff `source-snapshot.*` against `updated.*` (using `git diff -w --numstat`)
- Replace the original file when ready — either via
  `cp updated.<ext> <original>` (destroys `--continue`) or by re-running with
  `--apply=original`

## Notes for the main agent

- If Codex call fails (exit code ≠ 0 or CLI missing), handle per SKILL.md's
  "Codex 부재 시 동작" section — interactive confirmation to self-review, or
  auto-abort in non-interactive environments. Do NOT silently fall back.
- Never elide or shorten the target file content when building the Codex
  prompt. Always `cat` the whole file into the prompt file, then redirect
  stdin — content shortening has previously been documented to degrade review
  fidelity (see `skills/mangchi/references/usage.md`).
- **All dynamic prompt content MUST be appended via `cat <file> >>`, never
  via unquoted variable expansion**. Codex outputs may contain backticks and
  `$(...)` — interpolating them would re-trigger shell expansion.
- If the user provides a file path that matches `*.md`, warn them that
  mangchi is for code and recommend the triad plugin for markdown.
- Cross-round issue identifiers use the format `R{n}.{axis}#{id}` — within a
  round `id` is unique, but round numbers prefix for cross-round reference.
- Legacy sessions (schema_version absent) encountered via `--continue`:
  warn the user before resuming; behavior may differ from current design.
