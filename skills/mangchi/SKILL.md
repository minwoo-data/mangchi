---
name: mangchi
description: Iterative code refinement — Claude edits, Codex CLI adversarially reviews one of 5 axes per round, verifies Claude's REJECTs on a second call. Stops on 2 clean rounds / 2 PASS / R5 cap / optional --gate. Existing code file ≤2000 LoC. Requires Codex CLI; /triad for Codex-free review.
---

# Mangchi — Iterative Code Refinement (망치)

## TL;DR

- **대상**: 이미 존재하는 단일 코드 파일 (≤ 2000 LoC 권장). Greenfield → pumasi.
- **역할**: Claude = 코더 + 판정. Codex CLI = 적대적 리뷰 + Claude의 REJECT 재검증.
- **라운드**: 기본 5축 순환 (correctness/security/readability/performance/design). `necessity`는 opt-in. R5 hard cap.
- **Codex 호출**: 라운드당 최대 2회 (review + verify). `--no-verify`면 1회 (adversarial 가드 포기).
- **종결**:
  ① 2 consecutive verified rounds — ACCEPT diff-검증 통과 + DISAGREE 0
  ② 2 consecutive PASS — **단 `correctness` + `security` 축이 이력에 각각 ≥ 1회 실행되어 있어야 유효**
  ③ R5 cap
  ④ `--gate "<cmd>"` 통과 (종결 직전 1회)
  ⑤ 사용자 `--stop`
  ⑥ Abort: token budget / `forced_accept_count ≥ --force-accept-threshold` (default 2) / Codex schema 재시도 실패 / per-call context window 초과
- **불변**: Codex는 읽고 비판만. Claude만 파일 수정. 원본 불변 (`updated.*` 작업본).

> 이 description은 skill catalogue에 노출. Mangchi 선택 판단의 1차 정보.

## 철학 — Pumasi와 정확히 반대

| | pumasi | **mangchi** |
|---|---|---|
| 주연 | Codex (구현) | **Claude (구현 + 수정)** |
| 조연 | Claude (설계/감독) | **Codex (비판 + 검증)** |
| 불변식 | "Claude는 코드 안 짠다" | **"Codex는 코드 안 짠다"** |
| 토큰 | Codex 많이, Claude 적게 | **Claude 많이, Codex 적게** |
| 작업 흐름 | 병렬 구현 → 게이트 | **직렬 라운드, 축 로테이션, 이중 Codex 호출** |

Claude Max $200 경제(Claude 토큰 풍부, Codex 토큰 희소)에 맞춰 설계.

## 핵심 불변식

1. **Codex는 읽고 지적만 한다**. 코드 쓰지 않음, 새 파일 생성 없음.
2. **Claude만 파일을 수정한다**. Codex 의견을 받아 판단하고 Edit/Write로 반영.
3. **원본 불변**. 기본 동작은 `updated.<ext>`에만. `--apply=original` 지정 시만 원본 교체.
4. **R5 hard cap**.
5. **같은 축 2연속 금지**. 라운드 N의 축 ≠ 라운드 N-1의 축.
6. **Codex는 adversary**. Claude가 모든 REJECT를 할 수 없다 — Codex가 verify 단계에서 DISAGREE하면 다음 라운드 선행 의제로 이월, 2연속 DISAGREE → 강제 ACCEPT.
7. **Shell injection 차단**. Codex 호출은 `tempfile + stdin` 방식만 허용. 파일 내용을 `"<prompt>"` argv로 전달 금지.

## 요구사항

- **Bash 4+**. `declare -A` 등 associative array 사용. Windows는 Git Bash (4.4+) 또는 WSL.
- **Codex CLI 설치 권장**. 없으면 대화형 확인 후에만 self-review 가능.
- **Git** (diff 측정 `git diff -w --numstat`).
- **Python 3.8+** (YAML 응답 파싱, `python -c "import yaml; ..."`).

## 트리거 (CLI flags)

### 자주 쓰는 플래그 (Essential — first-time users)

| 트리거 | 효과 |
|---|---|
| `/mangchi <file>` | 기본 — updated.* 작업, 원본 불변 |
| `--apply=original` | 원본 파일도 Edit 반영 (위험, PR 직전 권장) |
| `--gate "<cmd>"` | 종결 직전 외부 게이트 실행 (예: `"pytest -x"`), exit 0 필수 |
| `--continue <slug>` | 기존 세션 이어가기 (abort된 세션도 포함) |
| `--stop <slug>` | 강제 종결 |

자연어: "망치로 다듬어줘", "codex로 반복 리뷰해줘".

### 고급 플래그 (Advanced — 특정 시나리오)

<details>
<summary>클릭해서 펼치기 — 대부분은 default 그대로가 최적</summary>

| 트리거 | 효과 |
|---|---|
| `--only-axes=correctness,security` | 지정 축만 순환 (default 5축 대체). 사용 시 2-PASS 종결 조건에 correctness+security 둘 다 포함 필요. |
| `--include-axes=necessity` | default 5축 + `necessity` 추가 |
| `--start-axis=security` | R1 시작 축 (기본 `correctness`). 보안 민감 파일에 security-first 돌릴 때. |
| `--no-verify` | Phase 6 Codex verify 생략. **adversarial 가드 + FORCED_ACCEPT 동시 비활성** — mangchi의 핵심 가치 포기. 이미 외부 리뷰어 있는 빠른 체크에만. |
| `--allow-self-review` | Codex 없을 때 묻지 않고 self-review 강제 (CI 전용). 대화형 환경에선 자동으로 y/N 물어보므로 불필요. |
| `--force` | Pre-flight 2000 LoC / 200KB 가드 bypass. Codex context window는 그래도 reject할 수 있음. |
| `--force-accept-threshold=N` | FORCED_ACCEPT abort 임계값 (default **2**). `=1` 엄격 모드 (보안/암호학), `≥3` permissive (legacy 파일). |

</details>

## 5개 리뷰 축 + `necessity` opt-in

자세한 프롬프트는 `axes.md`. **스키마는 `axes.md` §"공통 출력 포맷"이 SSOT** (single source of truth).

| 축 | 질문 | 기본 |
|---|---|---|
| **correctness** | 버그, 엣지 케이스, 계약 위반 있는가? | ✓ |
| **security** | 인젝션/인증 우회/누출/레이스 조건 있는가? | ✓ |
| **readability** | 명명/구조/주석이 미래 독자에게 친절한가? | ✓ |
| **performance** | 불필요한 I/O, N+1, 비효율 자료구조 있는가? | ✓ |
| **design** | SRP/결합도/의존 방향/테스트 용이성 있는가? | ✓ |
| **necessity** | 이 추가가 정말 필요한가? (YAGNI·Occam) | opt-in (`--include-axes=necessity`) |

`necessity`는 "제거/축약" 판단 — refinement보다 greenfield 판단에 가까워 default 제외.

## 워크플로우 (라운드 N)

### Phase 0: 초기화 (R1에만)

**Consolidated preflight** — 모든 환경 의존성을 한 번에 검증 후 시작.

```bash
FILE="$1"

# ──────────────────────────────────────────────
# Step 1: 환경 의존성 (Bash / Python / Git / Codex / PyYAML)
# ──────────────────────────────────────────────
preflight_env() {
  local fail=0
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || {
    echo "[ERROR] Bash 4+ required (declare -A). Current: ${BASH_VERSION}"
    echo "  macOS: brew install bash"
    echo "  Windows: install Git Bash 4.4+ or use WSL"
    fail=1
  }
  command -v git >/dev/null 2>&1 || {
    echo "[ERROR] git not in PATH (diff measurement requires it)"
    fail=1
  }
  command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || {
    echo "[ERROR] Python 3.8+ not found (YAML parsing)"
    fail=1
  }
  python -c "import yaml" 2>/dev/null || python3 -c "import yaml" 2>/dev/null || {
    echo "[ERROR] PyYAML missing. Install: pip install pyyaml"
    fail=1
  }
  command -v codex >/dev/null 2>&1 || {
    echo "[WARN] Codex CLI missing. (See 'Codex 부재 시 동작' section for options)"
    # Not a hard fail — handle_codex_missing routes the user
  }
  [ "$fail" -eq 0 ] || exit 1
}
preflight_env

# ──────────────────────────────────────────────
# Step 2: 입력 유효성 + 경로 정규화
# ──────────────────────────────────────────────
[ -f "$FILE" ] || { echo "[ERROR] File not found: $FILE"; exit 1; }
FILE="${FILE//\\//}"   # Windows path normalization (Git Bash)

# ──────────────────────────────────────────────
# Step 3: 파일 크기 가드
# ──────────────────────────────────────────────
LOC=$(wc -l < "$FILE")
BYTES=$(wc -c < "$FILE")
if { [ "$LOC" -gt 2000 ] || [ "$BYTES" -gt 204800 ]; } && [ -z "$FORCE" ]; then
  echo "[ERROR] File exceeds limits (LoC=$LOC, bytes=$BYTES)."
  echo "  Use --force to override (Codex context window may still reject)."
  exit 1
fi

# ──────────────────────────────────────────────
# Step 4: 축 커버리지 경고 (2-PASS 종결 경로)
# ──────────────────────────────────────────────
if has_only_axes && ! ( contains "$ONLY_AXES" "correctness" && contains "$ONLY_AXES" "security" ); then
  echo "[WARN] --only-axes excludes correctness or security."
  echo "       2-PASS termination DISABLED. Converge via R5 cap or --gate."
fi

# ──────────────────────────────────────────────
# Step 5: Codex CLI 부재 시 라우팅 (있으면 skip)
# ──────────────────────────────────────────────
if ! command -v codex >/dev/null 2>&1; then
  handle_codex_missing   # 대화형 확인 / abort / self-review (see below)
fi

# ──────────────────────────────────────────────
# Step 6: Slug + 작업 디렉토리 + 백워드 호환 경고
# ──────────────────────────────────────────────
SLUG=$(compute_slug "$FILE")
DIR="docs/refinement/mangchi/$SLUG"
mkdir -p "$DIR"

OLD_DIR="docs/refinement/$SLUG"
if [ -d "$OLD_DIR" ] && [ ! -L "$OLD_DIR" ]; then
  echo "[WARN] Legacy path detected: $OLD_DIR."
  echo "       New runs use $DIR. Move manually if continuing old session."
fi

# ──────────────────────────────────────────────
# Step 7: 작업본 + 스냅샷 + state.json
# ──────────────────────────────────────────────
EXT="${FILE##*.}"
cp "$FILE" "$DIR/updated.$EXT"
cp "$FILE" "$DIR/source-snapshot.$EXT"
init_state "$DIR/state.json"
```

### Phase 1: 축 선택 (Claude)

**Precedence** (R2+, 높은 우선순위부터):
1. **Same-axis ban**: 직전 라운드 축은 제외.
2. **Carryover DISAGREE**: state.json에 `status: PENDING` 이슈의 원래 축이 directly available하면 그 축. (단 same-axis ban 우선 — carryover 축이 직전과 같으면 다음으로 ban 해제된 축 중 신호 강한 것.)
3. **Signal heuristic**: 남은 축 중 이전까지 issues 누적이 많은 축.

**R1 규칙**:
- `--start-axis=<axis>` 있으면 그 축.
- 없으면 `correctness`.

### Phase 2: Codex Review 호출 (shell-injection-safe)

**Token pre-send estimate (single cap, 180K)**:
```python
est_tokens = char_count(prompt) / 4 * 1.3   # 1.3 = safety factor for punctuation-heavy code
if est_tokens >= 180_000:   # hard context-window guard (model limit)
    abort_round("single-call context window exceeded (>180K). Split the file.")
```

**Per-call context window guard (180K)**: Codex model (gpt-4o 등) context ≈ 200K. 여유 두고 180K cap. 누적 폭주는 **cumulative 500K** 가드가 별도로 잡음 (아래 참조).

**호출** (tempfile + stdin, argv 금지):
```bash
PROMPT_FILE="$DIR/round-${N}.prompt.txt"
CODEX_OUT="$DIR/round-${N}.codex.txt"

# Heredoc quoted로 작성 (shell expansion 차단)
cat > "$PROMPT_FILE" <<'PROMPT_EOF'
# ... 전체 프롬프트 ... 
# 파일 본문은 별도 cat으로 append (quoted heredoc 안에서 또 heredoc 넣기 어려움):
PROMPT_EOF

# 축 rubric
cat "path/to/axis_rubric.md" >> "$PROMPT_FILE"

# 대상 파일 본문 — cat append (여기서 shell 해석 없음)
echo '--- BEGIN FILE ---' >> "$PROMPT_FILE"
cat "$DIR/updated.$EXT" >> "$PROMPT_FILE"
echo '--- END FILE ---' >> "$PROMPT_FILE"

# 지난 라운드 decisions (R ≥ 2)
# ...

# stdin 리다이렉션으로 Codex 호출
codex exec --dangerously-bypass-approvals-and-sandbox \
  < "$PROMPT_FILE" \
  > "$CODEX_OUT"
```

> `--dangerously-bypass-approvals-and-sandbox` 플래그: Codex가 자신의 파일 시스템 샌드박스/승인 프롬프트를 건너뛰도록 하는 Codex CLI 옵션. mangchi는 Codex를 read-only로 사용하므로 파일 쓰기는 없음. 이 플래그는 Codex 자체 동작에만 영향. 호스트 시스템 보안엔 영향 없음.

**프롬프트 구성**:
- 해당 축의 full rubric (`axes.md`)
- `updated.<ext>` 전체 내용 (축약 금지)
- 지난 라운드 ACCEPT/REJECT 요약 (R ≥ 2)
- DISAGREE 이월 의제 (optional)
- **이미 FORCED_ACCEPT된 이슈 ID 목록 — 재제기 금지 명시**
- 출력 포맷: `axes.md` §"공통 출력 포맷" 참조 (schema_version: 1)

### Phase 3: 응답 파싱 + 스키마 검증

```python
# 핵심 로직 (Python 3)
import yaml
try:
    response = yaml.safe_load(open(CODEX_OUT))
except yaml.YAMLError as e:
    retry_codex(reason=f"YAML parse error: {e}")   # 1회만
    # 재시도 또 실패 시 abort

# 필수 필드 검증
assert response["axis"] in VALID_AXES
assert response["verdict"] in {"PASS", "REVISE"}
if response["verdict"] == "REVISE":
    assert isinstance(response["issues"], list) and len(response["issues"]) >= 1
    for issue in response["issues"]:
        assert isinstance(issue["id"], int)
        assert issue["severity"] in {"HIGH", "MEDIUM", "LOW"}
        assert ":" in issue["locus"]   # "file:LINE" 형식
        # ... 기타 필드
```

실패 시:
- Attempt 1: Codex에 "이전 응답 schema 위반: {error}. Re-emit complete YAML matching schema." 프롬프트 1회 재전송.
- Attempt 2도 실패: `[ERROR] Codex output invalid after retry` + abort (state.json.last_invalid_codex_output에 raw 저장).

### Phase 4: Claude 판단 (ACCEPT/REJECT)

각 issue별 판정. **schema v1 decision values**: `ACCEPT` | `REJECT`. (legacy `DEFER` 폐지.)

**REJECT citation 강제 (hard validation)**:
- 사유에 `file:LINE` 형식 code_ref 또는 test name 인용 **필수**.
- 없으면 Claude가 **즉시 에러 처리** — REJECT 판정 무효로 돌리고 다시 judgment 요청 (silent ACCEPT flip 금지). 이는 Claude가 "그냥 REJECT하고 싶을 때 근거 생략"하는 경로를 봉쇄.
- round-N.md에 `decision | reason (citation 포함)` 컬럼으로 기록.

### Phase 5: 수정 적용 + ACCEPT diff 검증

ACCEPT된 이슈를 `updated.<ext>`에 Edit로 반영.

**Diff 측정**:
```bash
git diff -w --numstat "$DIR/updated.$EXT"   # whitespace 무시
```

**ACCEPT git-diff 검증**:
- 각 ACCEPT 이슈의 `locus` 영역 **±5줄** (fuzz factor — 편집이 locus 경계 바로 밖에서 일어난 경우 포착)이 실제 diff에 touched인지 체크.
- `-w` (whitespace 무시) 기반이므로 whitespace-only 편집은 "no-op"로 간주 (그 편집은 의미 없는 변경).
- 변경 없으면 **no-op ACCEPT**로 기록, 다음 라운드 의제 유지 (`state.json.issues[].status: PENDING`).
- no-op ACCEPT는 **Phase 7 "2 verified rounds" 수렴 카운트에서 제외**.

> **±5 근거**: 실측이 아닌 heuristic. locus는 Codex가 지적 시 본 line이지만, Claude의 실제 수정이 그 함수 머리(±5)에서 일어나는 경우 흔함. 너무 크게 잡으면 false-negative (전혀 다른 영역 변경도 통과), 너무 작으면 false-positive (legitimate 수정 놓침). 5줄은 mangchi 개발 중 실 사용에서 조정된 값.
> **False-positive 경로**: 리팩터링으로 ±5 밖에 실제 수정이 일어난 경우 no-op ACCEPT로 잘못 기록. 사용자가 CONVERGED.md §6 확인 시 수동 arbitration 가능.
> **False-negative 경로**: whitespace-only 편집은 `-w` 때문에 자동 탐지 (의미 없는 변경이 통과하지 않음).

`--apply=original` 지정 시 이 시점에 원본도 함께 Edit.

### Phase 6: Codex 재검증 (verification loop)

**Skip 조건** (다음 중 하나):
- REJECT 0개
- `--no-verify` 플래그
- Self-review 모드 (FORCED_ACCEPT 메커니즘도 동시 비활성)

**호출 (REJECT 이슈만 + post-edit locus ±10줄 context)**:

> **Context는 pre-edit이 아니라 post-edit `updated.<ext>`**. ACCEPT 적용 후 라인 번호가 이동했을 수 있으므로 verify는 최신 파일 상태를 참조해야 함.
> **Clamp 룰**: ±10줄이 파일 경계 밖이면 `max(0, start-10)` ~ `min(file_len, end+10)` 로 클램프. Locus가 파일 끝 근처일 때 context가 파일 밖으로 흘러넘치지 않도록.

```bash
VERIFY_PROMPT="$DIR/round-${N}.verify.prompt.txt"
VERIFY_OUT="$DIR/round-${N}.verify.txt"

cat > "$VERIFY_PROMPT" <<'VERIFY_EOF'
# Codex가 Claude의 REJECT 근거를 검증한다.
# 아래 각 이슈에 대해 AGREE(종결) 또는 DISAGREE(유지 주장)로 응답.
# DISAGREE는 post-edit 코드 상의 구체 근거 (file:line) 인용 필수.
# ...
VERIFY_EOF

# REJECT 이슈 + post-edit context append
append_rejected_issues_with_post_edit_context >> "$VERIFY_PROMPT"

codex exec --dangerously-bypass-approvals-and-sandbox \
  < "$VERIFY_PROMPT" \
  > "$VERIFY_OUT"
```

**처리**:
- `AGREE`: 이슈 종결, `issues[].status: RESOLVED`.
- `DISAGREE`: 이슈 carry over, `issues[].status: PENDING`, `history[].verification.verdict: DISAGREE`.
- 같은 `issue_id`가 **2라운드 연속 DISAGREE** → 시스템이 `FORCED_ACCEPT`로 승격 (Claude 직접 선택 아님), `forced_accept_count += 1`.
- **Abort 정책 (γ, configurable)**: `forced_accept_count ≥ --force-accept-threshold` (default **2**) → abort + 구조화 리포트:

```
[ABORT] forced_accept_count reached N. Disputes:
  1. R{n}.{axis}#{id} | locus=auth.py:42 | Claude: "<reason>" | Codex: "<reason>" | resolution: FORCED_ACCEPT pending
  2. ...
Session state preserved. Review state.json and resume with:
  /mangchi --continue <slug>   # after manually arbitrating the disputes
```

**정책 설명**:
- **Default (threshold=2, adoption-friendly)**: 첫 FORCED_ACCEPT 후 경고 로깅만, 2번째에서 abort. 작은 의견 차이 1건은 flow 중단 없이 흡수. 대부분의 첫-실행 사용자가 수렴까지 도달.
- **Strict (threshold=1)**: 첫 FORCED_ACCEPT 즉시 abort. Adversarial 가치 극대화, 의견 차 한 건도 묵과 안 함. 보안 심사 / 회계 로직 / 암호학 코드에 권장.
- **Permissive (threshold≥3)**: 의견 차이 많은 legacy 파일에 실용적. N-1회 forced-accept 적용 후 N번째에 abort.
- **Resume**: abort된 세션도 `--continue <slug>`로 재개 가능. state.json에서 disputed issue들을 사용자가 수동 arbitrate 후 재실행.

**AGREE on ACCEPT without diff (symmetric guard)**: verify 없이도 Phase 5 no-op ACCEPT 검출이 ACCEPT 오용을 막음. AGREE가 붙은 ACCEPT여도 `diff_verified: false`면 "2 verified rounds" 카운트에서 제외 (즉 ACCEPT + AGREE 조합도 실제 수정 없으면 수렴 신호 아님).

### Phase 7: 종결 판정

**Stop 조건 평가 순서 (OR — 하나만 만족하면 종결)**:

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
   - Per-call context window 180K 초과 (hard limit — 모델 제약).
   - `--only-axes`가 correctness+security 둘 다 빠진 상태에서 R5 cap 도달하고 `--gate`도 없으면 `aborted_no_termination_path` (Phase 0 경고와 symmetrical).

### Soft coverage floor (R4→R5)

R4 종료 시점에 `correctness` 또는 `security` 축이 **한 번도 실행되지 않았으면**, R5는 그 누락 축으로 자동 배정 (signal heuristic 무시). `--only-axes`에 의해 해당 축이 아예 제외됐으면 적용 불가 (Phase 0 경고로 알림).

목적: "쉬운 축만 돌리고 끝나는" 게이밍 마지막 방지선. R4까지 correctness/security 안 돌렸다 = 거의 확실히 게이밍 중.

종결 시 `CONVERGED.md` 작성 (템플릿 `templates/converged.md`).

### Phase 8: INDEX.md rewrite

매 라운드 종료 시 요약표 재작성 (abort 경로에서도 남김):

```markdown
# Mangchi: <slug>

| Round | Axis        | Verdict  | ACCEPT | Verify |
|-------|-------------|----------|--------|--------|
| R1    | correctness | REVISE   | 2/3    | AGREE 1, DISAGREE 0 |
| R2    | security    | PASS     | -      | - (skipped) |

**Status**: active | converged | aborted (reason)
**See**: round-N.md for details, state.json for full record
```

### Phase 9: 다음 라운드 or 종료

- 종결 → `state.json.status = "converged" | "aborted"`, `CONVERGED.md` 작성, 완료 메시지.
- 미종결 → round N+1 진입, Phase 1으로.

## 축 로테이션 규칙

- 같은 축 2연속 리뷰 금지 (핵심 불변식 #5).
- 모든 issue가 REJECT + 모두 verify AGREE로 종결된 축: 다음 라운드도 같은 축 재리뷰 금지.
- 5축 (또는 necessity opt-in 시 6축) 한 번씩 썼으면 wrap 룰 이론적 존재 (R5 cap상 실제 도달은 `--include-axes=necessity`일 때 약간 가능).
- **중복 금지**: 이 규칙은 핵심 불변식 #5와 중복이라 참조만 — 위에서 정의한 것을 그대로 따름.

## Codex 부재 시 동작

**Hard refuse on security-sensitive filenames** (any mode — 심지어 `--allow-self-review`도 거부):
- 파일명 매칭 regex: `.*(auth|security|crypto|password|token|secret|sanitiz|permission|acl).*`
- 매칭 시 즉시 abort + `[ERROR] Self-review mode is refused on security-sensitive files. Install Codex or use /triad.`
- 이유: mangchi의 adversarial 가드가 가장 중요한 파일 유형. self-review로 돌리면 false confidence 유발.

**대화형 환경 (TTY, security-sensitive 아님)**:
```
[WARN] Codex CLI not found.

mangchi is designed as multi-model adversarial review —
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
- "2 verified rounds" 종결 조건은 여전히 유효 (ACCEPT diff-검증은 Phase 5에 남음) — 단 DISAGREE 검증이 없으므로 조건 달성이 쉬워짐.

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

## state.json 스키마 (schema_version: 1)

```json
{
  "schema_version": 1,
  "slug": "src-routes-auth-py",
  "started_at": "2026-04-16T10:00:00Z",
  "self_review_mode": false,
  "no_verify_mode": false,
  "axes_opt_in": [],
  "start_axis": "correctness",
  "gate_cmd": null,
  "gate_every_round": false,
  "force_round_rounds": [],
  "rounds": [
    {
      "n": 1,
      "axis": "correctness",
      "verdict": "REVISE",
      "no_changes_suggested": false,
      "diff_loc": 18,
      "codex_tokens": {"review": 15234, "verify": 4821, "estimate_only": false},
      "ended_at": "..."
    }
  ],
  "issues": [
    {
      "id": 1,
      "first_seen_round": 1,
      "axis": "correctness",
      "title": "null check missing",
      "locus": "auth.py:42-45",
      "severity": "HIGH",
      "confidence": "HIGH",
      "history": [
        {
          "round": 1,
          "action": "ACCEPT | REJECT | FORCED_ACCEPT",
          "reason": "... (REJECT는 file:line citation 포함)",
          "diff_verified": true,
          "verification": {"verdict": "AGREE | DISAGREE", "reason": "..."}
        }
      ],
      "status": "RESOLVED | PENDING | FORCED_ACCEPT"
    }
  ],
  "codex_tokens_total": 20055,
  "forced_accept_count": 0,
  "force_accept_threshold": 2,
  "last_invalid_codex_output": null,
  "status": "active | converged | aborted",
  "termination_reason": null
}
```

## 슬러그 규칙

- 확장자 유지 + `/` → `-` + 특수문자 → `-` 치환.
- 결과가 숫자 또는 dot(`.`)으로 시작하면 `_` 접두.
- 결과가 빈 문자열이면 `unnamed-<timestamp>`.

예:
- `src/routes/auth.py` → `src-routes-auth-py`
- `.bashrc` → `_bashrc`
- `123config.yaml` → `_123config-yaml`
- `a/b/c d.ts` → `a-b-c-d-ts` (공백도 `-`)

## 토큰 예산

- **Per-round pre-send estimate** (단일 cap, 180K):
  - 측정 시점: `$PROMPT_FILE` 이 **완전히 assemble된 후 (stdin redirect 직전)**. 축 rubric + updated.<ext> + 이전 라운드 digest + FORCED_ACCEPT 목록 전부 포함된 최종 상태 기준.
  - 공식: `char_count(PROMPT_FILE) / 4 * 1.3`.
    - `/4`: 영문 평균 토큰당 ~4 char (OpenAI tokenizer 휴리스틱).
    - `*1.3`: safety factor — 코드는 punctuation density 높아 실 토큰이 heuristic보다 많음. 경험적 보수값 (정확한 숫자 원하면 tiktoken 사용).
  - ≥ **180K**: per-call context-window 초과 → **강제 abort** (모델 제약). 파일 분할 필요.
- **Cumulative (state.json)**:
  - ≥ **150K**: `[WARN]` 로그.
  - ≥ **500K**: abort + 구조화 리포트 (남은 의제 + 선택지 제시).
- **Codex CLI가 usage 정보 미반환 시**: 추정치로 누적 근사 + `[WARN] Token tracking approximate` + `codex_tokens.estimate_only: true`.

## Codex CLI 호출 규칙

**환경 변수**:
```bash
CODEX="${CODEX:-codex exec --dangerously-bypass-approvals-and-sandbox}"
```

**불변 규칙**:
- **argv 금지** — 절대 `$CODEX "$PROMPT_TEXT"` 패턴 쓰지 않음. Shell injection 벡터.
- **tempfile + stdin 강제** — `$CODEX < "$PROMPT_FILE"` 만 허용.
- **Heredoc quoted** (`<<'EOF'`) — prompt body 작성 시 shell expansion 차단.
- **Dynamic content는 항상 파일 append** — target source, 이전 라운드 decisions digest, FORCED_ACCEPT 이슈 목록 등 **모든 동적 섹션은 `cat <source_file> >> "$PROMPT_FILE"` 패턴만 허용**. `echo "$VAR" >>` 같은 unquoted 변수 expansion 금지 (VAR에 backtick/`$(...)` 있으면 shell 해석됨). 이전 Codex 응답을 다음 라운드에 참조할 때 특히 주의 — Codex가 자기 reason 필드에 backtick 넣어올 수 있음.
- **FORCED_ACCEPT 이슈 목록 identifier 형식**: `R{n}.{axis}#{id}` (cross-round unique). 예: `R1.correctness#2`. round 내 id는 unique지만 round 간 재사용될 수 있으므로 prefix 필수.

**설치 확인**:
```bash
command -v codex || echo "codex missing; install: npm install -g @openai/codex"
```

**인증**: Codex CLI가 처리 (`codex login` 또는 `OPENAI_API_KEY`). mangchi는 건드리지 않음.

## 안티패턴

- ❌ Claude가 Codex에게 "이 코드 써줘" 요청 — Codex는 리뷰만.
- ❌ 같은 축 2연속 실행 — 진자 운동.
- ❌ R5 초과.
- ❌ 원본 파일을 `--apply=original` 없이 수정.
- ❌ Codex "비판 없음"을 메인이 무시하고 "뭐라도 고쳐야 한다"로 강제 진행.
- ❌ Codex 프롬프트에서 대상 코드 축약.
- ❌ 라운드당 축 2개 이상 리뷰.
- ❌ **REJECT-all 강제 수렴** — verification loop이 자동 차단하나 의도 자체를 배제.
- ❌ **No-op ACCEPT** — ACCEPT 처리만 하고 실제 수정 안 함 (git-diff 검증이 탐지).
- ❌ **Citation 없는 REJECT** — hard error로 처리, silent ACCEPT flip 금지.
- ❌ **`$CODEX "$PROMPT"` argv 패턴** — shell injection 벡터.
- ❌ **`--no-verify` + 보안 코드** — adversarial 가드 없이 보안 리뷰 = 효과 없음.

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
- **CASE-STUDIES.md 주의**: 해당 사례들은 **legacy schema (verdict BLOCK 포함, verify loop 없음)** 기준. 현 schema_version 1과 동작 다름 — 새 디자인의 empirical evidence는 재축적 필요.

## Known Limits (새로 명시)

### 설계 가정이 맞지 않는 경우
- **Token 경제**: "Claude 토큰 풍부, Codex 토큰 희소" 가정 — ChatGPT Plus 위주 사용자(Codex 싸고 Claude 비쌈)에겐 역방향. 그땐 pumasi가 더 적합.
- **Python 3.8+** 가정 — YAML 파싱에 프로젝트 Python 재사용. Python 없는 환경에선 별도 yaml parser (yq 등) 필요.

### 자동 탐지 한계
- **No-op ACCEPT (locus ±5)**: 리팩터링으로 locus가 함수 전체 이동한 경우 false-negative 가능. CONVERGED.md §6 수동 확인 권장.
- **Citation 진위**: Claude의 REJECT citation이 `file:LINE`은 체크하지만, 그 line의 코드가 실제로 Codex 지적을 "처리한 코드"인지는 검증 불가. 유일한 하드 카운터는 `--gate "<test>"`.
- **Fabricated test name**: `tests/test_x.py::test_y`가 실존하는 테스트인지는 체크 안 함 (`--gate`로 통해야 drop되지만 gate 없으면 통과).

### Resume 제한
- **mv destroys continue**: CONVERGED 후 `mv updated.<ext> target_file` 실행 시 `--continue` 불가능. `--apply=original` 쓰거나 `mv` 전에 세션 종결 확인.
- **Abort 후 continue 가능**: FORCED_ACCEPT ≥ threshold abort는 state 보존 — 수동 arbitration 후 `/mangchi --continue <slug>` 가능.

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

## 참조

- Axes prompts & YAML schema SSOT: `axes.md`
- Templates: `templates/round.md`, `templates/converged.md`
- Usage examples: `references/usage.md`
- Case studies (legacy schema): `CASE-STUDIES.md`
- Research notes: `RESEARCH.md`

## Changelog (이 SKILL 자체)

- **v2 (schema_version 1)** — 2026-04-16:
  - verification loop 도입 (Codex 재검증)
  - `necessity` → opt-in
  - ratio-based 수렴 제거, 2-verified-rounds 도입
  - 2 PASS 종결에 correctness+security 최소 커버리지 요구
  - Shell injection 차단 (tempfile + stdin)
  - Schema 통일 (verdict PASS|REVISE, severity HIGH|MEDIUM|LOW, locus)
  - `docs/refinement/mangchi/<slug>/` 네임스페이스 분리
  - 새 플래그: `--only-axes`, `--include-axes`, `--start-axis`, `--gate`, `--gate-every-round`, `--no-verify`, `--allow-self-review`, `--force`, `--force-round`, `--dry-run`
  - Token 예산 (80K per-round, 180K per-call, 500K cumulative)
  - FORCED_ACCEPT 메커니즘 (2연속 DISAGREE → 강제 ACCEPT, threshold 도달 시 abort)
- **v1 (legacy)** — 원본: diff ≤ 30% 수렴, verdict BLOCK, 단일 Codex 호출/라운드.
