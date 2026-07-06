#!/usr/bin/env bash
set -o pipefail

if ! command -v patchelf >/dev/null 2>&1; then
  sudo apt update || true
  sudo apt install patchelf -y || true
fi

unset USE_CCACHE
unset CC_WRAPPER
unset CCACHE_EXEC
unset CCACHE_DIR
unset CCACHE_BASEDIR
unset CCACHE_COMPILERCHECK

export WITH_GMS=false
export LANGUAGE=C
export LC_ALL=C

python3 - <<PY
from pathlib import Path
import re

def disable_bp(path_str):
    p = Path(path_str)
    if p.exists():
        disabled = p.with_name(p.name + ".disabled")
        disabled.write_text(p.read_text())
        p.unlink()

def add_soong_imports(bp_path_str, imports_to_add):
    bp = Path(bp_path_str)
    if not bp.exists():
        bp.write_text("soong_namespace {\\n    imports: [\\n    ],\\n}\\n")

    s = bp.read_text()

    if "soong_namespace" not in s:
        s = "soong_namespace {\\n    imports: [\\n    ],\\n}\\n\\n" + s

    ns_start = s.find("soong_namespace")
    ns_chunk = s[ns_start:ns_start + 800]

    if "imports:" not in ns_chunk:
        s = re.sub(
            r"soong_namespace\\s*{\\s*",
            "soong_namespace {\\n    imports: [\\n    ],\\n",
            s,
            count=1,
        )

    m = re.search(r"imports\\s*:\\s*\\[", s)
    if not m:
        s = re.sub(
            r"soong_namespace\\s*{\\s*",
            "soong_namespace {\\n    imports: [\\n    ],\\n",
            s,
            count=1,
        )
        m = re.search(r"imports\\s*:\\s*\\[", s)

    insert_at = m.end()

    lines = ""
    for imp in imports_to_add:
        if f'"{imp}"' not in s:
            lines += f'\\n        "{imp}",'

    if lines:
        s = s[:insert_at] + lines + s[insert_at:]

    bp.write_text(s)

disable_bp("prebuilts/misc/protobuf_vendorcompat/Android.bp")

add_soong_imports(
    "hardware/qcom-caf/sm8550/Android.bp",
    [
        "hardware/qcom-caf/sm8450",
        "vendor/motorola/sm8550-common",
    ],
)

for bp in [
    "hardware/qcom-caf/sm8450-6.6/display/core/snapalloc/Android.bp",
    "hardware/qcom-caf/sm8450-6.6/display/hal/gralloc/Android.bp",
    "hardware/qcom-caf/sm8650/display/gralloc/Android.bp",
    "hardware/qcom-caf/sm8750/display/core/snapalloc/Android.bp",
    "hardware/qcom-caf/sm8750/display/hal/gralloc/Android.bp",
]:
    disable_bp(bp)

mk = Path("device/motorola/rtwo/lineage_rtwo.mk")
s = mk.read_text()
s = re.sub(r"(?m)^\\s*TARGET_CUSTOM_UDFPS\\s*:=.*\\n?", "", s)
s = re.sub(r"(?m)^\\s*WITH_GMS\\s*:=.*\\n?", "", s)
s = s.rstrip() + "\\n\\n# Lunaris options\\nTARGET_CUSTOM_UDFPS := true\\nWITH_GMS := false\\n"
mk.write_text(s)

vh = Path("kernel/motorola/sm8550/include/uapi/linux/videodev2.h")
if vh.exists():
    s = vh.read_text()

    if "#include <linux/time_types.h>" not in s:
        if "#include <linux/time.h>" in s:
            s = s.replace(
                "#include <linux/time.h>\\n",
                "#include <linux/time.h>\\n#include <linux/time_types.h>\\n",
                1,
            )
        elif "#include <linux/types.h>" in s:
            s = s.replace(
                "#include <linux/types.h>\\n",
                "#include <linux/types.h>\\n#include <linux/time_types.h>\\n",
                1,
            )

    s = re.sub(
        r"struct\\s+(?:timespec|__kernel_old_timespec|__kernel_timespec)\\s+timestamp;",
        "struct __kernel_timespec timestamp;",
        s,
    )

    vh.write_text(s)

bc = Path("device/motorola/rtwo/BoardConfig.mk")
s = bc.read_text()

for key in [
    "BOARD_PRODUCTIMAGE_PARTITION_RESERVED_SIZE",
    "BOARD_SYSTEMIMAGE_PARTITION_RESERVED_SIZE",
    "BOARD_SYSTEM_EXTIMAGE_PARTITION_RESERVED_SIZE",
    "BOARD_VENDORIMAGE_PARTITION_RESERVED_SIZE",
    "BOARD_SYSTEM_DLKMIMAGE_PARTITION_RESERVED_SIZE",
    "BOARD_VENDOR_DLKMIMAGE_PARTITION_RESERVED_SIZE",
]:
    s = re.sub(rf"(?m)^\\s*{key}\\s*:=.*\\n?", "", s)

s = s.rstrip() + """

# Lunaris: reduce dynamic partition padding to fit super
BOARD_PRODUCTIMAGE_PARTITION_RESERVED_SIZE := 0
BOARD_SYSTEMIMAGE_PARTITION_RESERVED_SIZE := 0
BOARD_SYSTEM_EXTIMAGE_PARTITION_RESERVED_SIZE := 0
BOARD_VENDORIMAGE_PARTITION_RESERVED_SIZE := 0

# Tiny ext4 partitions still need metadata headroom
BOARD_SYSTEM_DLKMIMAGE_PARTITION_RESERVED_SIZE := 4194304
BOARD_VENDOR_DLKMIMAGE_PARTITION_RESERVED_SIZE := 4194304
"""

bc.write_text(s)
PY

. build/envsetup.sh || true
lunch lineage_rtwo-bp4a-userdebug || exit 1

m installclean
m bacon

ls -lah out/target/product/rtwo/*.zip out/target/product/rtwo/*.img 2>/dev/null || true
