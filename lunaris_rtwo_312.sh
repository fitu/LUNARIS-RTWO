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

unset USE_CCACHE
unset CC_WRAPPER
unset CCACHE_EXEC
unset CCACHE_DIR
unset CCACHE_BASEDIR
unset CCACHE_COMPILERCHECK
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

def find_list_end(text, list_open_abs):
    depth = 0

    for i in range(list_open_abs, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return i

    return None

def add_list_item_to_module(bp_path_str, module_name, list_name, item_name):
    bp = Path(bp_path_str)
    if not bp.exists():
        return

    s = bp.read_text()
    block_range = find_module_block(s, module_name)

    if block_range is None:
        return

    start, end = block_range
    block = s[start:end]

    m = re.search(r"\b" + re.escape(list_name) + r"\s*:\s*\[", block)

    if m:
        list_open_abs = start + m.end() - 1
        list_close_abs = find_list_end(s, list_open_abs)

        if list_close_abs is None:
            return

        list_block = s[list_open_abs:list_close_abs]

        if '"' + item_name + '"' not in list_block:
            insert_at = list_open_abs + 1
            s = s[:insert_at] + '\n        "' + item_name + '",' + s[insert_at:]
    else:
        addition = '\n    ' + list_name + ': [\n        "' + item_name + '",\n    ],\n'
        s = s[:end] + addition + s[end:]

    bp.write_text(s)

def remove_list_item_from_module(bp_path_str, module_name, item_name):
    bp = Path(bp_path_str)
    if not bp.exists():
        return

    s = bp.read_text()
    block_range = find_module_block(s, module_name)

    if block_range is None:
        return

    start, end = block_range
    block = s[start:end]

    new_block = re.sub(
        r'\n\s*"' + re.escape(item_name) + r'",?',
        "",
        block,
    )

    s = s[:start] + new_block + s[end:]
    bp.write_text(s)

def patch_gr_dma_mgr_for_dlopen(path_str):
    p = Path(path_str)
    if not p.exists():
        return

    s = p.read_text()

    if "#include <dlfcn.h>" not in s:
        include_matches = list(re.finditer(r'^\s*#include\s+[<"].+[>"]\s*$', s, flags=re.M))
        if include_matches:
            last = include_matches[-1]
            s = s[:last.end()] + '\n#include <dlfcn.h>' + s[last.end():]
        else:
            s = '#include <dlfcn.h>\n' + s

    helper = r'''
namespace {
using CreateVmMemFunc = std::unique_ptr<VmMem> (*)();

std::unique_ptr<VmMem> CreateVmMemDlopen() {
    static void *libvmmem_handle = nullptr;
    static CreateVmMemFunc create_vm_mem = nullptr;

    if (!libvmmem_handle) {
        libvmmem_handle = dlopen("libvmmem.so", RTLD_NOW);
        if (!libvmmem_handle) {
            return nullptr;
        }

        create_vm_mem = reinterpret_cast<CreateVmMemFunc>(
            dlsym(libvmmem_handle, "_ZN5VmMem11CreateVmMemEv"));

        if (!create_vm_mem) {
            return nullptr;
        }
    }

    return create_vm_mem();
}
}  // namespace
'''

    if "CreateVmMemDlopen()" not in s:
        marker = "namespace gralloc {"
        pos = s.find(marker)

        if pos != -1:
            insert_at = pos + len(marker)
            s = s[:insert_at] + "\n" + helper + s[insert_at:]
        else:
            include_matches = list(re.finditer(r'^\s*#include\s+[<"].+[>"]\s*$', s, flags=re.M))
            if include_matches:
                last = include_matches[-1]
                s = s[:last.end()] + "\n" + helper + s[last.end():]
            else:
                s = helper + "\n" + s

    s = s.replace("VmMem::CreateVmMem()", "CreateVmMemDlopen()")

    p.write_text(s)

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

gralloc_bp = "hardware/qcom-caf/sm8550/display/gralloc/Android.bp"

remove_list_item_from_module(
    gralloc_bp,
    "libgralloccore",
    "libvmmem",
)

add_list_item_to_module(
    gralloc_bp,
    "libgralloccore",
    "shared_libs",
    "libdl",
)

add_list_item_to_module(
    gralloc_bp,
    "libgralloccore",
    "header_libs",
    "libvmmem_headers",
)

patch_gr_dma_mgr_for_dlopen(
    "hardware/qcom-caf/sm8550/display/gralloc/gr_dma_mgr.cpp"
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
