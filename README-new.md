# 사내 LLM SWE-bench 평가 실행 가이드

## 사전 요구사항

- Docker 설치 및 데몬 실행 중
- Python 3.10 이상
- 사내 LLM OpenAI-compatible 엔드포인트 접근 가능

---

## 실행 순서

### 1. 클론

```bash
git clone https://github.com/hyonisss/mini-swe-agent.git
cd mini-swe-agent
```

### 2. 초기 설치 (최초 1회)

```bash
pip install -e .
pip install swebench
```

> 사내 네트워크에서 SSL 오류가 발생하면 `pip install --cert /path/to/corp-ca.pem -e .` 로 실행한다.

### 3. 환경변수 파일 작성 (최초 1회)

```bash
cp .env.example .env
```

`.env` 를 열어 아래 항목을 실제 사내 값으로 수정한다.

```bash
INTERNAL_LLM_MODEL_NAME=openai/<모델명>
INTERNAL_LLM_API_BASE=http://<LLM-호스트>/v1
INTERNAL_LLM_API_KEY=<API-키>

HTTP_PROXY=http://<프록시-호스트>:<포트>
HTTPS_PROXY=http://<프록시-호스트>:<포트>
NO_PROXY=localhost,127.0.0.1,<사내-도메인>

UBUNTU_APT_MIRROR=http://<내부-apt-미러>/ubuntu
DEBIAN_APT_MIRROR=http://<내부-apt-미러>/debian
DEBIAN_SECURITY_MIRROR=http://<내부-apt-미러>/debian-security

PIP_INDEX_URL=https://<내부-pypi>/simple
PIP_TRUSTED_HOST=<내부-pypi-호스트>

NPM_REGISTRY=https://<내부-npm-레지스트리>

CORP_CA_BUNDLE_PATH=/etc/ssl/certs/<사내-CA-번들>.pem
```

> `.env` 에 설정하는 값들은 평가 실행 시 Docker 컨테이너 내부로 전달되어
> 컨테이너 안에서 apt, pip, git, npm 이 사내 환경을 사용하도록 설정된다.

### 4. 사내 환경변수 로드 (매 세션마다)

> **반드시 `source` 로 실행** (`bash` 로 실행하면 현재 셸에 export 되지 않음)

```bash
source scripts/setup_eval_env.sh
```

성공 시 사내 설정값 요약이 출력된다.

### 5. Docker 프록시 설정 (사내 네트워크 필수)

채점(`swebench run_evaluation`) 시 Docker 컨테이너 내부에서 apt-get 이 외부 Ubuntu 미러에
접근하지 못하는 문제를 방지하기 위해 Docker 클라이언트 프록시를 설정한다.

> **반드시 `source scripts/setup_eval_env.sh` 실행 후** 아래 명령을 실행한다.

```bash
bash scripts/setup_docker_proxy.sh
```

성공 시 출력 예시:

```
================================================================
 Docker 프록시 설정 완료
----------------------------------------------------------------
 httpProxy  : http://proxy.corp.example.com:8080
 httpsProxy : http://proxy.corp.example.com:8080
 noProxy    : localhost,127.0.0.1,...
----------------------------------------------------------------
 이후 Docker 가 실행하는 모든 컨테이너에 위 프록시가 자동 주입됩니다.
================================================================
```

> sudo 불필요. `~/.docker/config.json` 에 유저 레벨로 저장되며 최초 1회만 실행하면 된다.
> 프록시 주소가 바뀐 경우 다시 실행한다.

### 6. 평가 이미지에 CA 인증서 + 프록시 사전 설치 (사내 네트워크 필수)

채점 단계(`swebench run_evaluation`)는 docker-py(Python SDK)로 자체 컨테이너를 관리하므로
`swebench_internal.yaml` 의 `env_startup_command` 와 `forward_env` 가 **적용되지 않는다**.
이로 인해 두 가지 문제가 발생한다:

- 사내 CA 를 신뢰하지 못해 HTTPS 요청에서 SSL 오류 발생
- 프록시가 설정되지 않아 테스트 코드의 외부 HTTP 요청이 502 오류로 실패

아래 스크립트가 평가 이미지를 pull 한 뒤 **사내 CA 인증서 설치와 프록시 환경변수(`HTTP_PROXY` 등)** 를 포함한 레이어를 추가해 동일 태그로 덮어씌운다.

> **반드시 `source scripts/setup_eval_env.sh` 실행 후** 아래 명령을 실행한다.

```bash
bash scripts/prebuild_eval_images.sh
```

성공 시 출력 예시:

```
================================================================
 prebuild_eval_images.sh 완료
----------------------------------------------------------------
 성공 (빌드됨) : 50개
 스킵 (기존)   : 0개
 실패          : 0개
 합계          : 50개
================================================================
```

> 이미지 pull 후 CA 설치 + 프록시 ENV 주입을 한 번에 수행한다.
> CA 와 프록시가 모두 설치된 이미지는 자동으로 스킵한다(`corp-ca-installed` + `corp-proxy-injected` 라벨로 판별).
> CA만 설치된 구버전 이미지는 재빌드되어 프록시 ENV 가 추가된다.
> `--dry-run` 옵션으로 이미지 목록만 먼저 확인할 수 있다.
> Docker Hub 접근이 불가한 경우 사내 Docker Registry 에 이미지를 미러링해야 한다.

### 7. 파일럿 실행 (5개 문제로 설정 검증)

```bash
mini-extra swebench \
  -c swebench.yaml \
  -c swebench_internal.yaml \
  --subset ./data/swebench_lite_test2.jsonl \
  --slice 0:5 \
  -o ./results/pilot \
  -w 1
```

로그 확인:
```bash
tail -f results/pilot/minisweagent.log
```

`[corp-setup] Corporate environment configured.` 메시지가 보이면 컨테이너 환경 설정 성공.

### 8. 본 평가 실행 (50개 전체)

```bash
mini-extra swebench \
  -c swebench.yaml \
  -c swebench_internal.yaml \
  --subset ./data/swebench_lite_test2.jsonl \
  -o ./results/my-model \
  -w 4
```

중단 후 재개 시 동일 명령을 재실행하면 완료된 문제는 건너뛴다.

### 9. 채점

```bash
python -m swebench.harness.run_evaluation \
  --dataset_name ./data/swebench_lite_test2.jsonl \
  --predictions_path ./results/my-model/preds.json \
  --max_workers 4 \
  --run_id my-model-eval
```

결과 확인:
```bash
cat <model>.my-model-eval.json | python3 -c "
import json, sys; d = json.load(sys.stdin)
resolved = len(d['resolved_ids']); total = d['total_instances']
print(f'Resolved Rate: {resolved}/{total} ({resolved/total*100:.1f}%)')
"
```

> swebench 는 요약 `.json` 파일을 **현재 디렉터리**에 저장한다 (`<model_name_or_path>.<run_id>.json`).
> 상세 로그(인스턴스별 `report.json`)는 `logs/run_evaluation/` 하위에 저장된다.

### 10. summary.json 생성 (채점 후 실행)

채점 결과와 에이전트 실행 궤적을 합쳐 전체 평가 요약 파일을 생성한다.

```bash
python scripts/generate_summary.py results/my-model \
  --eval-results . \
  --run-id my-model-eval \
  --dataset data/swebench_lite_test2.jsonl
```

출력: `results/my-model/summary.json`

파일에는 인스턴스별 결과(resolved, 비용, 토큰, 스텝 수, fail_to_pass 카운트)와 전체 지표(Resolved Rate, 평균 비용 등)가 포함된다.

---

## 새 터미널 세션에서 재시작할 때

```bash
cd mini-swe-agent
source scripts/setup_eval_env.sh
```

---

## 참고 문서

- 상세 설계서: [`docs/eval_plan_swebench_internal.md`](docs/eval_plan_swebench_internal.md)
- 환경변수 전체 목록: [`.env.example`](.env.example)
