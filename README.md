# 망치 (Mangchi) — Iterative Code Refinement

**Language**: **English** · [한국어](README.ko.md)

> Claude writes, Codex critiques, Claude decides. Rotating review axes until
> the code stops moving or you hit the cap. Like hammering metal into shape
> one stroke at a time.

---

## What this is

A Claude Code skill that hardens a **single code file** through iterative
cross-model review. Each round picks one axis (correctness / security /
readability / performance / design), sends the file to the Codex CLI for
adversarial critique, lets Claude decide which issues to accept, and applies
the fixes. Repeat with a different axis until the file converges.

Think of it as a code-review ping-pong where neither player gets to
short-circuit — Codex can't apply its own fixes, Claude can't skip the
critique.

## When to use it

- **Existing code that needs hardening** before a release, PR, or deploy
- **Security review** of code that accepts untrusted input
- **Post-implementation cleanup** when Claude wrote the first draft and you
  want an outside model to sanity-check it
- **Before turning a prototype into production code**

## When NOT to use it

- **Greenfield construction from scratch** — mangchi hardens existing code;
  use a code-generation tool for net-new implementation
- **Markdown or documentation review** — use a deliberation tool instead
  (e.g. [triad](https://github.com/minwoo-data/triad) — mangchi operates on
  executable code with real fixes, not prose)
- **Cross-file architectural refactors** — mangchi is single-file by design
- **Tiny utility files** (< 80 LoC) — overhead exceeds signal

## Related tools (ecosystem fit)

Mangchi is designed to compose with other Claude Code tools in a natural
workflow:

| Stage | Tool | Role |
|---|---|---|
| Decide | deliberation tools (e.g. [triad](https://github.com/minwoo-data/triad)) | Multi-perspective design review before coding |
| Build | code-generation plugins (e.g. [pumasi](https://github.com/fivetaku/pumasi)) | Parallel greenfield implementation |
| **Harden** | **mangchi (this)** | **Single-file iterative cross-model review** |
| Verify | existing review/test runners | Final gate before merge |

Pick the one that matches the stage you're in. Mangchi specifically
targets the "code exists, needs to be better" gap.

## Install

### Prerequisites

```bash
# Codex CLI (the reviewer)
npm install -g @openai/codex
codex login    # or set OPENAI_API_KEY

# Claude Code (the orchestrator)
# See https://docs.claude.com/en/docs/claude-code
```

### Plugin install

```bash
# via marketplace (once published)
/plugin marketplace add https://github.com/minwoo-data/mangchi
/plugin install mangchi

# or manual: clone into your Claude Code skills path
git clone https://github.com/minwoo-data/mangchi ~/.claude/skills/mangchi-src
cp -r ~/.claude/skills/mangchi-src/skills/mangchi ~/.claude/skills/
```

Restart Claude Code after install.

## Usage

```
/mangchi src/services/auth.py                   # default: updated.py only, original untouched
/mangchi src/services/auth.py --apply=original  # also Edit the original file
/mangchi src/utils/hash.py --axes=correctness,security   # restrict axis rotation
/mangchi --continue auth-py                     # resume an in-progress session
/mangchi --stop auth-py                         # force close with whatever's in state
```

Natural-language triggers also work: *"망치로 다듬어줘"*, *"codex로 반복 리뷰해줘"*.

See `skills/mangchi/references/usage.md` for more examples.

## The five axes

| Axis | Question it asks |
|---|---|
| `correctness` | Does the code behave right on every input shape? |
| `security` | What attack surface does this expose? |
| `readability` | Can a contributor understand & change this in 6 months? |
| `performance` | Where is it wasting I/O, memory, or cycles? |
| `design` | Will this still be maintainable in a year? |

Each round uses exactly one axis. **Adjacent rounds cannot repeat an axis** —
rotation is enforced so you don't get five "correctness" rounds in a row.

## Termination

Any of:
1. **Two consecutive PASS + no-changes** verdicts from Codex
2. **Diff convergence** — the current round's LoC change is ≤ 30% of the previous round's
3. **5 rounds** (hard cap; prevents oscillation + token drain)
4. **User `/stop`**

## Safety defaults

- Original files are **never** modified without explicit `--apply=original`
- Default mode writes to `docs/refinement/<slug>/updated.py`; user decides
  when to replace the original
- Each round's Codex prompt and response are preserved as audit trail
- If Codex CLI fails or times out, main agent falls back to a local review
  pass with the same axis prompt, tagged `[fallback: main-local-pass]` in
  the round log

## Evidence

See [`skills/mangchi/CASE-STUDIES.md`](skills/mangchi/CASE-STUDIES.md) for
concrete examples of real bugs caught on real projects — bug categories,
accept rates, token costs, and honest limits.

## License

MIT — see [`LICENSE`](LICENSE).

## Credits

- Created by: Minwoo Park
- Built on [Claude Code](https://docs.claude.com/en/docs/claude-code)
  and the [OpenAI Codex CLI](https://github.com/openai/codex)
- Inspired by [pumasi](https://github.com/fivetaku/pumasi), which pioneered
  Claude-as-supervisor / Codex-as-worker patterns in Claude Code plugins
