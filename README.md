# Mangchi - Iterative Code Refinement

**Language**: **English** · [한국어](README.ko.md)

**One model editing its own code keeps reinforcing its own blind spots, so the same bug survives multiple review passes?** mangchi alternates Claude-as-editor with Codex-as-reviewer across rotating review axes (5 default: correctness / security / readability / performance / design, plus opt-in `necessity` / `robustness`), catching each model's blind spots with the other until the code converges.

> Claude writes, Codex critiques, Claude decides. Rotating review axes until
> the code stops moving or you hit the cap. Like hammering metal into shape
> one stroke at a time.

---

## 30-second demo

**Without mangchi:**

You ask Claude to harden `auth.py`. It reviews itself, says "good enough", you ship it. A week later, Codex or a different reviewer immediately spots a race condition that Claude and you both missed. Same blind spot, one model, one pass.

**With mangchi:**

`/mangchi src/services/auth.py`. Round 1: Claude edits, Codex reviews on `correctness`. Round 2: Claude edits, Codex reviews on `security`. Round 3: `readability`. Each round a different axis, a different model doing the critique. Stop when two rounds in a row agree nothing more is needed, or at round 5. The delta file is written separately so the original is never touched unless you say so.

## Who should use this

- **Production-bound code you want to harden before release** - single-file sweep across the 5 default axes (plus opt-in `robustness` for stateful code)
- **Prompt-injection and security defense code** - adversarial second opinion from a different model
- **Claude Max users with spare Claude tokens** but needing external cross-model review without running Codex by hand
- **Correctness / security / readability / performance / design** sweep in one loop
- **Code-review PRs that need a rationale doc** - mangchi writes the round-by-round history

## Sibling tools (same marketplace)

- **[ddaro](https://github.com/minwoo-data/ddaro)** - worktree-based parallel Claude Code sessions with safe merge.
- **[prism](https://github.com/minwoo-data/prism)** - 5-agent parallel code review (broader, one-shot).
- **[triad](https://github.com/minwoo-data/triad)** - 3-perspective deliberation for design docs and markdown.

---

## What this is

A Claude Code skill that hardens a **single code file** through iterative
cross-model review. Each round picks one axis (correctness / security /
readability / performance / design), sends the file to the Codex CLI for
adversarial critique, lets Claude decide which issues to accept, and applies
the fixes. Repeat with a different axis until the file converges.

Think of it as a code-review ping-pong where neither player gets to
short-circuit - Codex can't apply its own fixes, Claude can't skip the
critique.

## When to use it

- **Existing code that needs hardening** before a release, PR, or deploy
- **Security review** of code that accepts untrusted input
- **Post-implementation cleanup** when Claude wrote the first draft and you
  want an outside model to sanity-check it
- **Before turning a prototype into production code**

## When NOT to use it

- **Greenfield construction from scratch** - mangchi hardens existing code;
  use a code-generation tool for net-new implementation
- **Markdown or documentation review** - use a deliberation tool instead
  (e.g. [triad](https://github.com/minwoo-data/triad) - mangchi operates on
  executable code with real fixes, not prose)
- **Cross-file architectural refactors** - mangchi is single-file by design
- **Tiny utility files** (< 80 LoC) - overhead exceeds signal

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

`mangchi` is distributed through the **haroom_plugins** aggregator marketplace along with the other haroom plugins (ddaro, prism, triad).

```bash
# 1. Add the haroom_plugins marketplace (one time)
/plugin marketplace add https://github.com/minwoo-data/haroom_plugins.git

# 2. Install
/plugin install mangchi
```

Restart Claude Code after install. Upgrades are a single `/plugin update` - the aggregator pulls updates for every haroom plugin you have installed.

## Usage

```
/mangchi src/services/auth.py                         # default: updated.* only, original untouched
/mangchi src/services/auth.py --apply=original        # also Edit the original file
/mangchi src/utils/hash.py --only-axes=correctness,security   # restrict axis rotation
/mangchi src/new_module.py --include-axes=necessity   # default 5 + necessity opt-in
/mangchi src/orders.py --include-axes=robustness      # add the concurrency / failure-recovery axis (preflight hints this for stateful code)
/mangchi src/auth.py --start-axis=security            # R1 starts on security (not default correctness)
/mangchi src/parse.py --gate "pytest -x tests/"       # require external gate before CONVERGED
/mangchi src/x.py --no-verify                         # skip verify loop (adversarial guarantee lost)
/mangchi --continue src-services-auth-py              # resume an in-progress session (including aborted)
/mangchi --stop src-services-auth-py                  # force close with whatever's in state
```

Natural-language triggers also work (e.g. *"refine with mangchi"*, *"cross-model review"*). Korean triggers are documented in the Korean README.

See `skills/mangchi/references/usage.md` for every flag and more examples.

## The five axes (default) + `necessity` / `robustness` opt-in

| Axis | Question it asks | Default |
|---|---|---|
| `correctness` | Does the code behave right on every input shape, single-threaded? (never flags races - that is `robustness`) | ✓ |
| `security` | What attack surface does this expose? (TOCTOU only when the attacker controls the timing) | ✓ |
| `readability` | Can a contributor understand & change this in 6 months? (owns function length, arity, nesting) | ✓ |
| `performance` | Where is it wasting I/O, memory, or cycles? | ✓ |
| `design` | Will this still be maintainable in a year? (SRP = mixed responsibilities only, not length) | ✓ |
| `necessity` | Is this new code necessary, or does existing infra cover it? (YAGNI) | opt-in via `--include-axes=necessity` |
| `robustness` | Does it survive concurrency / failure-recovery / data-integrity / state-transitions? **Sole owner of all concurrency findings.** | opt-in via `--include-axes=robustness` |

Each round uses exactly one axis. **Adjacent rounds cannot repeat an axis** -
rotation is enforced so you don't get five "correctness" rounds in a row.

**Axis ownership (0.3.1).** Every finding has exactly one home. Concurrency - shared-state races, lost updates, double-submit, TOCTOU without an attacker - belongs to `robustness` only; `correctness` reviews the single-threaded contract and self-rejects race findings; `security` keeps TOCTOU only when the attacker deliberately widens the check-to-use gap. Likewise `readability` owns "this function is too long", while `design`'s SRP item is reserved for genuinely mixed responsibilities. Before 0.3.1 the same race could be filed under three axes and the signal was split.

`robustness` is a 4-sub-axis runtime-failure probe - the reviewer must walk all four sub-axes (concurrency, failure & recovery, data integrity, state transitions) per round, or mark N/A with reason. It's orthogonal to `correctness` (which asks "does it meet its contract on the happy path?") - `robustness` asks "does it survive adversarial runtime conditions?". Opt-in because pure/stateless code has no realistic signal on these axes.

**Robustness hint.** Because races now live only in `robustness`, the preflight script greps the target for stateful markers (`threading`, `asyncio` / `await`, `Lock(`, `transaction` / `commit(` / `rollback`, `INSERT` / `UPDATE` / `DELETE`, `session.` / `cursor.`, `fetch(` / `requests.` / `httpx`, `state_machine`, `status =`). On a hit it prints:

```
[HINT] stateful code detected — consider --include-axes=robustness
```

It is a hint only - the axis is never enabled automatically. To enable both opt-in axes: `--include-axes=necessity,robustness`.

## Termination (v2 schema)

Any of:
1. **Two consecutive verified rounds** - all ACCEPTed issues actually touched
   a matching diff (`locus` ±5 rule) AND zero `DISAGREE` returns from Codex's
   verify pass.
2. **Two consecutive `PASS + no_changes_suggested`** - requires `correctness`
   AND `security` to each have been executed at least once (gaming guard;
   "easy axes only" PASS streaks don't count).
3. **R5 hard cap** (prevents oscillation + token drain).
4. **`--gate "<cmd>"` exit 0** - external command passes (runs once before
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
- **Verification loop (Phase 6)** - every Claude REJECT is re-reviewed by
  Codex. `DISAGREE` carries the issue into the next round; two consecutive
  `DISAGREE` on the same issue flips to `FORCED_ACCEPT` (system-promoted,
  not Claude's choice).
- **ACCEPT diff verification (Phase 5)** - each ACCEPTed issue's `locus`
  must actually be touched in `git diff -w --numstat` (±5 line fuzz). No-op
  ACCEPTs are carried forward, not counted toward convergence.
- **REJECT requires citation** - `file:LINE` or test name in the reason is
  mandatory (hard validation error, never silently flipped to ACCEPT).
- **Shell-injection-safe Codex calls** - strict tempfile + stdin pattern; no
  argv interpolation. All dynamic prompt content appended via
  `cat <file> >>` (never via unquoted variable expansion).
- **Pre-flight guards** - a real script, `skills/mangchi/scripts/preflight.sh`
  (Phase 0): Bash 4+ / git / Python 3.8+ + PyYAML / Codex presence, file
  size (≤ 2000 LoC / ≤ 200KB unless `--force`), 2-PASS coverage warning if
  `--only-axes` excludes correctness or security, hard refusal of self-review
  on security-sensitive filenames, the `robustness` hint, then slug + working
  dir + `updated.*` / `source-snapshot.*` / `state.json` initialisation.
- **Token budget** - per-call (180K context window, measured on the fully
  assembled prompt, hard abort), cumulative (150K warn, 500K abort).
- **Codex missing handling** - interactive confirmation before self-review
  (which disables verify loop + `FORCED_ACCEPT`). Non-interactive envs
  auto-abort unless `--allow-self-review` passed.
- Each round's Codex prompt, review response, and verify response are
  preserved as audit trail (`round-N.prompt.txt`, `.codex.txt`,
  `.verify.txt`). `INDEX.md` summarizes all rounds.

### Skill layout (0.3.1)

```
skills/mangchi/
├── SKILL.md                     # the workflow contract (~380 lines; loaded on every call)
├── axes.md                      # axis rubrics + YAML output schema (SSOT)
├── scripts/preflight.sh         # Phase 0: guards, robustness hint, slug, state.json init
├── references/
│   ├── state-schema.md          # state.json schema (schema_version 1)
│   ├── known-limits.md          # full list of design assumptions and detection limits
│   └── usage.md                 # every flag with examples
├── templates/                   # round.md, converged.md, index.md
├── CASE-STUDIES*.md, RESEARCH.md
```

SKILL.md deliberately carries only the rules; schemas, limits and the
preflight code live in the files above so each invocation pays for ~380
lines of contract instead of ~680.

## Research backing

Cross-model code review is empirically supported. LLMs systematically
underperform when reviewing their own output - Tsui et al. (2025) document
a 64.5% self-correction blind spot across 14 open-source models
([arXiv:2507.02778](https://arxiv.org/abs/2507.02778), NeurIPS 2025 LLM
Evaluation Workshop). Gong et al. (2024) find the same pattern specifically
for code security: models repair their own insecure code far less
successfully than code produced by a different model
([arXiv:2408.10495](https://arxiv.org/abs/2408.10495)). Semgrep (2025)
confirms the complementary-failure prediction in practice - Claude and
Codex caught different vulnerability classes on 11 real-world Python web
apps ([Semgrep blog](https://semgrep.dev/blog/2025/finding-vulnerabilities-in-modern-web-apps-using-claude-code-and-openai-codex)).

Mangchi operationalizes this: Claude edits, Codex reviews, rotating axes,
round-delta accumulation, audit trail per round.

See [`skills/mangchi/RESEARCH.md`](skills/mangchi/RESEARCH.md) for full
quotes, links, and what these sources do NOT claim.

## Evidence from real use

See [`skills/mangchi/CASE-STUDIES.md`](skills/mangchi/CASE-STUDIES.md) for
concrete examples of real bugs caught on real projects - bug categories,
accept rates, token costs, and honest limits.

## License

MIT - see [`LICENSE`](LICENSE).

## Credits

- Created by: haroom
- Built on [Claude Code](https://docs.claude.com/en/docs/claude-code)
  and the [OpenAI Codex CLI](https://github.com/openai/codex)
- Inspired by [pumasi](https://github.com/fivetaku/pumasi), which pioneered
  Claude-as-supervisor / Codex-as-worker patterns in Claude Code plugins
