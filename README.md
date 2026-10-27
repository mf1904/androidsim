# Android Sim

Rig uji Android multi-emulator untuk macOS (Apple Silicon), tanpa Android Studio:

- emulator arm64 headless (hingga 10 AVD: `erp-01`..`erp-10`, API 30/33/34/35),
- **dinding layar**: 6 HP dalam satu halaman (3 kolom × 2 baris) dengan tombol on/off dan kontrol sentuh,
- runner [Maestro](https://maestro.mobile.dev) paralel, satu proses per HP, akun berbeda per HP.

Dibuat untuk menguji satu aplikasi Android internal. APK-nya **tidak** ada di repo; taruh sendiri di folder ini.

## Kebutuhan

- Mac **Apple Silicon** (M-series), macOS, dan [Homebrew](https://brew.sh).
- Disk ±35 GB (Android SDK ±21 GB, AVD ±11 GB).
- RAM menentukan jumlah HP yang muat (lihat "Hasil ukur"). Di Mac 24 GB: 6 HP headless muat jika aplikasi besar lain ditutup.
- APK aplikasi **arm64** (image emulatornya arm64).

## Mulai cepat

```bash
./setup.sh                                              # Homebrew + SDK + 10 AVD (aman dijalankan ulang)
cp maestro/accounts.env.example maestro/accounts.env    # isi akun uji; file ini diabaikan git
cp /path/ke/app.apk .                                   # APK terbaru di folder ini dipasang otomatis ke tiap HP yang menyala
./devices.sh view                                       # buka dinding, lalu tekan On pada HP yang diperlukan
```

`setup.sh` memasang `openjdk@17`, `android-commandlinetools`, dan Maestro dari tap resmi `mobile-dev-inc/tap`
(bukan `brew install maestro` polos: itu memasang aplikasi lain dengan nama sama), menulis `JAVA_HOME`/`ANDROID_HOME`/`PATH`
ke `~/.zshrc`, mengunduh 4 system image, dan membuat AVD.

## devices.sh

| Perintah | Fungsi |
|---|---|
| `up [N]` | nyalakan N HP (default 6), tunggu boot selesai |
| `start NN...` / `stop NN...` | nyalakan / matikan HP bernomor tertentu |
| `install [apk]` | pasang APK ke semua HP online (tanpa argumen: APK terbaru di folder ini) |
| `debloat` / `restore` | nonaktifkan / aktifkan app Google bawaan (opsional) |
| `status` | HP online + RAM terpakai |
| `estimate [N]` | perkiraan RAM untuk N HP, tanpa menyalakan apa pun |
| `view [stop]` | dinding layar di `http://127.0.0.1:8765` |
| `down` | matikan semua emulator |

Env opsional: `HEADLESS=1`, `DEBLOAT=1`, `APP_ID=...`, `GPU=host|swiftshader_indirect`, `BOOT_TIMEOUT`, `VIEWER_PORT`, `VIEWER_APP`, `NO_OPEN=1`.
HP yang baru menyala otomatis diberi aplikasi bila belum terpasang. `up N` selalu menyalakan `erp-01..N`.

## Dinding emulator

`./devices.sh view` menjalankan server kecil (`viewer/`, hanya stdlib Python) dan membuka halamannya. Semua HP **mati secara
bawaan**; HP dinyalakan (headless) dengan tombol On, per HP atau "Nyalakan semua".

Kontrol: klik layar = tap, seret = geser, tahan = tekan lama, roda mouse = gulir, tombol Back/Home/Recents/Hapus/Enter,
dan kolom ketik (hanya karakter ASCII, batas `adb input text`).

Server hanya mendengarkan `127.0.0.1`. Endpoint yang mengubah keadaan (`/api/power`, `/api/input`) butuh token per sesi,
Origin/Host yang cocok, dan memvalidasi input dengan daftar putih (tipe aksi, kode tombol, koordinat 0..1, teks ASCII yang
dikutip aman untuk shell di emulator). Teks yang diketik tidak pernah dicatat.

## Maestro

`maestro/run-all.sh` menjalankan flow paralel, satu proses `maestro --device <id>` per HP, dan memetakan HP ke akun lewat
nama AVD (`erp-03` → `ACC_03_*` di `accounts.env`). Laporan JUnit dan log per HP ada di `maestro/reports/<waktu>/`.

`main.yaml` memulai dengan `clearState: true`, jadi tiap run **menghapus data aplikasi** dan login dari awal.
`login.yaml` sudah memakai selector yang diverifikasi pada aplikasi yang diuji; `input-produksi.yaml` masih **tebakan** dan
harus diganti dengan selector asli (`maestro --device <id> hierarchy`).

## Hasil ukur (MacBook M-series, 24 GB)

- **RAM guest punya lantai keras**: emulator menaikkan `hw.ramSize` ke minimum 2048 MB (API ≤ 33) atau 2560 MB (API ≥ 34);
  flag `-memory` tidak menembusnya.
- Footprint di Mac: ±2,0–2,8 GB per HP headless (berjendela ±0,35 GB lebih besar). 6 HP idle ±13 GB. Tiap JVM Maestro ±0,39 GB;
  6 HP + 6 Maestro puncak ±16 GB. Dengan Chrome dkk. terbuka, angka itu mendorong swap; tutup dulu.
- Pengambilan gambar dinding memakai konsol emulator (`emu screenrecord screenshot`), ±30× lebih murah di CPU daripada
  `adb screencap -p`. Folder tujuannya **tidak boleh berspasi** (konsol memecah argumen di spasi); server memakai folder sementara.
- Menonaktifkan app Google bawaan menurunkan memori di dalam guest ±140 MB pada HP yang sudah lama menyala, tetapi tidak
  menghemat RAM Mac pada boot segar (selisih dalam derau). Penghemat besar hanya lewat ukuran RAM guest.

## Platform lain

- **Mac Apple Silicon lain:** bisa langsung (butuh Homebrew). Jumlah HP mengikuti RAM; jalankan `./devices.sh estimate N`.
- **Mac Intel, Linux x86, Windows x86:** tidak langsung. Image arm64 tidak bisa diakselerasi di CPU x86 (jalan sangat lambat tanpa
  akselerasi), jadi perlu image x86_64 **dan** APK yang memuat library x86_64. Skrip juga memakai perintah macOS
  (`sysctl hw.memsize`, `open`, `sed -i ''`, `memory_pressure`, jalur `/opt/homebrew`). Belum diuji.
- **Linux/Windows ARM:** secara teori bisa, belum diuji.

## Catatan

- Jangan commit APK atau `maestro/accounts.env` (sudah ada di `.gitignore`).
- Diuji dengan Android Emulator 37.2.x, Maestro 2.12, Homebrew 7, macOS 26.
