# 망치 (Mangchi) — 반복 코드 다듬기

**Language**: [English](README.md) · **한국어**

> 기존 코드 파일 하나를 cross-model 반복 리뷰로 망치질합니다. Claude가 수정·판단하고 Codex CLI가 축별(correctness / security / readability / performance / design)로 비판. 수렴하거나 cap에 도달할 때까지 반복.

---

## 이런 분을 위한 도구입니다

- 이미 동작하는 코드의 품질을 출시/PR 전에 끌어올리고 싶은 분
- 프롬프트 주입·보안 방어 코드를 2차 검토 받고 싶은 분
- Claude Max 구독 등으로 Claude 토큰은 여유 있는데, 외부 모델의 adversarial 리뷰가 필요한 분
- 단일 파일의 correctness / security / readability / performance / design을 한 번에 훑고 싶은 분
- 코드 리뷰 PR에 "왜 이렇게 바꿨나"의 근거 문서를 자동으로 남기고 싶은 분

## 이런 작업엔 쓰지 마세요

- **Greenfield 구현 (처음부터 만들기)** — mangchi는 기존 코드를 다듬는 도구. 코드 생성은 별도 도구가 적합
- **문서/마크다운 리뷰** — mangchi는 실행 가능한 코드 대상. 문서는 [triad](https://github.com/minwoo-data/triad) 같은 숙의형 도구 권장
- **다중 파일 교차 리팩토링** — mangchi는 단일 파일 전용
- **80줄 이하 유틸리티** — 오버헤드가 signal 대비 큼
- **테스트 작성만** — Claude가 직접 쓰거나 코드 생성 도구가 적합

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

**핵심 불변식**: Claude만 파일을 수정하고, Codex는 비판만 한다. 이 분리가 mangchi의 전부.

## 관련 도구 (생태계 위치)

Mangchi는 다른 Claude Code 도구들과 자연스럽게 조합됨:

| 단계 | 도구 | 역할 |
|---|---|---|
| 결정 | 숙의형 도구 (예: [triad](https://github.com/minwoo-data/triad)) | 다관점 설계 리뷰 |
| 구현 | 코드 생성 플러그인 (예: [pumasi](https://github.com/fivetaku/pumasi)) | 병렬 greenfield 구현 |
| **다듬기** | **mangchi (이 도구)** | **단일 파일 반복 cross-model 리뷰** |
| 검증 | 기존 리뷰/테스트 러너 | merge 전 최종 게이트 |

Mangchi가 타깃하는 지점은 **"코드는 있는데 더 견고해져야 한다"는 구체적 공백**. Claude Max 구독 등으로 Claude 토큰 여유가 있으면 경제적으로 잘 맞음.

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

## 연구 근거 (Research backing)

Cross-model 코드 리뷰는 학술적으로 뒷받침됨. LLM은 **자기가 만든 출력을 리뷰할 때 구조적으로 실패**함 — Tsui et al. (2025)은 14개 오픈소스 모델에서 64.5%의 self-correction blind spot을 문서화([arXiv:2507.02778](https://arxiv.org/abs/2507.02778), NeurIPS 2025 LLM Evaluation Workshop). Gong et al. (2024)는 동일한 패턴이 **코드 보안**에서 특히 심하다는 것을 확인 — 모델은 자기 코드의 보안 결함을 수리하는 성공률이 다른 모델의 코드를 수리할 때보다 현저히 낮음 ([arXiv:2408.10495](https://arxiv.org/abs/2408.10495)). Semgrep (2025)은 이 이론적 예측이 실전에서 확인됨을 보임 — Claude와 Codex는 11개 실제 Python 웹 앱에서 **서로 다른 취약점 클래스**를 잡았고, 발견 내용이 중복이 아닌 상보적이었음 ([Semgrep blog](https://semgrep.dev/blog/2025/finding-vulnerabilities-in-modern-web-apps-using-claude-code-and-openai-codex)).

Mangchi는 이 발견들을 단일 워크플로우로 구현: Claude가 편집, Codex가 리뷰, 축 로테이션, 라운드 누적, 라운드별 감사 기록.

전체 인용과 각 출처가 **주장하지 않는 것** 목록은 [`skills/mangchi/RESEARCH.md`](skills/mangchi/RESEARCH.md) 참조.

---

## 실전 검증 근거

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
- [Claude Code](https://docs.claude.com/en/docs/claude-code) + [OpenAI Codex CLI](https://github.com/openai/codex) 위에 구축
- [Pumasi](https://github.com/fivetaku/pumasi)에서 영감 — Claude-as-supervisor / Codex-as-worker 패턴을 Claude Code 플러그인에 처음 도입한 도구
