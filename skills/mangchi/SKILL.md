---
name: mangchi
description: Iterative code refinement - Claude edits, Codex CLI adversarially reviews one of 5 axes per round, verifies Claude's REJECTs on a second call. Stops on 2 clean rounds / 2 PASS / R5 cap / optional --gate. Existing code file ≤2000 LoC. Requires Codex CLI; /triad for Codex-free review.
---

# Mangchi - Iterative Code Refinement (망치)

## TL;DR

- **대상**: 이미 존재하는 단일 코드 파일 (≤ 2000 LoC 권장). Greenfield → pumasi.
- **역할**: Claude = 코더 + 판정. Codex CLI = 적대적 리뷰 + Claude의 REJECT 재검증.
- **라운드**: 기본 5축 순환 (correctness/security/readability/performance/design). `necessity`·`robustness`는 opt-in (stateful 코드면 preflight가 robustness 힌트). R5 hard cap.
- **Codex 호출**: 라운드당 최대 2회 (review + verify). `--no-verify`면 1회 (adversarial 가드 포기).
- **종결**:
  ① 2 consecutive verified rounds - ACCEPT diff-검증 통과 + DISAGREE 0
  ② 2 consecutive PASS - **단 `correctness` + `security` 축이 이력에 각각 ≥ 1회 실행되어 있어야 유효**
  ③ R5 cap
  ④ `--gate "<cmd>"` 통과 (종결 직전 1회)
  ⑤ 사용자 `--stop`
  ⑥ Abort: token budget / `forced_accept_count ≥ --force-accept-threshold` (default 2) / Codex schema 재시도 실패 / per-call context window 초과
- **불변**: Codex는 읽고 비판만. Claude만 파일 수정. 원본 불변 (`updated.*` 작업본).

> 이 description은 skill catalogue에 노출. Mangchi 선택 판단의 1차 정보.

## 철학 - Pumasi와 정확히 반대

pumasi는 "Codex가 구현, Claude가 감독"; mangchi는 **"Claude가 구현+수정, Codex가 비판+검증"** - 불변식이 뒤집힌다 ("Codex는 코드 안 짠다"). 직렬 라운드 · 축 로테이션 · 라운드당 Codex ≤2콜. Claude Max 경제(Claude 토큰 풍부, Codex 토큰 희소)에 맞춘 설계. 비교표는 §"pumasi / triad와의 관계".

## 핵심 불변식

1. **Codex는 읽고 지적만 한다**. 코드 쓰지 않음, 새 파일 생성 없음.
2. **Claude만 파일을 수정한다**. Codex 의견을 받아 판단하고 Edit/Write로 반영.
3. **원본 불변**. 기본 동작은 `updated.<ext>`에만. `--apply=original` 지정 시만 원본 교체.
4. **R5 hard cap**.
5. **같은 축 2연속 금지**. 라운드 N의 축 ≠ 라운드 N-1의 축.
6. **Codex는 adversary**. Claude가 모든 REJECT를 할 수 없다 - Codex가 verify 단계에서 DISAGREE하면 다음 라운드 선행 의제로 이월, 2연속 DISAGREE → 강제 ACCEPT.
7. **Shell injection 차단**. Codex 호출은 `tempfile + stdin` 방식만 허용. 파일 내용을 `"<prompt>"` argv로 전달 금지.

## 요구사항

Bash 4+ (Windows는 Git Bash 4.4+/WSL) · Git (`git diff -w --numstat`) · Python 3.8+ + PyYAML (응답 파싱) · Codex CLI 권장 (없으면 대화형 확인 후 self-review). 전부 `scripts/preflight.sh`가 한 번에 검사한다.

## 트리거 (CLI flags)

### 자주 쓰는 플래그 (Essential - first-time users)

| 트리거 | 효과 |
|---|---|
| `/mangchi <file>` | 기본 - updated.* 작업, 원본 불변 |
| `--apply=original` | 원본 파일도 Edit 반영 (위험, PR 직전 권장) |
| `--gate "<cmd>"` | 종결 직전 외부 게이트 실행 (예: `"pytest -x"`), exit 0 필수 |
| `--continue <slug>` | 기존 세션 이어가기 (abort된 세션도 포함) |
| `--stop <slug>` | 강제 종결 |

자연어: "망치로 다듬어줘", "codex로 반복 리뷰해줘".

### 고급 플래그 (Advanced - 특정 시나리오)

<details>
<summary>클릭해서 펼치기 - 대부분은 default 그대로가 최적</summary>

| 트리거 | 효과 |
|---|---|
| `--only-axes=correctness,security` | 지정 축만 순환 (default 5축 대체). 사용 시 2-PASS 종결 조건에 correctness+security 둘 다 포함 필요. |
| `--include-axes=necessity` | default 5축 + `necessity` 추가 |
| `--start-axis=security` | R1 시작 축 (기본 `correctness`). 보안 민감 파일에 security-first 돌릴 때. |
| `--no-verify` | Phase 6 Codex verify 생략. **adversarial 가드 + FORCED_ACCEPT 동시 비활성** - mangchi의 핵심 가치 포기. 이미 외부 리뷰어 있는 빠른 체크에만. |
| `--allow-self-review` | Codex 없을 때 묻지 않고 self-review 강제 (CI 전용). 대화형 환경에선 자동으로 y/N 물어보므로 불필요. |
| `--force` | Pre-flight 2000 LoC / 200KB 가드 bypass. Codex context window는 그래도 reject할 수 있음. |
| `--force-accept-threshold=N` | FORCED_ACCEPT abort 임계값 (default **2**). `=1` 엄격 모드 (보안/암호학), `≥3` permissive (legacy 파일). |

</details>

## 5개 리뷰 축 + `necessity` / `robustness` opt-in

자세한 프롬프트는 `axes.md`. **스키마는 `axes.md` §"공통 출력 포맷"이 SSOT** (single source of truth).

| 축 | 질문 | 기본 |
|---|---|---|
| **correctness** | 버그, 엣지 케이스, 계약 위반 있는가? | ✓ |
| **security** | 인젝션/인증 우회/누출/레이스 조건 있는가? | ✓ |
| **readability** | 명명/구조/주석이 미래 독자에게 친절한가? | ✓ |
| **performance** | 불필요한 I/O, N+1, 비효율 자료구조 있는가? | ✓ |
| **design** | SRP/결합도/의존 방향/테스트 용이성 있는가? | ✓ |
| **necessity** | 이 추가가 정말 필요한가? (YAGNI·Occam) | opt-in (`--include-axes=necessity`) |
| **robustness** | 동시성·장애복구·데이터무결성·상태전이 4축에서 버티는가? | opt-in (`--include-axes=robustness`) |

`necessity`는 "제거/축약" 판단, `robustness`는 runtime 장애 시나리오 probing. 둘 다 default 제외 - `necessity`는 greenfield 성격이라, `robustness`는 순수 함수/stateless 코드에선 해당 없어 signal 0이라. **동시성/레이스는 robustness가 단일 소유자**다 (correctness는 single-threaded 계약, security는 공격자가 타이밍을 조작하는 TOCTOU만) - stateful 코드에서 레이스를 잡고 싶으면 robustness를 켜야 한다. preflight가 stateful 마커를 보면 힌트를 낸다.

둘 다 동시에 켜려면: `--include-axes=necessity,robustness`.

## 워크플로우 (라운드 N)

### Phase 0: 초기화 (R1에만)

**Consolidated preflight** - 환경·입력·크기·축 커버리지·Codex 유무·작업 디렉토리·state.json을 한 번에 처리하는 스크립트. 산문으로 재현하지 말고 실행한다:

```bash
FORCE= ONLY_AXES= INCLUDE_AXES= START_AXIS= GATE_CMD= bash "<skill dir>/scripts/preflight.sh" "<target-file>"
```

- 검사 순서: Bash 4+ / git / Python 3.8+ / PyYAML / Codex → 파일 존재 + Windows 경로 정규화 → 2000 LoC·200KB 가드(`FORCE=1` bypass) → `--only-axes` 커버리지 경고 → 보안 민감 파일명 + Codex 부재 시 즉시 거부 → **robustness 힌트** → slug·`docs/refinement/mangchi/<slug>/` 생성 + legacy 경로 경고 → `updated.<ext>`·`source-snapshot.<ext>`·`state.json` 초기화.
- 성공 시 stdout에 `SLUG= DIR= EXT= LOC= BYTES= CODEX= SECURITY_SENSITIVE= STATEFUL_HINT=`를 출력한다. 이 값을 이후 Phase에서 쓴다. exit 1이면 stderr 메시지를 그대로 사용자에게 보이고 중단.
- **robustness 힌트**: 대상 파일에 stateful 마커(`threading|asyncio|await|Lock(|transaction|commit(|rollback|INSERT|UPDATE|DELETE|session.|cursor.|fetch(|requests.|httpx|state_machine|status =`)가 있으면 `[HINT] stateful code detected — consider --include-axes=robustness`를 출력한다. **자동 활성화는 하지 않는다** - 사용자가 플래그를 명시해야 축이 켜진다. `STATEFUL_HINT=1`인데 robustness가 꺼져 있으면 Claude는 R1 시작 전에 한 줄로 되묻는다(대화형) 또는 CONVERGED.md Known Limits에 "robustness 미실행" 한 줄을 남긴다(비대화형).
- Codex 부재 시의 대화형 y/N 라우팅은 스크립트가 아니라 §"Codex 부재 시 동작"을 따른다 (스크립트는 `CODEX=0`만 보고).

### Phase 1: 축 선택 (Claude)

**Precedence** (R2+, 높은 우선순위부터):
1. **Same-axis ban**: 직전 라운드 축은 제외.
2. **Carryover DISAGREE**: state.json에 `status: PENDING` 이슈의 원래 축이 directly available하면 그 축. (단 same-axis ban 우선 - carryover 축이 직전과 같으면 다음으로 ban 해제된 축 중 신호 강한 것.)
3. **Signal heuristic**: 남은 축 중 이전까지 issues 누적이 많은 축.

**R1 규칙**: `--start-axis=<axis>`가 있으면 그 축, 없으면 `correctness`.

**추가 ban**: 모든 issue가 REJECT되고 verify가 전부 AGREE로 종결된 축은 다음 라운드에도 재리뷰 금지 (진자 운동 방지).

### Phase 2: Codex Review 호출 (shell-injection-safe)

**Pre-send guard**: 프롬프트 파일이 **완전히 조립된 뒤** `char/4*1.3 ≥ 180K`면 라운드 abort ("context window exceeded. Split the file."). 공식·누적 가드는 §"토큰 예산".

**호출 불변 (shell injection 차단)** - `CODEX="${CODEX:-codex exec --dangerously-bypass-approvals-and-sandbox}"`:
- **argv 금지** - `$CODEX "$PROMPT_TEXT"` 패턴 절대 금지. **tempfile + stdin** (`$CODEX < "$PROMPT_FILE"`)만 허용.
- **Heredoc quoted** (`<<'EOF'`)로 정적 본문 작성 - shell expansion 차단.
- **동적 내용은 전부 `cat <file> >> "$PROMPT_FILE"`** - target source, 이전 라운드 decisions digest, FORCED_ACCEPT 목록 포함. `echo "$VAR" >>`처럼 unquoted expansion 금지 (Codex가 reason 필드에 backtick/`$(...)`를 넣어올 수 있다).
- FORCED_ACCEPT 식별자는 `R{n}.{axis}#{id}` (예 `R1.correctness#2`) - round 내 id는 round 간 재사용되므로 prefix 필수.
- `--dangerously-bypass-approvals-and-sandbox`는 Codex 자체의 승인 프롬프트/샌드박스만 끈다. mangchi는 Codex를 read-only로 쓰므로 호스트에 쓰기 없음. 인증은 Codex CLI 몫 (`codex login` / `OPENAI_API_KEY`).

```bash
PROMPT_FILE="$DIR/round-${N}.prompt.txt"; CODEX_OUT="$DIR/round-${N}.codex.txt"
cat > "$PROMPT_FILE" <<'PROMPT_EOF'
# (정적 지시문: 역할, 이번 라운드 축, 출력 포맷 = axes.md §공통 출력 포맷, schema_version 1)
PROMPT_EOF
cat "<skill dir>/axes.md"            >> "$PROMPT_FILE"   # 해당 축 rubric (전체 파일 또는 해당 섹션 발췌 파일)
echo '--- BEGIN FILE ---'            >> "$PROMPT_FILE"
cat "$DIR/updated.$EXT"              >> "$PROMPT_FILE"   # 전문, 축약 금지
echo '--- END FILE ---'              >> "$PROMPT_FILE"
# R ≥ 2: 지난 라운드 ACCEPT/REJECT digest, DISAGREE 이월 의제, FORCED_ACCEPT 목록(재제기 금지) - 전부 파일에서 cat append
$CODEX < "$PROMPT_FILE" > "$CODEX_OUT"
```

### Phase 3: 응답 파싱 + 스키마 검증

`yaml.safe_load`로 파싱 후 필수 필드 검증 (스키마 SSOT: `axes.md` §"공통 출력 포맷"):
`axis ∈ VALID_AXES` · `verdict ∈ {PASS, REVISE}` · REVISE면 `issues` 비어있지 않은 list · 각 issue에 `id`(int) · `severity ∈ {HIGH, MEDIUM, LOW}` · `locus`에 `:` 포함(`file:LINE`) · `problem` · `proposed_fix` · `confidence`.

실패 시: Attempt 1은 "이전 응답 schema 위반: {error}. Re-emit complete YAML matching schema."로 **1회** 재전송. Attempt 2도 실패면 `[ERROR] Codex output invalid after retry` + abort (`state.json.last_invalid_codex_output`에 raw 저장).

### Phase 4: Claude 판단 (ACCEPT/REJECT)

각 issue별 판정. **schema v1 decision values**: `ACCEPT` | `REJECT`. (legacy `DEFER` 폐지.)

**REJECT citation 강제 (hard validation)**:
- 사유에 `file:LINE` 형식 code_ref 또는 test name 인용 **필수**.
- 없으면 Claude가 **즉시 에러 처리** - REJECT 판정 무효로 돌리고 다시 judgment 요청 (silent ACCEPT flip 금지). 이는 Claude가 "그냥 REJECT하고 싶을 때 근거 생략"하는 경로를 봉쇄.
- round-N.md에 `decision | reason (citation 포함)` 컬럼으로 기록.

### Phase 5: 수정 적용 + ACCEPT diff 검증

ACCEPT된 이슈를 `updated.<ext>`에 Edit로 반영.

**Diff 측정**:
```bash
git diff -w --numstat "$DIR/updated.$EXT"   # whitespace 무시
```

**ACCEPT git-diff 검증**:
- 각 ACCEPT 이슈의 `locus` 영역 **±5줄** (fuzz factor - 편집이 locus 경계 바로 밖에서 일어난 경우 포착)이 실제 diff에 touched인지 체크.
- `-w` (whitespace 무시) 기반이므로 whitespace-only 편집은 "no-op"로 간주 (그 편집은 의미 없는 변경).
- 변경 없으면 **no-op ACCEPT**로 기록, 다음 라운드 의제 유지 (`state.json.issues[].status: PENDING`).
- no-op ACCEPT는 **Phase 7 "2 verified rounds" 수렴 카운트에서 제외**.

> **±5 근거**: 실측이 아닌 heuristic. locus는 Codex가 지적 시 본 line이지만, Claude의 실제 수정이 그 함수 머리(±5)에서 일어나는 경우 흔함. 너무 크게 잡으면 false-negative (전혀 다른 영역 변경도 통과), 너무 작으면 false-positive (legitimate 수정 놓침). 5줄은 mangchi 개발 중 실 사용에서 조정된 값.
> **False-positive 경로**: 리팩터링으로 ±5 밖에 실제 수정이 일어난 경우 no-op ACCEPT로 잘못 기록. 사용자가 CONVERGED.md §6 확인 시 수동 arbitration 가능.
> **False-negative 경로**: whitespace-only 편집은 `-w` 때문에 자동 탐지 (의미 없는 변경이 통과하지 않음).

`--apply=original` 지정 시 이 시점에 원본도 함께 Edit.

### Phase 6: Codex 재검증 (verification loop)

**Skip 조건** (하나라도): REJECT 0개 · `--no-verify` · self-review 모드 (이 경우 FORCED_ACCEPT도 비활성).

**호출**: Phase 2와 같은 tempfile+stdin 패턴 (`round-${N}.verify.prompt.txt` → `round-${N}.verify.txt`). 프롬프트에는 **REJECT 이슈만** + 각 locus의 **post-edit `updated.<ext>` ±10줄** context (ACCEPT 적용 후 줄 번호가 밀리므로 pre-edit 금지; 파일 경계는 `max(0,start-10)`~`min(len,end+10)`로 clamp). Codex는 이슈별 `AGREE`(종결) / `DISAGREE`(유지 - post-edit 코드 `file:line` 인용 필수)로 답한다 (포맷: `axes.md` §"Verify 호출 전용 포맷").

**처리**:
- `AGREE` → `issues[].status: RESOLVED`. `DISAGREE` → `PENDING` + `history[].verification.verdict: DISAGREE`, 다음 라운드 선행 의제.
- 같은 issue가 **2라운드 연속 DISAGREE** → 시스템이 `FORCED_ACCEPT`로 승격 (Claude 선택 아님), `forced_accept_count += 1`.
- `forced_accept_count ≥ --force-accept-threshold` (default **2**) → abort + 구조화 리포트 (`[ABORT] forced_accept_count reached N. Disputes: R{n}.{axis}#{id} | locus | Claude: ... | Codex: ... ` + "Review state.json and resume with /mangchi --continue <slug>"). threshold=1은 strict(보안/회계/암호학 권장), ≥3은 permissive(legacy 파일). abort된 세션은 수동 arbitration 후 `--continue` 가능.
- **대칭 가드**: AGREE가 붙은 ACCEPT라도 `diff_verified: false`면 "2 verified rounds" 카운트에서 제외 - 실제 수정 없는 ACCEPT는 수렴 신호가 아니다.

### Phase 7: 종결 판정

**Stop 조건 평가 순서 (OR - 하나만 만족하면 종결)**:

1. **2 consecutive verified rounds**:
   - 연속 2라운드 모두 ACCEPT 전부 `diff_verified: true` AND DISAGREE 0.
   - no-op ACCEPT 있으면 이 카운트 리셋.

2. **2 consecutive PASS** (gaming-guarded):
   - 연속 2라운드 `verdict: PASS` AND `no_changes_suggested: true`.
   - **AND** `correctness`와 `security` 축이 **이력에 각각 ≥ 1회 실행**되어 있어야 유효.
   - 실행 안 됐으면 이 사유 비활성 (R5 cap까지 감).

3. **R5 hard cap**.

4. **`--gate "<cmd>"`** (옵션):
   - 종결 직전 (1, 2, 3번 조건이 충족된 시점)에 1회 실행.
   - exit 0이면 CONVERGED, 비0이면 다음 라운드 계속 (cap 도달 시 `aborted_gate_failed`).

5. **`--stop`** (manual).

6. **Abort trigger**:
   - Cumulative Codex 토큰 ≥ 500K.
   - `forced_accept_count ≥ force_accept_threshold` (default 2).
   - Codex schema 재시도 실패.
   - Per-call context window 180K 초과 (hard limit - 모델 제약).
   - `--only-axes`가 correctness+security 둘 다 빠진 상태에서 R5 cap 도달하고 `--gate`도 없으면 `aborted_no_termination_path` (Phase 0 경고와 symmetrical).

### Soft coverage floor (R4→R5)

R4 종료 시점에 `correctness` 또는 `security` 축이 **한 번도 실행되지 않았으면**, R5는 그 누락 축으로 자동 배정 (signal heuristic 무시). `--only-axes`에 의해 해당 축이 아예 제외됐으면 적용 불가 (Phase 0 경고로 알림).

목적: "쉬운 축만 돌리고 끝나는" 게이밍 마지막 방지선. R4까지 correctness/security 안 돌렸다 = 거의 확실히 게이밍 중.

종결 시 `CONVERGED.md` 작성 (템플릿 `templates/converged.md`).

### Phase 8: INDEX.md rewrite

매 라운드 종료 시 `INDEX.md` 요약표를 통째로 재작성한다 (abort 경로에서도). 템플릿: `templates/index.md` (Round / Axis / Verdict / ACCEPT / Verify 표 + Status 줄).

### Phase 9: 다음 라운드 or 종료

- 종결 → `state.json.status = "converged" | "aborted"`, `CONVERGED.md` 작성, 완료 메시지.
- 미종결 → round N+1 진입, Phase 1으로.

## Codex 부재 시 동작

**Hard refuse on security-sensitive filenames** (any mode - 심지어 `--allow-self-review`도 거부):
- 파일명 매칭 regex: `.*(auth|security|crypto|password|token|secret|sanitiz|permission|acl).*`
- 매칭 시 즉시 abort + `[ERROR] Self-review mode is refused on security-sensitive files. Install Codex or use /triad.`
- 이유: mangchi의 adversarial 가드가 가장 중요한 파일 유형. self-review로 돌리면 false confidence 유발.

**대화형 환경 (TTY, security-sensitive 아님)**:
```
[WARN] Codex CLI not found.

mangchi is designed as multi-model adversarial review -
Claude writes, Codex critiques. Self-review defeats the design.

Strongly recommended:
  1. Install Codex: npm i -g @openai/codex
  2. Or use /triad <file> (Claude-only, three-lens review)

Do you really want to run Claude-only self-review? [y/N]:
```

- `y` → self-review 진행:
  - `state.json.self_review_mode: true`
  - **Phase 6 verify skip** (adversary 없음)
  - **FORCED_ACCEPT 메커니즘 비활성** (검증 없으니 이월 근거 없음)
  - frontmatter 경고 로그
- `N` 또는 Enter → abort.

**비대화형 환경** (CI, pipe, stdin 닫힘): 자동 abort.

**`--allow-self-review` 플래그**: 묻지 않고 self-review (automation escape hatch). 단 **security-sensitive 파일은 그래도 거부**.

> Self-review 모드 = mangchi가 사실상 linter 수준으로 degrade. CONVERGED.md §"Known Limits"에 명시됨.

## `--no-verify` 주의사항

`--no-verify`는 Phase 6 전체를 생략. 결과:
- Codex 호출 평균 절반 절감.
- Claude의 REJECT를 Codex가 재검증하는 adversarial 가드 **제거**.
- DISAGREE 이월 + FORCED_ACCEPT 메커니즘 **동시 비활성**.
- "2 verified rounds" 종결 조건은 여전히 유효 (ACCEPT diff-검증은 Phase 5에 남음) - 단 DISAGREE 검증이 없으므로 조건 달성이 쉬워짐.

**frontmatter description + 안전 장치 목록에 명시**. 보안/복잡 로직엔 비권장.

## 파일 구조

```
docs/refinement/mangchi/
└── <slug>/
    ├── source-snapshot.<ext>        # 원본 스냅샷 (불변)
    ├── updated.<ext>                # Claude가 수정하는 작업본
    ├── state.json                   # 아래 스키마
    ├── INDEX.md                     # 라운드 요약표 (매 라운드 rewrite)
    ├── round-1.md                   # axis + decisions + diff (템플릿: round.md)
    ├── round-1.prompt.txt           # Codex review 프롬프트 (shell-safe tempfile)
    ├── round-1.codex.txt            # Codex review raw 응답
    ├── round-1.verify.prompt.txt    # Codex verify 프롬프트 (있는 경우)
    ├── round-1.verify.txt           # Codex verify raw 응답 (있는 경우)
    ├── round-2.md
    ├── ...
    └── CONVERGED.md                 # 최종 리포트 (템플릿: converged.md)
```

## state.json

스키마는 `references/state-schema.md`가 SSOT (schema_version 1). `scripts/preflight.sh`가 초기화하고, 매 라운드 `rounds[]`·`issues[].history[]`에 append. 핵심 필드: `issues[].status` (RESOLVED | PENDING | FORCED_ACCEPT), `issues[].history[].diff_verified`, `forced_accept_count` / `force_accept_threshold`, `codex_tokens_total`, `status` (active | converged | aborted), `termination_reason`.

## 슬러그 규칙

`scripts/preflight.sh`의 `compute_slug`가 정본: `/`·공백·특수문자 → `-`, 확장자는 유지(`.`도 `-`), 숫자/dot으로 시작하면 `_` 접두, 빈 결과면 `unnamed-<timestamp>`. 예: `src/routes/auth.py` → `src-routes-auth-py`, `.bashrc` → `_bashrc`, `a/b/c d.ts` → `a-b-c-d-ts`.

## 토큰 예산

- **Per-round pre-send estimate** (단일 cap, 180K):
  - 측정 시점: `$PROMPT_FILE` 이 **완전히 assemble된 후 (stdin redirect 직전)**. 축 rubric + updated.<ext> + 이전 라운드 digest + FORCED_ACCEPT 목록 전부 포함된 최종 상태 기준.
  - 공식: `char_count(PROMPT_FILE) / 4 * 1.3`.
    - `/4`: 영문 평균 토큰당 ~4 char (OpenAI tokenizer 휴리스틱).
    - `*1.3`: safety factor - 코드는 punctuation density 높아 실 토큰이 heuristic보다 많음. 경험적 보수값 (정확한 숫자 원하면 tiktoken 사용).
  - ≥ **180K**: per-call context-window 초과 → **강제 abort** (모델 제약). 파일 분할 필요.
- **Cumulative (state.json)**:
  - ≥ **150K**: `[WARN]` 로그.
  - ≥ **500K**: abort + 구조화 리포트 (남은 의제 + 선택지 제시).
- **Codex CLI가 usage 정보 미반환 시**: 추정치로 누적 근사 + `[WARN] Token tracking approximate` + `codex_tokens.estimate_only: true`.

## 안티패턴

- ❌ Claude가 Codex에게 "이 코드 써줘" 요청 - Codex는 리뷰만.
- ❌ 같은 축 2연속 실행 - 진자 운동.
- ❌ R5 초과.
- ❌ 원본 파일을 `--apply=original` 없이 수정.
- ❌ Codex "비판 없음"을 메인이 무시하고 "뭐라도 고쳐야 한다"로 강제 진행.
- ❌ Codex 프롬프트에서 대상 코드 축약.
- ❌ 라운드당 축 2개 이상 리뷰.
- ❌ **REJECT-all 강제 수렴** - verification loop이 자동 차단하나 의도 자체를 배제.
- ❌ **No-op ACCEPT** - ACCEPT 처리만 하고 실제 수정 안 함 (git-diff 검증이 탐지).
- ❌ **Citation 없는 REJECT** - hard error로 처리, silent ACCEPT flip 금지.
- ❌ **`$CODEX "$PROMPT"` argv 패턴** - shell injection 벡터.
- ❌ **`--no-verify` + 보안 코드** - adversarial 가드 없이 보안 리뷰 = 효과 없음.

## pumasi / triad와의 관계

| | triad | pumasi | **mangchi** |
|---|---|---|---|
| 대상 | md/코드 (리뷰만) | 스펙 (구현) | **코드 (반복 다듬기)** |
| 워커 | Claude 서브에이전트 × 3 | Codex × N 병렬 | **Codex 직렬 × 최대 2/라운드 (review + verify)¹** |
| 병렬 vs 직렬 | 관점 병렬 | 태스크 병렬 | **라운드 직렬 (로테이션)** |
| 코드 수정 | 없음 | 새 파일 생성 | **기존 파일 수정** |
| 종결 | 3-PASS 합의 | 게이트 PASS | **verified rounds / 2-PASS(with guard) / cap / gate** |

¹ `--no-verify` 시 1/라운드, self-review fallback 시 0 (Claude 자체 리뷰).

**파이프라인 조합 예시**:
```
triad (설계 결정) → pumasi (초기 구현) → mangchi (품질 망치질) → commit
```

## Skill 자체 제한

- **Existing single code file only**. Greenfield는 pumasi.
- **Codex CLI 권장** (없으면 대화형 확인 후 self-review로 degrade).
- **다중 파일 동시 refinement 범위 밖**.
- **권장 파일 크기**: ≤ 2000 LoC, ≤ 200KB. 초과 시 `--force` 필요.
- **CASE-STUDIES.md 주의**: 해당 사례들은 **legacy schema (verdict BLOCK 포함, verify loop 없음)** 기준. 현 schema_version 1과 동작 다름 - 새 디자인의 empirical evidence는 재축적 필요.

## Known Limits (요약)

전체 목록은 `references/known-limits.md`. 핵심 3가지:

- **Token 경제 가정** (Claude 풍부 / Codex 희소)이 반대인 사용자는 pumasi가 적합. Python 3.8+ 필요.
- **자동 탐지 한계**: no-op ACCEPT는 locus ±5줄 휴리스틱(리팩터링 시 false-negative), REJECT citation·test name의 **진위**는 미검증 - 유일한 하드 카운터는 `--gate`.
- **Degrade 모드**: self-review(Codex 부재)와 `--no-verify`는 verify loop + FORCED_ACCEPT를 끄므로 adversarial 보증이 사라진다 (linter 수준). `mv updated.*`로 원본 교체 시 `--continue` 불가.

## 참조

- Axes prompts & YAML schema SSOT: `axes.md`
- Preflight script (Phase 0): `scripts/preflight.sh`
- state.json schema SSOT: `references/state-schema.md`
- Known limits (full): `references/known-limits.md`
- Templates: `templates/round.md`, `templates/converged.md`, `templates/index.md`
- Usage examples: `references/usage.md`
- Case studies (legacy schema): `CASE-STUDIES.md`, `CASE-STUDIES-v2.md`
- Research notes: `RESEARCH.md`
- Version history: `CHANGELOG.md` (repo root)
