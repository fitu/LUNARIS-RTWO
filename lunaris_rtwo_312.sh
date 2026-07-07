#!/usr/bin/env bash
set -o pipefail

if [ ! -f build/envsetup.sh ]; then
  echo "Error: run this from the Android source root."
  exit 1
fi

if ! command -v patchelf >/dev/null 2>&1; then
  sudo apt update || true
  sudo apt install patchelf -y || true
fi

if ! command -v patchelf >/dev/null 2>&1; then
  echo "Error: patchelf is still missing."
  exit 1
fi

unset CC_WRAPPER
unset CCACHE_EXEC
unset CCACHE_DIR
unset CCACHE_BASEDIR
unset CCACHE_COMPILERCHECK
export USE_CCACHE=0
export CCACHE_DISABLE=1

export WITH_GMS=false
export LANGUAGE=C
export LC_ALL=C

python3 <<'PY'
from pathlib import Path
import re

def disable_bp(path_str):
    p = Path(path_str)
    if p.exists():
        disabled = p.with_name(p.name + ".disabled")
        if not disabled.exists():
            disabled.write_text(p.read_text())
        p.unlink()

def update_soong_imports(bp_path_str, add_imports, remove_imports=None):
    if remove_imports is None:
        remove_imports = []

    bp = Path(bp_path_str)

    if not bp.exists():
        bp.write_text('soong_namespace {\n    imports: [\n    ],\n}\n')

    s = bp.read_text()

    if "soong_namespace" not in s:
        s = 'soong_namespace {\n    imports: [\n    ],\n}\n\n' + s

    for rem in remove_imports:
        s = re.sub(r'\n\s*"' + re.escape(rem) + r'",?', "", s)

    ns_start = s.find("soong_namespace")
    ns_chunk = s[ns_start:ns_start + 1000]

    if "imports:" not in ns_chunk:
        s = re.sub(
            r"soong_namespace\s*{\s*",
            "soong_namespace {\n    imports: [\n    ],\n",
            s,
            count=1,
        )

    m = re.search(r"imports\s*:\s*\[", s)

    if not m:
        s = re.sub(
            r"soong_namespace\s*{\s*",
            "soong_namespace {\n    imports: [\n    ],\n",
            s,
            count=1,
        )
        m = re.search(r"imports\s*:\s*\[", s)

    insert_at = m.end()

    additions = ""
    for imp in add_imports:
        quoted = '"' + imp + '"'
        if quoted not in s:
            additions += '\n        "' + imp + '",'

    if additions:
        s = s[:insert_at] + additions + s[insert_at:]

    bp.write_text(s)

def find_module_block(text, module_name):
    name_pos = text.find('name: "' + module_name + '"')
    if name_pos == -1:
        return None

    start = text.rfind("{", 0, name_pos)
    if start == -1:
        return None

    depth = 0
    end = None

    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break

    if end is None:
        return None

    return start, end

def find_list_end(text, list_start):
    depth = 0
    for i in range(list_start, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return i
    return None

def add_shared_lib_to_module(bp_path_str, module_name, lib_name):
    bp = Path(bp_path_str)
    if not bp.exists():
        return

    s = bp.read_text()
    block_range = find_module_block(s, module_name)

    if block_range is None:
        return

    start, end = block_range
    block = s[start:end]

    shared_match = re.search(r"shared_libs\s*:\s*\[", block)

    if shared_match:
        shared_start_abs = start + shared_match.start()
        list_open_abs = start + shared_match.end() - 1
        list_close_abs = find_list_end(s, list_open_abs)

        if list_close_abs is None:
            return

        shared_block = s[list_open_abs:list_close_abs]

        if '"' + lib_name + '"' not in shared_block:
            insert_at = list_open_abs + 1
            s = s[:insert_at] + '\n        "' + lib_name + '",' + s[insert_at:]
    else:
        addition = '\n    shared_libs: [\n        "' + lib_name + '",\n    ],\n'
        s = s[:end] + addition + s[end:]

    bp.write_text(s)

disable_bp("prebuilts/misc/protobuf_vendorcompat/Android.bp")

update_soong_imports(
    "hardware/qcom-caf/sm8550/Android.bp",
    add_imports=[
        "hardware/qcom-caf/sm8450",
    ],
    remove_imports=[
        "vendor/motorola/sm8550-common",
    ],
)

add_shared_lib_to_module(
    "hardware/qcom-caf/sm8550/display/gralloc/Android.bp",
    "libgralloccore",
    "libvmmem",
)

for folder in [
    "hardware/qcom-caf/sm8450-6.6/display",
    "hardware/qcom-caf/sm8650/display",
    "hardware/qcom-caf/sm8750/display",
]:
    root = Path(folder)
    if root.exists():
        for bp in root.rglob("Android.bp"):
            disable_bp(str(bp))

mk = Path("device/motorola/rtwo/lineage_rtwo.mk")
s = mk.read_text()
s = re.sub(r"(?m)^\s*TARGET_CUSTOM_UDFPS\s*:=.*\n?", "", s)
s = re.sub(r"(?m)^\s*WITH_GMS\s*:=.*\n?", "", s)
s = s.rstrip() + "\n\n# Lunaris options\nTARGET_CUSTOM_UDFPS := true\nWITH_GMS := false\n"
mk.write_text(s)

vh = Path("kernel/motorola/sm8550/include/uapi/linux/videodev2.h")
if vh.exists():
    s = vh.read_text()

    if "#include <linux/time_types.h>" not in s:
        if "#include <linux/time.h>" in s:
            s = s.replace(
                "#include <linux/time.h>\n",
                "#include <linux/time.h>\n#include <linux/time_types.h>\n",
                1,
            )
        elif "#include <linux/types.h>" in s:
            s = s.replace(
                "#include <linux/types.h>\n",
                "#include <linux/types.h>\n#include <linux/time_types.h>\n",
                1,
            )

    s = re.sub(
        r"struct\s+(?:timespec|__kernel_old_timespec|__kernel_timespec)\s+timestamp;",
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
    s = re.sub(rf"(?m)^\s*{key}\s*:=.*\n?", "", s)

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

PATCH_RC=$?
if [ "$PATCH_RC" -ne 0 ]; then
  echo "Patch step failed."
  exit "$PATCH_RC"
fi

. build/envsetup.sh || exit 1
lunch lineage_rtwo-bp4a-userdebug || exit 1

m installclean || exit 1

m bacon
BUILD_RC=$?

if [ "$BUILD_RC" -eq 0 ]; then
  ls -lah out/target/product/rtwo/*.zip out/target/product/rtwo/*.img 2>/dev/null || true
fi

exit "$BUILD_RC"
