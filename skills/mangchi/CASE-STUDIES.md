# Mangchi — Case Studies

> Evidence of what mangchi has caught in production-adjacent code.
> Factual. No marketing. Includes limits and failures.
>
> Each study anonymizes project identity and domain context while keeping
> bug categories, metrics, and the mangchi operational details intact.

---

## Case Study 1 — Python Backend OCR Pipeline Hardening

**Target kind**: A Python Flask backend with an AI-driven OCR pipeline — image
upload → provider fallback (two LLM providers) → response validation →
domain-specific normalization → DB persistence. ~2,000 LoC across nine
files covering prompt construction, the provider fallback chain, response
sanitization, normalization, caching, a circuit breaker, a bounded task
queue, injection defense, and the top-level orchestrator.

**Environment**:
- Main agent: Claude Opus 4.6 (1M context)
- Reviewer: OpenAI Codex CLI 0.120.0 (default model)
- Mode: `updated-only` (originals untouched; main-agent applied after decision)
- Axis usage: primarily `correctness` with `security` on files that handle
  untrusted input

### Headline numbers

| Metric | Value |
|---|---|
| Files processed | 9 |
| Total LoC (before) | ~2,156 |
| Total LoC (after) | ~2,372 (+216 net, +10%) |
| Codex API tokens consumed | ~63,300 |
| Issues raised by Codex | 29 |
| Accepted by main agent | 23 (79%) |
| Deferred as architectural | 5 (17%) |
| Rejected — prompt-transcription artifact (see below) | 1 (3%) |
| High-severity accept rate | ~90% |
| Targeted tests passing after batch | 33/33 (1 pre-existing test updated — see below) |
| Wall-clock time | ~90 min (including review, smoke tests, and doc) |

### Bug categories landed

#### Accuracy defects — OCR output was silently wrong

- **Locale-dependent amount parsing corruption** — the amount normalizer
  stripped everything except digits, dot, and minus. European-format values
  (`1.234,56` meaning 1234.56) became `1.23`, a 100× loss. Parenthesized
  negatives and trailing-minus formats also dropped their signs.
  Fix: rewrite as a proper parser with sign detection, currency-hint-driven
  decimal separator selection, and a rightmost-separator rule.

- **Non-US date formats rejected** — the date normalizer assumed MM/DD/YYYY
  and kept unparseable inputs (like `31/12/2024`) as-is with a warning.
  Fix: add DD/MM fallback when the first component is > 12, plus a
  day-first English pattern (`15 Jan 2024`).

- **Category misclassification from first-match-wins** — a dict-order
  category keyword map mapped "client dinner" to a generic Meals category
  because the `dinner` key came before the `client` key in the ordered dict.
  Fix: reorder so specific intent keywords (`client`) beat generic domain
  keywords.

- **JSON parser discarded the outer object** — the response parser searched
  for `[` before `{` regardless of textual position, so a response like
  `{"vendor": "X", "items": [...]}` was parsed as `[...]` alone.
  Fix: sort candidate start positions and decode from the earliest.

#### Resilience defects — partial failures degraded the whole pipeline

- **Last-model 503 killed every request** — the Gemini provider's model
  chain treated 503 UNAVAILABLE as "advance to next model" unconditionally.
  On the last model, that meant zero retries on the configured budget.
  A single transient outage killed every in-flight request.
  Fix: inline `is_last` check so the last model retries transient 503s
  within its budget.

- **MAX_TOKENS bonus retry never executed** — the truncation-detection path
  doubled the output token budget and `continue`d, but with
  `attempts_budget = 1` there was no next iteration.
  Fix: `attempts_budget += 1` grants a bonus attempt when truncation is
  detected, so the doubled budget is actually exercised.

- **Half-open circuit probe wedged forever** — the circuit breaker let one
  probe through after cooldown and set `_half_open_in_flight = True`. If
  the caller crashed before reporting, the flag stayed `True` forever and
  every subsequent request was blocked, permanently.
  Fix: record probe start timestamp; if probe hasn't reported within a
  timeout window, treat as failed, reset cooldown, release slot.

- **Bounded-queue invariant broke on timeouts** — on future timeout, the
  queue's `finally` block decremented the outstanding counter, but the
  underlying thread kept running (Python `future.cancel()` can't stop
  started work). Repeated timeouts meant real in-flight count exceeded
  `max_pending`, defeating the bound.
  Fix: use `add_done_callback` so the counter decrements only when the
  future truly reaches a terminal state.

- **Provider exceptions bypassed fallback chain** — the `_call_api_with_retry`
  loop didn't catch exceptions from individual provider calls, so if a
  provider wrapper raised instead of returning `None`, the remaining
  fallbacks were never tried.
  Fix: per-provider `try/except Exception` inside the chain loop.

- **Top-level exception handler too narrow** — the orchestrator caught a
  specific list of stdlib exceptions but missed provider-SDK-specific
  exceptions. When those propagated, the circuit breaker's failure
  counter wasn't bumped and no structured error was returned.
  Fix: broad `except Exception` at the orchestration boundary, below the
  narrower specific catches.

#### Security defects — prompt injection surface

- **Retry prompt interpolated attacker-controlled strings** — the amount
  retry prompt formatted raw `previous_data` values into the prompt text.
  Since `previous_data` carries OCR output from an attacker-controlled
  image, a string printed on a receipt could reach the retry prompt as
  an instruction to the downstream LLM.
  Fix: coerce all amount fields through a safe-numeric helper at
  assignment, so a malicious string becomes `0.0` before interpolation.

- **Unicode bypass of injection regex** — the sanitizer matched patterns
  against raw strings. Zero-width joiners, fullwidth characters, and
  NFKC-normalizable homoglyphs bypassed English-language injection
  patterns while still being interpreted by the downstream LLM.
  Fix: normalize to NFKC and strip a curated set of invisible format
  characters before pattern matching; sanitize the original on hit.

- **Nested-dict bypass of injection scan** — the sanitizer only iterated
  top-level string values. An attacker-controlled response with a nested
  structure like `{"notes": {"text": "ignore previous"}}` skipped
  injection scanning entirely; the value was preserved for downstream
  stringification.
  Fix: coerce non-string values in expected-string fields to sanitized
  defaults BEFORE pattern matching.

- **Log-poisoning via attacker-controlled values** — warning logs format
  attacker-controlled field values with `%s`. Newlines and terminal
  escape sequences in that content could forge log-line boundaries and
  corrupt later log review.
  Fix: use `%r` (repr) on attacker-controlled keys and values in log
  statements.

#### Defensive hygiene

- Cache `get`/`put` returned and stored dict references; caller mutations
  polluted the shared cached entry. Fix: `copy.deepcopy` at both
  boundaries.
- Several amount-parsing callsites used `float(x or 0)` which crashes on
  dirty strings (`"$12.34"`, `"N/A"`). Unified via a shared `_safe_float`
  helper.
- `None`-input guards added on functions that documented a `dict` type
  but could in practice receive `None` after an upstream failure.
- `page_count < 1` now raises `ValueError` instead of silently falling
  through to the single-page prompt path.

### Deferred as architectural (logged, not fixed in-line)

- **Thundering herd** in the idempotency cache — concurrent requests for
  the same uncached key each perform the expensive OCR call before the
  first one stores. Proper fix needs a `get_or_compute` API change that
  affects call sites — out of single-file scope.
- **Instance-state race on `_last_used_provider`** — multiple in-flight
  requests on a shared orchestrator can overwrite each other's provider
  value. Proper fix returns `(data, provider)` tuples through three
  method signatures — out of single-file scope.
- **Refund / credit receipt semantics** — the amount cross-validation
  auto-calculates or rejects negative totals. Real refund receipts have
  valid negative totals. This is a domain modeling question, not a code
  fix — escalated to product.
- **Timezone-aware date validation** — comparing a naive receipt date to
  `datetime.now()` produces false "future date" errors near midnight for
  international users. Low-impact edge case, logged for future.
- **Upstream discount-sign contract** — the validator could defensively
  `abs()` discount values, but the upstream prompt already enforces
  negative discounts. Adding defensive coercion would mask upstream bugs.
  Kept as-is by design.

### What mangchi did NOT find

- **Prompt-content quality**: the natural-language OCR instructions (word
  choice, example placement, instruction ordering) — this is prompt
  engineering, not code. Mangchi stays in its lane.
- **Cross-file architectural issues**: the `_last_used_provider` race
  WAS flagged (Codex is smart enough to spot it) but the full fix lives
  across multiple methods and files. Mangchi correctly surfaced it and
  correctly deferred it.
- **Performance under real load**: no benchmarks were run. The file-local
  reasoning did catch algorithmic concerns (thundering herd, N+1 patterns)
  but never profiled.
- **Domain semantics**: refund receipt handling is a business decision,
  not a bug. Mangchi correctly escalated it rather than inventing a fix.

### What surprised us

- **Correctness axis and security axis produced different fixes on the
  same function.** Correctness round said "you need a safe-float helper
  for these math operations." Security round said "now use that helper
  at all interpolation sites to prevent prompt injection." Same helper,
  different application, two distinct patches. This is exactly what axis
  rotation is designed to surface.
- **Cross-model review caught state-race issues the main agent's own
  review missed.** Instance-state races are easy to miss when you wrote
  the code — a second model with a different prior is less invested in
  the code being correct.
- **One false positive came from a prompt-transcription typo by the main
  agent.** While generating the Codex prompt for one file, the main
  agent accidentally retyped `False` as lowercase `false`. Codex
  correctly flagged `false` as a `NameError`-producing bug — except the
  real source had `False`. The "bug" was in the prompt, not the code.
  Operational lesson captured: always `cat` the file into the prompt;
  never re-type. Codex still did the right thing given the input it saw.

### Test regression and update

One pre-existing test literally encoded the OLD (broken) behavior —
"last-model 503 gives up with zero retries." The test comment even read
as if the bug were intended. After mangchi's fix, that test started
failing. Updated the test to assert the new, correct behavior (primary
fast-fails, last model retries within budget), with a comment explaining
the outage-resilience rationale. 33/33 targeted OCR tests now pass.

### Reproducibility

For each file, the run preserved:
- `source-snapshot.py` — pre-patch source
- `updated.py` — post-patch source
- `codex-prompt-r1.txt` — exact prompt sent to Codex CLI
- `codex-response-r1.txt` — Codex's full YAML output
- `round-1.md` — decision log + smoke test results

A future reader can paste the preserved prompt into `codex exec` and
compare against the preserved response to verify output stability.

### Key takeaways for adopters

- **Strongest value on code with untrusted-input surfaces** — OCR/vision
  outputs, external API responses, user submissions. Axis rotation from
  correctness → security reliably surfaces different classes of issue.
- **Moderate value on utility code** — queues, circuit breakers, caches.
  Real bugs exist but fewer per file.
- **Diminishing value on large orchestration code** — files > 400 LoC
  saw accept rate drop from ~100% to ~67% as Codex started flagging
  issues that really required cross-file context.
- **Low value on trivial files** — sub-100-line utilities may PASS or
  return one low-severity issue. The overhead exceeds signal.

---

## Template for future case studies

Append new case studies to the TOP of this file. Keep the oldest at the
bottom for easy release-over-release comparison.

```markdown
## Case Study N — <anonymized project kind> (<date>)

**Target kind**: <generic project description, no identifying info>
**Environment**: <agents, models, config>

### Headline numbers
| Metric | Value |
|---|---|

### Bug categories landed
- **<category>**: <generic description>. Fix: <one-line>.

### Deferred as architectural
- <reason out of scope>

### What mangchi did NOT find
- <honest limitation>

### Reproducibility
- Artifacts preserved at <path>
```
