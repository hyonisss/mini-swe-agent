# 사내 LLM SWE-bench 평가 설계서

> **목적**: mini-swe-agent v2를 활용하여 사내 LLM 모델의 소프트웨어 엔지니어링 자동화 능력을 SWE-bench Lite 기준으로 정량 평가한다.

---

## 1. 평가 개요

| 항목 | 내용 |
|------|------|
| 평가 프레임워크 | [mini-swe-agent v2](https://mini-swe-agent.com/latest/) |
| 벤치마크 | SWE-bench Lite (커스텀 서브셋) |
| 평가 문제 수 | 50개 |
| 문제 출처 | `data/swebench_lite_test2.jsonl` |
| 평가 환경 | 사내 서버 (Docker 필요) |
| 결과 저장 위치 | `results/<model-name>/` |

### 평가 지표

- **Resolved Rate** (`%resolved`): 에이전트가 생성한 패치가 실제로 테스트를 통과한 문제의 비율 (주요 지표)
- **Submission Rate**: 에이전트가 정상적으로 패치를 제출한 문제의 비율 (포기/에러 제외)
- **평균 비용** (토큰 기준): 문제당 평균 LLM 호출 비용
- **평균 스텝 수**: 문제당 평균 에이전트 실행 스텝

---

## 2. 평가 데이터셋

### 데이터셋 정보

- **원본 소스**: `https://github.com/joyon1104/coding-agent-eval/blob/master/data/swebench_lite_test2.jsonl`
- **로컬 경로**: `./data/swebench_lite_test2.jsonl`
- **문제 수**: 50개
- **포맷**: SWE-bench 표준 포맷 (JSONL)

### 대상 오픈소스 프로젝트 (11개 리포지토리)

| 프로젝트 | 도메인 |
|---------|--------|
| `astropy/astropy` | 천문학 라이브러리 |
| `django/django` | 웹 프레임워크 |
| `mwaskom/seaborn` | 데이터 시각화 |
| `pallets/flask` | 웹 마이크로프레임워크 |
| `psf/requests` | HTTP 클라이언트 |
| `pydata/xarray` | 다차원 배열 처리 |
| `pylint-dev/pylint` | 코드 정적 분석 |
| `pytest-dev/pytest` | 테스트 프레임워크 |
| `scikit-learn/scikit-learn` | 머신러닝 라이브러리 |
| `sphinx-doc/sphinx` | 문서 생성 도구 |
| `sympy/sympy` | 심볼릭 수학 |

### 각 문제의 구성 요소

```
instance_id        : 고유 식별자 (예: psf__requests-863)
repo               : 대상 리포지토리
base_commit        : 문제 발생 시점의 커밋 해시
problem_statement  : 버그/기능 요청 설명 (에이전트에게 주어지는 입력)
patch              : 정답 패치 (평가 시 비교 기준)
test_patch         : 검증용 테스트 코드
FAIL_TO_PASS       : 수정 후 통과해야 하는 테스트
PASS_TO_PASS       : 기존 통과 상태를 유지해야 하는 테스트
```

---

## 3. 시스템 구성

### 구성 요소 관계

```
┌─────────────────────────────────────────────────┐
│                 mini-swe-agent v2                │
│                                                  │
│  ┌──────────┐   ┌───────────┐   ┌────────────┐  │
│  │  Agent   │──▶│   Model   │──▶│  사내 LLM  │  │
│  │(Default) │   │(LiteLLM)  │   │  Endpoint  │  │
│  └────┬─────┘   └───────────┘   └────────────┘  │
│       │                                          │
│  ┌────▼─────────────────────────┐               │
│  │  Environment (Docker)        │               │
│  │  swebench/sweb.eval.x86_64.* │               │
│  └──────────────────────────────┘               │
└─────────────────────────────────────────────────┘
         │
         ▼
  results/<model>/
  ├── preds.json          ← 제출 패치 모음
  ├── <instance_id>/
  │   └── <id>.traj.json ← 에이전트 실행 궤적
  └── minisweagent.log
```

### 핵심 설정 파일

| 파일 | 역할 |
|------|------|
| `src/minisweagent/config/benchmarks/swebench.yaml` | 기본 에이전트/환경 설정 |
| `src/minisweagent/config/benchmarks/swebench_internal.yaml` | 사내 LLM + Docker 환경 오버라이드 |
| `.env.example` → `.env` | 사내 환경변수 템플릿 (`.env`는 gitignore) |
| `scripts/setup_eval_env.sh` | 호스트 셋업 자동화 스크립트 |
| `data/swebench_lite_test2.jsonl` | 평가 문제 데이터셋 |

---

## 3.5. 사내 네트워크 환경 설정

사내 네트워크에서 평가를 실행하면 Docker 컨테이너 내부에서 pip, apt, git 작업이 실패할 수 있다. 원인과 해결 방법:

| 문제 | 원인 | 해결 |
|------|------|------|
| pip/apt SSL 오류 | 사내 CA 인증서 없음 | CA 파일을 컨테이너에 볼륨 마운트 후 설치 |
| 외부 패키지 서버 접근 불가 | 방화벽/프록시 | 내부 미러로 apt sources.list 교체 |
| git clone 실패 | 프록시 미설정 | `HTTP_PROXY` 등을 컨테이너에 forward |

### 설정 흐름

```
.env.example ──copy──> .env ──source──> setup_eval_env.sh
                                              │
                                 ┌────────────┴─────────────┐
                                 │ 환경변수 export            │
                                 │ .venv 생성/활성화          │
                                 │ pip install mini-swe-agent │
                                 │ pip install swebench       │
                                 └────────────┬─────────────┘
                                              │
                                   mini-extra swebench 실행
                                              │
                         ┌────────────────────┴───────────────────┐
                         │ docker run                              │
                         │   -v $CORP_CA_BUNDLE_PATH:/run/corp-ca.pem:ro │
                         └────────────────────┬───────────────────┘
                                              │
                         ┌────────────────────┴───────────────────┐
                         │ docker exec (env_startup_command)       │
                         │   apt sources.list → 내부 미러 교체      │
                         │   CA cert 설치 (update-ca-certificates) │
                         │   pip / git / npm 설정                  │
                         └────────────────────────────────────────┘
```

### 설정 절차

**Step A: `.env` 파일 생성**

```bash
cp .env.example .env
```

`.env`를 열어 아래 항목을 실제 사내 값으로 채운다.

| 변수 | 설명 |
|------|------|
| `INTERNAL_LLM_MODEL_NAME` | 사내 LLM 모델명 (예: `openai/llama-3.1-70b`) |
| `INTERNAL_LLM_API_BASE` | OpenAI 호환 엔드포인트 URL |
| `INTERNAL_LLM_API_KEY` | API 키 (불필요 시 `none`) |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | 사내 프록시 |
| `UBUNTU_APT_MIRROR` | 내부 Ubuntu apt 미러 URL |
| `DEBIAN_APT_MIRROR` | 내부 Debian apt 미러 URL |
| `DEBIAN_SECURITY_MIRROR` | 내부 Debian security 미러 URL |
| `NPM_REGISTRY` | 내부 npm 레지스트리 URL |
| `CORP_CA_BUNDLE_PATH` | 호스트의 CA 번들 PEM 파일 절대 경로 |

**Step B: 셋업 스크립트 실행 (`source` 필수)**

```bash
source scripts/setup_eval_env.sh
```

> `bash scripts/setup_eval_env.sh` 또는 `./scripts/setup_eval_env.sh`로 실행하면
> 환경변수가 현재 셸에 export되지 않으므로 반드시 `source`를 사용한다.

스크립트가 완료되면 아래가 자동으로 처리된 상태가 된다.
- `.env` 로드 및 유효성 검사 완료
- Docker 데몬 동작 확인 완료
- `.venv/` 생성 및 활성화 완료
- `pip install -e .` (mini-swe-agent) 완료
- `pip install swebench` (채점 도구) 완료

**Step C: 새 터미널 세션에서 재활성화**

새 터미널을 열 때마다 다시 실행한다:

```bash
source scripts/setup_eval_env.sh
```

---

## 4. 사전 준비

### 4-1. 환경 요구사항 확인

```bash
# Docker 설치 확인
docker --version

# Docker 데몬 실행 확인
docker info
```

> Python 패키지 설치는 `source scripts/setup_eval_env.sh` 가 자동으로 처리한다.

### 4-2. 사내 LLM 및 네트워크 설정

`swebench_internal.yaml`을 직접 수정하지 않는다. 대신 `.env` 파일에서 값을 설정하고 `source scripts/setup_eval_env.sh` 로 로드한다.

```bash
# .env 에서 수정할 핵심 항목
INTERNAL_LLM_MODEL_NAME=openai/your-model-name
INTERNAL_LLM_API_BASE=http://your-internal-llm-host/v1
INTERNAL_LLM_API_KEY=your-api-key
CORP_CA_BUNDLE_PATH=/etc/ssl/certs/corp-ca-bundle.pem
```

### 4-3. 데이터셋 확인

데이터셋은 repo에 포함되어 있으므로 `git clone` 후 별도 다운로드 없이 바로 사용 가능하다.

```bash
# 파일 존재 및 문제 수 확인
wc -l data/swebench_lite_test2.jsonl
# 예상 출력: 50 data/swebench_lite_test2.jsonl
```

### 4-4. SWE-bench Docker 이미지 사전 pull (선택)

각 문제 실행 시 자동으로 pull되지만, 사내 네트워크 속도가 느릴 경우 미리 받아두면 좋다.

```bash
# 예시: requests 관련 이미지
docker pull swebench/sweb.eval.x86_64.psf_1776_requests-863:latest
```

사내 Docker Registry에 미러링이 필요한 경우 `swebench_internal.yaml`의 `environment` 섹션에 커스텀 레지스트리 주소를 추가한다.

---

## 5. 평가 실행

### 5-1. 소규모 검증 (권장 — 본 실행 전)

전체 실행 전 5개 문제로 설정이 정상인지 확인한다.

```bash
mini-extra swebench \
  -c swebench.yaml \
  -c swebench_internal.yaml \
  --subset ./data/swebench_lite_test2.jsonl \
  --slice 0:5 \
  -o ./results/my-model-pilot \
  -w 1
```

확인 항목:
- [ ] 에이전트가 문제를 정상적으로 읽는지
- [ ] 사내 LLM 호출이 성공하는지 (`minisweagent.log` 확인)
- [ ] Docker 컨테이너가 정상 생성되는지
- [ ] `preds.json`에 결과가 저장되는지

### 5-2. 본 평가 실행

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
| `-c swebench.yaml` | 기본 에이전트/환경 설정 로드 |
| `-c swebench_internal.yaml` | 사내 LLM 설정으로 오버라이드 |
| `--subset` | 로컬 JSONL 데이터셋 경로 |
| `-o` | 결과 저장 디렉토리 |
| `-w 4` | 병렬 실행 워커 수 (서버 사양에 맞게 조정) |

### 5-3. 중단 후 재개

평가 중 중단되더라도 `preds.json`에 완료된 결과가 저장되어 있으므로 동일 명령을 재실행하면 미완료 문제만 이어서 실행된다. 처음부터 다시 실행하려면 `--redo-existing` 플래그를 추가한다.

### 5-4. 실행 중 모니터링

```bash
# 실시간 로그 확인
tail -f results/my-model/minisweagent.log

# 현재까지 완료된 문제 수 확인
cat results/my-model/preds.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'완료: {len(d)}개')"
```

---

## 6. 결과 채점

mini-swe-agent는 패치 제출까지만 수행한다. 실제 테스트 통과 여부(Resolved Rate)는 SWE-bench 공식 평가 도구로 채점한다.

### 6-1. 채점 도구 설치

```bash
pip install swebench
```

### 6-2. 채점 실행

```bash
python -m swebench.harness.run_evaluation \
  --dataset_name ./data/swebench_lite_test2.jsonl \
  --predictions_path ./results/my-model/preds.json \
  --max_workers 4 \
  --run_id my-model-eval
```

### 6-3. 결과 확인

채점 완료 후 `results/` 아래에 `<run_id>` 디렉토리가 생성되며, 아래 파일들을 확인한다.

```
results/my-model-eval/
├── results.json        ← 전체 요약 (resolved_instances, total_instances, ...)
└── logs/               ← 인스턴스별 테스트 실행 로그
```

주요 지표 추출:

```bash
cat results/my-model-eval/results.json | python3 -c "
import json, sys
d = json.load(sys.stdin)
total = d['total_instances']
resolved = d['resolved_instances']
print(f'Resolved Rate : {resolved}/{total} ({resolved/total*100:.1f}%)')
"
```

---

## 7. 비교 기준 (참고)

향후 보고서 작성 시 비교 참고값으로 활용한다.

| 모델 | SWE-bench Lite Resolved Rate |
|------|------------------------------|
| Claude Sonnet 4.5 (mini-swe-agent v2 기본) | ~45–55% (버전에 따라 상이) |
| GPT-4o | ~30–40% |
| Gemini 1.5 Pro | ~74% (SWE-bench Verified 기준) |

> 위 수치는 공개 리더보드 기준이며, 문제 구성이 다를 수 있으므로 절대적 비교보다 **상대적 개선 추이** 확인에 활용한다.

---

## 8. 결과 디렉토리 구조

평가 완료 후 예상 디렉토리 구조:

```
results/
└── my-model/
    ├── preds.json                         ← 에이전트 제출 패치 전체
    ├── minisweagent.log                   ← 실행 로그
    ├── exit_statuses_<timestamp>.yaml     ← 종료 상태 요약
    └── psf__requests-863/
        └── psf__requests-863.traj.json   ← 에이전트 실행 궤적 (메시지 전체)
```

### `traj.json` 활용

에이전트의 사고 과정, 실행 명령, 출력을 전부 포함하므로 오답 케이스 분석 시 유용하다.

```bash
# 특정 인스턴스의 최종 제출 확인
cat results/my-model/psf__requests-863/psf__requests-863.traj.json \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['info']['submission'])"
```

---

## 9. 코드 수정 이력 (재현성 확보)

이 평가를 위해 mini-swe-agent 원본 코드에서 변경된 부분:

| 파일 | 변경 내용 | 이유 |
|------|-----------|------|
| `src/minisweagent/run/benchmarks/swebench.py` | 로컬 JSONL 파일 직접 파싱 지원 추가 | 사내 환경 SSL 오류로 HuggingFace 직접 접근 불가 |
| `src/minisweagent/config/benchmarks/swebench_internal.yaml` | 사내 LLM 엔드포인트 config 추가 | 사내 모델 연동 |
| `scripts/download_swebench_lite.py` | URL 직접 다운로드 스크립트 추가 | SSL 우회(curl `--ssl-no-revoke`) 방식으로 데이터 확보 |

### 핵심 코드 변경 (swebench.py)

```python
# 변경 전
from datasets import load_dataset
instances = list(load_dataset(dataset_path, split=split))

# 변경 후 — 로컬 .jsonl 파일이면 직접 파싱, 아니면 기존 방식
if dataset_path.endswith(".jsonl") and Path(dataset_path).exists():
    instances = [json.loads(line) for line in Path(dataset_path).read_text().splitlines() if line.strip()]
elif Path(dataset_path).exists():
    from datasets import load_from_disk
    instances = list(load_from_disk(dataset_path)[split])
else:
    from datasets import load_dataset
    instances = list(load_dataset(dataset_path, split=split))
```
