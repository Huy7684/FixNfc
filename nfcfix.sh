#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SOURCE_ROOT=""
CHECK_ONLY=0

usage() {
    cat <<EOF
Usage:
  bash $SCRIPT_NAME [--check] [DUONG_DAN_SOURCE_ROM]

Vi du:
  cd ~/aosp && bash /duong/dan/$SCRIPT_NAME
  bash $SCRIPT_NAME ~/aosp
  bash $SCRIPT_NAME --check ~/aosp

Tuy chon:
  --check     Chi kiem tra, khong sua tep.
  -h, --help  Hien huong dan nay.
EOF
}

die() {
    printf '[LOI] %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --check)
            CHECK_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if (($# > 1)); then
                die "Chi duoc truyen mot duong dan source ROM."
            fi
            if (($# == 1)); then
                SOURCE_ROOT="$1"
            fi
            break
            ;;
        -*)
            die "Tuy chon khong hop le: $1"
            ;;
        *)
            if [[ -n "$SOURCE_ROOT" ]]; then
                die "Chi duoc truyen mot duong dan source ROM."
            fi
            SOURCE_ROOT="$1"
            ;;
    esac
    shift
done

if [[ -z "$SOURCE_ROOT" ]]; then
    SOURCE_ROOT="$PWD"
fi

[[ -d "$SOURCE_ROOT" ]] || die "Khong tim thay thu muc: $SOURCE_ROOT"
command -v python3 >/dev/null 2>&1 || die "Can cai python3 de chay script."

SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"
printf '[INFO] Source ROM: %s\n' "$SOURCE_ROOT"

if ! python3 - "$SOURCE_ROOT" "$CHECK_ONLY" <<'PY'
from __future__ import annotations

import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


class NfcPatchError(Exception):
    pass


def clean_exception_hook(exception_type, exception, traceback) -> None:
    if issubclass(exception_type, NfcPatchError):
        print(f"[LOI] {exception}", file=sys.stderr)
        return
    sys.__excepthook__(exception_type, exception, traceback)


sys.excepthook = clean_exception_hook


@dataclass
class Document:
    path: Path
    original_bytes: bytes
    original_text: str
    text: str
    newline: str
    mode: int


root = Path(sys.argv[1])
check_only = sys.argv[2] == "1"

relative_paths = (
    "device/xiaomi/sapphire/BoardConfig.mk",
    "device/xiaomi/sapphire/device.mk",
    "device/xiaomi/sapphire/sepolicy/vendor/property_contexts",
    "device/xiaomi/sapphire/sepolicy/vendor/vendor_init.te",
    "device/xiaomi/sapphire/rootdir/etc/init.xiaomi.rc",
    "hardware/st/nfc/1.2/android.hardware.nfc@1.2-service.st.rc",
)


def load_document(relative_path: str) -> Document:
    path = root / relative_path
    raw = path.read_bytes()
    try:
        decoded = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise NfcPatchError(f"Tep khong phai UTF-8: {relative_path}") from exc

    newline = "\r\n" if b"\r\n" in raw and raw.count(b"\r\n") >= raw.count(b"\n") / 2 else "\n"
    normalized = decoded.replace("\r\n", "\n").replace("\r", "\n")
    return Document(
        path=path,
        original_bytes=raw,
        original_text=normalized,
        text=normalized,
        newline=newline,
        mode=stat.S_IMODE(path.stat().st_mode),
    )


missing = [relative_path for relative_path in relative_paths if not (root / relative_path).is_file()]
if missing:
    details = "\n".join(f"  - {item}" for item in missing)
    raise NfcPatchError(
        "Khong tim thay day du tep can thiet. Hay chay script tai thu muc goc source ROM:\n"
        + details
    )

documents = {relative_path: load_document(relative_path) for relative_path in relative_paths}
notes: list[tuple[str, str]] = []


def split_lines(text: str) -> list[str]:
    return text.split("\n")


def join_lines(lines: list[str]) -> str:
    return "\n".join(lines)


def note(relative_path: str, message: str) -> None:
    notes.append((relative_path, message))


def configure_board() -> None:
    relative_path = "device/xiaomi/sapphire/BoardConfig.mk"
    document = documents[relative_path]
    lines = split_lines(document.text)
    assignment_re = re.compile(
        r"^(?P<indent>[ \t]*)BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE[ \t]*:?="
        r"[ \t]*(?P<value>[^# \t]+)(?P<tail>[ \t]*(?:#.*)?)$"
    )
    matches = [(index, assignment_re.match(line)) for index, line in enumerate(lines)]
    matches = [(index, match) for index, match in matches if match]

    if matches:
        first_index, first_match = matches[0]
        assert first_match is not None
        lines[first_index] = (
            f"{first_match.group('indent')}BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE := true"
            f"{first_match.group('tail')}"
        )
        for index, _ in reversed(matches[1:]):
            del lines[index]
        document.text = join_lines(lines)
        note(relative_path, "Da chuan hoa BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE=true")
        return

    init_index = next(
        (index for index, line in enumerate(lines) if re.fullmatch(r"[ \t]*# Init[ \t]*", line)),
        None,
    )
    if init_index is not None:
        lines[init_index:init_index] = [
            "# Broken namespace",
            "BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE := true",
            "",
        ]
        document.text = join_lines(lines)
        note(relative_path, "Da them tuy chon vendor property namespace")
        return

    per_mgr_index = next(
        (
            index
            for index, line in enumerate(lines)
            if re.fullmatch(r"[ \t]*TARGET_PER_MGR_ENABLED[ \t]*:?=[ \t]*true[ \t]*", line)
        ),
        None,
    )
    if per_mgr_index is None:
        raise NfcPatchError(
            f"Khong tim thay vi tri chen an toan trong {relative_path}. Tree nay co the khong tuong thich."
        )

    lines[per_mgr_index + 1 : per_mgr_index + 1] = [
        "",
        "# Broken namespace",
        "BUILD_BROKEN_VENDOR_PROPERTY_NAMESPACE := true",
    ]
    document.text = join_lines(lines)
    note(relative_path, "Da them tuy chon vendor property namespace")


def configure_device_packages() -> None:
    relative_path = "device/xiaomi/sapphire/device.mk"
    document = documents[relative_path]
    lines = split_lines(document.text)
    old_package = "android.hardware.nfc-service.st"
    new_package = "android.hardware.nfc@1.2-service.st"

    def package_indices(package: str) -> list[int]:
        pattern = re.compile(rf"^[ \t]*{re.escape(package)}(?=[ \t]|\\|$)")
        return [index for index, line in enumerate(lines) if pattern.search(line)]

    old_indices = package_indices(old_package)
    new_indices = package_indices(new_package)

    if not old_indices and not new_indices:
        raise NfcPatchError(
            f"Khong tim thay {old_package} hoac {new_package} trong {relative_path}."
        )

    if new_indices:
        keep_index = new_indices[0]
        remove_indices = old_indices + new_indices[1:]
        for index in sorted(remove_indices, reverse=True):
            if index != keep_index:
                del lines[index]
        note(relative_path, "NFC HAL 1.2 da co; da loai bo dong trung neu co")
    else:
        first_index = old_indices[0]
        lines[first_index] = lines[first_index].replace(old_package, new_package, 1)
        for index in reversed(old_indices[1:]):
            del lines[index]
        note(relative_path, "Da doi goi NFC AIDL sang NFC HAL 1.2 ST")

    document.text = join_lines(lines)


def configure_property_contexts() -> None:
    relative_path = "device/xiaomi/sapphire/sepolicy/vendor/property_contexts"
    document = documents[relative_path]
    lines = split_lines(document.text)
    property_re = re.compile(r"^[ \t]*ro\.nfc\.port(?:[ \t]+.*)?$")
    indices = [index for index, line in enumerate(lines) if property_re.fullmatch(line)]
    wanted = "ro.nfc.port                              u:object_r:vendor_nfc_prop:s0"

    if indices:
        lines[indices[0]] = wanted
        for index in reversed(indices[1:]):
            del lines[index]
        note(relative_path, "Da chuan hoa ro.nfc.port va loai bo khai bao trung")
    else:
        while lines and lines[-1] == "":
            lines.pop()
        if lines and lines[-1].strip() == "# NFC":
            lines.append(wanted)
        else:
            lines.extend(["", "# NFC", wanted])
        lines.append("")
        note(relative_path, "Da them context cho ro.nfc.port")

    document.text = join_lines(lines)


def configure_vendor_init_policy() -> None:
    relative_path = "device/xiaomi/sapphire/sepolicy/vendor/vendor_init.te"
    document = documents[relative_path]
    lines = split_lines(document.text)
    rule_re = re.compile(
        r"^[ \t]*set_prop\([ \t]*vendor_init[ \t]*,[ \t]*vendor_nfc_prop[ \t]*\)[ \t]*;?[ \t]*$"
    )
    indices = [index for index, line in enumerate(lines) if rule_re.fullmatch(line)]
    wanted = "set_prop(vendor_init, vendor_nfc_prop)"

    if indices:
        lines[indices[0]] = wanted
        for index in reversed(indices[1:]):
            del lines[index]
        note(relative_path, "Da chuan hoa quyen set vendor_nfc_prop")
        document.text = join_lines(lines)
        return

    ril_re = re.compile(
        r"^[ \t]*set_prop\([ \t]*vendor_init[ \t]*,[ \t]*vendor_ril_prop[ \t]*\)[ \t]*;?[ \t]*$"
    )
    ril_index = next((index for index, line in enumerate(lines) if ril_re.fullmatch(line)), None)
    if ril_index is not None:
        insert_index = ril_index + 1
        if insert_index < len(lines) and lines[insert_index] == "":
            insert_index += 1
        lines[insert_index:insert_index] = ["# NFC:", wanted, ""]
        document.text = join_lines(lines)
        note(relative_path, "Da them quyen set vendor_nfc_prop")
        return

    usb_comment_index = next(
        (
            index
            for index, line in enumerate(lines)
            if line.strip().startswith("# Allow init.qcom.usb.sh")
        ),
        None,
    )
    if usb_comment_index is None:
        raise NfcPatchError(
            f"Khong tim thay vi tri chen an toan trong {relative_path}. Tree nay co the khong tuong thich."
        )

    lines[usb_comment_index:usb_comment_index] = ["# NFC:", wanted, ""]
    document.text = join_lines(lines)
    note(relative_path, "Da them quyen set vendor_nfc_prop")


def remove_duplicate_init_service() -> None:
    relative_path = "device/xiaomi/sapphire/rootdir/etc/init.xiaomi.rc"
    document = documents[relative_path]
    lines = split_lines(document.text)
    service_re = re.compile(r"^service[ \t]+vendor\.st_nfc_hal_service(?:[ \t]|$)")
    removed = 0
    index = 0

    while index < len(lines):
        if not service_re.match(lines[index]):
            index += 1
            continue

        end = index + 1
        while end < len(lines):
            line = lines[end]
            if line.strip() == "" or line[:1].isspace():
                end += 1
                continue
            break
        del lines[index:end]
        removed += 1

    document.text = join_lines(lines)
    if removed:
        note(relative_path, f"Da xoa {removed} service NFC trung khoi init.xiaomi.rc")
    else:
        note(relative_path, "Service NFC trung da duoc xoa tu truoc")


def configure_hal_rc_interfaces() -> None:
    relative_path = "hardware/st/nfc/1.2/android.hardware.nfc@1.2-service.st.rc"
    document = documents[relative_path]
    lines = split_lines(document.text)
    service_re = re.compile(r"^service[ \t]+vendor\.st_nfc_hal_service(?:[ \t]|$)")
    service_indices = [index for index, line in enumerate(lines) if service_re.match(line)]
    if len(service_indices) != 1:
        raise NfcPatchError(
            f"Can dung 1 service vendor.st_nfc_hal_service trong {relative_path}, tim thay {len(service_indices)}."
        )

    service_index = service_indices[0]
    stanza_end = service_index + 1
    while stanza_end < len(lines):
        line = lines[stanza_end]
        if line.strip() == "" or line[:1].isspace():
            stanza_end += 1
            continue
        break

    interface_re = re.compile(
        r"^[ \t]+interface[ \t]+android\.hardware\.nfc@1\.[012]::INfc[ \t]+default[ \t]*$"
    )
    stanza = [line for line in lines[service_index + 1 : stanza_end] if not interface_re.fullmatch(line)]
    wanted_interfaces = [
        "    interface android.hardware.nfc@1.2::INfc default",
        "    interface android.hardware.nfc@1.1::INfc default",
        "    interface android.hardware.nfc@1.0::INfc default",
    ]
    lines[service_index + 1 : stanza_end] = wanted_interfaces + stanza
    document.text = join_lines(lines)
    note(relative_path, "Da khai bao interface NFC 1.2, 1.1 va 1.0")


try:
    configure_board()
    configure_device_packages()
    configure_property_contexts()
    configure_vendor_init_policy()
    remove_duplicate_init_service()
    configure_hal_rc_interfaces()
except NfcPatchError:
    raise
except Exception as exc:
    raise NfcPatchError(f"Khong the xu ly patch: {exc}") from exc

changed = [relative_path for relative_path, document in documents.items() if document.text != document.original_text]

for relative_path, message in notes:
    marker = "DOI" if relative_path in changed else "OK"
    print(f"[{marker}] {relative_path}: {message}")

if check_only:
    if changed:
        print(f"[CHECK] Hop le. Se sua {len(changed)} tep; chua ghi thay doi.")
    else:
        print("[CHECK] NFC patch da duoc ap dung day du; khong can sua gi.")
    sys.exit(0)

if not changed:
    print("[OK] NFC patch da duoc ap dung day du. Khong co thay doi moi.")
    sys.exit(0)

temporary_paths: dict[str, Path] = {}
try:
    for relative_path in changed:
        document = documents[relative_path]
        output_text = document.text
        if document.newline == "\r\n":
            output_text = output_text.replace("\n", "\r\n")
        output_bytes = output_text.encode("utf-8")

        descriptor, temp_name = tempfile.mkstemp(
            prefix=f".{document.path.name}.nfc_master.",
            dir=document.path.parent,
        )
        temp_path = Path(temp_name)
        temporary_paths[relative_path] = temp_path
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(output_bytes)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temp_path, document.mode)
        except Exception:
            temp_path.unlink(missing_ok=True)
            raise

    for relative_path in changed:
        os.replace(temporary_paths[relative_path], documents[relative_path].path)
        temporary_paths.pop(relative_path, None)
except Exception as exc:
    for temp_path in temporary_paths.values():
        temp_path.unlink(missing_ok=True)
    raise NfcPatchError(f"Khong the ghi thay doi: {exc}") from exc

print(f"[THANH CONG] Da ap dung NFC patch vao {len(changed)} tep.")
PY
then
    printf '[LOI] Khong ap dung thay doi. Kiem tra thong bao phia tren.\n' >&2
    exit 1
fi
