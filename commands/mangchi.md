---
name: mangchi
description: "Iterative cross-model code refinement — Claude edits, Codex reviews one axis at a time, until the code converges."
argument-hint: "<file> [--apply=original] [--axes=correctness,security,...] | --continue <slug> | --stop <slug>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# /mangchi Command

Harden a single code file through iterative cross-model review. Claude writes
and decides; Codex CLI critiques one axis at a time (correctness / security /
readability / performance / design) until the code converges or hits the cap.

## Parse Arguments

Inspect `$ARGUMENTS` to determine the action:

| Argument Pattern | Action |
|---|---|
| `<file>` | Start a new refinement session on `<file>` (read-only mode — writes to `docs/refinement/<slug>/updated.*` only, original untouched) |
| `<file> --apply=original` | Same as above, BUT also Edit the original file after each round |
| `<file> --axes=a,b,c` | Restrict axis rotation to the given subset (default: all five) |
| `--continue <slug>` | Resume an in-progress session from `docs/refinement/<slug>/state.json` |
| `--stop <slug>` | Force-close the named session, produce CONVERGED.md with current state |
| (no argument) | Show interactive menu (see below) |

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

1. **Codex CLI installed** — run `command -v codex || echo missing`
   - If missing: instruct the user to `npm install -g @openai/codex && codex login` (or set `OPENAI_API_KEY`) and retry. Do NOT proceed — the skill relies on Codex as the reviewer.
2. **Target file exists** — `test -f "<file>"` before starting a new session. If absent, ask the user to correct the path.
3. **Not a binary or huge file** — if file size > 500 LoC, warn the user that accept rate drops on larger files per CASE-STUDIES.md, and ask whether to proceed.

## Execute

Read the skill file, then follow its workflow exactly:

1. Read `${CLAUDE_PLUGIN_ROOT}/skills/mangchi/SKILL.md`
2. Follow SKILL.md's 7-phase workflow with the user's argument string: `$ARGUMENTS`
3. Respect SKILL.md's hard invariants:
   - Codex never writes code (only critiques in YAML)
   - Claude never skips a review round
   - Axis rotation enforced — no adjacent-round repeats
   - Original file never modified unless `--apply=original` explicitly passed
4. Preserve per-round audit trail under `docs/refinement/<slug>/` as documented
5. Terminate on any of: two consecutive `PASS + no_changes_suggested` / diff ≤ 30% of previous round / 5-round hard cap / explicit `--stop`

## Output expectations

On success, the user should be able to:
- Review `docs/refinement/<slug>/CONVERGED.md` for a summary of all decisions
- Diff `source-snapshot.*` against `updated.*` to see cumulative changes
- Replace the original file when ready — either via `cp updated.py <original>` or by re-running with `--apply=original`

## Notes for the main agent

- If the Codex call fails (exit code ≠ 0 or missing CLI), fall back to a local review pass using the same axis prompt and tag the round with `[fallback: main-local-pass]`. Do not silently skip the round.
- Never elide or shorten the target file content when building the Codex prompt. Always `cat` the whole file into the prompt — content shortening has previously been documented to degrade review fidelity (see `skills/mangchi/references/usage.md`).
- If the user provides a file path that matches `*.md`, warn them that mangchi is for code and recommend the triad plugin for markdown deliberation.
