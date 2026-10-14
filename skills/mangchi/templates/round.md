# Round {N} - Axis: `{axis}`

**Target**: `{target_file}`  → working on `updated.{ext}`
**Started**: {timestamp}
**Previous axis**: `{previous_axis or "(none, R1)"}`
**Schema version**: 1

---

## 1. Axis selection rationale

왜 이 축을 선택했는가. (직전 축과 다름 확인. 이전 라운드 어떤 signal이 이 축으로 유도했는가. DISAGREE 이월 의제 있었는지.)

**Precedence** (R2+): `same-axis-ban > carryover-disagree > rotation heuristic`.
- 직전 축과 같음: 거부.
- DISAGREE 이월 있고 그 축이 직전과 다름: 그 축 우선.
- 그 외: issue 빈도/signal 기준 선택.

---

## 2. Codex Review Call (Phase 2)

### Invocation (`scripts/codex-run.sh` - preamble, stdin, read-only sandbox, scrub, schema check)
```bash
bash "<skill dir>/scripts/codex-run.sh" review docs/refinement/mangchi/{slug} {N} {axis}
```

**Summary line**: `{codex_run_summary_line}` (`status=… verdict=… issues=… tokens=… sandbox=read-only`)

**Prompt**: `round-{N}.prompt.txt` = preamble → 역할 + `{axis}` rubric + 출력 포맷 (axes.md) → `updated.{ext}` 전문 → `round-{N-1}.carryover.md` (R≥2). 스크립트가 조립 - argv 전달 없음 (shell injection 차단).

**Token pre-estimate** (per-call guard, 스크립트가 계산):
- `char_count(prompt) / 4 * 1.3` ≥ 180K → Codex 호출 없이 `degraded(prompt-too-large)` → abort `aborted_context_window`.

### Codex answer (`round-{N}.codex.txt`, scrub 통과분)

```yaml
{codex_yaml_answer}
```

**Schema validation** (Phase 3, `round-{N}.codex.txt.json`):
- `status`: `{ok | schema-invalid(<field>) | degraded(<reason>) | secret-scrubbed(<reason>)}`
- schema-invalid → 같은 명령에 `--retry` 1회 (첫 답은 `round-{N}.codex.attempt1.txt`).
- 재시도 실패 → abort `aborted_codex_schema`, `state.json.last_invalid_codex_output: "..."` 기록.

**Fallback check**: `{no_fallback | [fallback: main-self-review] - reason}`

> Self-review 모드 시: verify 호출 (Phase 6)과 FORCED_ACCEPT 메커니즘 **전부 비활성**. `state.json.self_review_mode: true` 기록.

---

## 3. Claude Decisions (Phase 4)

이슈별 판정. **REJECT 근거는 `file:LINE` 인용 필수** - 없으면 Codex에 재질의하거나 판정 보류 (절대 silently ACCEPT 처리 안 함, hard validation error).

| issue_id | severity | locus | decision | reason (citation 포함) |
|---|---|---|---|---|
| 1 | HIGH | auth.py:45-52 | ACCEPT | <1-line> |
| 2 | MEDIUM | auth.py:120 | REJECT | auth.py:118 already handles null-check; Codex missed |
| 3 | LOW | auth.py:200 | REJECT | tests/test_auth.py::test_edge covers this |

**Decisions 가능값 (Claude만 선택)**: `ACCEPT | REJECT`. (DEFER는 schema v1에서 제거됨.)

> `FORCED_ACCEPT`는 **Claude가 직접 선택하지 않음** - Phase 6 verify loop에서 Codex가 2연속 DISAGREE 유지할 때 시스템이 자동 승격하는 action. §5 참조.

---

## 4. Applied Changes (Phase 5)

### Diff measurement
```bash
git diff -w --numstat updated.{ext}
```
(`-w`: whitespace 무시 - 의미적 변경만 카운트.)

- Inserted (non-whitespace): `{+N}` lines
- Deleted (non-whitespace): `{-M}` lines
- Total diff_loc: `{N+M}`

### ACCEPT git-diff verification

각 ACCEPT된 이슈에 대해 `locus`의 ±5줄 영역이 실제 diff에서 변경됐는지 확인:

| issue_id | locus | diff_verified |
|---|---|---|
| 1 | auth.py:45-52 | ✓ (lines 43-55 touched) |
| 4 | utils.py:10 | ✗ (no-op ACCEPT - 영역 변경 없음, state에 기록, carry over) |

### Key patches

```diff
- before
+ after
```

Applied to: `updated.{ext}`.
Original (`{target_file}`): `{unchanged | modified}` (apply_mode={apply_mode}).

---

## 5. Verification Loop (Phase 6)

**Skip conditions** (모두 해당 시 생략):
- REJECT 0개
- `--no-verify` 플래그
- Self-review 모드

### Verify invocation
```bash
# round-{N}.rejects.yaml: REJECT된 이슈 (id, locus, problem, reason(인용 필수), post_edit_lines)
bash "<skill dir>/scripts/codex-run.sh" verify docs/refinement/mangchi/{slug} {N} \
  --issues docs/refinement/mangchi/{slug}/round-{N}.rejects.yaml
```

스크립트가 각 locus의 post-edit `updated.{ext}` ±10줄 context를 붙인다. 결과: `round-{N}.verify.txt` + `.json` (`status`, `verify.verifications[]`).

### Verify results

| issue_id | claude_decision | codex_verdict | action |
|---|---|---|---|
| 2 | REJECT | AGREE | 종결 |
| 3 | REJECT | DISAGREE | carry over to R{N+1}, status: PENDING |

**FORCED_ACCEPT 룰**: 같은 `issue_id`가 2라운드 연속 DISAGREE → 강제 ACCEPT + `forced_accept_count += 1`. `forced_accept_count ≥ force_accept_threshold` (default **2**) → abort.

---

## 6. Stop Condition Check (Phase 7)

| Condition | Value | Triggered? |
|---|---|---|
| 2 consecutive verified rounds (all ACCEPTs diff-verified + DISAGREE 0) | {running count} | {yes/no} |
| 2 consecutive PASS (`correctness`와 `security`가 이력에 **각각** ≥ 1회 실행되어 있어야 유효) | {running count} | {yes/no} |
| R5 cap | current=R{N} | {yes if N==5} |
| `--gate "<cmd>"` (옵션) | `{gate_result or "N/A"}` | {yes/no} |
| `--stop` (manual) | - | {yes/no} |
| Token abort: cumulative ≥ 500K | {total} | {yes/no} |
| `forced_accept_count ≥ force_accept_threshold` (default 2) | {count} / {threshold} | {yes/no} |

**Termination**: `{CONTINUE | TERMINATE: <reason>}`

---

## 7. Token Accounting

| Call | Tokens (Codex-reported) | Tokens (estimate if missing) |
|---|---|---|
| review (Phase 2) | {n} | `char/4 * 1.3 = {n}` |
| verify (Phase 6) | {n or "skipped"} | - |
| **Round total** | {sum} | |
| **Cumulative** (state.json) | {running} | |

Cumulative ≥ 150K: `[WARN]` 로그. ≥ 500K: abort.

---

## 8. Carryover to Round {N+1}

- Remaining axes eligible: `{list}`
- Excluded (already used or all-REJECTed + verify-AGREE): `{list}`
- DISAGREE carry (이월 선행 의제): `{issue_id list}`
- No-op ACCEPT carry: `{issue_id list}`
- `round-{N}.carryover.md` 작성됨 (`## decisions` / `## carryover` / `## forced_accept`) - R{N+1} `review`가 읽는다

종결 시 이 섹션 대신 **"CONVERGED - see CONVERGED.md"** 또는 **"ABORTED - see state.json"**.
