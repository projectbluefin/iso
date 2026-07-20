#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 ISO_PATH [OUTPUT_DIRECTORY]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

iso_path="$1"
output_directory="${2:-smoke-output}"
timeout_seconds="${QEMU_TIMEOUT_SECONDS:-90}"
qemu_binary="${QEMU_BINARY:-qemu-system-x86_64}"
qemu_machine="${QEMU_MACHINE:-q35}"
qemu_accel="${QEMU_ACCEL:-kvm:tcg}"

mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
proof_file="$output_directory/smoke-proof.svg"
summary_file="$output_directory/smoke-summary.json"
screen_file="$output_directory/smoke-screen.ppm"
screen_png="$output_directory/smoke-screen.png"
serial_file="$output_directory/serial.log"
runtime_directory="$output_directory/.runtime"
qmp_socket="$runtime_directory/qmp.sock"

result_message=""
qemu_status="not-started"
boot_evidence="none"
qemu_pid=""

write_results() {
    local exit_code="$1"
    local result="failed"

    if [[ "$exit_code" -eq 0 ]]; then
        result="passed"
    fi

    ISO_PATH="$iso_path" \
    RESULT="$result" \
    RESULT_MESSAGE="$result_message" \
    QEMU_STATUS="$qemu_status" \
    BOOT_EVIDENCE="$boot_evidence" \
    SCREEN_FILE="$screen_file" \
    SCREEN_PNG="$screen_png" \
    SERIAL_FILE="$serial_file" \
    SUMMARY_FILE="$summary_file" \
    PROOF_FILE="$proof_file" \
    python3 - <<'PY'
import hashlib
import html
import json
import os
from pathlib import Path

iso = Path(os.environ["ISO_PATH"])
screen = Path(os.environ["SCREEN_FILE"])
serial = Path(os.environ["SERIAL_FILE"])

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

summary = {
    "result": os.environ["RESULT"],
    "message": os.environ["RESULT_MESSAGE"],
    "iso": str(iso),
    "iso_sha256": sha256(iso) if iso.is_file() else None,
    "iso_size_bytes": iso.stat().st_size if iso.is_file() else None,
    "qemu_status": os.environ["QEMU_STATUS"],
    "boot_evidence": os.environ["BOOT_EVIDENCE"],
    "screen_capture": screen.name if screen.is_file() else None,
"screen_image": os.path.basename(os.environ["SCREEN_PNG"]) if os.path.exists(os.environ["SCREEN_PNG"]) else None,
"serial_log": serial.name if serial.is_file() else None,
}
Path(os.environ["SUMMARY_FILE"]).write_text(json.dumps(summary, indent=2) + "\n")

rows = "".join(
    f"<text x='24' y='{48 + index * 28}'>{html.escape(f'{key}: {value}')}</text>"
    for index, (key, value) in enumerate(summary.items())
)
proof = """<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="320" role="img"
  aria-label="ISO smoke test proof">
  <rect width="100%" height="100%" fill="#101820"/>
  <text x="24" y="28" fill="#66ff99" font-family="monospace" font-size="20">Bluefin ISO smoke test</text>
  <g fill="#ffffff" font-family="monospace" font-size="16">""" + rows + """</g>
</svg>
"""
Path(os.environ["PROOF_FILE"]).write_text(proof)
PY
}

convert_screen_to_png() {
    if [[ -f "$screen_file" ]] && command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -y -loglevel error -i "$screen_file" "$screen_png" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    local exit_code=$?

    if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi

    convert_screen_to_png
    rm -rf "$runtime_directory"
    write_results "$exit_code"
}

trap cleanup EXIT

fail() {
    result_message="$1"
    echo "Error: $result_message" >&2
    exit 1
}

qmp_status() {
    python3 - "$qmp_socket" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])

def read_message():
    data = b""
    while b"\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("QMP socket closed")
        data += chunk
    return json.loads(data.split(b"\r\n", 1)[0])

read_message()
sock.sendall(b'{"execute":"qmp_capabilities"}\r\n')
read_message()
sock.sendall(b'{"execute":"query-status"}\r\n')
print(read_message()["return"]["status"])
PY
}

capture_screen() {
    python3 - "$qmp_socket" "$screen_file" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(sys.argv[1])

def read_message():
    data = b""
    while b"\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("QMP socket closed")
        data += chunk
    return json.loads(data.split(b"\r\n", 1)[0])

read_message()
sock.sendall(b'{"execute":"qmp_capabilities"}\r\n')
read_message()
command = {"execute": "screendump", "arguments": {"filename": sys.argv[2]}}
sock.sendall((json.dumps(command) + "\r\n").encode())
response = read_message()
if "error" in response:
    raise RuntimeError(response["error"]["desc"])
PY
}

[[ -f "$iso_path" ]] || fail "ISO does not exist: $iso_path"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || fail "QEMU_TIMEOUT_SECONDS must be a positive integer"
command -v "$qemu_binary" >/dev/null || fail "qemu-system-x86_64 is not installed"
command -v xorriso >/dev/null || fail "xorriso is not installed"

if ! xorriso -indev "$iso_path" -report_el_torito plain 2>&1 | grep -q "El Torito"; then
    fail "ISO has no readable El Torito boot catalog"
fi

mkdir -p "$runtime_directory"
"$qemu_binary" \
    -name iso-smoke-test \
    -machine ${qemu_machine},accel=${qemu_accel} \
    -cpu max \
    -m 4096 \
    -smp 2 \
    -boot once=d \
    -cdrom "$iso_path" \
    -vga std \
    -display none \
    -serial "file:$serial_file" \
    -monitor none \
    -qmp "unix:$qmp_socket,server=on,wait=off" \
    -no-reboot &
qemu_pid=$!

for _ in $(seq 1 15); do
    [[ -S "$qmp_socket" ]] && break
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        wait "$qemu_pid" || true
        fail "QEMU exited before its monitor became available"
    fi
    sleep 1
done

[[ -S "$qmp_socket" ]] || fail "QEMU monitor did not become available"

deadline=$((SECONDS + timeout_seconds))
started_at=$SECONDS
while (( SECONDS < deadline )); do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        wait "$qemu_pid" || true
        fail "QEMU exited before the ISO completed its boot smoke window"
    fi

    qemu_status="$(qmp_status)" || fail "Unable to query QEMU monitor status"
    [[ "$qemu_status" == "running" ]] || fail "QEMU is not running (status: $qemu_status)"

    if grep -Eqi 'Linux version|dracut|anaconda|Starting ' "$serial_file" 2>/dev/null; then
        boot_evidence="serial-console"
        break
    fi

    sleep 5
done

if [[ "$boot_evidence" == "none" ]]; then
    boot_evidence="qemu-running"
fi

capture_screen || fail "Unable to capture the QEMU display"
[[ -s "$screen_file" ]] || fail "QEMU display capture is empty"
result_message="QEMU ran for $((SECONDS - started_at)) seconds with ${boot_evidence} evidence"
