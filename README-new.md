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

### 2. 환경변수 파일 작성

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

### 3. 셋업 스크립트 실행

> **반드시 `source` 로 실행** (`bash` 로 실행하면 환경변수가 현재 셸에 유지되지 않음)

```bash
source scripts/setup_eval_env.sh
```

이 명령 하나로 아래가 자동 완료된다.
- `.env` 유효성 검사
- Docker 데몬 동작 확인
- `.venv/` 생성 및 활성화
- `pip install -e .` (mini-swe-agent)
- `pip install swebench` (채점 harness)

### 4. 파일럿 실행 (5개 문제로 설정 검증)

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

### 5. 본 평가 실행 (50개 전체)

```bash
mini-extra swebench \
  -c swebench.yaml \
  -c swebench_internal.yaml \
  --subset ./data/swebench_lite_test2.jsonl \
  -o ./results/my-model \
  -w 4
```

중단 후 재개 시 동일 명령을 재실행하면 완료된 문제는 건너뛴다.

### 6. 채점

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
