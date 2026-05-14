# [보고서] 사내 LLM SWE-bench 평가 환경 구축 및 실행 결과

> **작성일**: 2026-05-13
> **작성자**: 평가 인프라 팀
> **상태**: 초안 (파일럿 실행 완료)
> **참조**: [`docs/eval_plan_swebench_internal.md`](eval_plan_swebench_internal.md) · [`README-new.md`](../README-new.md)

---

## 1. 개요

사내 LLM 모델의 소프트웨어 엔지니어링 자동화 능력을 객관적으로 측정하기 위해 오픈소스 평가 프레임워크인 **mini-swe-agent v2** 와 코딩 에이전트 벤치마크 표준인 **SWE-bench Lite** 를 활용한 평가 파이프라인을 구축하였다.

외부 인터넷이 제한된 사내 네트워크 환경에서 평가를 수행하기 위해 여러 기술적 제약을 식별·해결하였으며, 이 문서는 그 과정 전체를 기록한다.

### 핵심 목표

| 항목 | 내용 |
|------|------|
| 평가 프레임워크 | mini-swe-agent v2 (오픈소스, MIT 라이선스) |
| 벤치마크 | SWE-bench Lite 커스텀 서브셋 50문제 |
| 평가 대상 | 사내 OpenAI-compatible LLM 엔드포인트 |
| 주요 지표 | **Resolved Rate** — 에이전트 패치가 실제 테스트를 통과한 비율 |
| 평가 환경 | 사내 서버, Docker 기반 문제별 격리 실행 |

---

## 2. 평가 시스템 아키텍처

### 2.1 구성 요소 관계

```
┌────────────────────────────────────────────────────┐
│               mini-swe-agent v2                     │
│                                                    │
│  ┌──────────┐    ┌───────────────┐   ┌──────────┐  │
│  │  Agent   │───▶│  Model        │──▶│ 사내 LLM │  │
│  │(Default) │    │(LiteLLM)      │   │ Endpoint │  │
│  └────┬─────┘    └───────────────┘   └──────────┘  │
│       │                                            │
│  ┌────▼──────────────────────────┐                │
│  │  Environment (Docker)          │                │
│  │  swebench/sweb.eval.x86_64.*  │                │
│  └───────────────────────────────┘                │
└────────────────────────────────────────────────────┘
         │
         ▼
  results/<model>/
  ├── preds.json            ← 에이전트 제출 패치
  ├── <instance_id>/
  │   └── <id>.traj.json   ← 실행 궤적
  └── minisweagent.log
```

### 2.2 데이터 흐름

1. **입력**: `data/swebench_lite_test2.jsonl` (50개 문제, JSONL 포맷)
2. **실행**: 문제별로 Docker 컨테이너를 기동하여 에이전트가 bash 명령으로 소스 코드를 수정
3. **출력**: `preds.json` — 에이전트가 생성한 git diff 패치 모음
4. **채점**: `swebench` 도구로 각 패치가 테스트를 통과하는지 검증

### 2.3 핵심 설정 파일

| 파일 | 역할 |
|------|------|
| `src/minisweagent/config/benchmarks/swebench.yaml` | 기본 에이전트/환경 설정 |
| `src/minisweagent/config/benchmarks/swebench_internal.yaml` | 사내 환경 오버라이드 (LLM, Docker, 프록시) |
| `.env.example` → `.env` | 사내 환경변수 템플릿 (`.env`는 gitignore) |
| `scripts/setup_eval_env.sh` | 호스트 셸 환경 초기화 스크립트 |
| `data/swebench_lite_test2.jsonl` | 평가 데이터셋 |

---

## 2.4 에이전트 실행 루프 — "생각은 호스트, 실행은 Docker"

에이전트가 한 문제를 푸는 동안 호스트와 Docker 컨테이너 사이에서 다음 루프가 수십 회 반복된다.

```
┌─────────────────────────────────────────────────┐
│  호스트 (mini-swe-agent Python 프로세스)          │
│                                                  │
│  1. 문제 읽기 (problem_statement)                │
│  2. "어떻게 고칠까?" → LiteLLM → 사내 LLM       │
│  3. LLM 응답: "이 bash 명령을 실행해"            │
│                                                  │
└──────────────────┬──────────────────────────────┘
                   │ docker exec "bash 명령"
                   ▼
┌─────────────────────────────────────────────────┐
│  Docker 컨테이너 (버그 있는 코드베이스)           │
│                                                  │
│  4. bash 명령 실행 (파일 수정, 테스트 실행 등)   │
│  5. 실행 결과(stdout/stderr) 반환                │
│                                                  │
└──────────────────┬──────────────────────────────┘
                   │ 결과 반환
                   ▼
┌─────────────────────────────────────────────────┐
│  호스트                                          │
│                                                  │
│  6. 결과를 LLM에 다시 전달 → "다음 명령은?"      │
│  7. 해결될 때까지 4~6 반복                       │
│  8. 완료 시 git diff → preds.json 저장           │
│                                                  │
└─────────────────────────────────────────────────┘
```

**LLM은 생각만 하고, Docker는 손만 쓴다.** 따라서 호스트에서 litellm의 사내 CA/프록시 설정과 Docker 컨테이너 내부의 네트워크 설정이 모두 필요하다.

### 2.5 문제별 Docker 컨테이너

50개 문제는 각각 **별도의 Docker 컨테이너**에서 실행된다. 동시 실행 수는 `-w` 워커 옵션으로 조절한다.

```
문제 1: psf__requests-863      → sweb.eval.x86_64.psf_1776_requests-863:latest
문제 2: django__django-1234    → sweb.eval.x86_64.django_1776_django-1234:latest
...
문제 50: sympy__sympy-456      → sweb.eval.x86_64.sympy_1776_sympy-456:latest
```

- 각 이미지는 SWE-bench에서 **문제별로 미리 빌드하여 제공** — 버그가 있는 시점의 소스코드 + 테스트 환경 포함
- 문제 완료 후 컨테이너는 `--rm` 으로 즉시 삭제 (코드베이스 오염 방지)
- `-w 4` 설정 시 4개 컨테이너가 동시에 실행되어 병렬 처리

---

## 3. 사내 환경 구성 과정

### 3.1 환경 제약 사항

사내 네트워크 환경에서 외부 서비스를 사용하는 표준 평가 파이프라인을 그대로 실행하면 다음 문제가 발생한다.

| 계층 | 문제 | 원인 |
|------|------|------|
| 호스트 | HuggingFace 데이터셋 다운로드 실패 | SSL 인증서 오류 (사내 CA 미신뢰) |
| 호스트 | LiteLLM → 사내 LLM 호출 실패 | CA 번들 미설정 / 프록시 미설정 |
| 컨테이너 | `pip install` 실패 | 외부 PyPI 차단 + 사내 CA 미신뢰 |
| 컨테이너 | `apt-get install` 실패 | 외부 apt 미러 차단 |
| 컨테이너 | `git clone` 실패 | HTTPS 프록시 미설정 |

### 3.2 해결 전략 — 2계층 환경변수 흐름

```
.env
 │  (사내 실제 값 설정)
 ▼
source scripts/setup_eval_env.sh
 │  호스트 셸에 export
 │  ├─ SSL_CERT_FILE / REQUESTS_CA_BUNDLE / LITELLM_SSL_VERIFY  ← 호스트 litellm SSL 적용
 │  ├─ HTTP_PROXY / HTTPS_PROXY / NO_PROXY
 │  └─ MSWEA_COST_TRACKING=ignore_errors  ← 미등록 모델 비용 계산 오류 억제
 ▼
mini-extra swebench 실행
 │
 ▼
docker run
 │  swebench_internal.yaml 의 environment 설정 적용
 │  ├─ forward_env: HTTP_PROXY, HTTPS_PROXY, NO_PROXY, PIP_INDEX_URL, ...
 │  │    → docker exec -e 로 컨테이너에 주입
 │  └─ run_args: -v $CORP_CA_BUNDLE_PATH:/run/corp-ca.pem:ro
 │       → CA 파일을 컨테이너 내 /run/corp-ca.pem 으로 마운트
 ▼
env_startup_command (컨테이너 내부 1회 실행)
 │  ├─ apt sources.list → 사내 미러로 교체
 │  ├─ update-ca-certificates (corp-ca.pem 설치)
 │  ├─ pip config (index-url, cert, proxy)
 │  ├─ git config (sslCAInfo, proxy)
 │  └─ npm config (registry, cafile)
 ▼
에이전트 bash 명령 정상 실행
```

### 3.3 `swebench_internal.yaml` 구성

```yaml
model:
  model_name: "${INTERNAL_LLM_MODEL_NAME}"   # os.path.expandvars 로 런타임 치환
  model_kwargs:
    api_base: "${INTERNAL_LLM_API_BASE}"
    api_key: "${INTERNAL_LLM_API_KEY}"
    temperature: 0.0
    drop_params: true         # 사내 모델 미지원 파라미터 무시
    ssl_verify: "${CORP_CA_BUNDLE_PATH}"  # litellm SSL 인증서 경로

environment:
  forward_env:                # 호스트 env → docker exec -e 로 주입
    - HTTP_PROXY
    - HTTPS_PROXY
    - NO_PROXY
    - PIP_INDEX_URL
    - PIP_TRUSTED_HOST
    - UBUNTU_APT_MIRROR
    - ...
  run_args:                   # docker run 추가 인자
    - "--rm"
    - "-v"
    - "${CORP_CA_BUNDLE_PATH}:/run/corp-ca.pem:ro"  # CA 마운트

run:
  env_startup_command: |      # 컨테이너 기동 직후 1회 실행
    # apt 미러 교체, CA 설치, pip/git/npm 설정
```

---

## 4. 코드 수정 사항

원본 mini-swe-agent 코드에서 사내 환경 호환성을 위해 수정한 내용이다.

### 4.1 수정 목록

| 커밋 | 파일 | 변경 내용 | 이유 |
|------|------|-----------|------|
| `0aa60516` | `config/__init__.py` | YAML 로드 시 `os.path.expandvars()` 적용 | `${VAR}` 리터럴 그대로 전달되는 버그 수정 |
| `5729e045` | `run/benchmarks/swebench.py` | `env.execute(startup_command)` → `env.execute({"command": startup_command})` | `execute()`가 dict를 기대하는데 string 전달로 AttributeError 발생 |
| `afb10435` | `scripts/setup_eval_env.sh` | `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `LITELLM_SSL_VERIFY` export 추가 | 호스트 litellm의 CA 인증서 미적용으로 사내 LLM 호출 실패 |
| `6823d219` | `.env.example`, `setup_eval_env.sh` | `MSWEA_COST_TRACKING=ignore_errors` 추가 | 사내 미등록 모델의 비용 계산 예외로 실행 중단 |
| `ceb65a4c` | `swebench.py` | 로컬 JSONL 파일 직접 파싱 지원 | HuggingFace SSL 오류로 데이터셋 다운로드 불가 |
| `72095bb8` | `environments/docker.py` | `run_args` 내 `${VAR}` 확장을 위한 `model_validator` 추가 | CA 경로 env var가 docker run 인자에 미치환 |
| — | `run/benchmarks/swebench.py` | `process_instance()`에 `started_at`/`completed_at` 기록 추가 | traj.json 기반 정확한 e2e 시간 계산 |
| — | `scripts/generate_summary.py` | summary.json 생성 스크립트 신규 추가 | 채점 결과 + 실행 궤적 통합 집계 리포트 생성 |
| — | `scripts/prebuild_eval_images.sh` | CA 포함 이미지 사전 빌드 스크립트 신규 추가 | `run_evaluation` 컨테이너의 사내 CA 미신뢰로 HTTPS 요청 실패하는 문제 해결 |

### 4.2 주요 수정 상세

#### (1) YAML 환경변수 치환 (`config/__init__.py`)

```python
# 변경 전
return yaml.safe_load(path.read_text())

# 변경 후
return yaml.safe_load(os.path.expandvars(path.read_text()))
```

> `swebench_internal.yaml` 의 `${INTERNAL_LLM_MODEL_NAME}` 같은 `${VAR}` 구문이
> 치환되지 않고 그대로 litellm 에 전달되어 API 호출 실패.
> `get_config_from_spec()` 에서 파일 읽기 직후 `expandvars` 처리로 해결.

#### (2) `env.execute()` 타입 불일치 (`swebench.py`)

```python
# 변경 전 — startup_command 가 string
out = env.execute(startup_command)

# 변경 후
out = env.execute({"command": startup_command})
```

> `DockerEnvironment.execute()` 는 `action: dict` 를 기대하고 내부에서
> `action.get("command", "")` 를 호출한다. string 전달 시 AttributeError 발생.

#### (3) 로컬 JSONL 데이터셋 지원 (`swebench.py`)

```python
if dataset_path.endswith(".jsonl") and Path(dataset_path).exists():
    instances = [
        json.loads(line)
        for line in Path(dataset_path).read_text().splitlines()
        if line.strip()
    ]
elif Path(dataset_path).exists():
    from datasets import load_from_disk
    instances = list(load_from_disk(dataset_path)[split])
else:
    from datasets import load_dataset
    instances = list(load_dataset(dataset_path, split=split))
```

> 사내 환경에서 HuggingFace(`datasets.load_dataset`)로 데이터셋을 다운로드하면
> SSL 오류 발생. `curl --ssl-no-revoke` 로 사전 다운로드한 JSONL 파일을 직접 파싱.

#### (4) `MSWEA_COST_TRACKING=ignore_errors`

사내 LLM 모델은 litellm 내부 가격 데이터베이스에 등록되어 있지 않아 응답 토큰 수로 비용을 계산하는 단계에서 예외가 발생한다. 이 환경변수를 설정하면 예외를 무시하고 `$0.00` 으로 기록한다.

```bash
# .env 에 추가 (setup_eval_env.sh 가 export 처리)
MSWEA_COST_TRACKING=ignore_errors
```

---

## 5. 환경 구축 절차 (재현 가이드)

### 5.1 사전 요구사항

- Docker 설치 및 데몬 실행 (`docker info` 로 확인)
- Python 3.10 이상
- 사내 LLM OpenAI-compatible 엔드포인트 접근 가능

### 5.2 초기 설치 (최초 1회)

```bash
git clone https://github.com/hyonisss/mini-swe-agent.git
cd mini-swe-agent

# 사내 CA 인증서 지정이 필요한 경우
pip install --cert /path/to/corp-ca.pem -e .
pip install --cert /path/to/corp-ca.pem swebench
```

### 5.3 환경변수 파일 작성 (최초 1회)

```bash
cp .env.example .env
# .env 열어서 아래 항목을 실제 값으로 수정
```

| 변수 | 설명 | 예시 |
|------|------|------|
| `INTERNAL_LLM_MODEL_NAME` | litellm 모델 식별자 | `openai/llama-3.1-70b` |
| `INTERNAL_LLM_API_BASE` | OpenAI-compatible 엔드포인트 | `http://llm.corp.local/v1` |
| `INTERNAL_LLM_API_KEY` | API 키 | `none` (불필요 시) |
| `HTTP_PROXY` / `HTTPS_PROXY` | 사내 프록시 | `http://proxy.corp.local:8080` |
| `NO_PROXY` | 프록시 우회 목록 | `localhost,10.0.0.0/8` |
| `UBUNTU_APT_MIRROR` | Ubuntu apt 미러 | `http://apt.corp.local/ubuntu` |
| `PIP_INDEX_URL` | 내부 PyPI URL | `https://pypi.corp.local/simple` |
| `PIP_TRUSTED_HOST` | PyPI 신뢰 호스트 | `pypi.corp.local` |
| `CORP_CA_BUNDLE_PATH` | 사내 CA PEM 절대 경로 | `/etc/ssl/certs/corp-ca.pem` |
| `MSWEA_COST_TRACKING` | 비용 계산 오류 처리 | `ignore_errors` |

### 5.4 환경 초기화 (매 세션마다)

```bash
# 반드시 source 로 실행 — bash 로 실행하면 현재 셸에 export 되지 않음
source scripts/setup_eval_env.sh
```

성공 시 출력 예시:

```
================================================================
 환경변수 로드 완료
----------------------------------------------------------------
 LLM 모델      : openai/your-model
 LLM 주소      : http://llm.corp.local/v1
 프록시        : http://proxy.corp.local:8080
 CA 번들       : /etc/ssl/certs/corp-ca.pem
 비용 추적     : ignore_errors
================================================================
```

### 5.5 평가 이미지에 CA 인증서 사전 설치 (사내 네트워크 필수)

`swebench.harness.run_evaluation`은 자체 Docker 컨테이너를 관리하며 `swebench_internal.yaml`의
`env_startup_command`가 적용되지 않는다. 따라서 채점 컨테이너 내부에서 HTTPS 요청 시 사내 CA를
신뢰하지 못해 SSL 오류가 발생한다.

`prebuild_eval_images.sh`가 평가 이미지를 pull하고 사내 CA 인증서 레이어를 추가해 동일 태그로 덮어씌운다.

```bash
# 반드시 source scripts/setup_eval_env.sh 실행 후 수행
bash scripts/prebuild_eval_images.sh
```

> 이미 CA 레이어가 추가된 이미지는 자동 스킵된다 (Docker 라벨 `corp-ca-installed=true`).

### 5.6 Docker 이미지 사전 pull (권장)

50개 문제 각각에 대응하는 Docker 이미지를 미리 받아두면 평가 중 네트워크 오류를 예방할 수 있다.
(`prebuild_eval_images.sh`가 pull도 자동 수행하므로 별도 실행은 필요 없을 수 있다.)

```bash
python3 - <<'EOF'
import json, subprocess
instances = [json.loads(l) for l in open("data/swebench_lite_test2.jsonl")]
for inst in instances:
    iid = inst["instance_id"].replace("__", "_1776_")
    image = f"docker.io/swebench/sweb.eval.x86_64.{iid}:latest".lower()
    print(f"Pulling {image} ...")
    subprocess.run(["docker", "pull", image], check=False)
EOF
```

---

## 6. 평가 실행

### 6.1 파일럿 실행 (5개 문제로 설정 검증)

```bash
mini-extra swebench \
  -c swebench.yaml \
  -c swebench_internal.yaml \
  --subset ./data/swebench_lite_test2.jsonl \
  --slice 0:5 \
  -o ./results/pilot \
  -w 1
```

검증 체크리스트:

- [ ] 컨테이너 기동 후 `[corp-setup] Corporate environment configured.` 출력 확인
- [ ] 사내 LLM 호출 정상 응답 (`minisweagent.log` 에서 스텝 진행 확인)
- [ ] `results/pilot/preds.json` 에 5개 결과 저장 확인
- [ ] 에러 없이 완료 또는 `exit_status: submitted` 확인

### 6.2 본 평가 실행 (50개 전체)

```bash
mini-extra swebench \
  -c swebench.yaml \
  -c swebench_internal.yaml \
  --subset ./data/swebench_lite_test2.jsonl \
  -o ./results/my-model \
  -w 4
```

| 옵션 | 설명 |
|------|------|
| `-w 4` | 병렬 워커 수 (서버 코어 수 고려하여 조정) |
| `--redo-existing` | 완료된 문제 포함 처음부터 재실행 |

### 6.3 모니터링

```bash
# 실시간 로그
tail -f results/my-model/minisweagent.log

# 완료 문제 수 확인
cat results/my-model/preds.json | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(f'완료: {len(d)}개')"
```

---

## 7. 채점 및 결과 분석

### 7.1 채점 실행

```bash
python -m swebench.harness.run_evaluation \
  --dataset_name ./data/swebench_lite_test2.jsonl \
  --predictions_path ./results/my-model/preds.json \
  --max_workers 4 \
  --run_id my-model-eval
```

### 7.2 주요 지표 추출

```bash
cat logs/run_evaluation/<model>.my-model-eval.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
resolved = len(d['resolved_ids'])
total = d['total_instances']
print(f'Resolved Rate : {resolved}/{total} ({resolved/total*100:.1f}%)')
"
```

### 7.3 summary.json 생성

채점 결과와 에이전트 실행 궤적을 통합하여 레퍼런스 포맷의 요약 파일을 생성한다.

```bash
python scripts/generate_summary.py results/my-model \
  --eval-results logs/run_evaluation \
  --run-id my-model-eval \
  --dataset data/swebench_lite_test2.jsonl
```

출력: `results/my-model/summary.json`

생성 파일에는 per-task 결과(비용, 토큰, 스텝 수, resolved 여부, fail_to_pass 카운트)와 전체 집계 지표(Resolved Rate, 평균 비용, 평균 스텝 등)가 포함된다.

### 7.4 결과 디렉토리 구조

```
results/
└── my-model/
    ├── preds.json                          ← 에이전트 제출 패치 전체
    ├── summary.json                        ← 통합 요약 리포트
    ├── minisweagent.log                    ← 실행 로그
    ├── exit_statuses_<timestamp>.yaml      ← 인스턴스별 종료 상태
    └── psf__requests-863/
        └── psf__requests-863.traj.json    ← 에이전트 실행 궤적

logs/run_evaluation/
├── <model>.my-model-eval.json             ← Resolved Rate 등 집계
└── my-model-eval/
    └── <model>/
        └── <instance_id>/
            └── report.json                ← 인스턴스별 테스트 결과
```

### 7.4 오답 케이스 분석

```bash
# 특정 인스턴스 제출 패치 확인
cat results/my-model/<instance_id>/<instance_id>.traj.json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['info']['submission'])"

# 종료 상태 전체 요약
cat results/my-model/exit_statuses_*.yaml
```

---

## 8. 비교 기준

| 모델 | SWE-bench Lite Resolved Rate |
|------|------------------------------|
| Claude Sonnet 4.5 (mini-swe-agent v2) | ~45–55% |
| GPT-4o | ~30–40% |
| **사내 모델 (목표)** | **측정 예정** |

> 위 수치는 공개 리더보드 기준이며, 문제 구성 차이가 있을 수 있다.
> 절대값 비교보다 동일 데이터셋 기준의 **상대적 개선 추이** 확인에 활용한다.

---

## 9. 트러블슈팅 이력

구축 과정에서 발생한 주요 문제와 해결 방법이다.

| # | 증상 | 원인 | 해결 |
|---|------|------|------|
| 1 | `datasets.load_dataset` SSL 오류 | HuggingFace 인증서 미신뢰 | `curl --ssl-no-revoke` 로 사전 다운로드, 로컬 JSONL 파싱 추가 |
| 2 | `${INTERNAL_LLM_MODEL_NAME}` 미치환 | `yaml.safe_load` 는 env var 치환 안 함 | `os.path.expandvars()` 래핑 추가 |
| 3 | `AttributeError: 'str' object has no attribute 'get'` | `env.execute()` 에 string 전달 | `{"command": startup_command}` dict 로 변경 |
| 4 | 호스트 litellm SSL/프록시 오류 | Python HTTP 라이브러리 CA 미설정 | `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `LITELLM_SSL_VERIFY` export |
| 5 | 비용 계산 예외로 로그 오염 | 사내 모델이 litellm DB 미등록 | `MSWEA_COST_TRACKING=ignore_errors` 설정 |
| 6 | `source setup_eval_env.sh` 실행 중 셸 종료 | `set -euo pipefail` + pip 실패 | `set -euo pipefail` 제거, 개별 명령 에러 처리로 변경 |
| 7 | `docker run_args` 의 `${VAR}` 미치환 | Pydantic 모델 생성 시점에 미확장 | `model_validator(mode="after")` 로 `run_args` expandvars 처리 |
| 8 | 채점 컨테이너 내 HTTPS 요청 SSL 오류 (httpbin.org 등) | `run_evaluation`이 자체 컨테이너 관리 — `env_startup_command` 미적용으로 사내 CA 미설치 | `scripts/prebuild_eval_images.sh` 로 평가 이미지에 CA 레이어 사전 추가 |

---

## 10. 향후 계획

- [ ] 사내 모델 전체 50문제 평가 실행
- [ ] Resolved Rate 측정 및 기준 모델과 비교
- [ ] `scripts/generate_summary.py` 로 summary.json 생성 및 결과 정리
- [ ] 모델 버전별 비교 평가 체계화 (`results/<model-version>/` 구조)
- [ ] 실패 케이스 패턴 분석 (`traj.json` 활용)
- [ ] 워커 수 / max_iterations 파라미터 튜닝 실험
