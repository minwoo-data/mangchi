# Round {N} — Axis: `{axis}`

**Target**: `{target_file}`  → working on `updated.{ext}`
**Started**: {timestamp}
**Previous axis**: `{previous_axis or "(none, R1)"}`

---

## 1. Axis selection rationale

왜 이 축을 선택했는가. (직전 축과 다름 확인. 이전 라운드 어떤 signal이 이 축으로 유도했는가.)

---

## 2. Codex Response

### Invocation
```bash
codex exec --dangerously-bypass-approvals-and-sandbox "<prompt digest>"
```

### Raw YAML output

```yaml
{raw_codex_yaml}
```

**Fallback check**: `{no_fallback | [fallback: main-self-review] — reason}`

---

## 3. Claude Decisions

이슈별 판정. 근거 한 줄 필수.

| # | severity | locus | decision | reason |
|---|---|---|---|---|
| 1 | high | auth.py:45-52 | ACCEPT | <1-line> |
| 2 | med | auth.py:120 | REJECT | <reason: Codex missed context that X> |
| 3 | low | auth.py:200 | DEFER | <reason: scope creep, not this axis's job> |

---

## 4. Applied Changes

### Diff summary
- Inserted: `{+N}` lines
- Deleted: `{-M}` lines
- Total diff_size: `{N+M}`

### Key patches

```diff
- before
+ after
```

Applied to: `updated.{ext}`.
Original (`{target_file}`): **{unchanged | modified}` (apply_mode={apply_mode})`.

---

## 5. Convergence Stats

| Metric | Value |
|---|---|
| diff_size this round | {N+M} |
| diff_size last round | {prev N+M or "(N/A, R1)"} |
| convergence_ratio | {ratio or "(N/A)"} |
| consecutive PASS + no_changes_suggested | {count} |

**Termination check**: `{CONTINUE | TERMINATE: <reason>}`

---

## 6. Carryover to Round {N+1}

- Remaining axes eligible: `{list}`
- Excluded (already used or all-REJECTed): `{list}`
- DEFERred issues: `{count}` (not forced to next round; axis rotation drives selection)

종결 시 이 섹션 대신 **"CONVERGED — see CONVERGED.md"**.
