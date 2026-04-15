# CONVERGED

**Target**: `{target_file}`
**Working copy**: `updated.{ext}`
**Started**: {start_timestamp}
**Closed**: {end_timestamp}
**Rounds consumed**: {N} / 5
**Termination reason**: `{two_consecutive_pass | diff_convergence | max_rounds | user_stop}`

---

## 1. Axes Used

| round | axis | issues raised | accepted | diff_size |
|---|---|---|---|---|
| 1 | correctness | 3 | 2 | 18 |
| 2 | security | 1 | 1 | 5 |
| 3 | readability | 0 | 0 | 0 |
| ... | | | | |

Axes never used: `{list}`  (왜 안 썼는지 한 줄)

## 2. Final Diff (vs source-snapshot)

- Total +{added_lines} / -{deleted_lines}
- Key structural changes: `{bullet list}`
- Semantics preserved: `{yes | flagged: <reason>}`

## 3. Accepted Issues (합의된 수정)

라운드 번호 붙여 나열. `{[R1.correctness]: ...}` 형식.

- [R1.correctness] 입력 검증 누락 → 추가
- [R2.security] 로그에 토큰 노출 → 마스킹

## 4. Rejected Issues (보존되는 메인 판단)

메인이 기각한 Codex 지적. 기각 근거 기록.

- [R1] Codex 제안: X → 기각 (이유: ...)

## 5. Deferred Issues

별도 task로 추적 가치. pumasi/manual 입력 후보.

- [R3] 대규모 리팩토링 (`severity: low`이지만 가치 큼)

## 6. Known Limits

- Codex가 커버 못한 영역 (예: 실행 환경 특정 버그, UI 렌더링).
- 라운드 cap 때문에 다룬 축 {N} / 5 — 남은 축 `{list}`은 미검토.
- 테스트로 검증 안 한 변경 → 수동 테스트 추천.

## 7. Downstream Hooks

- `--apply=original` 사용했다면 원본 {target_file} 이미 교체됨.
- 아니라면 `updated.{ext}`가 최신본. 채택하려면:
  ```bash
  mv docs/refinement/{slug}/updated.{ext} {target_file}
  ```
  또는 `/mangchi {target_file} --apply=original` 재실행.
- 배포 전 기존 테스트 스위트 통과 확인 필수.
- 이 CONVERGED.md는 코드 리뷰 PR 첨부물로 적합 (변경 근거 + 반대의견 보존).
