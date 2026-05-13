#!/usr/bin/env bash
# =============================================================================
# scripts/setup_docker_proxy.sh
# Docker 클라이언트 프록시 설정 스크립트
#
# 사내 네트워크에서 채점(swebench run_evaluation) 시 Docker 컨테이너 내부의
# apt-get 이 외부 Ubuntu 미러에 접근하지 못하는 문제를 해결한다.
#
# 이 스크립트가 하는 일:
#   ~/.docker/config.json 에 프록시 설정을 추가하여
#   Docker 가 실행하는 모든 컨테이너에 HTTP_PROXY, HTTPS_PROXY, NO_PROXY 를
#   자동으로 주입하도록 한다.
#
# 사전 조건:
#   source scripts/setup_eval_env.sh  # HTTP_PROXY 등 환경변수 로드 후 실행
#
# 실행:
#   bash scripts/setup_docker_proxy.sh
#
# sudo 불필요 — 유저 레벨 Docker 클라이언트 설정
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. 필수 환경변수 확인
# ---------------------------------------------------------------------------
if [[ -z "${HTTP_PROXY:-}" || -z "${HTTPS_PROXY:-}" || -z "${NO_PROXY:-}" ]]; then
    echo "[docker-proxy] ERROR: HTTP_PROXY, HTTPS_PROXY, NO_PROXY 가 설정되지 않았습니다."
    echo "        먼저 다음을 실행하세요:"
    echo "          source scripts/setup_eval_env.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. ~/.docker 디렉토리 생성
# ---------------------------------------------------------------------------
mkdir -p ~/.docker

# ---------------------------------------------------------------------------
# 3. config.json 작성 (기존 설정 보존)
# ---------------------------------------------------------------------------
CONFIG_FILE="${HOME}/.docker/config.json"

if [[ -f "${CONFIG_FILE}" ]]; then
    # 기존 파일이 있으면 proxies 키만 추가/덮어쓰기 (python3 으로 merge)
    python3 - << PYEOF
import json, os, sys

config_file = os.path.expanduser("~/.docker/config.json")
with open(config_file) as f:
    config = json.load(f)

config["proxies"] = {
    "default": {
        "httpProxy":  os.environ["HTTP_PROXY"],
        "httpsProxy": os.environ["HTTPS_PROXY"],
        "noProxy":    os.environ["NO_PROXY"],
    }
}

with open(config_file, "w") as f:
    json.dump(config, f, indent=2)

print(f"[docker-proxy] 기존 {config_file} 에 proxies 설정을 추가했습니다.")
PYEOF
else
    # 신규 생성
    cat > "${CONFIG_FILE}" << EOF
{
  "proxies": {
    "default": {
      "httpProxy":  "${HTTP_PROXY}",
      "httpsProxy": "${HTTPS_PROXY}",
      "noProxy":    "${NO_PROXY}"
    }
  }
}
EOF
    echo "[docker-proxy] ${CONFIG_FILE} 을 새로 생성했습니다."
fi

# ---------------------------------------------------------------------------
# 4. 완료 메시지
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " Docker 프록시 설정 완료"
echo "----------------------------------------------------------------"
echo " httpProxy  : ${HTTP_PROXY}"
echo " httpsProxy : ${HTTPS_PROXY}"
echo " noProxy    : ${NO_PROXY}"
echo "----------------------------------------------------------------"
echo " 이후 Docker 가 실행하는 모든 컨테이너에 위 프록시가 자동 주입됩니다."
echo " (채점 컨테이너의 apt-get 이 프록시를 통해 외부 Ubuntu 미러에 접근)"
echo "================================================================"
