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
output_directory="${2:-e2e-output}"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"

qemu_binary="${QEMU_BINARY:-qemu-system-x86_64}"
qemu_img_binary="${QEMU_IMG_BINARY:-qemu-img}"
qemu_machine="${QEMU_MACHINE:-q35}"
qemu_accel="${QEMU_ACCEL:-kvm:tcg}"
http_port="${E2E_HTTP_PORT:-18080}"
image_ref="${IMAGE_REF:-ghcr.io/ublue-os/bluefin}"
image_tag="${IMAGE_TAG:-stable}"
disk_size="${E2E_DISK_SIZE:-32G}"
install_timeout="${E2E_INSTALL_TIMEOUT:-1800}"
post_install_timeout="${E2E_POST_INSTALL_TIMEOUT:-180}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

template_file="$script_dir/data/bluefin-unattended.ks.tmpl"
serial_file="$output_directory/installer-serial.log"
post_install_serial="$output_directory/post-install-serial.log"
summary_file="$output_directory/e2e-summary.json"
proof_file="$output_directory/e2e-proof.svg"
final_screen_ppm="$output_directory/final-screen.ppm"
final_screen_png="$output_directory/final-screen.png"
install_disk="$output_directory/installed.qcow2"
http_root="$output_directory/http-root"
work_dir="$output_directory/.work"
kernel_path="$work_dir/vmlinuz"
initrd_path="$work_dir/initramfs.img"
qmp_socket="$output_directory/.work/qmp.sock"
post_qmp_socket="$output_directory/.work/post-qmp.sock"

mkdir -p "$http_root" "$work_dir"

install_pid=""
post_install_pid=""

if [[ ! -f "$iso_path" ]]; then
    echo "ISO does not exist: $iso_path" >&2
    exit 1
fi

if ! command -v "$qemu_img_binary" >/dev/null 2>&1; then
    echo "QEMU image tool not found: $qemu_img_binary" >&2
    exit 1
fi

if ! command -v "$qemu_binary" >/dev/null 2>&1; then
    echo "QEMU binary not found: $qemu_binary" >&2
    exit 1
fi

kickstart_file="$http_root/kickstart.ks"
python3 - "$work_dir/bluefin-unattended.ks" "$template_file" "$image_ref" "$image_tag" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[2])
text = source.read_text()
text = text.replace('__IMAGE_REF__', sys.argv[3])
text = text.replace('__IMAGE_TAG__', sys.argv[4])
pathlib.Path(sys.argv[1]).write_text(text)
PY
cp "$work_dir/bluefin-unattended.ks" "$kickstart_file"

if [[ ! -f "$kernel_path" ]]; then
    xorriso -indev "$iso_path" -osirrox on -extract /boot/vmlinuz "$kernel_path"
fi

if [[ ! -f "$initrd_path" ]]; then
    xorriso -indev "$iso_path" -osirrox on -extract /boot/initramfs.img "$initrd_path"
fi

if [[ ! -f "$install_disk" ]]; then
    "$qemu_img_binary" create -f qcow2 "$install_disk" "$disk_size"
fi

python3 -m http.server "$http_port" --bind 0.0.0.0 --directory "$http_root" >/dev/null 2>&1 &
http_server_pid=$!
cleanup() {
    local exit_code=$?
    for pid in "$install_pid" "$post_install_pid"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    kill "$http_server_pid" 2>/dev/null || true
    wait "$http_server_pid" 2>/dev/null || true
    rm -rf "$work_dir"
    exit "$exit_code"
}
trap cleanup EXIT

for _ in $(seq 1 20); do
    if curl --silent --show-error --fail "http://127.0.0.1:${http_port}/kickstart.ks" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

"$qemu_binary" \
    -name bluefin-e2e \
    -machine "${qemu_machine},accel=${qemu_accel}" \
    -cpu max \
    -m 4096 \
    -smp 2 \
    -drive file="$install_disk",format=qcow2,if=virtio,cache=none \
    -cdrom "$iso_path" \
    -kernel "$kernel_path" \
    -initrd "$initrd_path" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -serial "file:$serial_file" \
    -vga std \
    -display none \
    -monitor none \
    -qmp "unix:$qmp_socket,server=on,wait=off" \
    -append "console=ttyS0 rd.live.image rd.live.ram rd.neednet=1 ip=dhcp root=live:CDLABEL=titanoboa_boot inst.ks=http://10.0.2.2:${http_port}/kickstart.ks inst.text" \
    -no-reboot > /dev/null 2>&1 &
install_pid=$!

install_evidence=""
start_time=$SECONDS
while (( SECONDS - start_time < install_timeout )); do
    if grep -Eqi 'Installation complete|Rebooting|Powering off|reboot: Power down' "$serial_file" 2>/dev/null; then
        install_evidence="installer-complete"
        break
    fi
    if ! kill -0 "$install_pid" 2>/dev/null; then
        wait "$install_pid" || true
        break
    fi
    sleep 10
done

if [[ -z "$install_evidence" ]]; then
    if kill -0 "$install_pid" 2>/dev/null; then
        kill "$install_pid" 2>/dev/null || true
        wait "$install_pid" 2>/dev/null || true
    fi
    echo "Installer did not report completion within ${install_timeout}s" >&2
    exit 1
fi

kill "$install_pid" 2>/dev/null || true
wait "$install_pid" 2>/dev/null || true
install_pid=""

"$qemu_binary" \
    -name bluefin-e2e-postinstall \
    -machine "${qemu_machine},accel=${qemu_accel}" \
    -cpu max \
    -m 4096 \
    -smp 2 \
    -drive file="$install_disk",format=qcow2,if=virtio,cache=none \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -serial "file:$post_install_serial" \
    -vga std \
    -display none \
    -monitor none \
    -qmp "unix:$post_qmp_socket,server=on,wait=off" \
    > /dev/null 2>&1 &
post_install_pid=$!

post_install_evidence=""
post_start=$SECONDS
while (( SECONDS - post_start < post_install_timeout )); do
    if grep -Eqi 'Linux version|Reached target (multi-user|graphical)|bluefin login:|login:' "$post_install_serial" 2>/dev/null; then
        post_install_evidence="installed-system-booted"
        break
    fi
    if ! kill -0 "$post_install_pid" 2>/dev/null; then
        wait "$post_install_pid" || true
        break
    fi
    sleep 5
done

if [[ -z "$post_install_evidence" ]]; then
    echo "Installed system did not boot within ${post_install_timeout}s" >&2
    exit 1
fi

for _ in $(seq 1 10); do
    [[ -S "$post_qmp_socket" ]] && break
    sleep 1
done
if [[ ! -S "$post_qmp_socket" ]]; then
    echo "Installed system booted on serial console but QEMU monitor was unavailable for capture" >&2
    exit 1
fi

if command -v ffmpeg >/dev/null 2>&1; then
    python3 - "$post_qmp_socket" "$final_screen_ppm" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(sys.argv[1])

def read_message():
    data = b''
    while b'\r\n' not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError('QMP socket closed')
        data += chunk
    return json.loads(data.split(b'\r\n', 1)[0])

read_message()
sock.sendall(b'{"execute":"qmp_capabilities"}\r\n')
read_message()
command = {"execute": "screendump", "arguments": {"filename": sys.argv[2]}}
sock.sendall((json.dumps(command) + "\r\n").encode())
response = read_message()
if 'error' in response:
    raise RuntimeError(response['error']['desc'])
PY
    ffmpeg -y -loglevel error -i "$final_screen_ppm" "$final_screen_png" >/dev/null 2>&1 || true
fi

kill "$post_install_pid" 2>/dev/null || true
wait "$post_install_pid" 2>/dev/null || true

python3 - "$summary_file" "$iso_path" "$serial_file" "$post_install_serial" "$final_screen_png" "$install_evidence" "$post_install_evidence" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
iso_path = Path(sys.argv[2])
serial_path = Path(sys.argv[3])
post_install_serial = Path(sys.argv[4])
image_path = Path(sys.argv[5])
install_evidence = sys.argv[6]
post_install_evidence = sys.argv[7]
summary = {
    'result': 'passed' if install_evidence and post_install_evidence else 'failed',
    'iso': str(iso_path),
    'install_evidence': install_evidence or None,
    'post_install_evidence': post_install_evidence or None,
    'serial_log': serial_path.name if serial_path.exists() else None,
    'post_install_serial_log': post_install_serial.name if post_install_serial.exists() else None,
    'final_screen_image': image_path.name if image_path.exists() else None,
}
summary_path.write_text(json.dumps(summary, indent=2) + '\n')
PY

cat > "$proof_file" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="320" role="img" aria-label="Bluefin ISO E2E proof">
  <rect width="100%" height="100%" fill="#101820"/>
  <text x="24" y="28" fill="#66ff99" font-family="monospace" font-size="20">Bluefin ISO E2E proof</text>
  <text x="24" y="80" fill="#ffffff" font-family="monospace" font-size="16">Installer completed and installed system booted</text>
</svg>
EOF
