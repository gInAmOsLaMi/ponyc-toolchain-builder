#!/usr/bin/env bash

# Author: Albert L. Delima aka gInAmOs
# License: BSD-2-Clause
# Repository: https://github.com/gInAmOsLaMi/ponyc-toolchain-builder

# ==============================================================================
# Cross-platform automated builder for ponyc toolchains (ASan, TSan, Release+LTO)
# Supported Platforms & Architectures:
#   - Linux (x86_64, 32-bit Raspbian, 64-bit Raspbian, Asahi M1/M2+ Linux)
#   - FreeBSD, OpenBSD (doas), DragonFly BSD (gcc13)
#   - macOS (Intel & Apple Silicon)
# ==============================================================================

set -euo pipefail

# ==============================================================================
# 1. REPOSITORY VALIDATION
# ==============================================================================
if [ ! -f "CMakeLists.txt" ] || [ ! -f "cmake/PonyUses.cmake" ]; then
    printf "Error: Run this script from the root of the ponyc repository.\n" >&2
    exit 1
fi

# ==============================================================================
# 2. OS, DISTRO & ARCHITECTURE DETECTION
# ==============================================================================
printf "%-38s " "Checking OS & Architecture"
OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
DISTRO_DISPLAY="${OS_NAME} (${ARCH_NAME})"
DISTRO_ID=""
SUPPORTS_SANITIZERS=1
USE_GCC_TOOLCHAIN=0
PRESET_PREFIX=""
FORCE_LTO_OFF=0
LIBS_CMAKE_ARGS=()
CONFIG_CMAKE_ARGS=()

case "${OS_NAME}" in
    Linux)
        DEFAULT_JOBS="$(nproc)"
        ASAN_BUILD_ENV="detect_leaks=0"
        if [ -f /etc/os-release ]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            DISTRO_ID="${ID:-}"
            DISTRO_DISPLAY="${PRETTY_NAME:-Linux} (${ARCH_NAME})"
        fi

        case "${ARCH_NAME}" in
            armv7l|armv6l)
                DISTRO_DISPLAY="${DISTRO_DISPLAY} [32-bit ARM / GCC]"
                USE_GCC_TOOLCHAIN=1
                FORCE_LTO_OFF=1
                LIBS_CMAKE_ARGS+=("-DCMAKE_C_COMPILER=gcc" "-DCMAKE_CXX_COMPILER=g++")
                CONFIG_CMAKE_ARGS+=(
                    "-DCMAKE_C_COMPILER=gcc"
                    "-DCMAKE_CXX_COMPILER=g++"
                    "-DCMAKE_C_FLAGS=-march=native -mtune=native"
                    "-DCMAKE_CXX_FLAGS=-march=native -mtune=native"
                )
                ;;
            aarch64|arm64)
                if grep -qiE 'apple|asahi' /proc/device-tree/compatible /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || [ "${DISTRO_ID}" = "fedora-asahi-remix" ]; then
                    DISTRO_DISPLAY="${DISTRO_DISPLAY} [Asahi ARMv8]"
                    PRESET_PREFIX="armv8-"
                elif [ -f /etc/rpi-issue ] || [ "${DISTRO_ID}" = "raspbian" ] || grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
                    DISTRO_DISPLAY="${DISTRO_DISPLAY} [64-bit Raspbian ARMv8-A]"
                    PRESET_PREFIX="armv8-a-"
                    LIBS_CMAKE_ARGS+=("-DPONY_PIC_FLAG=-fPIC")
                    CONFIG_CMAKE_ARGS+=("-DPONY_PIC_FLAG=-fPIC")
                fi
                ;;
        esac
        ;;
    FreeBSD)
        DEFAULT_JOBS="$(sysctl -n hw.ncpu)"
        ASAN_BUILD_ENV="detect_leaks=0:detect_container_overflow=0"
        DISTRO_DISPLAY="FreeBSD $(uname -r) (${ARCH_NAME})"
        ;;
    OpenBSD)
        DEFAULT_JOBS="$(sysctl -n hw.ncpu)"
        ASAN_BUILD_ENV=""
        SUPPORTS_SANITIZERS=0
        DISTRO_DISPLAY="OpenBSD $(uname -r) (${ARCH_NAME})"
        ;;
    DragonFly)
        DEFAULT_JOBS="$(sysctl -n hw.ncpu)"
        ASAN_BUILD_ENV=""
        SUPPORTS_SANITIZERS=0
        USE_GCC_TOOLCHAIN=1
        FORCE_LTO_OFF=1
        DISTRO_DISPLAY="DragonFly BSD $(uname -r) (${ARCH_NAME})"
        LIBS_CMAKE_ARGS+=("-DCMAKE_C_COMPILER=/usr/local/bin/gcc13" "-DCMAKE_CXX_COMPILER=/usr/local/bin/g++13")
        CONFIG_CMAKE_ARGS+=("-DCMAKE_C_COMPILER=/usr/local/bin/gcc13" "-DCMAKE_CXX_COMPILER=/usr/local/bin/g++13")
        ;;
    Darwin)
        DEFAULT_JOBS="$(sysctl -n hw.ncpu)"
        ASAN_BUILD_ENV="detect_leaks=0:detect_container_overflow=0"
        DISTRO_DISPLAY="macOS $(sw_vers -productVersion 2>/dev/null || uname -r) (${ARCH_NAME})"
        ;;
    *)
        printf "[FAILED]\nError: Unsupported operating system: %s\n" "${OS_NAME}" >&2
        exit 1
        ;;
esac

printf "[FOUND] -> %s\n" "${DISTRO_DISPLAY}"

PREFIX_BASE="${PREFIX_BASE:-/opt}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
BUILD_TYPE="${BUILD_TYPE:-release}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
RUN_TESTS="${RUN_TESTS:-0}"
JOBS="${JOBS:-${DEFAULT_JOBS}}"

ACTIVE_PRESET="${PRESET_PREFIX}${BUILD_TYPE}"
BUILD_DIR="build/build_${ACTIVE_PRESET}"

# ==============================================================================
# 3. PRIVILEGE ESCALATION (SUDO / DOAS KEEP-ALIVE)
# ==============================================================================
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if [ "${OS_NAME}" = "OpenBSD" ] && command -v doas >/dev/null 2>&1; then
        SUDO="doas"
        ${SUDO} true
    else
        SUDO="sudo"
        ${SUDO} -v
        while true; do ${SUDO} -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
    fi
fi

# ==============================================================================
# 4. SINGLE-LINE 0-100% PROGRESS RUNNER
# ==============================================================================
run_with_progress() {
    local label="$1"
    shift
    local install_label=""
    if [ "${1:-}" = "--install-label" ]; then
        install_label="$2"
        shift 2
    fi

    local log_file
    log_file="$(mktemp)"

    printf "\r%-38s [--------------------]   0%%" "${label}"

    set +e
    "$@" >"${log_file}" 2>&1 &
    local cmd_pid=$!

    local pct=0
    local install_started=0
    while kill -0 "${cmd_pid}" 2>/dev/null; do
        local latest
        latest=$(grep -oE '\[ *[0-9]+%\]' "${log_file}" 2>/dev/null | tail -n 1 | tr -dc '0-9' || true)
        if [ -n "${latest}" ] && [ "${latest}" -ge "${pct}" ] && [ "${latest}" -le 100 ]; then
            pct="${latest}"
        fi

        if [ -n "${install_label}" ] && [ "${pct}" -eq 100 ]; then
            local inst_count
            inst_count=$(grep -c '^-- Installing:' "${log_file}" 2>/dev/null || true)
            if [ "${inst_count}" -gt 0 ]; then
                if [ "${install_started}" -eq 0 ]; then
                    printf "\r%-38s [####################] 100%%\n" "${label}"
                    install_started=1
                fi
                local inst_pct=$(( inst_count * 100 / 260 ))
                [ "${inst_pct}" -gt 99 ] && inst_pct=99
                local i_filled=$(( inst_pct / 5 ))
                local i_empty=$(( 20 - i_filled ))
                local i_bar
                i_bar="$(printf '%*s' "${i_filled}" '' | tr ' ' '#')$(printf '%*s' "${i_empty}" '' | tr ' ' '-')"
                printf "\r%-38s [%s] %3d%%" "${install_label}" "${i_bar}" "${inst_pct}"
                sleep 0.5
                continue
            fi
        fi

        local filled=$(( pct / 5 ))
        local empty=$(( 20 - filled ))
        local bar
        bar="$(printf '%*s' "${filled}" '' | tr ' ' '#')$(printf '%*s' "${empty}" '' | tr ' ' '-')"
        printf "\r%-38s [%s] %3d%%" "${label}" "${bar}" "${pct}"
        sleep 0.5
    done

    wait "${cmd_pid}"
    local exit_code=$?
    set -e

    if [ "${exit_code}" -eq 0 ]; then
        if [ -n "${install_label}" ]; then
            if [ "${install_started}" -eq 0 ]; then
                printf "\r%-38s [####################] 100%%\n" "${label}"
            fi
            printf "\r%-38s [####################] 100%%\n" "${install_label}"
        else
            printf "\r%-38s [####################] 100%%\n" "${label}"
        fi
        rm -f "${log_file}"
    else
        printf "\r%-38s [FAILED              ] ERR!\n" "${label}"
        printf "\n--- Build Log (%s) ---\n" "${label}" >&2
        cat "${log_file}" >&2
        rm -f "${log_file}"
        exit "${exit_code}"
    fi
}

# ==============================================================================
# 4B. SAFE CLEANUP OF PREVIOUS INSTALLATION
# ==============================================================================
cleanup_previous_install() {
    local target_name="$1"
    shift
    local install_dir="${PREFIX_BASE}/${target_name}"

    if [ -z "${PREFIX_BASE}" ] || [ "${PREFIX_BASE}" = "/" ]; then
        printf "Error: Refusing to clean unsafe PREFIX_BASE='%s'\n" "${PREFIX_BASE}" >&2
        exit 1
    fi

    if [ -d "${install_dir}" ]; then
        ${SUDO} rm -rf "${install_dir}"
    fi

    if [ -n "${BIN_DIR}" ] && [ "${BIN_DIR}" != "/" ]; then
        for bin_name in "$@"; do
            if [ -L "${BIN_DIR}/${bin_name}" ] || [ -e "${BIN_DIR}/${bin_name}" ]; then
                ${SUDO} rm -f "${BIN_DIR}/${bin_name}"
            fi
        done
    fi
}

# ==============================================================================
# 5. CHECK & INSTALL BUILD DEPENDENCIES
# ==============================================================================
check_and_install_dependencies() {
    printf "%-38s " "Checking for Build Dependencies"

    if [ "${INSTALL_DEPS}" != "1" ]; then
        printf "[SKIPPED] -> INSTALL_DEPS=0\n"
        return 0
    fi

    local missing=()
    for tool in cmake git python3 make; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done

    if [ "${OS_NAME}" = "DragonFly" ]; then
        [ -x "/usr/local/bin/gcc13" ] || missing+=("gcc13")
    elif [ "${USE_GCC_TOOLCHAIN}" -eq 1 ]; then
        command -v gcc >/dev/null 2>&1 || missing+=("gcc")
    else
        command -v clang >/dev/null 2>&1 || missing+=("clang")
        command -v lld >/dev/null 2>&1 || missing+=("lld")
    fi

    if [ ! -f /usr/include/openssl/ssl.h ] && [ ! -f /usr/local/include/openssl/ssl.h ] && [ ! -f /opt/homebrew/opt/openssl@3/include/openssl/ssl.h ]; then
        missing+=("openssl-dev")
    fi
    if [ ! -f /usr/include/zlib.h ] && [ ! -f /usr/local/include/zlib.h ]; then
        missing+=("zlib-dev")
    fi

    if [ "${#missing[@]}" -eq 0 ]; then
        printf "[FOUND] -> All build tools & headers present\n"
        return 0
    fi

    printf "[MISSING: %s] -> Installing...\n" "${missing[*]}"

    case "${OS_NAME}" in
        Linux)
            case "${DISTRO_ID}" in
                debian|ubuntu|linuxmint|pop|raspbian)
                    run_with_progress "Installing APT Build Packages" \
                        bash -c "${SUDO} apt-get update -qq && ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential clang cmake git lld llvm libssl-dev python3 zlib1g-dev"
                    ;;
                fedora|fedora-asahi-remix|rhel|centos|rocky|almalinux)
                    run_with_progress "Installing DNF Build Packages" \
                        ${SUDO} dnf install -y -q clang cmake compiler-rt gcc gcc-c++ git lld llvm make openssl-devel python3 zlib-devel
                    ;;
                arch|manjaro|endeavouros)
                    run_with_progress "Installing Pacman Build Packages" \
                        ${SUDO} pacman -S --needed --noconfirm base-devel clang cmake compiler-rt git lld llvm openssl python zlib
                    ;;
                alpine)
                    run_with_progress "Installing APK Build Packages" \
                        ${SUDO} apk add --no-cache build-base clang cmake compiler-rt git lld llvm openssl-dev python3 zlib-dev
                    ;;
                opensuse*|sles)
                    run_with_progress "Installing Zypper Build Packages" \
                        ${SUDO} zypper install -y clang cmake compiler-rt gcc gcc-c++ git lld llvm make libopenssl-devel python3 zlib-devel
                    ;;
                *)
                    printf "%-38s [FAILED] -> Unrecognized distro (%s); install: %s\n" "Installing Build Packages" "${DISTRO_ID:-unknown}" "${missing[*]}" >&2
                    exit 1
                    ;;
            esac
            ;;
        FreeBSD)
            run_with_progress "Installing PKG Build Packages" \
                ${SUDO} pkg install -y cmake git gmake llvm openssl python3
            ;;
        OpenBSD)
            run_with_progress "Installing OpenBSD Build Packages" \
                ${SUDO} pkg_add -I cmake git gmake llvm python3
            ;;
        DragonFly)
            run_with_progress "Installing DragonFly Build Packages" \
                ${SUDO} pkg install -y cmake git gmake gcc13 openssl python3
            ;;
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                run_with_progress "Installing Homebrew Build Packages" \
                    brew install cmake llvm openssl@3
            else
                printf "%-38s [FAILED] -> Homebrew not found; install: %s\n" "Installing Build Packages" "${missing[*]}" >&2
                exit 1
            fi
            ;;
    esac
}

check_and_install_dependencies

# ==============================================================================
# 6. CAPABILITY-BASED FEATURE DETECTION & CMAKE SCANNER
# ==============================================================================
if [ "${USE_GCC_TOOLCHAIN}" -eq 0 ] && command -v clang >/dev/null 2>&1; then
    CONFIG_CMAKE_ARGS+=("-DPONY_RUNTIME_BITCODE=ON")
else
    CONFIG_CMAKE_ARGS+=("-DPONY_RUNTIME_BITCODE=OFF")
fi

TEST_DEBUGGER_CMD=""
if [ "${RUN_TESTS}" = "1" ] && [ -x ".ci-scripts/test-debugger.sh" ]; then
    if command -v lldb >/dev/null 2>&1; then
        TEST_DEBUGGER_CMD="$(.ci-scripts/test-debugger.sh lldb)"
    elif command -v gdb >/dev/null 2>&1; then
        TEST_DEBUGGER_CMD="$(.ci-scripts/test-debugger.sh gdb)"
    fi
fi

COMMON_INSTRUMENT_USES="undefined_behavior_sanitizer,coverage,systematic_testing,runtimestats,runtimestats_messages,reach_instrument"
ASAN_EXTRA_USES="address_sanitizer,pool_memalign"

scan_cmake_capabilities() {
    printf "%-38s " "Scanning CMake Build Options"

    local known_uses
    known_uses=$(awk '/set\(_pony_known_uses/,/\)/' cmake/PonyUses.cmake | grep -oE '[a-z0-9_]+' | grep -vE '^(set|_pony_known_uses)$' || true)

    local test_suites_count
    test_suites_count=$(find cmake -maxdepth 1 -name 'Test*.cmake' 2>/dev/null | wc -l | tr -d ' ')

    if [ -z "${known_uses}" ]; then
        printf "[WARNING] -> Using fallback options\n"
        return 0
    fi

    local desired_common=(
        "undefined_behavior_sanitizer"
        "coverage"
        "systematic_testing"
        "runtimestats"
        "runtimestats_messages"
        "reach_instrument"
    )

    local active_common=()
    for opt in "${desired_common[@]}"; do
        if printf "%s\n" "${known_uses}" | grep -qx "${opt}"; then
            active_common+=("${opt}")
        fi
    done

    local IFS=","
    COMMON_INSTRUMENT_USES="${active_common[*]}"
    unset IFS

    ASAN_EXTRA_USES="address_sanitizer"
    local total_active=$(( ${#active_common[@]} + 2 ))
    if printf "%s\n" "${known_uses}" | grep -qx "pool_memalign"; then
        ASAN_EXTRA_USES="address_sanitizer,pool_memalign"
        total_active=$(( total_active + 1 ))
    fi

    if [ ! -f "cmake/CheckRuntimeBitcode.cmake" ]; then
        CONFIG_CMAKE_ARGS=("${CONFIG_CMAKE_ARGS[@]/-DPONY_RUNTIME_BITCODE=ON/-DPONY_RUNTIME_BITCODE=OFF}")
    fi

    if [ -f "CMakePresets.json" ] && ! grep -q "\"name\": \"${ACTIVE_PRESET}\"" CMakePresets.json; then
        ACTIVE_PRESET="${BUILD_TYPE}"
        BUILD_DIR="build/build_${ACTIVE_PRESET}"
    fi

    printf "[FOUND] -> %d uses, %s ctest suites\n" "${total_active}" "${test_suites_count}"
}

scan_cmake_capabilities

# ==============================================================================
# 6C. INTERACTIVE BUILD & INSTRUMENTATION SELECTOR
# ==============================================================================
prompt_build_selection() {
    BUILD_ASAN=1
    BUILD_TSAN=1
    BUILD_RELEASE=1
    BUILD_TOOLS=1

    if [ ! -t 0 ] || [ "${INTERACTIVE:-1}" = "0" ]; then
        return 0
    fi

    printf "\n--- Select Toolchains to Build ---\n"
    printf "  1) Full Suite (ponyc-asan + ponyc-tsan + ponyc + self-hosted tools) [Default]\n"
    printf "  2) Custom Selection (choose individual toolchains & instrumentation)\n"
    printf "Choice [1/2]: "
    read -r suite_choice

    if [ "${suite_choice}" != "2" ]; then
        printf "\n"
        return 0
    fi

    if [ "${SUPPORTS_SANITIZERS}" -eq 1 ]; then
        printf "Build ponyc-asan (AddressSanitizer + pool_memalign)? [Y/n]: "
        read -r ans; [[ "${ans}" =~ ^[Nn]$ ]] && BUILD_ASAN=0

        printf "Build ponyc-tsan (ThreadSanitizer)? [Y/n]: "
        read -r ans; [[ "${ans}" =~ ^[Nn]$ ]] && BUILD_TSAN=0
    fi

    printf "Build ponyc (Clean Production Release)? [Y/n]: "
    read -r ans; [[ "${ans}" =~ ^[Nn]$ ]] && BUILD_RELEASE=0

    if [ "${BUILD_RELEASE}" -eq 1 ]; then
        printf "Build self-hosted tools (pony-lsp, pony-lint, pony-doc)? [Y/n]: "
        read -r ans; [[ "${ans}" =~ ^[Nn]$ ]] && BUILD_TOOLS=0
    else
        BUILD_TOOLS=0
    fi

    if [ "${BUILD_ASAN}" -eq 1 ] || [ "${BUILD_TSAN}" -eq 1 ]; then
        printf "\n--- Select Instrumentation Options for Sanitizer Builds ---\n"
        local available_opts=(
            "undefined_behavior_sanitizer"
            "coverage"
            "systematic_testing"
            "runtimestats"
            "runtimestats_messages"
            "reach_instrument"
        )
        local selected_opts=()
        for opt in "${available_opts[@]}"; do
            if printf "%s\n" "${COMMON_INSTRUMENT_USES}" | tr ',' '\n' | grep -qx "${opt}"; then
                printf "  Enable %-30s [Y/n]: " "${opt}?"
                read -r ans
                if [[ ! "${ans}" =~ ^[Nn]$ ]]; then
                    selected_opts+=("${opt}")
                fi
            fi
        done
        local IFS=","
        COMMON_INSTRUMENT_USES="${selected_opts[*]}"
        unset IFS
    fi
    printf "\n"
}

prompt_build_selection

# ==============================================================================
# 7. [1/13 - 2/13] VENDORED LLVM & SUPPORT LIBRARIES (ONE-TIME)
# Verify LLVMConfig.cmake actually exists; clean partial build/libs if interrupted.
# ==============================================================================
if [ ! -f "build/libs/lib/cmake/llvm/LLVMConfig.cmake" ]; then
    if [ -d "build/libs" ] || [ -d "build/build_libs" ]; then
        run_with_progress "Cleaning incomplete LLVM cache" \
            rm -rf build/libs build/build_libs
    fi
    run_with_progress "[1/13] Building vendored LLVM" \
        --install-label "[2/13] Installing vendored LLVM" \
        cmake -DJOBS="${JOBS}" "${LIBS_CMAKE_ARGS[@]}" -P lib/build-libs.cmake
else
    printf "%-38s [####################] 100%%\n" "[1/13] Building vendored LLVM (cached)"
    printf "%-38s [####################] 100%%\n" "[2/13] Installing vendored LLVM (cached)"
fi

# ==============================================================================
# 8. [3/13 - 5/13] BUILD 1: ponyc-asan (ASan + pool_memalign + UBSan + Instrumentation)
# ==============================================================================
if [ "${SUPPORTS_SANITIZERS}" -eq 1 ] && [ "${BUILD_ASAN}" -eq 1 ]; then
    rm -rf "${BUILD_DIR}"
    run_with_progress "[3/13] Configuring ponyc-asan" \
        cmake --preset "${ACTIVE_PRESET}" "${CONFIG_CMAKE_ARGS[@]}" \
            -DPONY_USE_LTO=OFF \
            -DPONY_USES="${ASAN_EXTRA_USES},${COMMON_INSTRUMENT_USES}"

    run_with_progress "[4/13] Compiling ponyc-asan" \
        env ASAN_OPTIONS="${ASAN_BUILD_ENV}" cmake --build "${BUILD_DIR}" --target ponyc --parallel "${JOBS}"

    if [ "${RUN_TESTS}" = "1" ]; then
        run_with_progress "[4/13] Testing ponyc-asan (ci-core)" \
            env ASAN_OPTIONS="${ASAN_BUILD_ENV}" PONY_TEST_DEBUGGER="${TEST_DEBUGGER_CMD}" \
                ctest --test-dir "${BUILD_DIR}" -L ci-core --output-on-failure
    fi

    cleanup_previous_install "ponyc-asan" "ponyc-asan"
    run_with_progress "[5/13] Installing ponyc-asan" \
        bash -c "${SUDO} cmake --install '${BUILD_DIR}' --prefix '${PREFIX_BASE}/ponyc-asan' && [ -n '${BIN_DIR}' ] && ${SUDO} mkdir -p '${BIN_DIR}' && ${SUDO} ln -sf '${PREFIX_BASE}/ponyc-asan/bin/ponyc' '${BIN_DIR}/ponyc-asan'"
elif [ "${SUPPORTS_SANITIZERS}" -eq 0 ]; then
    printf "%-38s [SKIPPED] -> Sanitizers unsupported on %s\n" "[3/13 - 5/13] ponyc-asan" "${OS_NAME}"
else
    printf "%-38s [SKIPPED] -> Deselected by user\n" "[3/13 - 5/13] ponyc-asan"
fi

# ==============================================================================
# 9. [6/13 - 8/13] BUILD 2: ponyc-tsan (TSan + UBSan + Instrumentation)
# ==============================================================================
if [ "${SUPPORTS_SANITIZERS}" -eq 1 ] && [ "${BUILD_TSAN}" -eq 1 ]; then
    rm -rf "${BUILD_DIR}"
    run_with_progress "[6/13] Configuring ponyc-tsan" \
        cmake --preset "${ACTIVE_PRESET}" "${CONFIG_CMAKE_ARGS[@]}" \
            -DPONY_USE_LTO=OFF \
            -DPONY_USES="thread_sanitizer,${COMMON_INSTRUMENT_USES}"

    run_with_progress "[7/13] Compiling ponyc-tsan" \
        cmake --build "${BUILD_DIR}" --target ponyc --parallel "${JOBS}"

    if [ "${RUN_TESTS}" = "1" ]; then
        run_with_progress "[7/13] Testing ponyc-tsan (ci-core)" \
            env PONY_TEST_DEBUGGER="${TEST_DEBUGGER_CMD}" \
                ctest --test-dir "${BUILD_DIR}" -L ci-core --output-on-failure
    fi

    cleanup_previous_install "ponyc-tsan" "ponyc-tsan"
    run_with_progress "[8/13] Installing ponyc-tsan" \
        bash -c "${SUDO} cmake --install '${BUILD_DIR}' --prefix '${PREFIX_BASE}/ponyc-tsan' && [ -n '${BIN_DIR}' ] && ${SUDO} ln -sf '${PREFIX_BASE}/ponyc-tsan/bin/ponyc' '${BIN_DIR}/ponyc-tsan'"
elif [ "${SUPPORTS_SANITIZERS}" -eq 0 ]; then
    printf "%-38s [SKIPPED] -> Sanitizers unsupported on %s\n" "[6/13 - 8/13] ponyc-tsan" "${OS_NAME}"
else
    printf "%-38s [SKIPPED] -> Deselected by user\n" "[6/13 - 8/13] ponyc-tsan"
fi

# ==============================================================================
# 10. [9/13 - 13/13] BUILD 3: ponyc + Self-Hosted Tools (pony-lsp, pony-lint, pony-doc)
# ==============================================================================
if [ "${BUILD_RELEASE}" -eq 1 ]; then
    RELEASE_LTO_ARGS=()
    RELEASE_BUILD_ENV=()
    if [ "${FORCE_LTO_OFF}" -eq 1 ]; then
        RELEASE_LTO_ARGS+=("-DPONY_USE_LTO=OFF")
    else
        RELEASE_BUILD_ENV+=("PONY_THIN_LTO=1")
    fi

    rm -rf "${BUILD_DIR}"
    run_with_progress "[9/13] Configuring ponyc (Release)" \
        cmake --preset "${ACTIVE_PRESET}" "${CONFIG_CMAKE_ARGS[@]}" "${RELEASE_LTO_ARGS[@]}"

    run_with_progress "[10/13] Compiling ponyc (Release)" \
        cmake --build "${BUILD_DIR}" --target ponyc --parallel "${JOBS}"

    if [ "${BUILD_TOOLS}" -eq 1 ]; then
        run_with_progress "[11/13] Compiling pony-lsp/lint/doc" \
            env "${RELEASE_BUILD_ENV[@]}" cmake --build "${BUILD_DIR}" --parallel "${JOBS}"
    else
        printf "%-38s [SKIPPED] -> Deselected by user\n" "[11/13] Compiling pony-lsp/lint/doc"
    fi

    if [ "${RUN_TESTS}" = "1" ]; then
        run_with_progress "[11/13] Testing ponyc & tools (ci-core)" \
            env PONY_TEST_DEBUGGER="${TEST_DEBUGGER_CMD}" \
                ctest --test-dir "${BUILD_DIR}" -L ci-core --output-on-failure
    fi

    cleanup_previous_install "ponyc" "ponyc" "pony-lsp" "pony-lint" "pony-doc"
    run_with_progress "[12/13] Installing ponyc & tools" \
        ${SUDO} cmake --install "${BUILD_DIR}" --prefix "${PREFIX_BASE}/ponyc"

    if [ -n "${BIN_DIR}" ]; then
        run_with_progress "[13/13] Symlinking binaries" \
            bash -c "${SUDO} mkdir -p '${BIN_DIR}' && for tool in ponyc pony-lsp pony-lint pony-doc; do [ -x '${PREFIX_BASE}/ponyc/bin/'\"\${tool}\" ] && ${SUDO} ln -sf '${PREFIX_BASE}/ponyc/bin/'\"\${tool}\" '${BIN_DIR}/'\"\${tool}\"; done"
    else
        printf "%-38s [SKIPPED] -> BIN_DIR is empty\n" "[13/13] Symlinking binaries"
    fi
else
    printf "%-38s [SKIPPED] -> Deselected by user\n" "[9/13 - 13/13] ponyc (Release)"
fi

