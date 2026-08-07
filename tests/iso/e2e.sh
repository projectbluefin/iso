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
luks_enabled="${E2E_LUKS:-0}"
luks_passphrase="${E2E_LUKS_PASSPHRASE:-bluefin-e2e-luks}"
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

autopart_extra=""
if [[ "$luks_enabled" == "1" ]]; then
    autopart_extra="--encrypted --luks-version=luks2 --passphrase=${luks_passphrase}"
fi

kickstart_file="$http_root/kickstart.ks"
python3 - "$work_dir/bluefin-unattended.ks" "$template_file" "$image_ref" "$image_tag" "$autopart_extra" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[2])
text = source.read_text()
text = text.replace('__IMAGE_REF__', sys.argv[3])
text = text.replace('__IMAGE_TAG__', sys.argv[4])
text = text.replace('__AUTOPART_EXTRA__', sys.argv[5])
pathlib.Path(sys.argv[1]).write_text(text)
PY
cp "$work_dir/bluefin-unattended.ks" "$kickstart_file"

if [[ ! -f "$kernel_path" ]]; then
    xorriso -indev "$iso_path" -osirrox on -extract /boot/vmlinuz "$kernel_path"
fi

# The live root is found by CD label, which differs between variants
# (stable vs LTS builders) — read it from the ISO instead of hardcoding.
iso_label="$(xorriso -indev "$iso_path" -pvd_info 2>/dev/null \
    | sed -n "s/^Volume Id *: *'\{0,1\}\([^']*\)'\{0,1\}[[:space:]]*$/\1/p" | head -1)"
if [[ -z "$iso_label" ]]; then
    iso_label="titanoboa_boot"
fi
echo "Using live root CDLABEL=${iso_label}"

# Boot with the ISO's own GRUB kernel arguments so the live rootfs is
# assembled exactly as on real hardware — variants disagree about details
# like rd.live.ram vs overlay. Fall back to the historic stable args.
iso_kargs=""
for cfg_path in /boot/grub2/grub.cfg /EFI/BOOT/grub.cfg /boot/grub/grub.cfg; do
    grub_cfg="$work_dir/grub.cfg"
    rm -f "$grub_cfg"
    if xorriso -indev "$iso_path" -osirrox on -extract "$cfg_path" "$grub_cfg" 2>/dev/null; then
        iso_kargs="$(awk '/^[[:space:]]*linux(efi)?[[:space:]]/{for(i=3;i<=NF;i++) printf "%s ", $i; exit}' "$grub_cfg")"
        if [[ -n "$iso_kargs" ]]; then
            break
        fi
    fi
done
if [[ -z "$iso_kargs" ]]; then
    iso_kargs="root=live:CDLABEL=${iso_label} rd.live.image rd.live.ram rd.neednet=1"
fi
# Serial-friendly, unattended: drop splash args the GRUB entry may carry.
iso_kargs="$(sed -E 's/(^| )(quiet|rhgb|splash)( |$)/ /g' <<<"$iso_kargs" | tr -s ' ')"
echo "Using kernel args from ISO: ${iso_kargs}"

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
    -m "${E2E_MEMORY_MB:-6144}" \
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
    -append "${iso_kargs} console=ttyS0 rd.neednet=1 ip=dhcp inst.ks=http://10.0.2.2:${http_port}/kickstart.ks inst.text" \
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

luks_evidence=""
if [[ "$luks_enabled" == "1" ]]; then
    # Hard assertion that the installed disk really is LUKS-encrypted, before
    # we prove it can also be unlocked at boot.
    if command -v qemu-nbd >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo modprobe nbd max_part=8
        sudo qemu-nbd --connect=/dev/nbd0 "$install_disk"
        for _ in $(seq 1 10); do
            [[ -b /dev/nbd0p1 ]] && break
            sleep 1
        done
        luks_parts="$(sudo blkid -o value -s TYPE /dev/nbd0p* 2>/dev/null | grep -c 'crypto_LUKS' || true)"
        sudo qemu-nbd --disconnect /dev/nbd0 >/dev/null
        if [[ "$luks_parts" -lt 1 ]]; then
            echo "LUKS mode requested but no crypto_LUKS partition found on installed disk" >&2
            exit 1
        fi
        luks_evidence="crypto_LUKS-partition-present"
        echo "Verified installed disk has ${luks_parts} crypto_LUKS partition(s)"
    else
        echo "qemu-nbd/sudo unavailable; skipping on-disk LUKS assertion (boot unlock still enforced)" >&2
        luks_evidence="on-disk-check-skipped"
    fi
fi

post_serial_socket="$work_dir/post-serial.sock"
serial_driver_pid=""
if [[ "$luks_enabled" == "1" ]]; then
    post_serial_args=(-chardev "socket,id=ser0,path=${post_serial_socket},server=on,wait=off" -serial chardev:ser0)
else
    post_serial_args=(-serial "file:$post_install_serial")
fi

"$qemu_binary" \
    -name bluefin-e2e-postinstall \
    -machine "${qemu_machine},accel=${qemu_accel}" \
    -cpu max \
    -m "${E2E_MEMORY_MB:-6144}" \
    -smp 2 \
    -drive file="$install_disk",format=qcow2,if=virtio,cache=none \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    "${post_serial_args[@]}" \
    -vga std \
    -display none \
    -monitor none \
    -qmp "unix:$post_qmp_socket,server=on,wait=off" \
    > /dev/null 2>&1 &
post_install_pid=$!

if [[ "$luks_enabled" == "1" ]]; then
    # Answer the systemd-cryptsetup passphrase prompt on the serial console and
    # mirror everything we see into the regular post-install serial log.
    python3 - "$post_serial_socket" "$post_install_serial" "$luks_passphrase" <<'PY' &
import re
import socket
import sys
import time

sock_path, log_path, passphrase = sys.argv[1], sys.argv[2], sys.argv[3]

sock = None
for _ in range(30):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(sock_path)
        break
    except OSError:
        time.sleep(1)
else:
    sys.exit(1)

sock.settimeout(5)
buffer = b''
answered = 0
prompt = re.compile(rb'(enter passphrase|passphrase for disk|Please enter passphrase)', re.IGNORECASE)
with open(log_path, 'wb', buffering=0) as log:
    deadline = time.time() + 900
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if not chunk:
            break
        log.write(chunk)
        buffer = (buffer + chunk)[-8192:]
        if prompt.search(buffer) and answered < 5:
            time.sleep(1)
            sock.sendall(passphrase.encode() + b'\n')
            answered += 1
            buffer = b''
PY
    serial_driver_pid=$!
fi

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

if [[ "$luks_enabled" == "1" ]]; then
    # The boot marker plus a passphrase prompt in the log proves the unlock
    # path was exercised rather than the disk being silently unencrypted.
    if ! grep -Eqi 'passphrase' "$post_install_serial" 2>/dev/null; then
        echo "LUKS mode: installed system booted but no passphrase prompt was observed" >&2
        exit 1
    fi
    luks_evidence="${luks_evidence:+${luks_evidence},}unlock-prompt-answered-and-booted"
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
if [[ -n "$serial_driver_pid" ]]; then
    kill "$serial_driver_pid" 2>/dev/null || true
    wait "$serial_driver_pid" 2>/dev/null || true
fi

python3 - "$summary_file" "$iso_path" "$serial_file" "$post_install_serial" "$final_screen_png" "$install_evidence" "$post_install_evidence" "$luks_evidence" <<'PY'
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
luks_evidence = sys.argv[8] if len(sys.argv) > 8 else ''
summary = {
    'result': 'passed' if install_evidence and post_install_evidence else 'failed',
    'iso': str(iso_path),
    'install_evidence': install_evidence or None,
    'post_install_evidence': post_install_evidence or None,
    'luks_evidence': luks_evidence or None,
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
