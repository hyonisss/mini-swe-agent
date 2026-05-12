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

### 5. SWE-bench Docker 이미지 사전 pull (선택, 권장)

평가 실행 전에 필요한 이미지를 미리 받아두면 평가 중 네트워크 오류로 인한 실패를 예방할 수 있다.

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

> Docker Hub 접근이 불가한 경우 사내 Docker Registry 에 이미지를 미러링해야 한다.
> 미러링 후 `swebench_internal.yaml` 의 `environment.image` 에 내부 레지스트리 주소를 지정한다.

### 6. 파일럿 실행 (5개 문제로 설정 검증)

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

### 7. 본 평가 실행 (50개 전체)

```bash
mini-extra swebench \
  -c swebench.yaml \
  -c swebench_internal.yaml \
  --subset ./data/swebench_lite_test2.jsonl \
  -o ./results/my-model \
  -w 4
```

중단 후 재개 시 동일 명령을 재실행하면 완료된 문제는 건너뛴다.

### 8. 채점

```bash
python -m swebench.harness.run_evaluation \
  --dataset_name ./data/swebench_lite_test2.jsonl \
  --predictions_path ./results/my-model/preds.json \
  --max_workers 4 \
  --run_id my-model-eval
```

결과 확인:
```bash
cat results/my-model-eval/results.json
```

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
