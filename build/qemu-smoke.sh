#!/usr/bin/env bash
# Boot the NOVA ISO in QEMU (UEFI or BIOS) headless and capture screenshots
# at intervals, so CI can prove the image boots + the installer renders
# without any physical hardware. Screenshots land in $OUT as PNGs.
set -uo pipefail
ISO="$1"; MODE="${2:-uefi}"; OUT="${3:-shots}"
mkdir -p "$OUT"
QMP="/tmp/qmp-$MODE.sock"; rm -f "$QMP"

ACCEL=tcg; [ -e /dev/kvm ] && ACCEL=kvm
echo "QEMU smoke: mode=$MODE accel=$ACCEL"

ARGS=( -m 4096 -smp 2 -accel "$ACCEL" -machine q35
       -cdrom "$ISO" -boot d -display none -vga virtio
       -qmp "unix:$QMP,server,nowait" -no-reboot )

if [ "$MODE" = uefi ]; then
  CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; [ -e "$CODE" ] || CODE=/usr/share/OVMF/OVMF_CODE.fd
  VSRC=/usr/share/OVMF/OVMF_VARS_4M.fd; [ -e "$VSRC" ] || VSRC=/usr/share/OVMF/OVMF_VARS.fd
  cp "$VSRC" "/tmp/vars-$MODE.fd"
  ARGS+=( -drive "if=pflash,format=raw,unit=0,readonly=on,file=$CODE"
          -drive "if=pflash,format=raw,unit=1,file=/tmp/vars-$MODE.fd" )
fi

timeout 760 qemu-system-x86_64 "${ARGS[@]}" &
QPID=$!

python3 - "$QMP" "$OUT" "$MODE" <<'PY'
import socket, json, time, sys
qmp, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
s = None
for _ in range(90):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(qmp); break
    except OSError:
        time.sleep(1)
if s is None:
    print("QMP connect failed"); sys.exit(0)
f = s.makefile('rw')
f.readline()
def cmd(o):
    f.write(json.dumps(o) + "\n"); f.flush(); return f.readline()
cmd({"execute": "qmp_capabilities"})
last = 0
for t in (45, 120, 210, 300, 400, 500, 620):
    time.sleep(t - last); last = t
    p = f"{out}/{mode}-{t:03d}s.ppm"
    try:
        cmd({"execute": "screendump", "arguments": {"filename": p}})
        print("shot", p, flush=True)
    except Exception as e:
        print("shot failed", e, flush=True)
cmd({"execute": "quit"})
PY

kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true

# PPM -> PNG so they're easy to view
if command -v convert >/dev/null; then
  for ppm in "$OUT"/*.ppm; do [ -e "$ppm" ] && convert "$ppm" "${ppm%.ppm}.png" && rm -f "$ppm"; done
fi
ls -l "$OUT" || true
