#!/usr/bin/env bash
# =============================================================================
# scripts/prebuild_eval_images.sh
# SWE-bench 평가 이미지에 사내 CA 인증서를 설치하는 스크립트
#
# 문제: swebench.harness.run_evaluation 은 자체 Docker 컨테이너를 관리하며
#       swebench_internal.yaml 의 env_startup_command 가 적용되지 않는다.
#       따라서 채점 컨테이너 내부에서는 사내 CA 가 신뢰되지 않아
#       HTTPS 요청(예: httpbin.org)이 SSL 검증 실패로 실패한다.
#
# 해결: 평가에 사용될 Docker 이미지를 미리 pull 하고,
#       사내 CA 인증서를 포함한 레이어를 추가해 동일 태그로 덮어쓴다.
#       swebench 는 이미지 이름만 참조하므로 코드 수정 없이 적용된다.
#
# 사전 조건:
#   source scripts/setup_eval_env.sh   # CORP_CA_BUNDLE_PATH 등 환경변수 로드
#
# 실행:
#   bash scripts/prebuild_eval_images.sh [--dataset <path>] [--dry-run]
#
# 옵션:
#   --dataset <path>   처리할 JSONL 파일 경로 (여러 번 지정 가능)
#                      미지정 시 data/ 폴더 내 모든 *.jsonl 파일을 자동 탐색
#   --dry-run          이미지 목록만 출력하고 실제 빌드는 수행하지 않음
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 기본값 및 인자 파싱
# ---------------------------------------------------------------------------
DATASETS=()
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dataset)
            DATASETS+=("$2"); shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        *)
            echo "[prebuild] 알 수 없는 옵션: $1"; exit 1 ;;
    esac
done

# --dataset 미지정 시 data/ 폴더 내 모든 *.jsonl 자동 탐색
if [[ ${#DATASETS[@]} -eq 0 ]]; then
    while IFS= read -r -d '' f; do
        DATASETS+=("$f")
    done < <(find data -maxdepth 1 -name "*.jsonl" -print0 2>/dev/null | sort -z)

    if [[ ${#DATASETS[@]} -eq 0 ]]; then
        echo "[prebuild] ERROR: data/ 폴더에서 *.jsonl 파일을 찾을 수 없습니다."
        echo "           --dataset <path> 옵션으로 직접 지정하거나 data/ 에 파일을 추가하세요."
        exit 1
    fi

    echo "[prebuild] 데이터셋 자동 탐색: ${#DATASETS[@]}개 파일 발견"
    for f in "${DATASETS[@]}"; do
        echo "[prebuild]   ${f}"
    done
fi

# ---------------------------------------------------------------------------
# 1. 사전 조건 확인
# ---------------------------------------------------------------------------
echo "[prebuild] 사전 조건 확인 중..."

if [[ -z "${CORP_CA_BUNDLE_PATH:-}" ]]; then
    echo "[prebuild] ERROR: CORP_CA_BUNDLE_PATH 환경변수가 설정되지 않았습니다."
    echo "           먼저 다음을 실행하세요:"
    echo "             source scripts/setup_eval_env.sh"
    exit 1
fi

if [[ ! -f "${CORP_CA_BUNDLE_PATH}" ]]; then
    echo "[prebuild] ERROR: CA 파일이 존재하지 않습니다: ${CORP_CA_BUNDLE_PATH}"
    exit 1
fi

for ds in "${DATASETS[@]}"; do
    if [[ ! -f "${ds}" ]]; then
        echo "[prebuild] ERROR: 데이터셋 파일이 존재하지 않습니다: ${ds}"
        exit 1
    fi
done

if ! command -v docker &>/dev/null; then
    echo "[prebuild] ERROR: docker 명령어를 찾을 수 없습니다."
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "[prebuild] ERROR: Docker 데몬이 실행 중이지 않습니다."
    exit 1
fi

echo "[prebuild] CA 파일   : ${CORP_CA_BUNDLE_PATH}"
echo "[prebuild] 드라이런  : ${DRY_RUN}"
echo ""

# ---------------------------------------------------------------------------
# 2. 인스턴스 ID → 이미지 이름 변환 (중복 제거)
# ---------------------------------------------------------------------------
# instance_id: psf__requests-863
# image:       docker.io/swebench/sweb.eval.x86_64.psf_1776_requests-863:latest
mapfile -t INSTANCE_IDS < <(python3 - "${DATASETS[@]}" <<'PYEOF'
import json, sys

seen = set()
for path in sys.argv[1:]:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                iid = json.loads(line)["instance_id"]
                if iid not in seen:
                    seen.add(iid)
                    print(iid)
PYEOF
)

declare -a IMAGES
for iid in "${INSTANCE_IDS[@]}"; do
    img="docker.io/swebench/sweb.eval.x86_64.$(echo "${iid//__/_1776_}" | tr '[:upper:]' '[:lower:]'):latest"
    IMAGES+=("${img}")
done

TOTAL="${#IMAGES[@]}"
echo "[prebuild] 총 ${TOTAL}개 이미지 처리 예정"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[prebuild] --dry-run 모드: 아래 이미지 목록만 출력합니다."
    for img in "${IMAGES[@]}"; do
        echo "  ${img}"
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. 임시 빌드 컨텍스트 디렉토리 생성
# ---------------------------------------------------------------------------
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

cp "${CORP_CA_BUNDLE_PATH}" "${BUILD_DIR}/corp-ca.pem"

# ---------------------------------------------------------------------------
# 4. 각 이미지에 CA 레이어 추가
# ---------------------------------------------------------------------------
SUCCESS=0
SKIP=0
FAIL=0

for i in "${!IMAGES[@]}"; do
    img="${IMAGES[$i]}"
    num=$((i + 1))

    echo "================================================================"
    echo "[prebuild] [${num}/${TOTAL}] ${img}"
    echo "----------------------------------------------------------------"

    # 4-1. 이미지 pull (로컬에 없으면)
    if ! docker image inspect "${img}" &>/dev/null; then
        echo "[prebuild] Pull 중..."
        if ! docker pull "${img}"; then
            echo "[prebuild] WARNING: pull 실패, 스킵합니다."
            FAIL=$((FAIL + 1))
            continue
        fi
    else
        echo "[prebuild] 로컬에 이미 존재함, pull 스킵"
    fi

    # 4-2. 이미 CA + 프록시가 설치되어 있는지 확인 (라벨로 표시)
    _ca=$(docker image inspect "${img}" --format '{{index .Config.Labels "corp-ca-installed"}}' 2>/dev/null)
    _proxy=$(docker image inspect "${img}" --format '{{index .Config.Labels "corp-proxy-injected"}}' 2>/dev/null)
    if [[ "${_ca}" == "true" && "${_proxy}" == "true" ]]; then
        echo "[prebuild] CA + 프록시 이미 설치됨, 스킵합니다."
        SKIP=$((SKIP + 1))
        continue
    fi

    # 4-3. Dockerfile 생성
    # ${HTTP_PROXY} 등은 heredoc 처리 시 bash 가 실제 값으로 치환됨
    # (source setup_eval_env.sh 실행 후 유효)
    # HTTP_PROXY / http_proxy 대소문자 모두 설정해 모든 HTTP 클라이언트가 인식하게 함
    cat > "${BUILD_DIR}/Dockerfile" << DOCKERFILE
FROM ${img}
COPY corp-ca.pem /usr/local/share/ca-certificates/corp-ca.crt
RUN update-ca-certificates 2>/dev/null || true
ENV HTTP_PROXY="${HTTP_PROXY}" \
    HTTPS_PROXY="${HTTPS_PROXY}" \
    NO_PROXY="${NO_PROXY}" \
    http_proxy="${HTTP_PROXY}" \
    https_proxy="${HTTPS_PROXY}" \
    no_proxy="${NO_PROXY}"
LABEL corp-ca-installed="true" \
      corp-proxy-injected="true"
DOCKERFILE

    # 4-4. 빌드 (같은 태그로 덮어쓰기)
    echo "[prebuild] CA 레이어 추가 빌드 중..."
    if docker build --quiet -t "${img}" "${BUILD_DIR}"; then
        echo "[prebuild] 완료"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "[prebuild] WARNING: 빌드 실패"
        FAIL=$((FAIL + 1))
    fi
done

# ---------------------------------------------------------------------------
# 5. 결과 요약
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " prebuild_eval_images.sh 완료"
echo "----------------------------------------------------------------"
echo " 성공 (빌드됨) : ${SUCCESS}개"
echo " 스킵 (기존)   : ${SKIP}개"
echo " 실패          : ${FAIL}개"
echo " 합계          : ${TOTAL}개"
echo "----------------------------------------------------------------"
if [[ ${FAIL} -gt 0 ]]; then
    echo " WARNING: ${FAIL}개 이미지 처리 실패. 로그를 확인하세요."
    echo "          해당 인스턴스는 채점 시 CA 없이 실행될 수 있습니다."
fi
echo "================================================================"
