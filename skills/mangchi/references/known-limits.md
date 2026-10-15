# Known Limits

> Full list of mangchi's design assumptions and detection limits. SKILL.md keeps a 3-line summary; this file is the SSOT.

### 설계 가정이 맞지 않는 경우
- **Token 경제**: "Claude 토큰 풍부, Codex 토큰 희소" 가정 - ChatGPT Plus 위주 사용자(Codex 싸고 Claude 비쌈)에겐 역방향. 그땐 pumasi가 더 적합.
- **Python 3.8+** 가정 - YAML 파싱에 프로젝트 Python 재사용. Python 없는 환경에선 별도 yaml parser (yq 등) 필요.
- **read-only 샌드박스** (0.4.0) - Codex는 `-s read-only`로 돈다: 읽기만 되고 쓰기·네트워크는 막힌다. 대상 파일 전문은 프롬프트에 들어가므로 리뷰 자체는 영향이 없지만, Codex가 주변 파일을 직접 열어 보는 탐색은 샌드박스가 읽게 해 주는 경로로 한정된다 (예: Windows에서 Google Drive `H:`는 access denied로 실측). 샌드박스를 못 쓰는 환경이면 사용자가 요청할 때만 `MANGCHI_CODEX_SANDBOX=bypass`.
- **`MANGCHI_CODEX_SANDBOX=bypass`는 환경변수로 받는다** - 한 번 export해 두면 이후 호출 모두 샌드박스 없이 돈다. 요약 줄·결과 JSON에 `sandbox=bypass`가 남고 stderr 경고가 나지만 호출마다 확인하지는 않는다 (prism·triad의 `PRISM_CODEX_SANDBOX`와 같은 방식이라 유지). 쓴 뒤에는 `unset`.
- **`-C`는 시작 폴더만 바꾼다** - Codex는 빈 임시 폴더에서 시작하지만, read-only 샌드박스는 절대 경로로 다른 파일을 읽을 수 있다. 읽기 제한이 아니라 실수로 프로젝트 파일을 여는 일을 줄이는 장치다.
- **Secret scrub은 패턴 기반** - `codex-run.sh`는 알려진 키 형식·`*_SECRET/PASSWORD/TOKEN=값`·DSN·JWT·PEM을 잡는다. 형식 없는 비밀(임의 문자열 비밀번호)은 못 잡으므로 `.env`·자격 증명 파일이 있는 디렉토리에서 돌리지 않는 것이 1차 방어다 (스크립트가 cwd에 있으면 경고).

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
