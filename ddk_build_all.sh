#!/bin/bash
set -euo pipefail

# ==============================================================
#  Android 内核驱动 (lsdriver.ko) 多版本批量编译脚本
#  修复版：不会自删、安全清理
# ==============================================================

# -------------------------- 核心配置 --------------------------
BUILD_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CLANG_ROOT="${CLANG_ROOT:-/opt/ddk/clang}"
KERNELS_ROOT="${KERNELS_ROOT:-/opt/ddk/kdir}"
DRIVER_SRC="${DRIVER_SRC:-$BUILD_ROOT/lsdriver}"
NO_STRIP_VERSIONS=("android16-6.12" "android15-6.6")

# -------------------------- 颜色定义 --------------------------
GREEN='\e[32m'
RED='\e[31m'
YELLOW='\e[33m'
BLUE='\e[34m'
NC='\e[0m'

# -------------------------- 全局变量 --------------------------
declare -a BUILD_RESULTS=()
STRIP_CHOICE="${STRIP_CHOICE:-}"

# -------------------------- 日志函数 --------------------------
log_info()  { echo -e "${GREEN}$*${NC}"; }
log_warn()  { echo -e "${YELLOW}$*${NC}"; }
log_error() { echo -e "${RED}$*${NC}"; }
log_title() { echo -e "${BLUE}====================================================${NC}"; }

# -------------------------- 清理编译缓存（修复版！不会删脚本） --------------------------

# 清理 Kbuild 中间文件，保留源码、构建脚本和所有 .ko
clean_driver_build() {
    if [[ ! -d "$DRIVER_SRC" ]]; then
        log_error "driver source directory not found: $DRIVER_SRC"
        return 1
    fi

    find "$DRIVER_SRC" -type f \( \
        -name '*.o' -o \
        -name '*.o.d' -o \
        -name '*.mod' -o \
        -name '*.mod.c' -o \
        -name '*.order' -o \
        -name '*.symvers' -o \
        -name '*.cmd' -o \
        -name '*.usyms' \
    \) -delete

    find "$DRIVER_SRC" -type d -name '.tmp_versions' -prune -exec rm -rf -- {} +
}

cleanup_driver_build_on_exit() {
    local status=$?

    trap - EXIT
    clean_driver_build || true
    exit "$status"
}

# -------------------------- 处理编译产物 --------------------------
handle_output() {
    local version="$1"
    local source_ko="$DRIVER_SRC/lsdriver.ko"
    local target_ko="$DRIVER_SRC/${version}lsdriver.ko"
    if [[ ! -f "$source_ko" ]]; then
        log_error "❌ $version 编译失败（未生成 .ko 文件）"
        BUILD_RESULTS+=("$version: ❌ 编译失败")
        return 1
    fi

    local force_no_strip=false
    for v in "${NO_STRIP_VERSIONS[@]}"; do
        [[ "$version" == "$v" ]] && force_no_strip=true && break
    done

    if [[ "$force_no_strip" == "true" ]]; then
        log_warn "⚠️ $version 强制保留符号（剥离后无法加载）"
        cp "$source_ko" "$target_ko" || return $?
    elif [[ "$STRIP_CHOICE" == "y" || "$STRIP_CHOICE" == "Y" ]]; then
        if command -v llvm-strip &>/dev/null; then
            log_info "🔧 剥离 $version 符号..."
            llvm-strip --strip-debug -o "$target_ko" "$source_ko" || return $?
        else
            log_warn "⚠️ 未找到 llvm-strip，直接复制"
            cp "$source_ko" "$target_ko" || return $?
        fi
    else
        cp "$source_ko" "$target_ko" || return $?
    fi

    BUILD_RESULTS+=("$version: ✅ 编译成功")
    log_info "✅ 生成产物：$target_ko"
}

# -------------------------- 核心编译函数 --------------------------
build_kernel() {
    local version="$1"
    local clang_path="$2"
    local cross_compile="$3"

    local kernel_dir="$KERNELS_ROOT/$version"
    log_title
    log_warn "开始编译：$version"

    if [[ ! -d "$kernel_dir" ]]; then
        log_error "❌ 内核目录不存在：$kernel_dir"
        BUILD_RESULTS+=("$version: ❌ 目录不存在")
        return 1
    fi

    clean_driver_build

    # 临时禁用 BTF
    if [[ -f "$kernel_dir/.config" ]]; then
        sed -i 's/CONFIG_DEBUG_INFO_BTF=y/CONFIG_DEBUG_INFO_BTF=n/g' "$kernel_dir/.config"
    fi

    log_info "🚀 执行编译命令..."
    export PATH="$clang_path:$PATH"
    make -C "$kernel_dir" \
        M="$DRIVER_SRC" \
        ARCH=arm64 \
        CROSS_COMPILE="$cross_compile" \
        LLVM=1 \
        LLVM_IAS=1 \
        PATH="$PATH" \
        CONFIG_DEBUG_INFO_BTF=n \
        modules -j"$(nproc)"

    local output_status=0
    handle_output "$version" || output_status=$?
    clean_driver_build
    return "$output_status"
}

# -------------------------- 主函数 --------------------------
main() {
    # 指定版本时仅构建对应目标；无参数时仍构建全部版本。
    local targets=("$@")
    local version clang_version input
    if [[ ${#targets[@]} -eq 0 ]]; then
        targets=(android16-6.12 android15-6.6 android14-6.1 android13-5.15 android13-5.10 android12-5.10)
    fi

    # 在清理文件或修改内核配置之前检查所有输入。
    for version in "${targets[@]}"; do
        case "$version" in
            android16-6.12|android15-6.6|android14-6.1|android13-5.15|android13-5.10|android12-5.10) ;;
            *) log_error "不支持的 DDK 构建目标: $version"; return 2 ;;
        esac
    done

    # CI 可设置 STRIP_CHOICE=y/n；非交互执行默认保留符号。
    if [[ -z "$STRIP_CHOICE" ]]; then
        STRIP_CHOICE="n"
        if [[ -t 0 ]]; then
            log_warn "是否剥离符号？(y=剥离/减小体积，n=保留/调试用)"
            read -rp "请输入 (y/n，默认 n): " input || input="n"
            [[ "$input" =~ ^[Yy]$ ]] && STRIP_CHOICE="y"
        fi
    fi
    case "$STRIP_CHOICE" in
        y|Y|n|N) ;;
        *) log_error "STRIP_CHOICE 必须为 y 或 n"; return 2 ;;
    esac
    readonly STRIP_CHOICE

    if [[ ! -d "$DRIVER_SRC" ]]; then
        log_error "driver source directory not found: $DRIVER_SRC"
        return 1
    fi
    if [[ ! -f "$DRIVER_SRC/arm64_ptedbg.h" ]]; then
        log_warn "arm64_ptedbg.h 缺失：PTE 断点已禁用，设置请求返回 -EOPNOTSUPP。"
    fi

    trap cleanup_driver_build_on_exit EXIT
    for version in "${targets[@]}"; do
        case "$version" in
            android16-6.12) clang_version=clang-r536225 ;;
            android15-6.6) clang_version=clang-r510928 ;;
            android14-6.1) clang_version=clang-r487747c ;;
            android13-5.15|android13-5.10) clang_version=clang-r450784e ;;
            android12-5.10) clang_version=clang-r416183b ;;
        esac
        build_kernel "$version" "$CLANG_ROOT/$clang_version/bin" "aarch64-linux-gnu-"
    done

    log_title
    echo -e "\n${BLUE}📊 编译结果汇总:${NC}"
    echo "----------------------------------------------------"
    for result in "${BUILD_RESULTS[@]}"; do
        echo -e "  $result"
    done
    echo "----------------------------------------------------"

    echo -e "\n${BLUE}📦 生成的产物列表:${NC}"
    ls -lh "$DRIVER_SRC"/android*.ko 2>/dev/null || log_error "❌ 未找到任何 .ko 产物"

    log_title
    log_info "🎉 批量编译脚本执行完成！"
}

main "$@"