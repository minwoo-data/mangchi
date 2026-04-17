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
# Preferred: via Claude Code plugin marketplace
/plugin marketplace add minwoo-data/mangchi
/plugin install mangchi@mangchi

# Or manual: clone into your Claude Code skills path
git clone https://github.com/minwoo-data/mangchi ~/.claude/skills/mangchi-src
cp -r ~/.claude/skills/mangchi-src/skills/mangchi ~/.claude/skills/
```

Restart Claude Code after install. After the marketplace route, upgrades are a single `/plugin update mangchi@mangchi` — no re-clone needed.

## Usage

```
/mangchi src/services/auth.py                         # default: updated.* only, original untouched
/mangchi src/services/auth.py --apply=original        # also Edit the original file
/mangchi src/utils/hash.py --only-axes=correctness,security   # restrict axis rotation
/mangchi src/new_module.py --include-axes=necessity   # default 5 + necessity opt-in
/mangchi src/auth.py --start-axis=security            # R1 starts on security (not default correctness)
/mangchi src/parse.py --gate "pytest -x tests/"       # require external gate before CONVERGED
/mangchi src/x.py --no-verify                         # skip verify loop (adversarial guarantee lost)
/mangchi --continue src-services-auth-py              # resume an in-progress session (including aborted)
/mangchi --stop src-services-auth-py                  # force close with whatever's in state
```

Natural-language triggers also work: *"망치로 다듬어줘"*, *"codex로 반복 리뷰해줘"*.

See `skills/mangchi/references/usage.md` for every flag and more examples.

## The five axes (default) + `necessity` opt-in

| Axis | Question it asks | Default |
|---|---|---|
| `correctness` | Does the code behave right on every input shape? | ✓ |
| `security` | What attack surface does this expose? | ✓ |
| `readability` | Can a contributor understand & change this in 6 months? | ✓ |
| `performance` | Where is it wasting I/O, memory, or cycles? | ✓ |
| `design` | Will this still be maintainable in a year? | ✓ |
| `necessity` | Is this new code necessary, or does existing infra cover it? (YAGNI) | opt-in via `--include-axes=necessity` |

Each round uses exactly one axis. **Adjacent rounds cannot repeat an axis** —
rotation is enforced so you don't get five "correctness" rounds in a row.

## Termination (v2 schema)

Any of:
1. **Two consecutive verified rounds** — all ACCEPTed issues actually touched
   a matching diff (`locus` ±5 rule) AND zero `DISAGREE` returns from Codex's
   verify pass.
2. **Two consecutive `PASS + no_changes_suggested`** — requires `correctness`
   AND `security` to each have been executed at least once (gaming guard;
   "easy axes only" PASS streaks don't count).
3. **R5 hard cap** (prevents oscillation + token drain).
4. **`--gate "<cmd>"` exit 0** — external command passes (runs once before
   termination, or every round with `--gate-every-round`).
5. **User `--stop`**.

Aborts (session can be resumed with `--continue` after manual arbitration):
- Cumulative Codex tokens ≥ 500K
- `forced_accept_count ≥ --force-accept-threshold` (default **1** = strict)
- Codex YAML schema retry exhausted
- Per-call context window exceeded (≥ 180K tokens)

## Safety defaults

- Original files are **never** modified without explicit `--apply=original`.
- Default writes under `docs/refinement/mangchi/<slug>/updated.*`; namespaced
  to avoid collision with `triad`.
- **Verification loop (Phase 6)** — every Claude REJECT is re-reviewed by
  Codex. `DISAGREE` carries the issue into the next round; two consecutive
  `DISAGREE` on the same issue flips to `FORCED_ACCEPT` (system-promoted,
  not Claude's choice).
- **ACCEPT diff verification (Phase 5)** — each ACCEPTed issue's `locus`
  must actually be touched in `git diff -w --numstat` (±5 line fuzz). No-op
  ACCEPTs are carried forward, not counted toward convergence.
- **REJECT requires citation** — `file:LINE` or test name in the reason is
  mandatory (hard validation error, never silently flipped to ACCEPT).
- **Shell-injection-safe Codex calls** — strict tempfile + stdin pattern; no
  argv interpolation. All dynamic prompt content appended via
  `cat <file> >>` (never via unquoted variable expansion).
- **Pre-flight guards** — Bash 4+, file size (≤ 2000 LoC / ≤ 200KB unless
  `--force`), 2-PASS coverage warning if `--only-axes` excludes correctness
  or security.
- **Token budget** — per-round (80K estimate cap, `--force-round` bypass),
  per-call (180K context window, hard abort), cumulative (150K warn, 500K
  abort).
- **Codex missing handling** — interactive confirmation before self-review
  (which disables verify loop + `FORCED_ACCEPT`). Non-interactive envs
  auto-abort unless `--allow-self-review` passed.
- Each round's Codex prompt, review response, and verify response are
  preserved as audit trail (`round-N.prompt.txt`, `.codex.txt`,
  `.verify.txt`). `INDEX.md` summarizes all rounds.

## Research backing

Cross-model code review is empirically supported. LLMs systematically
underperform when reviewing their own output — Tsui et al. (2025) document
a 64.5% self-correction blind spot across 14 open-source models
([arXiv:2507.02778](https://arxiv.org/abs/2507.02778), NeurIPS 2025 LLM
Evaluation Workshop). Gong et al. (2024) find the same pattern specifically
for code security: models repair their own insecure code far less
successfully than code produced by a different model
([arXiv:2408.10495](https://arxiv.org/abs/2408.10495)). Semgrep (2025)
confirms the complementary-failure prediction in practice — Claude and
Codex caught different vulnerability classes on 11 real-world Python web
apps ([Semgrep blog](https://semgrep.dev/blog/2025/finding-vulnerabilities-in-modern-web-apps-using-claude-code-and-openai-codex)).

Mangchi operationalizes this: Claude edits, Codex reviews, rotating axes,
round-delta accumulation, audit trail per round.

See [`skills/mangchi/RESEARCH.md`](skills/mangchi/RESEARCH.md) for full
quotes, links, and what these sources do NOT claim.

## Evidence from real use

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
