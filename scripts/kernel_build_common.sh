#!/bin/bash
# Shared version and modpost handling for source-tree and DDK builds.

update_driver_version() {
    if [[ ! -f "$VERSION_HEADER" ]]; then
        log_error "找不到驱动版本头文件: $VERSION_HEADER"
        return 1
    fi

    local current_version
    current_version=$(sed -nE 's/^[[:space:]]*#define[[:space:]]+LSDRIVER_VERSION[[:space:]]+"([^"]+)".*$/\1/p' "$VERSION_HEADER" | head -n 1)
    if [[ ! "$current_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        log_error "LSDRIVER_VERSION 必须使用 x.y.z 格式: $current_version"
        return 1
    fi

    local version_major=$((10#${BASH_REMATCH[1]}))
    local version_minor=$((10#${BASH_REMATCH[2]}))
    local version_patch=$((10#${BASH_REMATCH[3]}))
    if ((version_major > 12 || version_minor > 12 || version_patch > 12)); then
        log_error "版本号每一段都必须在 0 到 12 之间: $current_version"
        return 1
    fi

    if ((version_patch < 12)); then
        ((version_patch += 1))
    elif ((version_minor < 12)); then
        version_patch=0
        ((version_minor += 1))
    elif ((version_major < 12)); then
        version_patch=0
        version_minor=0
        ((version_major += 1))
    else
        log_error "版本号已经达到上限 12.12.12"
        return 1
    fi

    local next_version="$version_major.$version_minor.$version_patch"
    local temp_header="${VERSION_HEADER}.tmp.$$"
    sed -E "s/^([[:space:]]*#define[[:space:]]+LSDRIVER_VERSION[[:space:]]+\")[^\"]+(\".*)$/\1${next_version}\2/" \
        "$VERSION_HEADER" > "$temp_header"
    if ! grep -q "^[[:space:]]*#define[[:space:]]\+LSDRIVER_VERSION[[:space:]]\+\"${next_version}\"" "$temp_header"; then
        rm -f "$temp_header"
        log_error "无法更新驱动版本头文件: $VERSION_HEADER"
        return 1
    fi

    mv -f "$temp_header" "$VERSION_HEADER"
    log_info "驱动版本: $current_version -> $next_version"
}

fix_empty_ext_modversions() {
    local mod_c="$DRIVER_SRC/lsdriver.mod.c"

    if [[ ! -f "$mod_c" ]]; then
        return 1
    fi

    # Android 16 / 6.12 开启扩展 modversions 时，空 CRC 构建可能生成非法的：
    #   ____version_ext_names[] = ;
    # 这里把它修成空字符串，让最后的 mod.o/ko 链接继续完成。
    if grep -q '__section("__version_ext_names")' "$mod_c" && \
       grep -q '^[[:space:]]*;[[:space:]]*$' "$mod_c"; then
        perl -0pi -e 's/(__used __section\("__version_ext_names"\)\s*=\s*)\n\s*;/\1"";/s' "$mod_c"
        return 0
    fi

    return 1
}
