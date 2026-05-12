#!/usr/bin/env bash
# =============================================================================
# scripts/setup_eval_env.sh
# 사내 SWE-bench 평가를 위한 호스트 환경 셋업
#
# 반드시 source 로 실행해야 export 된 환경변수가 현재 셸에 유지됩니다:
#
#   source scripts/setup_eval_env.sh
#
# 수행 내용:
#   [Phase A] .env 로드 → 변수 검증 → Docker 확인 → venv 활성화 → pip 환경변수 export
#   [Phase B] pip 패키지 설치 (실패 시 환경변수는 보존된 상태로 에러 출력)
#
# 주의: set -euo pipefail 을 사용하지 않습니다.
#   source 실행 시 set -e 는 현재 셸에 적용되어, pip 실패 시 셸 자체가 종료됩니다.
#   대신 critical 단계마다 || { ...; return 1; } 으로 명시적 에러 처리합니다.
# =============================================================================

# ---------------------------------------------------------------------------
# 0. repo 루트 경로 확정 (어느 디렉토리에서 source 해도 동작)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ===========================================================================
# Phase A — 환경변수 export 및 venv 활성화 (실패 시 즉시 중단)
# ===========================================================================

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
# 4. Python venv 생성 및 활성화
# ---------------------------------------------------------------------------
VENV_DIR="${REPO_ROOT}/.venv"
if [[ ! -d "${VENV_DIR}" ]]; then
    echo "[setup] .venv 생성 중 ..."
    python3 -m venv "${VENV_DIR}" || { echo "[setup] ERROR: venv 생성 실패"; return 1 2>/dev/null || exit 1; }
fi

echo "[setup] .venv 활성화 ..."
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate" || { echo "[setup] ERROR: venv 활성화 실패"; return 1 2>/dev/null || exit 1; }

# ---------------------------------------------------------------------------
# 5. pip 환경변수 export
# ---------------------------------------------------------------------------
export PIP_CERT="${CORP_CA_BUNDLE_PATH}"
export PIP_INDEX_URL="${PIP_INDEX_URL}"
export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST}"
# HTTPS_PROXY 는 환경변수로 자동 적용됨

echo "[setup] Phase A 완료 — 환경변수 export 및 venv 활성화 성공"

# ===========================================================================
# Phase B — pip 패키지 설치
# (실패 시 에러를 출력하고 return. 환경변수와 venv는 이미 활성화된 상태 유지)
# ===========================================================================

# ---------------------------------------------------------------------------
# 6. pip / setuptools / wheel 업그레이드
#    사내 PyPI 미러에 setuptools 가 없어도 경고만 출력하고 계속 진행
# ---------------------------------------------------------------------------
echo "[setup] pip / setuptools / wheel 업그레이드 중 ..."
if ! pip install --quiet --upgrade pip setuptools wheel; then
    echo "[setup] WARNING: pip/setuptools/wheel 업그레이드 실패."
    echo "        사내 PyPI 미러에 setuptools 가 없을 수 있습니다."
    echo "        --no-build-isolation 으로 설치를 계속 시도합니다."
fi

# ---------------------------------------------------------------------------
# 7. mini-swe-agent 설치
#    --no-build-isolation: 격리 빌드 환경 생성 없이 venv 내 setuptools 직접 사용
# ---------------------------------------------------------------------------
echo "[setup] mini-swe-agent 설치 중 (editable) ..."
if ! pip install --quiet --no-build-isolation -e "${REPO_ROOT}"; then
    echo "[setup] ERROR: mini-swe-agent 설치 실패."
    echo "        환경변수와 venv는 활성화된 상태입니다."
    echo "        pip 로그를 확인하거나 수동으로 설치하세요:"
    echo "          pip install --no-build-isolation -e ${REPO_ROOT}"
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# 8. swebench 채점 harness 설치
# ---------------------------------------------------------------------------
echo "[setup] swebench harness 설치 중 ..."
if ! pip install --quiet --no-build-isolation swebench; then
    echo "[setup] ERROR: swebench 설치 실패."
    echo "        환경변수와 venv는 활성화된 상태입니다."
    echo "        수동으로 설치하세요:"
    echo "          pip install --no-build-isolation swebench"
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# 9. 완료
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " 셋업 완료"
echo "----------------------------------------------------------------"
echo " Venv         : ${VENV_DIR} (활성화됨)"
echo " LLM 모델     : ${INTERNAL_LLM_MODEL_NAME}"
echo " LLM 주소     : ${INTERNAL_LLM_API_BASE}"
echo " 프록시       : ${HTTP_PROXY}"
echo " CA 번들      : ${CORP_CA_BUNDLE_PATH}"
echo " pip 인덱스   : ${PIP_INDEX_URL}"
echo " pip 신뢰호스트: ${PIP_TRUSTED_HOST}"
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
