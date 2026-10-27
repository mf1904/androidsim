#!/usr/bin/env bash
# Setup Android multi-device testing tanpa Android Studio. Aman dijalankan ulang.
#   1. brew: openjdk@17, android-commandlinetools, maestro
#   2. ANDROID_HOME / JAVA_HOME / PATH di ~/.zshrc
#   3. sdkmanager: platform-tools, emulator, system image arm64-v8a google_apis
#   4. 10 AVD erp-01..erp-10 sesuai tabel di bawah
set -eo pipefail

# RAM adalah lantai emulator, bukan pilihan: emulator (37.x) menaikkan hw.ramSize yang lebih kecil
# ke 2048MB untuk API <= 33 dan 2560MB untuk API >= 34 ("Increasing RAM size to ..." di log),
# dan flag -memory pun tidak menembusnya. Nilai di sini sengaja sama dengan RAM yang benar-benar dipakai.
# name   API  device     RAM(MB)
AVD_TABLE=(
  "erp-01 30 pixel_3a 2048"
  "erp-02 33 pixel_5  2048"
  "erp-03 34 pixel_6  2560"
  "erp-04 35 pixel_7  2560"
  "erp-05 30 pixel_4  2048"
  "erp-06 33 pixel_6  2048"
  "erp-07 34 pixel_7  2560"
  "erp-08 35 pixel_5  2560"
  "erp-09 34 pixel_4  2560"
  "erp-10 35 pixel_3a 2560"
)
API_LEVELS=(30 33 34 35)

for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x $b ]] && eval "$($b shellenv)" && break
done
command -v brew >/dev/null || { echo "Homebrew belum terpasang." >&2; exit 1; }

echo "==> [1/4] Homebrew packages"
brew list --formula openjdk@17 >/dev/null 2>&1 || brew install openjdk@17
brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools
# Jangan `brew install maestro` polos: itu mengarah ke cask lain ("AI agent command center").
# Maestro UI testing ada di tap resmi mobile-dev-inc, dan Homebrew 7 minta tap itu di-trust dulu.
MAESTRO_FORMULA=mobile-dev-inc/tap/maestro
MAESTRO_MISSING=0
if ! command -v maestro >/dev/null; then
  brew tap mobile-dev-inc/tap
  if ! brew install "$MAESTRO_FORMULA"; then
    MAESTRO_MISSING=1
    echo "!! Maestro belum terpasang. Jalankan: brew trust --formula $MAESTRO_FORMULA" >&2
    echo "!! lalu ulangi setup.sh (langkah lain dilewati karena sudah selesai)." >&2
  fi
fi

JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export JAVA_HOME ANDROID_HOME
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

echo "==> [2/4] Environment di ~/.zshrc"
ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"
if ! grep -q '# >>> android-sim >>>' "$ZSHRC"; then
  cat >>"$ZSHRC" <<EOF

# >>> android-sim >>>
eval "\$($(command -v brew) shellenv)"
export JAVA_HOME="$JAVA_HOME"
export ANDROID_HOME="$ANDROID_HOME"
export PATH="\$JAVA_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/emulator:\$PATH"
# <<< android-sim <<<
EOF
  echo "ditambahkan ke $ZSHRC"
else
  echo "sudah ada di $ZSHRC"
fi

echo "==> [3/4] sdkmanager"
set +o pipefail
yes | sdkmanager --licenses >/dev/null 2>&1
set -o pipefail
PKGS=("platform-tools" "emulator")
for api in "${API_LEVELS[@]}"; do
  PKGS+=("system-images;android-$api;google_apis;arm64-v8a")
done
sdkmanager --install "${PKGS[@]}"

echo "==> [4/4] AVD"
# Emulator menulis ulang config.ini sebagai "key = value" saat pertama jalan, jadi cocokkan spasi opsional
# agar menjalankan ulang setup.sh tidak menambah baris duplikat.
set_ini() { # file key value
  local re="^${2//./\\.}[[:space:]]*="
  if grep -q "$re" "$1"; then sed -i '' -E "s|$re.*|$2=$3|" "$1"; else echo "$2=$3" >>"$1"; fi
}
for row in "${AVD_TABLE[@]}"; do
  read -r name api device ram <<<"$row"
  dir="$HOME/.android/avd/$name.avd"
  if [[ ! -d $dir ]]; then
    echo no | avdmanager create avd -n "$name" -d "$device" \
      -k "system-images;android-$api;google_apis;arm64-v8a"
  fi
  set_ini "$dir/config.ini" hw.ramSize "$ram"
  set_ini "$dir/config.ini" showDeviceFrame no
  echo "$name: API $api, $device, ${ram}MB"
done

echo "Selesai. Buka terminal baru (atau: source ~/.zshrc) agar PATH aktif."
(( MAESTRO_MISSING == 0 )) || { echo "PERHATIAN: Maestro belum terpasang (lihat pesan di atas)." >&2; exit 2; }
