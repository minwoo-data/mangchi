# Known Limits

> Full list of mangchi's design assumptions and detection limits. SKILL.md keeps a 3-line summary; this file is the SSOT.

### 설계 가정이 맞지 않는 경우
- **Token 경제**: "Claude 토큰 풍부, Codex 토큰 희소" 가정 - ChatGPT Plus 위주 사용자(Codex 싸고 Claude 비쌈)에겐 역방향. 그땐 pumasi가 더 적합.
- **Python 3.8+** 가정 - YAML 파싱에 프로젝트 Python 재사용. Python 없는 환경에선 별도 yaml parser (yq 등) 필요.

### 자동 탐지 한계
- **No-op ACCEPT (locus ±5)**: 리팩터링으로 locus가 함수 전체 이동한 경우 false-negative 가능. CONVERGED.md §6 수동 확인 권장.
- **Citation 진위**: Claude의 REJECT citation이 `file:LINE`은 체크하지만, 그 line의 코드가 실제로 Codex 지적을 "처리한 코드"인지는 검증 불가. 유일한 하드 카운터는 `--gate "<test>"`.
- **Fabricated test name**: `tests/test_x.py::test_y`가 실존하는 테스트인지는 체크 안 함 (`--gate`로 통해야 drop되지만 gate 없으면 통과).

### Resume 제한
- **mv destroys continue**: CONVERGED 후 `mv updated.<ext> target_file` 실행 시 `--continue` 불가능. `--apply=original` 쓰거나 `mv` 전에 세션 종결 확인.
- **Abort 후 continue 가능**: FORCED_ACCEPT ≥ threshold abort는 state 보존 - 수동 arbitration 후 `/mangchi --continue <slug>` 가능.

### Self-review 모드 (Codex 부재)
- Phase 6 verify loop 비활성 → Claude가 자기 판정을 자기 검증 = adversarial 무효.
- FORCED_ACCEPT 메커니즘 비활성.
- `state.json.self_review_mode: true` 기록됨.
- 실질적으로 mangchi가 linter 수준으로 degrade. 중요 작업엔 비권장.

### --no-verify 모드
- Phase 6 전체 스킵 → REJECT 재검증 없음.
- FORCED_ACCEPT 메커니즘 비활성.
- Claude의 REJECT를 신뢰한다는 결정 = adversarial 보증 포기.
- 보안/복잡 로직엔 비권장.
