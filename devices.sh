#!/usr/bin/env bash
# Kelola emulator erp-01..erp-10 (port berurutan 5554, 5556, ...).
#   ./devices.sh up [N]           nyalakan N emulator (default 6), tunggu sampai boot selesai
#   ./devices.sh start NN...      nyalakan hanya AVD bernomor NN (mis. start 3 5)
#   ./devices.sh stop NN...       matikan hanya AVD bernomor NN
#   ./devices.sh install [apk]    adb install ke semua device online (tanpa argumen: APK terbaru di folder ini)
#   ./devices.sh debloat [NN...]  nonaktifkan app Google bawaan yang tak dibutuhkan MFS (default: semua online)
#   ./devices.sh restore [NN...]  aktifkan kembali app bawaan tadi
#   ./devices.sh status           daftar device online + RAM terpakai
#   ./devices.sh estimate [N]     perkiraan RAM untuk N emulator (tanpa menyalakan apa pun)
#   ./devices.sh view [stop]      dinding layar semua emulator + menu on/off + kontrol sentuh (http://127.0.0.1:8765)
#   ./devices.sh down             matikan semua emulator
#
# Setiap HP yang baru menyala otomatis diberi MFS (APK terbaru di folder ini) bila belum terpasang.
#
# Env opsional: HEADLESS=1 (tanpa jendela), GPU=host|swiftshader_indirect, BOOT_TIMEOUT=detik,
#               DEBLOAT=1 (nonaktifkan app bawaan tiap HP menyala), APP_ID=id.megasys.mobile,
#               VIEWER_PORT=8765, VIEWER_APP=Safari (peramban untuk `view`), NO_OPEN=1
# Kompatibel bash 3.2 bawaan macOS.
set -o pipefail

: "${ANDROID_HOME:=/opt/homebrew/share/android-commandlinetools}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

BASE_PORT=5554
MAX_AVDS=10
BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
GPU=${GPU:-host}
APP_ID=${APP_ID:-id.megasys.mobile}
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT_DIR/.devices"

# App bawaan Google/AOSP yang tidak dibutuhkan MFS. Dinonaktifkan per pengguna (`pm disable-user`), bisa dibalik
# dengan `restore`. Launcher, keyboard, Play services, WebView, Settings, dan SystemUI sengaja tidak disentuh.
# Hasil ukur (erp-05): di dalam emulator memori terpakai turun ~140MB dan proses app 31 -> 24 pada emulator yang
# sudah lama menyala, tetapi footprint di Mac pada boot segar praktis sama (~1450MB, selisih dalam derau).
BLOAT_PKGS="com.android.chrome com.google.android.gm com.google.android.apps.maps com.google.android.apps.photos com.google.android.apps.messaging com.google.android.youtube com.google.android.apps.youtube.music com.google.android.apps.docs com.google.android.googlequicksearchbox com.google.android.apps.wellbeing com.google.android.calendar com.google.android.deskclock com.android.contacts com.android.dialer"

die() { echo "error: $*" >&2; exit 1; }

online_serials() { adb devices | awk 'NR>1 && $2=="device" {print $1}'; }
emulator_serials() { adb devices | awk 'NR>1 && $1 ~ /^emulator-/ && $2=="device" {print $1}'; }
avd_name() { adb -s "$1" emu avd name 2>/dev/null | head -1 | tr -d '\r'; }

valid_index() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= MAX_AVDS )); }

pid_alive() { local p; p=$(cat "$STATE_DIR/$1.pid" 2>/dev/null) && [[ -n $p ]] && kill -0 "$p" 2>/dev/null; }

wait_boot() { # serial name
  local serial=$1 name=$2 deadline=$((SECONDS + BOOT_TIMEOUT))
  while (( SECONDS < deadline )); do
    if [[ -f $STATE_DIR/$name.pid ]] && ! pid_alive "$name"; then
      echo "x  $name: emulator berhenti, lihat $STATE_DIR/$name.log" >&2
      return 1
    fi
    if [[ $(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; then
      return 0
    fi
    sleep 3
  done
  echo "x  $name: timeout boot setelah ${BOOT_TIMEOUT}s" >&2
  return 1
}

# Pasang APK terbaru di folder ini bila $APP_ID belum ada di emulator $1. `adb shell` selalu diberi </dev/null
# agar tidak menelan stdin milik loop pemanggil.
ensure_app() { # serial
  local serial=$1 apk
  adb -s "$serial" shell pm list packages "$APP_ID" </dev/null 2>/dev/null | tr -d '\r' | grep -q "^package:$APP_ID$" && return 0
  apk=$(ls -t "$ROOT_DIR"/*.apk 2>/dev/null | head -1)
  [[ -n $apk ]] || return 0
  echo "   $serial: memasang $(basename "$apk")"
  adb -s "$serial" install -r -t "$apk" </dev/null >/dev/null 2>&1 || echo "!  $serial: gagal memasang $(basename "$apk")" >&2
}

debloat_serial() { # serial disable-user|enable
  local p
  for p in $BLOAT_PKGS; do
    adb -s "$1" shell pm "$2" --user 0 "$p" </dev/null >/dev/null 2>&1
  done
}

# Dipanggil setelah emulator selesai boot.
prepare_avd() { # serial
  ensure_app "$1"
  [[ -n $DEBLOAT ]] && debloat_serial "$1" disable-user
  return 0
}

# Nyalakan proses emulator untuk AVD bernomor $1 tanpa menunggu boot.
# Return 0 bila dinyalakan, 1 bila sudah jalan.
launch_avd() {
  local i=$1 name port serial flags
  name=$(printf 'erp-%02d' "$i"); port=$((BASE_PORT + 2 * (i - 1))); serial="emulator-$port"
  # Ukuran "sudah jalan" = prosesnya ada. Jangan andalkan `adb devices`: setelah stop, adb masih sempat
  # mencantumkan serial itu sebagai offline, dan emulator baru tidak akan dinyalakan (menunggu boot sia-sia).
  if pgrep -f "qemu-system.*-avd $name( |\$)" >/dev/null; then
    echo "=  $name sudah jalan ($serial)"
    return 1
  fi
  flags="-gpu $GPU -no-snapshot-save -no-boot-anim -no-audio"
  [[ -n $HEADLESS ]] && flags="$flags -no-window"
  echo ">  start $name di port $port"
  mkdir -p "$STATE_DIR"
  # shellcheck disable=SC2086
  nohup emulator -avd "$name" -port "$port" $flags >"$STATE_DIR/$name.log" 2>&1 &
  echo $! >"$STATE_DIR/$name.pid"
  disown
  return 0
}

# RAM guest efektif = yang terbesar dari config.ini dan hardware-qemu.ini (RAM aktual boot terakhir),
# karena emulator menaikkan hw.ramSize ke lantai per API (2048MB <= API 33, 2560MB >= API 34).
avd_ram_mb() { # nomor AVD
  local d="$HOME/.android/avd/$(printf 'erp-%02d' "$1").avd" f v max=0
  for f in "$d/config.ini" "$d/hardware-qemu.ini"; do
    v=$(awk -F'[[:space:]]*=[[:space:]]*' '$1 == "hw.ramSize" {print $2}' "$f" 2>/dev/null)
    [[ $v =~ ^[0-9]+$ ]] && (( v > max )) && max=$v
  done
  echo "$max"
}

# Perkiraan RAM host per emulator = RAM guest + overhead + extra. Hasil ukur footprint (Apple Silicon):
# headless ~ +300MB di atas RAM guest, berjendela ~ +650MB. extra=570 = satu JVM Maestro (~390MB)
# + beban UI tambahan di emulator (~180MB).
est_mb() { # N extra_per_device_mb
  local n=$1 extra=$2 i ram total=0 over=650
  [[ -n $HEADLESS ]] && over=300
  for ((i = 1; i <= n; i++)); do
    ram=$(avd_ram_mb "$i"); (( ram > 0 )) || ram=2048
    total=$((total + ram + over + extra))
  done
  echo "$total"
}

cmd_estimate() {
  local n=${1:-6} phys=$(($(sysctl -n hw.memsize) / 1048576))
  [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= MAX_AVDS )) || die "N harus 1..$MAX_AVDS"
  printf '%s emulator (%s): ~%d MB, dengan Maestro ~%d MB, RAM fisik %d MB\n' "$n" \
    "$([[ -n $HEADLESS ]] && echo headless || echo berjendela)" "$(est_mb "$n" 0)" "$(est_mb "$n" 570)" "$phys"
}

cmd_up() {
  local n=${1:-6} i name serial failed=0 t0=$SECONDS
  [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= MAX_AVDS )) || die "N harus 1..$MAX_AVDS"
  command -v emulator >/dev/null || die "emulator tidak ada di PATH (cek ANDROID_HOME)"
  local est phys
  est=$(est_mb "$n" 570); phys=$(($(sysctl -n hw.memsize) / 1048576))
  # Ambang 80% dikalibrasi dari tes: 6 emulator headless + 6 Maestro (perkiraan 75%) muat di 24GB
  # selama Chrome dkk. ditutup; 6 berjendela (~85%) dan 7-8 tidak.
  if (( est * 100 > phys * 80 )); then
    local hint=", atau pakai HEADLESS=1"
    [[ -n $HEADLESS ]] && hint=""
    echo "!  PERINGATAN: $n emulator + Maestro butuh ~$((est / 1024)) GB dari $((phys / 1024)) GB RAM; Mac bisa swap dan lambat." >&2
    echo "!  Kurangi N$hint (lihat: ./devices.sh estimate $n)." >&2
  fi
  adb start-server >/dev/null 2>&1

  for ((i = 1; i <= n; i++)); do
    launch_avd "$i" && sleep 2 # jeda agar puncak CPU saat cold boot tidak menumpuk
  done

  for ((i = 1; i <= n; i++)); do
    name=$(printf 'erp-%02d' "$i")
    serial="emulator-$((BASE_PORT + 2 * (i - 1)))"
    if wait_boot "$serial" "$name"; then
      prepare_avd "$serial"
      echo "ok $name ($serial) siap, $((SECONDS - t0))s sejak mulai"
    else
      failed=$((failed + 1))
    fi
  done
  (( failed == 0 )) || die "$failed emulator gagal boot"
  echo "Semua $n emulator siap."
}

cmd_start() {
  local i name serial failed=0 t0=$SECONDS
  (( $# > 0 )) || die "pakai: devices.sh start NN [NN...]"
  for i in "$@"; do valid_index "$i" || die "nomor AVD harus 1..$MAX_AVDS: $i"; done
  command -v emulator >/dev/null || die "emulator tidak ada di PATH (cek ANDROID_HOME)"
  adb start-server >/dev/null 2>&1
  for i in "$@"; do launch_avd "$((10#$i))" && sleep 2; done
  for i in "$@"; do
    i=$((10#$i)); name=$(printf 'erp-%02d' "$i"); serial="emulator-$((BASE_PORT + 2 * (i - 1)))"
    if wait_boot "$serial" "$name"; then
      prepare_avd "$serial"
      echo "ok $name ($serial) siap, $((SECONDS - t0))s sejak mulai"
    else
      failed=$((failed + 1))
    fi
  done
  (( failed == 0 )) || die "$failed emulator gagal boot"
}

cmd_stop() {
  local i name serial deadline
  (( $# > 0 )) || die "pakai: devices.sh stop NN [NN...]"
  for i in "$@"; do valid_index "$i" || die "nomor AVD harus 1..$MAX_AVDS: $i"; done
  for i in "$@"; do
    i=$((10#$i)); name=$(printf 'erp-%02d' "$i"); serial="emulator-$((BASE_PORT + 2 * (i - 1)))"
    echo ">  matikan $name ($serial)"
    adb -s "$serial" emu kill >/dev/null 2>&1
  done
  deadline=$((SECONDS + 30))
  for i in "$@"; do
    i=$((10#$i)); name=$(printf 'erp-%02d' "$i")
    while pgrep -f "qemu-system.*-avd $name( |\$)" >/dev/null && (( SECONDS < deadline )); do sleep 1; done
    if pgrep -f "qemu-system.*-avd $name( |\$)" >/dev/null; then
      echo "!  $name masih jalan, kill paksa"
      pkill -9 -f "qemu-system.*-avd $name( |\$)"
    fi
    rm -f "$STATE_DIR/$name.pid"
  done
  echo "Mati: $*"
}

cmd_install() {
  local apk=${1:-} s pids="" p failed=0
  [[ -n $apk ]] || apk=$(ls -t "$ROOT_DIR"/*.apk 2>/dev/null | head -1)
  [[ -n $apk && -f $apk ]] || die "pakai: devices.sh install [path/to/app.apk] (tanpa argumen: APK terbaru di folder ini)"
  local serials
  serials=$(online_serials)
  [[ -n $serials ]] || die "tidak ada device online"
  for s in $serials; do
    (
      out=$(adb -s "$s" install -r -t "$apk" 2>&1); rc=$?
      echo "[$s] $(echo "$out" | tail -1)"
      exit $rc
    ) &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p" || failed=$((failed + 1)); done
  (( failed == 0 )) || die "install gagal di $failed device"
}

cmd_bloat() { # disable-user|enable [NN...]  (tanpa NN: semua emulator online)
  local mode=$1 s i serials=""
  shift
  if (( $# > 0 )); then
    for i in "$@"; do
      valid_index "$i" || die "nomor AVD harus 1..$MAX_AVDS: $i"
      serials="$serials emulator-$((BASE_PORT + 2 * (10#$i - 1)))"
    done
  else
    serials=$(emulator_serials)
  fi
  [[ -n $serials ]] || die "tidak ada emulator online"
  for s in $serials; do
    debloat_serial "$s" "$mode"
    if [[ $mode == enable ]]; then echo "ok $s: app bawaan diaktifkan kembali"; else echo "ok $s: app bawaan dinonaktifkan"; fi
  done
}

cmd_status() {
  local s name boot rss total=0 any=0
  printf '%-8s %-15s %-6s %9s\n' AVD SERIAL BOOT RSS_MB
  for s in $(emulator_serials); do
    any=1
    name=$(avd_name "$s")
    boot=$(adb -s "$s" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    rss=$(ps -axo rss=,command= | awk -v n="$name" '$0 ~ ("-avd " n "( |$)") && $0 ~ /qemu-system/ {s+=$1} END {printf "%d", s/1024}')
    total=$((total + rss))
    printf '%-8s %-15s %-6s %9s\n' "$name" "$s" "${boot:-?}" "$rss"
  done
  (( any )) || { echo "(tidak ada emulator online)"; return 0; }
  printf '%-8s %-15s %-6s %9s\n' TOTAL "" "" "$total"
}

cmd_view() {
  local port=${VIEWER_PORT:-8765} base app=${VIEWER_APP:-Safari} i p
  base="http://127.0.0.1:$port"
  if [[ ${1:-} == stop ]]; then
    p=$(cat "$STATE_DIR/viewer.pid" 2>/dev/null) && kill "$p" 2>/dev/null
    rm -f "$STATE_DIR/viewer.pid"
    echo "Dinding emulator dihentikan."
    return 0
  fi
  if ! curl -fsS -o /dev/null "$base/" 2>/dev/null; then
    command -v python3 >/dev/null || die "python3 tidak ada"
    mkdir -p "$STATE_DIR"
    ANDROID_HOME="$ANDROID_HOME" VIEWER_PORT="$port" nohup python3 -I "$ROOT_DIR/viewer/server.py" >"$STATE_DIR/viewer.log" 2>&1 &
    echo $! >"$STATE_DIR/viewer.pid"
    disown
    for i in $(seq 1 20); do
      curl -fsS -o /dev/null "$base/" 2>/dev/null && break
      sleep 0.5
    done
    curl -fsS -o /dev/null "$base/" 2>/dev/null || die "dinding gagal start, lihat $STATE_DIR/viewer.log"
  fi
  echo "Dinding emulator: $base"
  [[ -n $NO_OPEN ]] || open -a "$app" "$base" 2>/dev/null || open "$base"
}

cmd_down() {
  local s p f name
  for s in $(emulator_serials); do
    echo ">  matikan $s ($(avd_name "$s"))"
    adb -s "$s" emu kill >/dev/null 2>&1
  done
  local deadline=$((SECONDS + 30))
  while pgrep -f 'qemu-system.*-avd erp-' >/dev/null && (( SECONDS < deadline )); do sleep 1; done
  if pgrep -f 'qemu-system.*-avd erp-' >/dev/null; then
    echo "!  masih ada proses emulator, kill paksa"
    pkill -9 -f 'qemu-system.*-avd erp-'
  fi
  for f in "$STATE_DIR"/*.pid; do
    [[ -e $f ]] || continue
    name=$(basename "$f" .pid)
    [[ $name == viewer ]] && continue # dinding tetap hidup; hentikan dengan `view stop`
    p=$(cat "$f")
    kill "$p" 2>/dev/null
    rm -f "$f"
  done
  echo "Semua emulator mati."
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  start) shift; cmd_start "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  install) shift; cmd_install "$@" ;;
  debloat) shift; cmd_bloat disable-user "$@" ;;
  restore) shift; cmd_bloat enable "$@" ;;
  status) cmd_status ;;
  estimate) shift; cmd_estimate "$@" ;;
  view) shift; cmd_view "$@" ;;
  down) cmd_down ;;
  *) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 1 ;;
esac
