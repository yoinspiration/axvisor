#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
ARTIFACT_DIR="${CI_ARTIFACT_DIR:-${ROOT_DIR}/ci-artifacts}"
LOG_DIR="${ARTIFACT_DIR}/logs"
RESULT_DIR="${ARTIFACT_DIR}/results"
REPORT_DIR="${ARTIFACT_DIR}/report"
RESULT_FILE="${RESULT_DIR}/results.tsv"
REGRESSION_CASES="${ROOT_DIR}/scripts/ci/regression-cases.tsv"

SCENARIO="${CI_SCENARIO:-qemu}" # qemu | board
CASE_ID="${CI_CASE_ID:-${SCENARIO}-manual}"
CASE_NAME="${CI_CASE_NAME:-manual}"
ENABLE_STATIC_CHECKS="${CI_ENABLE_STATIC_CHECKS:-1}"
ENABLE_FMT_CHECK="${CI_ENABLE_FMT_CHECK:-1}"
ENABLE_CLIPPY_CHECK="${CI_ENABLE_CLIPPY_CHECK:-1}"
ALLOW_TEST_WHEN_STATIC_FAIL="${CI_ALLOW_TEST_WHEN_STATIC_FAIL:-0}"

MATRIX_ARCH="${MATRIX_ARCH:-}"
MATRIX_BOARD="${MATRIX_BOARD:-}"
MATRIX_VMCONFIGS="${MATRIX_VMCONFIGS:-}"
MATRIX_VMIMAGE_NAME="${MATRIX_VMIMAGE_NAME:-}"
export RUST_LOG="${RUST_LOG:-debug}"

mkdir -p "${LOG_DIR}" "${RESULT_DIR}" "${REPORT_DIR}"

cat > "${RESULT_FILE}" <<'EOF'
case_id	step_name	status	exit_code	duration_sec	log_file
EOF

overall_exit=0
static_checks_failed=0

record_result() {
    local case_id="$1"
    local step_name="$2"
    local status="$3"
    local exit_code="$4"
    local duration="$5"
    local log_file="$6"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${case_id}" "${step_name}" "${status}" "${exit_code}" "${duration}" "${log_file}" >> "${RESULT_FILE}"
}

record_skip() {
    local step_name="$1"
    local reason="$2"
    local log_file="${LOG_DIR}/${CASE_ID}-${step_name}.log"
    echo "SKIPPED: ${reason}" > "${log_file}"
    record_result "${CASE_ID}" "${step_name}" "SKIP" "0" "0" "${log_file}"
}

run_step() {
    local step_name="$1"
    shift

    local log_file="${LOG_DIR}/${CASE_ID}-${step_name}.log"
    local start_ts end_ts duration rc status
    start_ts="$(date +%s)"

    echo "[CI] STEP=${step_name} CASE=${CASE_ID}" | tee "${log_file}"
    echo "[CI] CMD=$*" | tee -a "${log_file}"

    set +e
    "$@" 2>&1 | tee -a "${log_file}"
    rc="${PIPESTATUS[0]}"
    set -e

    end_ts="$(date +%s)"
    duration="$((end_ts - start_ts))"
    status="PASS"
    if [[ "${rc}" -ne 0 ]]; then
        status="FAIL"
    fi

    record_result "${CASE_ID}" "${step_name}" "${status}" "${rc}" "${duration}" "${log_file}"
    return "${rc}"
}

ensure_case_registered() {
    if [[ ! -f "${REGRESSION_CASES}" ]]; then
        echo "[WARN] regression case registry not found: ${REGRESSION_CASES}"
        return 0
    fi
    if ! awk -F '\t' -v id="${CASE_ID}" 'NR > 1 && $1 == id { found = 1 } END { exit(found ? 0 : 1) }' "${REGRESSION_CASES}"; then
        echo "[WARN] case '${CASE_ID}' not found in ${REGRESSION_CASES}, continue as ad-hoc run."
    fi
}

prepare_qemu_images() {
    local image_dir="/tmp/.axvisor-images"
    local config img image_location rootfs_img_path img_name

    IFS=',' read -ra configs <<< "${MATRIX_VMCONFIGS}"
    IFS=',' read -ra images <<< "${MATRIX_VMIMAGE_NAME}"
    if [[ "${#configs[@]}" -ne "${#images[@]}" ]]; then
        echo "vmconfigs count != vmimage count"
        return 1
    fi

    for idx in "${!configs[@]}"; do
        config="$(echo "${configs[${idx}]}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        img="$(echo "${images[${idx}]}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        img_name="qemu-${MATRIX_ARCH}"

        cargo xtask image download "${img}"
        image_location="$(sed -n 's/^image_location[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${config}")"

        case "${image_location}" in
            fs)
                echo "Filesystem storage mode for ${config}"
                ;;
            memory)
                sed -i 's|^kernel_path[[:space:]]*=.*|kernel_path = "'"${image_dir}"'/'"${img}"'/'"${img_name}"'"|' "${config}"
                ;;
            *)
                echo "Unknown image_location '${image_location}' in ${config}"
                return 1
                ;;
        esac

        rootfs_img_path="${image_dir}/${img}/rootfs.img"
        if [[ -f "${rootfs_img_path}" ]]; then
            sed -i \
                's|file=${workspaceFolder}/tmp/rootfs.img|file='"${rootfs_img_path}"'|' \
                ".github/workflows/qemu-${MATRIX_ARCH}.toml"
        else
            sed -i '/-device/,/virtio-blk-device,drive=disk0/d' ".github/workflows/qemu-${MATRIX_ARCH}.toml"
            sed -i '/-drive/,/id=disk0,if=none,format=raw,file=${workspaceFolder}\/tmp\/rootfs.img/d' ".github/workflows/qemu-${MATRIX_ARCH}.toml"
            sed -i 's/root=\/dev\/vda rw //' ".github/workflows/qemu-${MATRIX_ARCH}.toml"
        fi
    done
}

run_static_checks() {
    if [[ "${ENABLE_STATIC_CHECKS}" != "1" ]]; then
        echo "[CI] static checks disabled"
        return 0
    fi

    local failed=0
    if [[ "${ENABLE_FMT_CHECK}" == "1" ]]; then
        if ! run_step "fmt-check" cargo fmt --all -- --check; then
            failed=1
        fi
    else
        record_skip "fmt-check" "CI_ENABLE_FMT_CHECK=0"
    fi

    if [[ "${ENABLE_CLIPPY_CHECK}" == "1" ]]; then
        if ! run_step "clippy-check" cargo xtask clippy --continue-on-error; then
            failed=1
        fi
    else
        record_skip "clippy-check" "CI_ENABLE_CLIPPY_CHECK=0"
    fi

    return "${failed}"
}

run_main_test() {
    case "${SCENARIO}" in
        qemu)
            if [[ -z "${MATRIX_ARCH}" || -z "${MATRIX_VMCONFIGS}" ]]; then
                echo "qemu scenario requires MATRIX_ARCH and MATRIX_VMCONFIGS"
                return 1
            fi
            if ! run_step "install-deps" cargo +stable install ostool --version '^0.8'; then
                return 1
            fi
            if ! run_step "prepare-images" prepare_qemu_images; then
                return 1
            fi
            run_step "qemu-run" \
                cargo xtask qemu \
                --build-config "configs/board/qemu-${MATRIX_ARCH}.toml" \
                --qemu-config ".github/workflows/qemu-${MATRIX_ARCH}.toml" \
                --vmconfigs "${MATRIX_VMCONFIGS}"
            ;;
        board)
            if [[ -z "${MATRIX_BOARD}" || -z "${MATRIX_VMCONFIGS}" ]]; then
                echo "board scenario requires MATRIX_BOARD and MATRIX_VMCONFIGS"
                return 1
            fi
            if ! run_step "install-deps" cargo +stable install ostool --version '^0.8'; then
                return 1
            fi
            run_step "board-run" \
                cargo xtask uboot \
                --build-config "configs/board/${MATRIX_BOARD}.toml" \
                --uboot-config ".github/workflows/uboot.toml" \
                --vmconfigs "${MATRIX_VMCONFIGS}" \
                --bin-dir /home/runner/tftp
            ;;
        *)
            echo "Unsupported CI_SCENARIO='${SCENARIO}', expected qemu or board"
            return 1
            ;;
    esac
}

write_metadata() {
    cat > "${RESULT_DIR}/metadata.env" <<EOF
CI_SCENARIO=${SCENARIO}
CI_CASE_ID=${CASE_ID}
CI_CASE_NAME=${CASE_NAME}
CI_ENABLE_STATIC_CHECKS=${ENABLE_STATIC_CHECKS}
EOF
    printf "%s\n" "${overall_exit}" > "${REPORT_DIR}/suite_exit_code.txt"
}

ensure_case_registered

if ! run_static_checks; then
    static_checks_failed=1
    overall_exit=1
fi

if [[ "${static_checks_failed}" -eq 1 && "${ALLOW_TEST_WHEN_STATIC_FAIL}" != "1" ]]; then
    record_skip "runtime-test" "static checks failed"
else
    if ! run_main_test; then
        overall_exit=1
    fi
fi

write_metadata
echo "[CI] suite finished with exit=${overall_exit}"
exit "${overall_exit}"
