#!/usr/bin/env bash
# Jalankan flow Maestro paralel, satu proses per emulator online.
# Akun diambil dari accounts.env berdasarkan nama AVD (erp-03 -> ACC_03_*).
#   ./run-all.sh                          flow main.yaml (login + input produksi)
#   FLOW=login.yaml ./run-all.sh          hanya satu flow
# Laporan dan log tiap device ada di maestro/reports/<timestamp>/
set -o pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
FLOW="${FLOW:-main.yaml}"
[[ $FLOW = /* ]] || FLOW="$DIR/$FLOW"
[[ -f $FLOW ]] || { echo "flow tidak ditemukan: $FLOW" >&2; exit 1; }
[[ -f $DIR/accounts.env ]] || { echo "accounts.env tidak ada: salin dari accounts.env.example lalu isi akun uji" >&2; exit 1; }
# shellcheck disable=SC1091
source "$DIR/accounts.env"

: "${ANDROID_HOME:=/opt/homebrew/share/android-commandlinetools}"
: "${JAVA_HOME:=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME JAVA_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:/opt/homebrew/bin:$PATH"
command -v maestro >/dev/null || { echo "maestro tidak ada di PATH" >&2; exit 1; }

OUT="$DIR/reports/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

pids=(); names=(); starts=()
for serial in $(adb devices | awk 'NR>1 && $1 ~ /^emulator-/ && $2=="device" {print $1}'); do
  avd=$(adb -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')
  idx=${avd#erp-}
  [[ $avd == erp-* && $idx =~ ^[0-9]+$ ]] || { echo "lewati $serial (AVD '$avd' bukan erp-NN)"; continue; }
  idx=$(printf '%02d' "$((10#$idx))")
  role_v="ACC_${idx}_ROLE"; user_v="ACC_${idx}_USER"; pass_v="ACC_${idx}_PASS"
  role=${!role_v}; user=${!user_v}; pass=${!pass_v}
  [[ -n $user && -n $pass ]] || { echo "lewati $avd: ACC_${idx}_* belum ada di accounts.env"; continue; }

  run_produksi=false
  for r in $INPUT_ROLES; do [[ $r == "$role" ]] && run_produksi=true; done

  echo ">  $avd ($serial) role=$role user=$user produksi=$run_produksi"
  maestro --device "$serial" test \
    -e APP_ID="$APP_ID" -e USERNAME="$user" -e PASSWORD="$pass" -e ROLE="$role" \
    -e AVD_NAME="$avd" -e QTY="$((10 + 10#$idx))" -e RUN_PRODUKSI="$run_produksi" \
    --format JUNIT --output "$OUT/$avd.xml" \
    --debug-output "$OUT/$avd-debug" \
    "$FLOW" >"$OUT/$avd.log" 2>&1 &
  pids+=($!); names+=("$avd"); starts+=("$SECONDS")
done

(( ${#pids[@]} > 0 )) || { echo "tidak ada emulator erp-NN yang online/berakun" >&2; exit 1; }

failed=0
echo
printf '%-8s %-6s %s\n' AVD HASIL DURASI
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then res=PASS; else res=FAIL; failed=$((failed + 1)); fi
  printf '%-8s %-6s %ss\n' "${names[$i]}" "$res" "$((SECONDS - starts[i]))"
done
echo
echo "Laporan: $OUT"
(( failed == 0 ))
