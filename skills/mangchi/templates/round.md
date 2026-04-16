# Round {N} — Axis: `{axis}`

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

### Invocation (stdin via tempfile, no shell interpolation)
```bash
cat > docs/refinement/mangchi/{slug}/round-{N}.prompt.txt <<'PROMPT_EOF'
<full prompt body: axis rubric + updated.<ext> content + prior decisions digest>
PROMPT_EOF

codex exec --dangerously-bypass-approvals-and-sandbox \
  < docs/refinement/mangchi/{slug}/round-{N}.prompt.txt \
  > docs/refinement/mangchi/{slug}/round-{N}.codex.txt
```

**Rationale**: 단일 인자 `"<prompt>"` 방식은 파일 내용에 backtick/`$(...)`/quote 있으면 shell injection. Heredoc `<<'PROMPT_EOF'` quoted + stdin으로 Codex에 전달해 이 벡터 차단.

**Token pre-estimate** (per-round guard, Phase 2 start):
- `char_count(prompt) / 4 * 1.3` ≥ 80K → abort round (unless `--force-round`).
- `--force-round`로 1회 bypass, state.json `force_round_rounds: [N]` 기록.

### Raw YAML output

```yaml
{raw_codex_yaml}
```

**Schema validation** (Phase 3):
- parse 실패 또는 required fields 누락 → Codex에 "schema 위반, 재전송" 프롬프트 1회 재시도.
- 재시도 실패 → abort, `state.json.last_invalid_codex_output: "..."` 기록.

**Fallback check**: `{no_fallback | [fallback: main-self-review] — reason}`

> Self-review 모드 시: verify 호출 (Phase 6)과 FORCED_ACCEPT 메커니즘 **전부 비활성**. `state.json.self_review_mode: true` 기록.

---

## 3. Claude Decisions (Phase 4)

이슈별 판정. **REJECT 근거는 `file:LINE` 인용 필수** — 없으면 Codex에 재질의하거나 판정 보류 (절대 silently ACCEPT 처리 안 함, hard validation error).

| issue_id | severity | locus | decision | reason (citation 포함) |
|---|---|---|---|---|
| 1 | HIGH | auth.py:45-52 | ACCEPT | <1-line> |
| 2 | MEDIUM | auth.py:120 | REJECT | auth.py:118 already handles null-check; Codex missed |
| 3 | LOW | auth.py:200 | REJECT | tests/test_auth.py::test_edge covers this |

**Decisions 가능값 (Claude만 선택)**: `ACCEPT | REJECT`. (DEFER는 schema v1에서 제거됨.)

> `FORCED_ACCEPT`는 **Claude가 직접 선택하지 않음** — Phase 6 verify loop에서 Codex가 2연속 DISAGREE 유지할 때 시스템이 자동 승격하는 action. §5 참조.

---

## 4. Applied Changes (Phase 5)

### Diff measurement
```bash
git diff -w --numstat updated.{ext}
```
(`-w`: whitespace 무시 — 의미적 변경만 카운트.)

- Inserted (non-whitespace): `{+N}` lines
- Deleted (non-whitespace): `{-M}` lines
- Total diff_loc: `{N+M}`

### ACCEPT git-diff verification

각 ACCEPT된 이슈에 대해 `locus`의 ±5줄 영역이 실제 diff에서 변경됐는지 확인:

| issue_id | locus | diff_verified |
|---|---|---|
| 1 | auth.py:45-52 | ✓ (lines 43-55 touched) |
| 4 | utils.py:10 | ✗ (no-op ACCEPT — 영역 변경 없음, state에 기록, carry over) |

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
cat > docs/refinement/mangchi/{slug}/round-{N}.verify.prompt.txt <<'VERIFY_EOF'
<verify prompt: REJECT된 이슈들 + 각 locus의 post-edit updated.<ext> ±10줄 context>
VERIFY_EOF

codex exec --dangerously-bypass-approvals-and-sandbox \
  < docs/refinement/mangchi/{slug}/round-{N}.verify.prompt.txt \
  > docs/refinement/mangchi/{slug}/round-{N}.verify.txt
```

### Verify results

| issue_id | claude_decision | codex_verdict | action |
|---|---|---|---|
| 2 | REJECT | AGREE | 종결 |
| 3 | REJECT | DISAGREE | carry over to R{N+1}, status: PENDING |

**FORCED_ACCEPT 룰**: 같은 `issue_id`가 2라운드 연속 DISAGREE → 강제 ACCEPT + `forced_accept_count += 1`. `forced_accept_count ≥ 3` → abort.

---

## 6. Stop Condition Check (Phase 7)

| Condition | Value | Triggered? |
|---|---|---|
| 2 consecutive verified rounds (all ACCEPTs diff-verified + DISAGREE 0) | {running count} | {yes/no} |
| 2 consecutive PASS (any axes, but 최소 `correctness` + `security` 중 최소 1회 실행 필수) | {running count} | {yes/no} |
| R5 cap | current=R{N} | {yes if N==5} |
| `--gate "<cmd>"` (옵션) | `{gate_result or "N/A"}` | {yes/no} |
| `--stop` (manual) | - | {yes/no} |
| Token abort: cumulative ≥ 500K | {total} | {yes/no} |
| `forced_accept_count ≥ 3` | {count} | {yes/no} |

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

종결 시 이 섹션 대신 **"CONVERGED — see CONVERGED.md"** 또는 **"ABORTED — see state.json"**.
