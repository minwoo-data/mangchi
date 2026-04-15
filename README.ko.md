# 망치 (Mangchi) — 반복 코드 다듬기

**Language**: [English](README.md) · **한국어**

> Claude가 코드를 수정하고 Codex CLI가 비판하며, 회전하는 리뷰 축(correctness / security / readability / performance / design)으로 코드를 반복 망치질합니다. Pumasi의 철학적 반전.

---

## 이런 분을 위한 도구입니다

- 이미 동작하는 코드의 품질을 출시/PR 전에 끌어올리고 싶은 분
- 프롬프트 주입·보안 방어 코드를 2차 검토 받고 싶은 분
- Claude Max 구독 등으로 Claude 토큰은 여유 있는데, 외부 모델의 adversarial 리뷰가 필요한 분
- 단일 파일의 correctness / security / readability / performance / design을 한 번에 훑고 싶은 분
- 코드 리뷰 PR에 "왜 이렇게 바꿨나"의 근거 문서를 자동으로 남기고 싶은 분

## 이런 작업엔 쓰지 마세요

- **Greenfield 구현** → [pumasi](https://github.com/fivetaku/pumasi) 추천 (Codex가 시그니처+게이트 기반으로 구현)
- **문서/마크다운 리뷰** → 3-관점 숙의 도구(예: triad) 추천
- **다중 파일 교차 리팩토링** — mangchi는 단일 파일 전용
- **80줄 이하 유틸리티** — 오버헤드가 signal 대비 큼
- **테스트 작성만** — Claude가 직접 쓰거나 pumasi가 적합

---

## 어떻게 작동하나요

```
┌─ Claude ──────────────────────────┐
│  ✅ 코드 수정 (Edit tool)          │
│  ✅ 판단 (ACCEPT / REJECT / DEFER) │
│  ✅ 전체 오케스트레이션            │
│  ❌ 리뷰는 안 함 (Codex에게 위임)  │
└───────────────────────────────────┘
           ↕ (라운드별 직렬 대화)
┌─ Codex CLI ───────────────────────┐
│  ✅ 한 축에 집중한 리뷰            │
│  ✅ YAML 포맷으로 지적만 출력      │
│  ❌ 코드 수정 절대 안 함           │
│  ❌ 새 파일 만들지 않음            │
└───────────────────────────────────┘
```

**Pumasi와 정확히 반대**:

| | Pumasi | Mangchi |
|---|---|---|
| Claude 역할 | PM / 감독 | 코더 + 판단자 |
| Codex 역할 | **코더 × N (병렬)** | **비판자 (직렬, 라운드당)** |
| 불변식 | "Claude는 코드 안 짠다" | **"Codex는 코드 안 짠다"** |
| 토큰 | Codex 많이, Claude 적게 | **Claude 많이, Codex 적게** |
| 최적 용도 | Greenfield 대량 구현 | 기존 코드 품질 개선 |

Claude 토큰이 Codex보다 여유 있다면(예: Claude Max $200), mangchi가 경제적으로 더 맞습니다. 반대 상황이라면 pumasi가 낫습니다. **두 도구는 조합 가능** — `triad(설계) → pumasi(구현) → mangchi(다듬기)`.

---

## 5개 리뷰 축

각 라운드는 **정확히 하나의 축**만 사용. **인접한 두 라운드는 같은 축을 반복할 수 없음**(로테이션 강제).

| 축 | 던지는 질문 |
|---|---|
| `correctness` | 모든 입력 형태에서 올바르게 동작하는가? |
| `security` | 어떤 공격 표면을 노출하는가? |
| `readability` | 6개월 뒤에도 기여자가 이해하고 변경할 수 있는가? |
| `performance` | I/O, 메모리, CPU를 어디서 낭비하는가? |
| `design` | 1년 뒤에도 유지 가능한 설계인가? |

---

## 종결 조건

아래 중 **하나라도** 충족되면 종결:

1. **2 라운드 연속 PASS + no-changes** — Codex가 2연속 "더 고칠 것 없음" 선언
2. **Diff 수렴** — 이번 라운드 변경 LoC가 직전 라운드의 **30% 이하**
3. **5 라운드 hard cap** — 오실레이션·토큰 드레인 방지
4. **사용자 `/stop`**

---

## 안전 기본값

- 원본 파일은 **절대로 자동 수정되지 않음** (명시적 `--apply=original` 없으면)
- 기본 모드: `docs/refinement/<slug>/updated.py`에만 작성, 사용자가 수동으로 원본 교체 결정
- 각 라운드의 Codex 프롬프트+응답이 감사 기록으로 보존됨
- Codex CLI 실패/타임아웃 시 메인 에이전트가 동일 축 프롬프트로 local-pass 대체, 라운드 문서에 `[fallback: main-local-pass]` 명시

---

## 설치

### 전제 조건

```bash
# Codex CLI (리뷰어)
npm install -g @openai/codex
codex login    # 또는 OPENAI_API_KEY 환경변수 설정

# Claude Code (오케스트레이터)
# https://docs.claude.com/en/docs/claude-code
```

### 플러그인 설치

```bash
# 마켓플레이스 (출시 후)
/plugin marketplace add https://github.com/minwoo-data/mangchi
/plugin install mangchi

# 또는 수동: repo를 clone하고 Claude Code의 skills 경로로 복사
git clone https://github.com/minwoo-data/mangchi ~/.claude/skills/mangchi-src
cp -r ~/.claude/skills/mangchi-src/skills/mangchi ~/.claude/skills/
```

설치 후 Claude Code **재시작** 필수.

---

## 사용법

```
/mangchi src/services/auth.py                         # 기본 모드 — updated.py만, 원본 불변
/mangchi src/services/auth.py --apply=original        # 원본 파일도 Edit
/mangchi src/utils/hash.py --axes=correctness,security  # 특정 축만 순환
/mangchi --continue auth-py                           # 진행 중 세션 이어하기
/mangchi --stop auth-py                               # 현 시점까지 결과로 강제 종결
```

자연어 트리거: *"망치로 다듬어줘"*, *"codex로 반복 리뷰해줘"* 도 동작.

자세한 예시는 [`skills/mangchi/references/usage.md`](skills/mangchi/references/usage.md) 참조.

---

## 검증 근거

실제 프로젝트에서 잡은 버그 사례는 [`skills/mangchi/CASE-STUDIES.md`](skills/mangchi/CASE-STUDIES.md)에 기록되어 있습니다.

**첫 번째 사례 요약** (Python Flask OCR 파이프라인, 9개 파일):
- 23개의 실제 버그 landed (prompt injection 2건, 유럽 통화 파싱 붕괴, 날짜 포맷 거부, 서킷 브레이커 영구 wedge 등)
- Accept rate: **79%** (High severity 기준 ~90%)
- Codex 토큰 소비: ~63k
- Wall-clock: ~90분

파일엔 **못 잡은 것**(prompt content 품질, cross-file 구조, 성능 프로파일링 등)과 **놀란 점**, **재현 방법**도 함께 기록되어 있습니다.

---

## 라이선스

MIT — [`LICENSE`](LICENSE) 참조.

## 크레딧

- Created by: Minwoo Park
- [Pumasi](https://github.com/fivetaku/pumasi)(철학적 반전의 원본)에서 영감
- [Claude Code](https://docs.claude.com/en/docs/claude-code) + [OpenAI Codex CLI](https://github.com/openai/codex) 위에 구축
