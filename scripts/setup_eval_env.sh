#!/usr/bin/env bash
# =============================================================================
# scripts/setup_eval_env.sh
# 사내 SWE-bench 평가를 위한 환경변수 로드 스크립트
#
# 반드시 source 로 실행해야 export 된 환경변수가 현재 셸에 유지됩니다:
#
#   source scripts/setup_eval_env.sh
#
# 이 스크립트가 하는 일:
#   - .env 의 사내 설정값을 현재 셸에 export
#   - .venv 가 있으면 활성화
#
# 이 스크립트가 하지 않는 일:
#   - pip install (초기 1회 설치는 README-new.md 의 "초기 설치" 단계에서 수행)
#
# export 된 환경변수는 mini-extra swebench 실행 시 Docker 컨테이너로 전달되어
# 사내 프록시, apt 미러, CA 인증서, pip 인덱스 등이 컨테이너 내부에 적용됩니다.
# =============================================================================

# ---------------------------------------------------------------------------
# 0. repo 루트 경로 확정 (어느 디렉토리에서 source 해도 동작)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# 1. .env 로드
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[setup] ERROR: ${ENV_FILE} 파일을 찾을 수 없습니다."
    echo "        먼저 .env.example 을 복사하고 값을 채워넣으세요:"
    echo "          cp ${REPO_ROOT}/.env.example ${REPO_ROOT}/.env"
    return 1 2>/dev/null || exit 1
fi

echo "[setup] ${ENV_FILE} 로드 중 ..."
set -o allexport
# shellcheck source=/dev/null
source "${ENV_FILE}" || { echo "[setup] ERROR: .env 로드 실패"; return 1 2>/dev/null || exit 1; }
set +o allexport

# ---------------------------------------------------------------------------
# 2. 필수 변수 검사
# ---------------------------------------------------------------------------
declare -a REQUIRED_VARS=(
    INTERNAL_LLM_MODEL_NAME
    INTERNAL_LLM_API_BASE
    INTERNAL_LLM_API_KEY
    HTTP_PROXY
    HTTPS_PROXY
    NO_PROXY
    CORP_CA_BUNDLE_PATH
    PIP_INDEX_URL
    PIP_TRUSTED_HOST
    MSWEA_COST_TRACKING
)

declare -a MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        MISSING+=("${var}")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "[setup] ERROR: .env 에서 아래 변수가 설정되지 않았습니다:"
    for var in "${MISSING[@]}"; do
        echo "          ${var}"
    done
    return 1 2>/dev/null || exit 1
fi

if [[ ! -r "${CORP_CA_BUNDLE_PATH}" ]]; then
    echo "[setup] ERROR: CORP_CA_BUNDLE_PATH='${CORP_CA_BUNDLE_PATH}' 파일을 읽을 수 없습니다."
    echo "        파일 경로와 읽기 권한을 확인하세요."
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# 3. Docker 데몬 확인
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    echo "[setup] ERROR: docker 명령을 찾을 수 없습니다. Docker 를 설치하세요."
    return 1 2>/dev/null || exit 1
fi
if ! docker info &>/dev/null; then
    echo "[setup] ERROR: Docker 데몬이 실행 중이지 않거나 권한이 없습니다."
    echo "        sudo usermod -aG docker \$(whoami) && newgrp docker"
    return 1 2>/dev/null || exit 1
fi
echo "[setup] Docker: $(docker --version)"

# ---------------------------------------------------------------------------
# 4. .venv bin 경로를 PATH 에 직접 주입 (source activate 대신)
#    이유: source activate 는 PYTHONHOME 을 unset 하고 PATH 를 재작성하므로
#         앞 단계에서 export 한 환경변수가 유실될 위험이 있음.
#         또한 Windows Git Bash 에서는 .venv/bin/activate 가 없고
#         .venv/Scripts/ 가 사용되어 activate 가 조용히 실패하는 문제도 있음.
#         PATH 직접 주입은 두 경우 모두 안전하게 동작한다.
# ---------------------------------------------------------------------------
VENV_DIR="${REPO_ROOT}/.venv"
if [[ -d "${VENV_DIR}/bin" ]]; then
    echo "[setup] .venv/bin → PATH 주입 ..."
    export PATH="${VENV_DIR}/bin:${PATH}"
elif [[ -d "${VENV_DIR}/Scripts" ]]; then
    echo "[setup] .venv/Scripts → PATH 주입 (Windows Git Bash) ..."
    export PATH="${VENV_DIR}/Scripts:${PATH}"
else
    echo "[setup] INFO: .venv 없음 — 시스템 Python 환경을 사용합니다."
    echo "        venv 를 사용하려면: python3 -m venv ${VENV_DIR} && pip install -e . && pip install swebench"
fi

# ---------------------------------------------------------------------------
# 5. 호스트 SSL 환경변수 export (litellm → httpx → 사내 CA 인증서 적용)
# ---------------------------------------------------------------------------
export SSL_CERT_FILE="${CORP_CA_BUNDLE_PATH}"       # Python stdlib ssl / httpx
export REQUESTS_CA_BUNDLE="${CORP_CA_BUNDLE_PATH}"  # requests 라이브러리
export CURL_CA_BUNDLE="${CORP_CA_BUNDLE_PATH}"      # curl / requests 일부 버전
export LITELLM_SSL_VERIFY="${CORP_CA_BUNDLE_PATH}"  # litellm 자체 SSL 설정
export MSWEA_COST_TRACKING="${MSWEA_COST_TRACKING}" # 사내 미등록 모델 비용 계산 오류 무시

# ---------------------------------------------------------------------------
# 6. 완료
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " 환경변수 로드 완료"
echo "----------------------------------------------------------------"
echo " LLM 모델      : ${INTERNAL_LLM_MODEL_NAME}"
echo " LLM 주소      : ${INTERNAL_LLM_API_BASE}"
echo " 프록시        : ${HTTP_PROXY}"
echo " CA 번들       : ${CORP_CA_BUNDLE_PATH}"
echo " SSL_CERT_FILE : ${SSL_CERT_FILE}"
echo " pip 인덱스    : ${PIP_INDEX_URL}"
echo " pip 신뢰호스트 : ${PIP_TRUSTED_HOST}"
echo " 비용 추적     : ${MSWEA_COST_TRACKING}"
echo "----------------------------------------------------------------"
echo " CA 번들은 호스트(litellm)와 Docker 컨테이너 양쪽에 적용됩니다."
echo "----------------------------------------------------------------"
echo " 파일럿 실행 (5개 인스턴스):"
echo "   mini-extra swebench \\"
echo "     -c swebench.yaml \\"
echo "     -c swebench_internal.yaml \\"
echo "     --subset ./data/swebench_lite_test2.jsonl \\"
echo "     --slice 0:5 \\"
echo "     -o ./results/pilot \\"
echo "     -w 1"
echo "================================================================"
