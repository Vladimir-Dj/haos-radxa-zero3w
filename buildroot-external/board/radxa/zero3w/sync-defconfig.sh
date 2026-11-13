#!/bin/bash
# Regenerate radxa_zero3w_defconfig from the official odroid_m1s_defconfig
# (same RK3566 SoC). Keeps kernel / U-Boot / blob versions in sync with
# upstream after every rebase. Run from the repository root.
set -euo pipefail

CONFIGS="buildroot-external/configs"
SRC="${CONFIGS}/odroid_m1s_defconfig"
DST="${CONFIGS}/radxa_zero3w_defconfig"

sed -e 's#board/hardkernel/odroid-m1s#board/radxa/zero3w#g' \
    -e 's#rockchip/rk3566-odroid-m1s#rockchip/rk3566-radxa-zero-3w#' \
    -e 's#^BR2_TARGET_UBOOT_BOARD_DEFCONFIG=.*#BR2_TARGET_UBOOT_BOARD_DEFCONFIG="radxa-zero-3-rk3566"#' \
    -e 's#^BR2_PACKAGE_OS_AGENT_BOARD=.*#BR2_PACKAGE_OS_AGENT_BOARD="GenericAarch64"#' \
    "${SRC}" > "${DST}"

if grep -n 'odroid-m1s\|odroid_m1s\|OdroidM1S' "${DST}"; then
    echo "ERROR: leftover ODROID-M1S references in ${DST}" >&2
    exit 1
fi
for want in 'board/radxa/zero3w' 'rk3566-radxa-zero-3w' '"radxa-zero-3-rk3566"'; do
    grep -q "${want}" "${DST}" || { echo "ERROR: '${want}' missing in ${DST}" >&2; exit 1; }
done

if ! git diff --quiet -- "${DST}" 2>/dev/null; then
    echo "NOTE: ${DST} changed (upstream M1S defconfig was updated):"
    git --no-pager diff -- "${DST}"
fi
echo "${DST} is in sync with ${SRC}"
