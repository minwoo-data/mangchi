# Mangchi 사용 예시

## 예시 1: 코드 파일 반복 리뷰 (기본, read/write updated.*)

```
/mangchi src/routes/auth.py
```

진행:
- R1 correctness → Codex 지적 → Claude 수정 → `updated.py`
- R2 security → Codex 지적 → ...
- 2 PASS 연속 or 수렴 or cap 도달 시 종결
- `docs/refinement/auth-py/CONVERGED.md` 작성
- 원본 `src/routes/auth.py`는 **불변**

## 예시 2: 원본까지 반영

```
/mangchi src/routes/auth.py --apply=original
```

updated.py 수정과 함께 원본 파일도 Edit. Git diff로 변경 확인 가능.

## 예시 3: 특정 축만 순환

```
/mangchi src/utils/hash.py --axes=correctness,security
```

correctness + security만 순환. 2개 축이므로 최대 4-5 라운드 가능 (축 2개를 번갈아가며).

## 예시 4: 이어하기

```
/mangchi --continue auth-py
```

이미 진행된 세션의 state.json 읽어서 다음 축/라운드 진행.

## 예시 5: 강제 종결

```
/mangchi --stop auth-py
```

현재 라운드까지 결과로 CONVERGED.md 작성. 미완 상태로 마무리.

---

## 언제 쓰는가 (Use)

- 이미 동작하는 코드의 품질 끌어올리기 (갓 짠 PR 전 다듬기)
- 오래된 legacy 함수 리팩토링 전 스크리닝
- 보안/정확성 2단 리뷰 (Claude 작성 → Codex 비판)
- 코드 리뷰 PR에 CONVERGED.md 첨부 시 근거 문서 역할

## 언제 쓰지 말 것 (Skip)

- **Greenfield 구현** → pumasi 사용 (코드가 없는데 망치질 불가)
- **다중 파일 교차 일관성 이슈** → mangchi는 단일 파일 전용
- **1-2줄 bug fix** → Claude 직접 수정 (오버헤드 큼)
- **문서 (md)** → triad 사용 (mangchi는 실행 가능 코드 전용)
- **테스트만 쓰기** → Claude 직접 또는 pumasi

## Codex CLI 없을 때

Codex가 설치 안 됐거나 호출 실패 시:
1. `state.json`에 `fallback: true` 기록
2. 메인 에이전트가 해당 축 프롬프트로 **스스로 리뷰** 수행
3. round-N.md에 `[fallback: main-self-review]` 태그 명시

Self-review 모드는 mangchi 본래 가치(외부 시각의 cross-model 비판)의 상당 부분을 잃음. 중요 작업에선 Codex 설치 권장:
```bash
npm install -g @openai/codex
codex login   # 또는 OPENAI_API_KEY env 설정
```

## 파이프라인 조합 예시

```
triad (설계 결정)
  ↓ CONSENSUS.md
pumasi (초기 구현)
  ↓ 코드 파일들
mangchi (품질 망치질, 파일별)
  ↓ updated.*
review-all (최종 4-agent 리뷰, optional)
  ↓
commit
```

각 단계는 독립. 일부만 사용 가능. mangchi는 특히 pumasi 직후 투입이 자연스러움 (Codex가 만든 초안을 Codex가 다시 비판하는 것도 cross-axis 리뷰로 유효).

## Triad와 mangchi 경계

| 상황 | 추천 |
|---|---|
| md 문서 명료화 | **triad** |
| 코드 파일 읽기만 하고 권고문 생성 | **triad** (code 입력, `RECOMMENDATIONS.md` 산출) |
| 코드 파일 직접 다듬기 | **mangchi** |
| 코드 리뷰 후 pumasi로 재구현 | **triad** → pumasi |
| 기존 코드 품질 iteration | **mangchi** |

## 5-agent team rule 관계

프로젝트의 "review/refactor/analysis은 5 parallel agents" 규칙:
- mangchi는 **직렬 리뷰** (라운드당 1 Codex call)이지만 **5 축 rotation**으로 5 관점 커버.
- 병렬이 아닌 직렬 구조가 mangchi의 본질 (이전 라운드 수정 결과에 다음 축이 반응해야 의미 있음).
- 무차별 병렬 리뷰가 필요한 경우엔 `/review-all`(4-agent 병렬) 또는 `/gsd-code-review` 사용.

## 안전 장치 요약

- **원본 불변 기본** (`--apply=original` 없으면 절대 수정 안 함)
- **5 라운드 hard cap** (토큰/시간 무한 소비 방지)
- **축 로테이션 강제** (진자 운동 방지)
- **Codex "통과" 허용** (억지 비판 회피)
- **수렴 감지 30%** (diff 크기가 줄면 자동 종결)
- **fallback 투명 태깅** (Codex 실패를 감추지 않음)

## 드라이런 권장

처음 쓸 때는 작고 독립적인 파일로 시작:
- `src/utils/*.py` 중 한 개 (외부 의존 적은 유틸)
- 100-300줄 규모
- 테스트 있는 파일 (변경 검증 가능)

대형 파일(1000줄+)에 바로 돌리면 Codex 응답 지연 + 프롬프트 한도 문제 가능.
