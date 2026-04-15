---
name: mangchi
description: Iterative code refinement — Claude writes/patches, Codex CLI reviews as adversarial critic with rotating axes (correctness/security/readability/performance/design). Hard cap 5 rounds; auto-stops on diff convergence (≤30% LoC change) or 2 consecutive "no-change" reviews. Works on updated.* copy; original untouched unless --apply=original. Triggers on "/mangchi <file>", "망치로 다듬어", "codex로 반복 리뷰".
---

# Mangchi — Iterative Code Refinement (망치)

> Mangchi는 **단일 코드 파일**을 Codex의 비판과 Claude의 수정 사이에서 **반복 망치질**해 품질을 높인다.
> Claude = 코더 + 판단자. Codex CLI = 적대적 비판자. pumasi의 역할 반전 버전.

## 철학 — Pumasi와 정확히 반대

| | pumasi | **mangchi** |
|---|---|---|
| 주연 | Codex (구현) | **Claude (구현 + 수정)** |
| 조연 | Claude (설계/감독) | **Codex (비판/리뷰만)** |
| 불변식 | "Claude는 코드 안 짠다" | **"Codex는 코드 안 짠다"** |
| 토큰 | Codex 많이, Claude 적게 | **Claude 많이, Codex 적게** |
| 작업 흐름 | 병렬 구현 → 게이트 | **직렬 라운드, 축 로테이션** |

이 반전은 사용자의 Claude Max $200 경제(Claude 토큰 풍부, Codex 토큰 희소)에 맞춰 설계됨.

## 핵심 불변식

1. **Codex는 읽고 지적만 한다**. 코드를 쓰지 않는다. 새 파일도 만들지 않는다.
2. **Claude만 파일을 수정한다**. Codex 의견을 받아 판단하고 Edit/Write로 반영.
3. **원본은 건드리지 않는다**. 기본 동작은 `updated.*` 복사본에 쓴다. `--apply=original` 명시한 경우만 원본 교체.
4. **5 라운드 hard cap**. 오실레이션/드리프트 방지.
5. **같은 축 2연속 금지**. 라운드 N의 축은 라운드 N-1의 축과 달라야 함.

## 트리거

- `/mangchi <file>` — read/write updated.*만, 원본 불변
- `/mangchi <file> --apply=original` — 원본 파일도 Edit 반영 (가장 공격적)
- `/mangchi <file> --axes=correctness,security` — 특정 축만 순환 (기본은 5개 전체)
- `/mangchi --continue <slug>` — 기존 세션 이어가기
- `/mangchi --stop <slug>` — 강제 종결
- 자연어: "망치로 다듬어줘", "codex로 반복 리뷰해줘"

## 5개 리뷰 축 (axes)

자세한 프롬프트는 `axes.md` 참조.

| 축 | 질문 |
|---|---|
| **correctness** | 버그, 엣지 케이스, 계약 위반 있는가? |
| **security** | 인젝션/인증 우회/누출/레이스 조건 있는가? |
| **readability** | 명명/구조/주석이 미래 독자에게 친절한가? |
| **performance** | 불필요한 I/O, N+1, 비효율 자료구조 있는가? |
| **design** | SRP/결합도/의존 방향/테스트 용이성 있는가? |

## 7단계 워크플로우 (라운드 N)

### Phase 0: 초기화 (R1에만)
- 입력 파일 존재 확인
- 슬러그 계산, `docs/refinement/<slug>/` 생성
- 원본을 `updated.<ext>`로 복사 (이후 모든 수정은 updated에만)
- `source.md` 또는 `source-snapshot.<ext>`로 스냅샷
- `state.json` 생성: `{round: 1, status: "open", axes_used: [], diff_history: []}`

### Phase 1: 축 선택 (메인)
메인 에이전트가 이번 라운드의 축 선택. 규칙:
- R1: `correctness` 기본 (옵션으로 --axes로 지정 시 첫 번째)
- R2+: 직전 라운드 축과 **반드시 다른** 축. 이전까지의 지적에서 신호 강한 축 선택.
- 같은 축 2연속 시도 → **거부**, 다른 축 선택 강제.

### Phase 2: Codex 호출 (메인 → Bash)
```bash
codex exec --dangerously-bypass-approvals-and-sandbox "<prompt>" > response.txt
```
프롬프트 구성:
- 해당 축의 full prompt (`axes.md`에서 해당 섹션)
- `updated.<ext>` 전체 내용 (축약 금지 — triad 드라이런 교훈)
- 지난 라운드 decisions 요약 (round ≥ 2)
- 출력 포맷 계약 (YAML)

Codex가 사용 불가 시 (exit code ≠ 0, 또는 CLI 없음):
- `state.json`에 `fallback: true` 기록
- 메인이 해당 축 프롬프트로 **스스로 리뷰 수행** (self-review)
- round-N.md에 `[fallback: main-self-review]` 태그 명시

### Phase 3: 응답 파싱 (메인)
Codex 응답 YAML 파싱:
```yaml
verdict: PASS | REVISE | BLOCK
issues:
  - severity: high | med | low
    locus: "file:line"
    problem: "..."
    proposed_fix: "..."
no_changes_suggested: true | false
```
`verdict: PASS` + `no_changes_suggested: true`는 **이 축에서 통과**를 의미. 억지 비판 없이 허용.

### Phase 4: Claude 판단 (메인)
각 issue별로 ACCEPT / REJECT / DEFER 판정. 근거 한 줄 필수. REJECT는 "Codex가 맥락을 몰라서 잘못 본 경우"가 전형 — 근거 명확해야 함.

### Phase 5: 수정 적용 (메인 → Edit)
ACCEPT된 이슈를 `updated.<ext>`에 Edit으로 반영. diff 크기 측정 (변경된 LoC).

`--apply=original` 지정된 경우 이 시점에 원본도 함께 Edit.

### Phase 6: 수렴 판정 (메인)
**종결 조건 OR** (하나만 만족하면 종결):
1. 2 라운드 연속 `verdict: PASS` + `no_changes_suggested: true`
2. 이번 라운드 diff 크기가 직전 라운드의 **30% 이하** (수렴)
3. 라운드 5 도달 (hard cap)
4. 사용자 `/mangchi --stop`

종결 시 `CONVERGED.md` 작성 (템플릿: `templates/converged.md`).

### Phase 7: 다음 라운드 or 종료
- 종결 → `state.json.status = "closed"`, 완료 메시지
- 미종결 → round N+1 진입, 축 선택(Phase 1)으로

## 축 로테이션 규칙

- 같은 축 2연속 리뷰 **금지**.
- 직전 라운드에서 모든 issue를 REJECT한 경우: 다음 라운드도 같은 축 재리뷰 **금지** (그 축은 이미 무의미하다고 판정된 것).
- 5 축 모두 한 번씩 사용했으면 다음은 "가장 issue 많이 나온 축"에서 재리뷰 허용 (rotation wrap).

## 수렴 감지 (diff convergence)

매 라운드 말미에 계산:
```
diff_size_N = (inserted_lines + deleted_lines)
convergence_ratio = diff_size_N / max(diff_size_{N-1}, 1)
```
ratio ≤ 0.30 → 수렴 종결.

R1은 비교 기준 없으므로 skip. R2부터 측정.

## 파일 구조

```
docs/refinement/
└── <slug>/
    ├── source-snapshot.<ext>        # 원본 스냅샷 (불변)
    ├── updated.<ext>                # Claude가 수정하는 작업본
    ├── state.json                   # round, axes_used, diff_history
    ├── round-1.md                   # axis + Codex output + decisions + diff
    ├── round-2.md
    ├── ...
    └── CONVERGED.md                 # 최종 리포트
```

슬러그 규칙: triad와 동일 (파일명 확장자 제거 + 특수문자 `-` 치환).
예: `src/routes/auth.py` → `auth-py`

## Codex CLI 인보크

### 기본 호출
```bash
codex exec --dangerously-bypass-approvals-and-sandbox "<prompt>"
```

### 모델 지정 (선택)
```bash
codex exec -m gpt-4o-mini --dangerously-bypass-approvals-and-sandbox "<prompt>"
```
(실제 flag는 `codex exec --help`로 확인)

### 설치 확인
```bash
command -v codex || echo "codex CLI missing; install with: npm install -g @openai/codex"
```

Codex 인증은 CLI 자체가 처리 (`codex login` 또는 `OPENAI_API_KEY` 환경변수). mangchi는 이를 건드리지 않음.

## 안티패턴

- ❌ Claude가 Codex에게 "이 코드 써줘" 요청 — Codex는 리뷰만 한다. 코드를 쓰면 mangchi 불변식 위반.
- ❌ 같은 축 2연속 실행 — 로테이션 규칙 위반, 진자 운동 발생.
- ❌ 5 라운드 초과 — hard cap 위반.
- ❌ 원본 파일을 `--apply=original` 없이 수정 — 정책 위반.
- ❌ Codex가 "비판 없음"을 냈는데 메인이 억지로 "뭐라도 고쳐야 한다"로 계속 진행 — 수렴 종결 신호 무시.
- ❌ Codex 프롬프트에서 대상 코드 축약 (`[...middle section...]`) — 리뷰 fidelity 훼손 (triad 드라이런 교훈).
- ❌ 라운드당 축 2개 이상 리뷰 — 한 라운드 = 한 축 원칙.

## pumasi / triad와의 관계

| | triad | pumasi | **mangchi** |
|---|---|---|---|
| 대상 | md/코드 (리뷰만) | 스펙 (구현) | **코드 (반복 다듬기)** |
| 워커 | Claude 서브에이전트 × 3 | Codex × N 병렬 | **Codex 직렬 × 1/라운드** |
| 병렬 vs 직렬 | 관점 병렬 | 태스크 병렬 | **라운드 직렬 (로테이션)** |
| 코드 수정 | 없음 | 새 파일 생성 | **기존 파일 수정** |
| 종결 | 3-PASS 합의 | 게이트 PASS | **수렴/2-PASS/cap** |

**파이프라인 조합 예시**:
```
triad (설계 결정)  →  pumasi (초기 구현)  →  mangchi (품질 망치질)  →  commit
```

## Skill 자체 제한

- **Codex CLI 필수**. 없으면 fallback(self-review)로 돌아가지만 mangchi 본래 가치의 상당 부분 상실.
- **단일 파일만**. 다중 파일 동시 refinement은 설계 범위 밖 (교차 파일 일관성은 별도 skill).
- **Greenfield 부적합**. 코드가 있어야 망치질 가능. 처음부터 만들기는 pumasi.

## 참조

- Axes prompts: `axes.md` (5개 축 전체)
- Templates: `templates/round.md`, `templates/converged.md`
- Usage examples: `references/usage.md`
