# Mangchi 사용 예시

## 예시 1: 코드 파일 반복 리뷰 (기본, read/write updated.*)

```
/mangchi src/routes/auth.py
```

진행:
- R1 correctness → Codex 지적 → Claude 수정 → Codex verify → `updated.py`
- R2 security → ...
- 2 verified rounds 또는 2 consecutive PASS 또는 R5 cap 도달 시 종결
- `docs/refinement/mangchi/src-routes-auth-py/CONVERGED.md` 작성
- 원본 `src/routes/auth.py`는 **불변**

## 예시 2: 원본까지 반영

```
/mangchi src/routes/auth.py --apply=original
```

updated.py 수정과 함께 원본 파일도 Edit. Git diff로 변경 확인 가능.

## 예시 3: 특정 축만 순환

```
/mangchi src/utils/hash.py --only-axes=correctness,security
```

correctness + security만 순환. 2개 축이므로 최대 4-5 라운드 가능 (축 2개를 번갈아가며).

> **Pass-based 종결 rule**: `2 consecutive PASS`로 종결하려면 `correctness`와 `security` 축이 **각각 최소 1회씩** 실행되어 있어야 함. 이 제약은 "쉬운 축만 돌아 security 미검수로 종결"을 막는 게이밍 가드. `--only-axes`가 correctness/security 중 하나라도 빼면 Pre-flight에 `[WARN]` — 2-PASS 종결 경로가 막히고 R5 cap이나 `--gate`로만 수렴 가능.

## 예시 4: necessity 축 opt-in

```
/mangchi src/services/new_manager.py --include-axes=necessity
```

default 5축 + `necessity` 추가. `necessity`는 제거 판단이 주라 default 제외, refactor/신규 모듈 리뷰 시 명시.

> Legacy alias: `--axes=+necessity` (1버전 유지, deprecated).

## 예시 5: R1 시작 축 지정

```
/mangchi src/auth/session.py --start-axis=security
```

보안 touchpoint 많은 파일은 R1부터 `security` 돌리기. 기본은 `correctness`.

## 예시 6: 외부 게이트

```
/mangchi src/utils/parse.py --gate "pytest -x tests/test_parse.py"
```

종결 판정 시 gate 명령어 exit 0이어야 CONVERGED. 테스트 기반 ground truth로 adversarial 게이밍까지 차단.

## 예시 7: 이어하기

```
/mangchi --continue src-routes-auth-py
```

이미 진행된 세션의 state.json 읽어서 다음 축/라운드 진행. DISAGREE 이월 의제가 선행.

**백워드 호환**: 구 경로 `docs/refinement/{slug}/` 사용 세션 감지 시 `[WARN]` 로그 + 마이그레이션 안내. 자동 이동은 안 함 (실수 방지).

## 예시 8: 강제 종결

```
/mangchi --stop src-routes-auth-py
```

현재 라운드까지 결과로 CONVERGED.md 작성. 미완 상태로 마무리.

---

## 언제 쓰는가 (Use)

- 이미 동작하는 코드의 품질 끌어올리기 (갓 짠 PR 전 다듬기)
- 오래된 legacy 함수 리팩토링 전 스크리닝
- 보안/정확성 2단 리뷰 (Claude 작성 → Codex 비판 → Codex 검증)
- 코드 리뷰 PR에 CONVERGED.md 첨부 시 근거 문서 역할

## 언제 쓰지 말 것 (Skip)

- **Greenfield 구현** → pumasi 사용 (코드가 없는데 망치질 불가)
- **다중 파일 교차 일관성 이슈** → mangchi는 단일 파일 전용
- **1-2줄 bug fix** → Claude 직접 수정 (오버헤드 큼)
- **문서 (md)** → triad 사용 (mangchi는 실행 가능 코드 전용)
- **테스트만 쓰기** → Claude 직접 또는 pumasi
- **대형 파일 (> 2000 LoC 또는 > 200KB)** → pre-flight에 abort. `--force`로 override 가능하지만 권장 X (Codex context window 한계).

## Codex CLI 없을 때

**mangchi는 multi-model adversarial review로 설계됨** — Codex 없이는 본질 가치 상실.

대화형 환경:
```
[WARN] Codex CLI not found.

mangchi is designed as multi-model adversarial review —
Claude writes, Codex critiques. Self-review defeats the design.

Strongly recommended:
  1. Install Codex: npm i -g @openai/codex
  2. Or use /triad <file> (Claude-only, three-lens review)

Do you really want to run Claude-only self-review? [y/N]:
```

- `y` → self-review 진행, `state.json.self_review_mode: true`, **verify loop + FORCED_ACCEPT 메커니즘 비활성**.
- `N` 또는 Enter → abort.

비대화형 환경 (CI, pipe): 자동 abort.

`--allow-self-review` 플래그: 묻지 않고 self-review (automation escape hatch).

## `--no-verify` 사용 시 주의

`--no-verify` 플래그는 Phase 6 (Codex verification loop)을 생략:
- Codex 호출 수 절반 절감
- **그러나**: Claude의 REJECT를 Codex가 재검증하는 adversarial 가드 제거.
- FORCED_ACCEPT / DISAGREE 이월 메커니즘도 **같이 비활성** (검증 없으니 이월할 근거 없음).
- 사용 권장 경우: 토큰 예산 빡빡 / 반복 빠른 개발 / 이미 신뢰하는 외부 리뷰어 있는 경우.
- 사용 비권장: 보안 관련 코드, 복잡한 비즈니스 로직, legacy 대상.

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

각 단계는 독립. 일부만 사용 가능. mangchi는 특히 pumasi 직후 투입이 자연스러움.

## Triad와 mangchi 경계

| 상황 | 추천 |
|---|---|
| md 문서 명료화 | **triad** |
| 코드 파일 읽기만 하고 권고문 생성 | **triad** (code 입력, `RECOMMENDATIONS.md` 산출) |
| 코드 파일 직접 다듬기 | **mangchi** |
| Codex CLI 없는 환경의 코드 리뷰 | **triad** (Claude 단독 3 lens) |
| 기존 코드 품질 iteration | **mangchi** |

## 5-agent team rule 관계

프로젝트의 "review/refactor/analysis은 5 parallel agents" 규칙:
- mangchi는 **직렬 리뷰** (라운드당 1-2 Codex call: review + verify)이지만 **5 축 rotation**으로 5 관점 커버.
- 병렬이 아닌 직렬 구조가 mangchi의 본질 (이전 라운드 수정 결과에 다음 축이 반응해야 의미 있음).
- 무차별 병렬 리뷰가 필요한 경우엔 `/review-all`(4-agent 병렬) 또는 `/gsd-code-review` 사용.

## 안전 장치 요약

- **원본 불변 기본** (`--apply=original` 없으면 절대 수정 안 함)
- **R5 hard cap** (토큰/시간 무한 소비 방지)
- **축 로테이션 강제** (진자 운동 방지)
- **Codex "통과" 허용** (억지 비판 회피)
- **Verification loop** (Claude의 REJECT를 Codex가 재검증, REJECT-all 게이밍 차단)
- **ACCEPT git-diff 검증** (no-op ACCEPT 차단)
- **Pass-based 종결의 최소 축 커버리지** (correctness + security 최소 1회 실행 필수)
- **Token 예산** (per-round 80K, cumulative 150K 경고 / 500K abort)
- **Shell injection 방어** (Codex 호출은 tempfile + stdin, argv 금지)
- **Schema 검증 + 1회 재시도** (Codex 출력 깨져도 안전 종료)
- **Fallback 투명 태깅** (Codex 실패 / self-review / `--no-verify` 모두 state.json에 기록)

## 드라이런 권장

처음 쓸 때는 작고 독립적인 파일로 시작:
- `src/utils/*.py` 중 한 개 (외부 의존 적은 유틸)
- 100-300줄 규모
- 테스트 있는 파일 (변경 검증 가능)

대형 파일(1000줄+)에 바로 돌리면 Codex 응답 지연 + 프롬프트 한도 문제 가능. Pre-flight 가드가 2000 LoC에서 abort.

## Schema 버전

현재 스키마: `schema_version: 1` (state.json / Codex YAML 포맷). 2025-04 이전 세션은 legacy schema (`verdict: BLOCK`, 소문자 severity). `--continue` 시 구 schema 감지하면 `[WARN]` 로그.
