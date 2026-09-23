#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 3 ]]; then
  echo 'Usage: run-windows10-vm.sh INSTALLER_EXE GUEST_PS1 OUTPUT_DIRECTORY' >&2
  exit 2
fi
infra_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
installer="$(realpath "$1")"
guest_script="$(realpath "$2")"
mkdir -p "$3"
output="$(realpath "$3")"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/screentrail-win10.XXXXXX")"
qemu_pid=''
server_pid=''
cleanup() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  # Delete only this run's disposable Windows disks and seed, never input files.
  rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
for binary in qemu-system-x86_64 qemu-img genisoimage python3 curl sha256sum; do command -v "$binary" >/dev/null; done
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || { echo 'Readable/writable /dev/kvm required.' >&2; exit 1; }
[[ -f "$installer" && -f "$guest_script" ]]
if command -v lscpu >/dev/null; then lscpu --json > "$output/host-cpu.json"; fi
cat /proc/cpuinfo > "$output/host-cpuinfo.txt"
qemu-system-x86_64 --version > "$output/qemu-version.txt"
df -h "$work" > "$output/host-disk-before.txt"
printf '%s  %s\n' '36e9b34c7bdec0739fb52de6aeeee57e1c212ac37f20b1b5a3fd7832b507e77e' "$installer" | sha256sum -c -
iso="${WINDOWS10_ISO_PATH:-$work/windows10-eval.iso}"
iso_url='https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso'
iso_sha='ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668'
if [[ ! -f "$iso" ]]; then curl --fail --location --retry 2 --connect-timeout 30 --max-time 1200 "$iso_url" -o "$iso"; fi
printf '%s  %s\n' "$iso_sha" "$iso" | sha256sum -c -
python3 - "$output/provenance.json" "$iso_url" "$iso_sha" <<'PY'
import json, platform, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'isoUrl':sys.argv[2], 'isoSha256':sys.argv[3], 'isoSize':5550497792, 'isoHashSource':'https://download.microsoft.com/download/c/1/1/c11d2ca5-967c-45c0-bc7d-2d9ca3f1fe07/Windows10Enterprise22H2HashValues.pdf', 'target':'Windows 10 Enterprise Evaluation 22H2 x64 (client)', 'host':platform.platform(), 'accelerator':'KVM', 'display':'QEMU standard VGA; inbox Windows driver', 'network':'QEMU user-mode NAT with no forwarded ports'}, indent=2))
PY
mkdir -p "$work/seed"
python3 - "$infra_dir/Autounattend.xml" "$work/seed/Autounattend.xml" <<'PY'
from pathlib import Path
import secrets, sys
password = 'STSmoke-' + secrets.token_hex(16) + '!2'
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('__DISPOSABLE_PASSWORD__', password), encoding='utf-8')
PY
python3 - "$infra_dir/bootstrap.ps1" "$work/seed/bootstrap.ps1" <<'PY'
from pathlib import Path
import os, sys
url = 'http://10.0.2.2:8765/candidate.exe' if os.environ.get('CANDIDATE_APPHOST_PATH') else ''
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace("$candidateUrl = '__CANDIDATE_URL__'", "$candidateUrl = '" + url + "'"), encoding='utf-8')
PY
genisoimage -quiet -J -r -V STSMOKE -o "$work/seed.iso" "$work/seed"
qemu-img create -f qcow2 "$work/windows10.qcow2" 40G
server_options=()
if [[ -n "${CANDIDATE_APPHOST_PATH:-}" ]]; then server_options+=(--candidate "$(realpath "$CANDIDATE_APPHOST_PATH")"); fi
python3 "$infra_dir/host_server.py" --installer "$installer" --guest-script "$guest_script" --output "$output" "${server_options[@]}" > "$output/http.log" 2>&1 &
server_pid=$!
for attempt in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8765/health >/dev/null; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:8765/health >/dev/null
qemu-system-x86_64 \
  -name screentrail-win10-22h2 -machine pc,accel=kvm -cpu host -smp 2 -m 4096 \
  -drive "file=$work/windows10.qcow2,if=ide,index=0,media=disk,format=qcow2,cache=writeback" \
  -drive "file=$iso,if=ide,index=2,media=cdrom,readonly=on" \
  -drive "file=$work/seed.iso,if=ide,index=3,media=cdrom,readonly=on" \
  -boot order=dc,menu=off \
  -netdev user,id=n0 -device e1000,netdev=n0 \
  -vga std -display none \
  -qmp "unix:$work/qmp.sock,server=on,wait=off" \
  -serial "file:$output/serial.log" -monitor none \
  > "$output/qemu.log" 2>&1 &
qemu_pid=$!
for attempt in $(seq 1 10); do
  [[ -S "$work/qmp.sock" ]] && break
  sleep 1
done
# The Microsoft DVD can require a key at the very first boot. Send one only
# during initial BIOS/DVD startup; never send keys during later reboots/setup.
sleep 3
python3 "$infra_dir/qmp_screenshot.py" "$work/qmp.sock" --boot-key || true
deadline=$((SECONDS + 1800))
next_capture=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then echo 'Windows VM exited before returning results.' >&2; exit 1; fi
  if [[ -f "$output/completion.json" ]]; then
    python3 "$infra_dir/qmp_screenshot.py" "$work/qmp.sock" "$output/final-desktop.ppm" "$output/guest-cpu.json" || true
    python3 - "$output/completion.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1]))
print(json.dumps(value, indent=2))
sys.exit(0 if value.get('passed') is True else 1)
PY
    exit $?
  fi
  if (( SECONDS >= next_capture )); then
    python3 "$infra_dir/qmp_screenshot.py" "$work/qmp.sock" "$output/latest-desktop.ppm" "$output/guest-cpu.json" || true
    echo "Waiting for Windows 10 desktop and startup evidence ($SECONDS seconds elapsed)."
    next_capture=$((SECONDS + 120))
  fi
  sleep 5
done
python3 "$infra_dir/qmp_screenshot.py" "$work/qmp.sock" "$output/timeout-desktop.ppm" "$output/guest-cpu.json" || true
echo 'Windows 10 VM timed out after 30 minutes.' >&2
exit 1
