# harn

AI 멀티 에이전트 스프린트 개발 루프 오케스트레이터

기획자(Planner) → 개발자(Generator) → 평가자(Evaluator) 루프를 자동화해 백로그 항목을 스프린트 단위로 구현합니다.

## 설치

```bash
git clone https://github.com/your-org/harn.git
cd harn
bash install.sh
```

설치가 완료되면 어디서든 `harn` 명령어를 사용할 수 있습니다.

### 옵션

```bash
bash install.sh             # 사용자 설치 (~/.local/share/harn, ~/.local/bin/harn)
bash install.sh --global    # 시스템 전역 설치 (/usr/local/lib/harn, /usr/local/bin/harn)
HARN_PREFIX=/opt bash install.sh   # 커스텀 경로
```

> **PATH 주의**: 사용자 설치 후 `~/.local/bin`이 PATH에 없으면 셸 설정 파일에 추가하세요:
> ```bash
> echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
> source ~/.zshrc
> ```

### 제거

```bash
bash uninstall.sh           # 사용자 설치 제거
bash uninstall.sh --global  # 전역 설치 제거
```

## 빠른 시작

```bash
# 프로젝트 디렉터리로 이동
cd /path/to/your/project

# 실행 — .harness_config 가 없으면 자동으로 초기 설정 진행
harn start
```

첫 실행 시 대화형 설정 마법사가 자동으로 시작됩니다. 설정이 완료되면 `.harness_config`가 생성되고 이후 실행부터는 바로 시작됩니다.

## 명령어

### 설정

| 명령어 | 설명 |
|--------|------|
| `harn init` | 초기 설정 (최초 1회 또는 재설정) |
| `harn config` | 현재 설정 출력 |
| `harn config set KEY VALUE` | 특정 설정값 변경 |
| `harn config regen` | `.harness_config`의 HINT_* 기반으로 커스텀 프롬프트 재생성 |

### 백로그 & 실행

| 명령어 | 설명 |
|--------|------|
| `harn backlog` | 대기 중인 백로그 항목 표시 |
| `harn auto` | 진행 중이면 재개 / 있으면 시작 / 없으면 발굴 |
| `harn start` | 백로그 항목 선택 후 전체 루프 실행 |
| `harn discover` | 코드베이스 분석 후 신규 항목 추가 |

### 단계별 실행

| 명령어 | 설명 |
|--------|------|
| `harn plan` | 현재 실행의 기획자 재실행 |
| `harn contract` | 스프린트 스코프 협의 |
| `harn implement` | 개발자 실행 |
| `harn evaluate` | 평가자 실행 (QA FAIL 시 자동 재시도) |
| `harn next` | 다음 스프린트 |

### 모니터링

| 명령어 | 설명 |
|--------|------|
| `harn status` | 현재 실행 상태 |
| `harn tail` | 실시간 로그 출력 |
| `harn runs` | 모든 실행 목록 |
| `harn resume <id>` | 이전 실행 재개 |
| `harn stop` | 실행 중인 루프 중지 |

## 전체 워크플로우

```
harn start
```

```
백로그 선택
    │
    ▼
[기획자] spec.md + sprint-backlog.md 생성
    │  모델: MODEL_PLANNER
    │  Git:  plan/<slug> 브랜치 생성
    │        백로그 In Progress 커밋
    │        → origin push
    │        → Draft PR 생성 (fork → upstream)
    │
    ▼ (스프린트 루프 시작)
┌───────────────────────────────────────────────────────────────┐
│  스프린트 N                                                    │
│                                                               │
│  ┌─ 스코프 협의 (ping-pong 1회) ───────────────────────────┐  │
│  │  [개발자] 스코프 제안          MODEL_GENERATOR_CONTRACT  │  │
│  │      ↓                                                   │  │
│  │  [평가자] APPROVED → contract.md  MODEL_EVALUATOR_CONTRACT│  │
│  │          NEEDS_REVISION → 개발자 재제안 → contract.md   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌─ 구현 → 검증 (최대 MAX_ITERATIONS 회) ──────────────────┐  │
│  │  [개발자] 구현                 MODEL_GENERATOR_IMPL      │  │
│  │      ↓   Git: 구현 커밋 + push                          │  │
│  │  [평가자] dart analyze / flutter test / E2E             │  │
│  │          VERDICT: PASS → 다음 스프린트  MODEL_EVALUATOR_QA│  │
│  │          VERDICT: FAIL → 개발자 재구현 (Opus 동일 유지) │  │
│  └──────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
    │
    ▼ (마지막 스프린트 통과 후)
[평가자] handoff.md 작성
백로그 → Done 이동 + 커밋
    │  Git (GIT_AUTO_MERGE=true 인 경우):
    │        git push origin <branch>   (PR 최신화)
    │        gh pr merge --merge        (squash 아님)
    │        git checkout develop
    │        git pull upstream develop
    │
    ▼
[평가자] 회고 + 프롬프트 개선 제안
```

> **QA FAIL 재시도 모델**: `MODEL_GENERATOR_CONTRACT` (`claude-sonnet-4.6` 기본값)  
> 최초 구현은 `MODEL_GENERATOR_IMPL` (Opus), FAIL 후 재시도는 `MODEL_GENERATOR_CONTRACT` (Sonnet)으로 전환합니다.

> **Git 머지 조건**: `GIT_ENABLED=true` + `GIT_AUTO_MERGE=true` 일 때만 자동 머지.  
> `GIT_AUTO_MERGE=false`(기본값)이면 루프 완료 후 수동으로 GitHub에서 PR을 머지하세요.

## 의존성

| 도구 | 용도 |
|------|------|
| `python3` | 백로그 파싱, 마크다운 렌더링 |
| `copilot` | AI 에이전트 실행 (GitHub Copilot CLI) |

GitHub Copilot CLI 설치:
```bash
npm install -g @githubnext/github-copilot-cli
```

## AI 모델 (기본값)

| 역할 | 기본 모델 |
|------|-----------|
| 기획자 | claude-haiku-4.5 |
| 개발자 (스코프) | claude-sonnet-4.6 |
| 개발자 (구현) | claude-opus-4.6 |
| 평가자 (스코프) | claude-haiku-4.5 |
| 평가자 (QA) | claude-sonnet-4.5 |

## 설정 파일 (.harness_config)

`harn init` 또는 첫 실행 시 프로젝트 루트에 자동 생성됩니다.

```bash
# .harness_config

# === 프로젝트 설정 ===
BACKLOG_FILE="docs/planner/sprint-backlog.md"
MAX_ITERATIONS=5

# === AI 모델 설정 ===
MODEL_PLANNER="claude-haiku-4.5"
MODEL_GENERATOR_CONTRACT="claude-sonnet-4.6"
MODEL_GENERATOR_IMPL="claude-opus-4.6"
MODEL_EVALUATOR_CONTRACT="claude-haiku-4.5"
MODEL_EVALUATOR_QA="claude-sonnet-4.5"

# === Git 통합 ===
GIT_ENABLED="false"
GIT_BASE_BRANCH="main"
GIT_AUTO_PUSH="false"
GIT_AUTO_PR="false"

# === 커스텀 프롬프트 ===
CUSTOM_PROMPTS_DIR=""
```

설정값 변경:

```bash
harn config set MAX_ITERATIONS 3
harn config set GIT_ENABLED true
harn config set MODEL_GENERATOR_IMPL claude-sonnet-4.6
```

## 프로젝트 컨텍스트

모든 AI 에이전트에 자동 주입되는 컨텍스트 파일입니다. 아키텍처, 기술 스택, 개발 규칙을 작성하세요.

```bash
cat > .harness/context.md << 'EOF'
## 프로젝트 개요
[설명]

## 아키텍처
[레이어 구조, 패키지 구성]

## 기술 스택
[주요 기술, 라이브러리]

## 개발 규칙
[코딩 컨벤션, 금지 패턴]
EOF
```

## 커스텀 프롬프트

`CUSTOM_PROMPTS_DIR`에 `planner.md`, `generator.md`, `evaluator.md`를 두면 내장 프롬프트를 대체합니다.

```bash
mkdir -p .harness/prompts
cp ~/.local/share/harn/prompts/planner.md .harness/prompts/
# 편집 후:
harn config set CUSTOM_PROMPTS_DIR ".harness/prompts"
```

## 환경변수 오버라이드

실행 시 모델 임시 변경:

```bash
HARNESS_COPILOT_MODEL_GENERATOR_IMPL=claude-sonnet-4.6 harn start
```
