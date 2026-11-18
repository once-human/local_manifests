#!/usr/bin/env bash
# =============================================================================
#  build_pixelos17_sky.sh  v4  --  PixelOS 17 (Android 17) for Xiaomi "sky"
#  Redmi 12 5G / Redmi Note 12R / POCO M6 Pro 5G  (Snapdragon 4 Gen 2, "parrot")
#
#  v4: Linux 6.6. Every tree is ours (github.com/once-human, branch "seventeen") and
#  carries all changes as commits; this script no longer patches anything on the fly.
#    device   android_device_xiaomi_sky, android_device_xiaomi_sm4450-common
#             (LineageOS-style, from the xiaomi-ravelin sm4450 6.6 bring-up)
#    kernel   android_kernel_xiaomi_sm4450 (6.6 "Nimbus": Suvojeet's kernel, WALT kept,
#             TopexGuy's watchdog/BBR fixes, moinator856's ramoops), -modules, -devicetrees
#    hw       android_hardware_xiaomi (LineageOS + fingerprint crash fix), branch seventeen-6.6
#    vendor   NOT downloaded: extracted here from Xiaomi's official stock ROMs
#             common blobs: mist OS3.0.306.0.WPUINXM   sky blobs + firmware: sky OS2.0.210.0.VMWMIXM
#  The repos come in through the local manifest (sky.xml in once-human/local_manifests).
#
#  STAGES (each is checked; rerunning resumes where it stopped)
#    0. preflight   CPU, filesystem, disk, RAM+swap, tools, every repo reachable, stock ROMs found
#    1. sync        PixelOS 17 source + our sky.xml local manifest
#    2. blobs       stock ROMs downloaded/verified, vendor/xiaomi/{sky,sm4450-common} extracted
#    3. trees       signing keys, (debug files), every path the build needs validated
#    4. configcheck lunch + build graph + SELinux + VINTF + kernel/boot images (catches most
#                   port errors before the long build)
#    5. build       m pixelos
#    6. verify      zip contents, device, Android 17, kernel 6.6, firmware, signed, enforcing
#    7. release     ~/release/<name>/: fastboot ROM (no firmware/bootloader/recovery), OTA zip
#                   (for the Updater and sideload; carries OS2.0.210 firmware), recovery.img,
#                   INSTALL.md, RELEASE_NOTES.md, SHA256SUMS, ota/sky.json + changelog for the Updater
#
#  USAGE
#    ./build_pixelos17_sky.sh                 full run (auto-resumes)
#    CHECK_ONLY=1 ./build_pixelos17_sky.sh    stage 0 only; changes nothing
#    Stock ROMs: put the official Xiaomi zips in ~/stock-roms (ROM_DIR), or give them:
#      SKY_ROM=<path or https URL on a Xiaomi server>    sky  OS2.0.210.0.VMWMIXM recovery zip
#      MIST_ROM=<path or https URL on a Xiaomi server>   mist OS3.0.306.0.WPUINXM recovery zip
#    Signing keys: KEYS_TGZ=~/sky17-signing-keys.tgz (the October backup; found automatically in
#      ~ and the work dir). Without it, new keys are made (users must then clean flash).
#    BUILD_TYPE=userdebug   (adds root/debug features; default user)
#    SIGN=0          test-keys instead of your own keys
#    RESYNC=1        re-run repo sync (pulls the newest commits of every tree)
#    REEXTRACT=1     extract the vendor blobs again
#    FLASH_FIRMWARE=0  leave OS2.0.210 firmware out of the OTA zip (default 1)
#    DEBUG_BOOT=1    diagnostic build: boot logs saved to /metadata, adb open, permissive
#                    (forces userdebug; never for daily use)
#    SKIP_KERNEL_CHECK=1  skip the early kernel/boot image build in stage 4
#    NO_CCACHE=1     don't use ccache (default: on, 50GB in the work dir, faster rebuilds)
#    RELEASE_ONLY=1  only redo stage 7 (e.g. after editing release-status.conf; seconds)
#    REPACK=1        with RELEASE_ONLY: also rebuild the fastboot zip
#    OTA_URL_BASE=https://...   where the OTA zip will be uploaded (for the Updater feed);
#                    default SourceForge pixelos-sky/files/17/<YYYY-MM>
#    ROM_MAINTAINER="Name"   AUTO_SWAP=1 FORCE=1 NO_TMUX=1 JOBS=N   as before
# =============================================================================
set -Eeo pipefail
SCRIPT_VERSION="4.0"

# ------------------------------- config --------------------------------------
WORKDIR="${WORKDIR:-$HOME/pixelos17}"
BUILD_TYPE="${BUILD_TYPE:-user}"
SIGN="${SIGN:-1}"
ROM_MAINTAINER="${ROM_MAINTAINER:-Onkar Yaglewad}"
CODENAME="sky"
FLASH_FIRMWARE="${FLASH_FIRMWARE:-1}"
ROM_DIR="${ROM_DIR:-$HOME/stock-roms}"

ANDROID_BRANCH="seventeen"
MANIFEST_URL="https://github.com/PixelOS-AOSP/android_manifest.git"
LOCAL_MANIFEST_URL="https://raw.githubusercontent.com/once-human/local_manifests/seventeen/sky.xml"

# what the local manifest brings in: path|url|branch (checked before syncing)
TREES=(
  "device/xiaomi/sky|https://github.com/once-human/android_device_xiaomi_sky.git|seventeen"
  "device/xiaomi/sm4450-common|https://github.com/once-human/android_device_xiaomi_sm4450-common.git|seventeen"
  "kernel/xiaomi/sm4450|https://github.com/once-human/android_kernel_xiaomi_sm4450.git|seventeen"
  "kernel/xiaomi/sm4450-modules|https://github.com/once-human/android_kernel_xiaomi_sm4450-modules.git|seventeen"
  "kernel/xiaomi/sm4450-devicetrees|https://github.com/once-human/android_kernel_xiaomi_sm4450-devicetrees.git|seventeen"
  "hardware/xiaomi|https://github.com/once-human/android_hardware_xiaomi.git|seventeen-6.6"
)
# v3 (5.10, TopexGuy) checkouts that were cloned by the script, not by repo: removed once
V3_PATHS=(device/xiaomi/sky vendor/xiaomi/sky kernel/xiaomi/sky kernel/xiaomi/sm8450-modules
          hardware/xiaomi hardware/dolby vendor/qcom/opensource/vibrator)

# stock ROMs the blobs come from: label|expected version|codename|known MD5s (any match = verified)
SKY_ROM_VERSION="OS2.0.210.0.VMWMIXM"
MIST_ROM_VERSION="OS3.0.306.0.WPUINXM"
SKY_ROM_MD5S="614cc2b1064a05fe1d3abb0edcb95481"
MIST_ROM_MD5S="244a8a4a0b49f4dae42d7b3676f6ae08"
# TrustZone version inside OS2.0.210's tz.img: proves the firmware is the one we tested
FIRMWARE_TZ_VERSION="TZ.XF.5.18-31602-10"

# release-key signing (only used when no key backup exists), pinned to a reviewed commit
SIGNIFY_REPO="https://github.com/TopexGuy/Signify.git"
SIGNIFY_COMMIT="c36d6fa5b4612baa915d5e0d05082637305e10cb"
# PixelOS's vendor/lineage/config/common.mk includes vendor/lineage-priv/keys/keys.mk
KEYS_REL="vendor/lineage-priv/keys"

STATE_DIR="$WORKDIR/.sky17"
LOG_DIR="$WORKDIR/logs"
CURRENT_STAGE="startup"

# ------------------------------ helpers --------------------------------------
# ------------------------------ helpers --------------------------------------
if [[ -t 1 ]]; then C_B=$'\033[1;36m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_0=$'\033[0m'
else C_B=""; C_Y=""; C_R=""; C_G=""; C_0=""; fi
log()  { printf '\n%s[sky17]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '\n%s[sky17 WARN]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%s[sky17 STOP @ %s]%s %s\n' "$C_R" "$CURRENT_STAGE" "$C_0" "$*" >&2
         [[ -d "$LOG_DIR" ]] && printf '  Full log: %s\n' "$LOG_FILE" >&2
         exit 1; }
PREFLIGHT_ISSUES=()
soft_fail() {
  if [[ -n "${CHECK_ONLY:-}" ]]; then warn "$*"; PREFLIGHT_ISSUES+=("$*"); return 0; fi
  if [[ -n "${FORCE:-}" ]]; then warn "$* (continuing: FORCE=1)"; else die "$*
  (set FORCE=1 to continue anyway)"; fi
}

on_err() {
  local rc=$? line=${BASH_LINENO[0]}
  printf '\n%s[sky17 STOP @ %s]%s unexpected error (exit %s) at line %s: %s\n' \
    "$C_R" "$CURRENT_STAGE" "$C_0" "$rc" "$line" "$BASH_COMMAND" >&2
  [[ -n "${LOG_FILE:-}" ]] && printf '  Full log: %s\n' "$LOG_FILE" >&2
  printf '  Rerun the same command to resume; send me the lines above if it repeats.\n' >&2
  exit "$rc"
}
trap on_err ERR

stage_done()   { [[ -f "$STATE_DIR/$1.done" ]]; }
mark_done()    { mkdir -p "$STATE_DIR"; date -u +%FT%TZ > "$STATE_DIR/$1.done"; }
clear_from()   { local s; for s in "$@"; do rm -f "$STATE_DIR/$s.done"; done; }

retry() { # retry <attempts> <sleep> cmd...
  local n=$1 s=$2 i; shift 2
  for ((i=1; i<=n; i++)); do "$@" && return 0; (( i < n )) && { warn "attempt $i/$n failed: $*; retrying in ${s}s"; sleep "$s"; }; done
  return 1
}

remote_has_branch() { # url branch(empty = default HEAD)
  if [[ -z "$2" ]]; then timeout 60 git ls-remote --exit-code "$1" HEAD >/dev/null 2>&1
  else timeout 60 git ls-remote --exit-code --heads "$1" "$2" >/dev/null 2>&1; fi
}

gb_free()  { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }
mem_gb() {  # RAM in GB, capped by any cgroup limit (shared servers cap per-user memory)
  local total cg d lim min=""
  total=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
  cg=$(awk -F: '$1=="0" {print $3}' /proc/self/cgroup 2>/dev/null || true)
  d="${CGROUP_ROOT:-/sys/fs/cgroup}$cg"
  while [[ "$d" == "${CGROUP_ROOT:-/sys/fs/cgroup}"* ]]; do
    if [[ -r "$d/memory.max" ]]; then
      lim=$(<"$d/memory.max")
      if [[ "$lim" =~ ^[0-9]+$ ]]; then
        lim=$(( lim / 1073741824 ))
        if [[ -z "$min" ]] || (( lim < min )); then min=$lim; fi
      fi
    fi
    [[ "$d" == "${CGROUP_ROOT:-/sys/fs/cgroup}" ]] && break
    d="${d%/*}"; [[ -z "$d" ]] && break
  done
  if [[ -n "$min" ]] && (( min > 0 && min < total )); then echo "$min"; else echo "$total"; fi
}
swap_gb()  { awk '/SwapTotal/ {printf "%d", $2/1048576}' /proc/meminfo; }

setup_logging() {
  mkdir -p "$LOG_DIR" "$STATE_DIR"
  LOG_FILE="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "build_pixelos17_sky.sh v$SCRIPT_VERSION  |  log: $LOG_FILE"
}

maybe_tmux() {
  [[ -n "${NO_TMUX:-}${CHECK_ONLY:-}${TMUX:-}${SKY17_IN_TMUX:-}" ]] && return 0
  [[ -t 0 && -t 1 ]] || return 0
  command -v tmux >/dev/null || return 0
  local envs="SKY17_IN_TMUX=1" v
  for v in WORKDIR BUILD_TYPE RESYNC REEXTRACT AUTO_SWAP FORCE JOBS DEBUG_BOOT FLASH_FIRMWARE SIGN ROM_MAINTAINER RELEASE_ONLY REPACK RELEASE_DIR \
           ROM_DIR SKY_ROM MIST_ROM KEYS_TGZ OTA_URL_BASE NO_CCACHE SKIP_KERNEL_CHECK; do
    [[ -n "${!v:-}" ]] && envs+=" $v=$(printf '%q' "${!v}")"
  done
  echo "Starting inside tmux session 'sky17' (survives SSH disconnects)."
  echo "Detach: Ctrl+B then D.  Reattach later: tmux attach -t sky17"
  sleep 2
  exec tmux new-session -A -s sky17 "env $envs bash $(printf '%q' "$(readlink -f "$0")"); echo; read -rp 'Finished. Press Enter to close.'"
}

install_deps() {  # installs only what is missing, one package at a time
  log "Checking build dependencies"
  # command -> Arch package / Debian package / Fedora package
  local -a need=(
    "git:git:git:git"            "git-lfs:git-lfs:git-lfs:git-lfs"
    "repo:repo:repo:repo"        "python3:python:python3:python3"
    "curl:curl:curl:curl"        "unzip:unzip:unzip:unzip"
    "zip:zip:zip:zip"            "rsync:rsync:rsync:rsync"
    "patchelf:patchelf:patchelf:patchelf"
    "readelf:binutils:binutils:binutils"
    "ccache:ccache:ccache:ccache" "bc:bc:bc:bc"
    "bison:bison:bison:bison"    "flex:flex:flex:flex"
    "gperf:gperf:gperf:gperf"    "lz4:lz4:lz4:lz4"
    "xsltproc:libxslt:xsltproc:libxslt"
    "xmllint:libxml2:libxml2-utils:libxml2"
    "mksquashfs:squashfs-tools:squashfs-tools:squashfs-tools"
    "make:make:make:make"        "gcc:gcc:gcc:gcc"
    "tmux:tmux:tmux:tmux"        "file:file:file:file"
    "timeout:coreutils:coreutils:coreutils"
    "openssl:openssl:openssl:openssl"
  )
  local pm="" idx=0
  if   command -v pacman  >/dev/null; then pm=pacman; idx=1
  elif command -v apt-get >/dev/null; then pm=apt;    idx=2
  elif command -v dnf     >/dev/null; then pm=dnf;    idx=3
  fi

  # Only install what's actually missing, one package at a time, so one
  # conflict (e.g. an adb package you already have) can't block the rest.
  local entry cmd pkg missing=()
  for entry in "${need[@]}"; do
    IFS=: read -r -a f <<<"$entry"; cmd=${f[0]}; pkg=${f[$idx]:-}
    command -v "$cmd" >/dev/null || missing+=("$cmd:$pkg")
  done

  if (( ${#missing[@]} )) && [[ -n "${CHECK_ONLY:-}" ]]; then
    warn "Missing tools (a full run would install them): ${missing[*]%%:*}"
    return 0
  fi
  if (( ${#missing[@]} )); then
    [[ -n "$pm" ]] || die "Install these manually, then rerun: ${missing[*]}"
    [[ "$pm" == apt ]] && sudo apt-get update
    for entry in "${missing[@]}"; do
      cmd=${entry%%:*}; pkg=${entry#*:}
      log "Installing $pkg (for $cmd)"
      case $pm in
        pacman) sudo pacman -S --needed --noconfirm "$pkg" ;;
        apt)    sudo apt-get install -y "$pkg" ;;
        dnf)    sudo dnf install -y "$pkg" ;;
      esac || warn "could not install $pkg"
    done
  else
    log "All build tools already installed"
  fi

  # repo fallback (official launcher) if the distro package wasn't available
  if ! command -v repo >/dev/null; then
    mkdir -p "$HOME/.bin"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.bin/repo"
    chmod +x "$HOME/.bin/repo"
    export PATH="$HOME/.bin:$PATH"
  fi

  # Hard check: stop here with a clear list instead of failing later
  local still=()
  for entry in "${need[@]}"; do
    cmd=${entry%%:*}; command -v "$cmd" >/dev/null || still+=("$cmd")
  done
  (( ${#still[@]} == 0 )) || die "Still missing: ${still[*]}. Install them and rerun."

  git lfs install >/dev/null 2>&1 || true
  git config --global user.name  >/dev/null || git config --global user.name  "builder"
  git config --global user.email >/dev/null || git config --global user.email "builder@localhost"

  log "Dependencies OK"
  return 0
}

make_swap() { # make_swap <GB>
  local gb=$1 sf="$WORKDIR/swapfile"
  [[ -f "$sf" ]] && { warn "swapfile exists at $sf; enabling"; sudo swapon "$sf" 2>/dev/null || true; return 0; }
  log "Creating ${gb}GB swapfile at $sf"
  if [[ "$(stat -f -c %T "$WORKDIR")" == btrfs ]]; then
    sudo btrfs filesystem mkswapfile --size "${gb}g" "$sf" || { warn "btrfs swapfile failed"; return 0; }
  else
    sudo fallocate -l "${gb}G" "$sf" 2>/dev/null || sudo dd if=/dev/zero of="$sf" bs=1M count=$((gb*1024)) status=none
    sudo chmod 600 "$sf"; sudo mkswap "$sf" >/dev/null
  fi
  sudo swapon "$sf" && ok "swap on: $sf (temporary; remove with: sudo swapoff $sf && sudo rm $sf)" || warn "swapon failed"
}

# =============================== STAGE 0 =====================================
preflight() {
  CURRENT_STAGE="0-preflight"
  log "STAGE 0: preflight checks"

  (( BASH_VERSINFO[0] >= 4 )) || die "bash 4+ required"
  [[ "$(uname -s)" == Linux ]] || die "Linux required (Android can only be built on Linux)"
  [[ "$(uname -m)" == x86_64 ]] || die "x86_64 CPU required; Android's build tools don't run on $(uname -m) (e.g. ARM servers/Oracle free tier)"
  ok "Linux x86_64"
  if [[ $EUID -eq 0 ]]; then warn "Running as root. It works, but a normal user is safer."; fi

  install_deps

  # --- filesystem ---
  mkdir -p "$WORKDIR"
  local fstype; fstype=$(stat -f -c %T "$WORKDIR")
  case "$fstype" in
    msdos|vfat|exfat|ntfs|ntfs3|fuseblk|fuse|9p|v9fs|drvfs|smb2|cifs|nfs)
      die "$WORKDIR is on '$fstype'. Android needs a native Linux filesystem (ext4/btrfs/xfs) with symlinks, permissions and case sensitivity." ;;
  esac
  local ct="$WORKDIR/.case_test_$$"; mkdir -p "$ct"; : > "$ct/a"; : > "$ct/A"
  if [[ $(ls "$ct" | wc -l) -ne 2 ]]; then rm -rf "$ct"; die "$WORKDIR is case-insensitive; Android needs case-sensitive storage."; fi
  rm -rf "$ct"; ok "filesystem: $fstype, case-sensitive"

  # --- disk + inodes (source ~150GB, out ~200GB, stock ROMs + extraction ~25GB, ccache 50GB) ---
  local free need_die need_warn
  free=$(gb_free "$WORKDIR")
  if [[ -d "$WORKDIR/.repo" ]]; then need_die=90; need_warn=180; else need_die=330; need_warn=450; fi
  if (( free < need_die )); then
    soft_fail "Only ${free}GB free in $WORKDIR (need ~450GB for a fresh build). Use a bigger disk: WORKDIR=/path/on/big/disk"
  elif (( free < need_warn )); then warn "${free}GB free in $WORKDIR: tight (NO_CCACHE=1 saves 50GB)."
  else ok "disk: ${free}GB free"; fi
  local inodes; inodes=$( { df --output=iavail "$WORKDIR" 2>/dev/null || true; } | tail -1 | tr -dc '0-9' )
  if [[ -n "$inodes" && "$inodes" -gt 0 && "$inodes" -lt 6000000 ]]; then
    soft_fail "Only $inodes free inodes on $WORKDIR; Android source needs ~6M files."
  fi

  # --- memory ---
  local mem swp total; mem=$(mem_gb); swp=$(swap_gb); total=$((mem + swp))
  if (( total < 32 )); then
    if [[ -n "${AUTO_SWAP:-}" && -z "${CHECK_ONLY:-}" ]]; then make_swap $((34 - total)); swp=$(swap_gb); total=$((mem + swp))
    fi
  fi
  if (( total < 24 )); then
    soft_fail "RAM ${mem}GB + swap ${swp}GB = ${total}GB. The build will be OOM-killed below ~24GB (32GB+ recommended). Rerun with AUTO_SWAP=1 to add a swapfile."
  elif (( total < 32 )); then warn "RAM+swap ${total}GB: it will work but slowly; AUTO_SWAP=1 adds more."
  else ok "memory: ${mem}GB RAM (after any cgroup cap) + ${swp}GB swap"; fi
  local cpus; cpus=$(nproc --all)
  local by_mem=$(( mem / 2 )); (( by_mem < 2 )) && by_mem=2   # RAM only: swap is too slow to count
  JOBS="${JOBS:-$(( cpus < by_mem ? cpus : by_mem ))}"   # ~2GB RAM per job avoids OOM
  SYNC_JOBS=$(( cpus > 16 ? 16 : cpus ))
  ok "cpus: $cpus  -> build jobs: $JOBS, sync jobs: $SYNC_JOBS"

  local cur; cur=$(ulimit -n)
  if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur < 65535 )); then ulimit -n "$(ulimit -Hn)" 2>/dev/null || true; fi

  # --- network: every source this build needs, BEFORE downloading 100GB ---
  log "Checking every repository and branch is reachable"
  local -a checks=("PixelOS manifest|$MANIFEST_URL|$ANDROID_BRANCH")
  local t tp tu tb
  for t in "${TREES[@]}"; do IFS='|' read -r tp tu tb <<<"$t"; checks+=("$tp|$tu|$tb"); done
  checks+=(
    "LineageOS sepolicy|https://github.com/LineageOS/android_device_lineage_sepolicy.git|lineage-24.0"
    "PixelOS vendor/custom|https://github.com/PixelOS-AOSP/android_vendor_custom.git|seventeen"
  )
  local c name url br bad=0
  for c in "${checks[@]}"; do
    IFS='|' read -r name url br <<<"$c"
    if retry 3 5 remote_has_branch "$url" "$br"; then ok "$name (${br:-default})"
    else printf '  %s✘%s %s: %s %s\n' "$C_R" "$C_0" "$name" "$url" "${br:-}"; bad=1; fi
  done
  if retry 3 5 curl -fsSL -o /dev/null "$LOCAL_MANIFEST_URL"; then ok "local manifest (sky.xml)"
  else printf '  %s✘%s local manifest: %s\n' "$C_R" "$C_0" "$LOCAL_MANIFEST_URL"; bad=1; fi
  if timeout 60 git ls-remote https://android.googlesource.com/platform/build/release refs/tags/android-17.0.0_r1 2>/dev/null | grep -q .; then
    ok "android.googlesource.com (AOSP android-17.0.0_r1)"
  else printf '  %s✘%s android.googlesource.com unreachable (AOSP source)\n' "$C_R" "$C_0"; bad=1; fi
  (( bad == 0 )) || soft_fail "Some sources are unreachable (see ✘ above). Check your internet/firewall, or the repo moved; nothing was downloaded."

  # --- stock ROMs (the vendor blobs come from them) ---
  if [[ -n "${REEXTRACT:-}" ]] || ! stage_done blobs; then
    check_rom_source SKY "${SKY_ROM:-}" "$SKY_ROM_VERSION"
    check_rom_source MIST "${MIST_ROM:-}" "$MIST_ROM_VERSION"
  fi

  if (( ${#PREFLIGHT_ISSUES[@]} )); then
    printf '\n%sPreflight found %d problem(s):%s\n' "$C_R" "${#PREFLIGHT_ISSUES[@]}" "$C_0"
    printf '  - %s\n' "${PREFLIGHT_ISSUES[@]}"
    die "Fix the problems above, then rerun."
  fi
  git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "builder"
  git config --global user.email >/dev/null 2>&1 || git config --global user.email "builder@localhost"
  git config --global color.ui false >/dev/null 2>&1 || true
  ok "preflight passed"
}

# ------------------------------ stock ROMs -----------------------------------
rom_local_candidate() { # rom_local_candidate <version> -> newest matching zip/tgz in ROM_DIR
  ls -t "$ROM_DIR"/*"$1"* 2>/dev/null | grep -E '\.(zip|tgz|tar\.gz)$' | head -1 || true
}

xiaomi_host() { # official Xiaomi download hosts only
  local h=${1#https://}; h=${h%%/*}; h=${h%%:*}
  [[ "$h" =~ (^|\.)(miui\.com|xiaomi\.com|mi\.com|xiaomi\.net|aliyuncs\.com)$ ]]
}

check_rom_source() { # check_rom_source <SKY|MIST> <value> <version>
  local label=$1 src=$2 ver=$3
  if [[ -z "$src" ]]; then
    src=$(rom_local_candidate "$ver")
    if [[ -n "$src" ]]; then ok "${label,,} stock ROM: $src"; return 0; fi
    soft_fail "No ${label,,} stock ROM ($ver). Put Xiaomi's official $ver recovery zip in $ROM_DIR, or set ${label}_ROM=<path or https URL>"
    return 0
  fi
  if [[ "$src" == https://* ]]; then
    xiaomi_host "$src" || { soft_fail "${label}_ROM is not on a Xiaomi download server: $src (use the official link, or download it yourself and give the path)"; return 0; }
    if [[ -f "$ROM_DIR/$(basename "${src%%\?*}")" ]] || retry 3 5 curl -fsIL -o /dev/null "$src"; then ok "${label,,} stock ROM URL reachable"
    else soft_fail "${label}_ROM URL not reachable: $src"; fi
  elif [[ -f "$src" ]]; then ok "${label,,} stock ROM: $src"
  else soft_fail "${label}_ROM: no such file: $src"; fi
}

fetch_rom() { # fetch_rom <SKY|MIST> <value> <version> -> prints the local path
  local label=$1 src=$2 ver=$3 f
  [[ -n "$src" ]] || src=$(rom_local_candidate "$ver")
  [[ -n "$src" ]] || die "No ${label,,} stock ROM ($ver) in $ROM_DIR; set ${label}_ROM"
  if [[ "$src" == https://* ]]; then
    xiaomi_host "$src" || die "${label}_ROM is not on a Xiaomi download server: $src"
    mkdir -p "$ROM_DIR"
    f="$ROM_DIR/$(basename "${src%%\?*}")"
    if [[ ! -s "$f" ]]; then
      log "downloading the ${label,,} stock ROM (~5GB): $src" >&2
      retry 5 15 curl -fL --retry 3 -C - -o "$f.part" "$src" >&2 || die "download failed: $src (rerun to resume)"
      mv -f "$f.part" "$f"
    fi
    src=$f
  fi
  [[ -f "$src" ]] || die "${label}_ROM: no such file: $src"
  printf '%s\n' "$(readlink -f "$src")"
}

verify_rom() { # verify_rom <file> <version> <codename> <known md5s> : must be the expected Xiaomi build
  local f=$1 ver=$2 dev=$3 md5s=$4 sig md5 meta
  sig="$(basename "$f")|$(stat -c '%s|%Y' "$f")"
  if grep -qxF "$sig" "$STATE_DIR/roms.verified" 2>/dev/null; then ok "$(basename "$f"): verified earlier"; return 0; fi
  log "verifying $(basename "$f") (checksum + build metadata)"
  md5=$(md5sum "$f" | cut -d' ' -f1)
  if [[ " $md5s " == *" $md5 "* ]]; then ok "$(basename "$f"): MD5 $md5 matches the official $ver"
  else
    case "$f" in
      *.zip)
        meta=$(unzip -p "$f" META-INF/com/android/metadata 2>/dev/null || true)
        [[ -n "$meta" ]] || die "$(basename "$f") is not a recovery/OTA zip (no META-INF/com/android/metadata). Use Xiaomi's recovery ROM zip."
        grep -q "^post-build=.*/$dev[/_:]*.*$ver" <<<"$meta" || grep -q "^post-build=.*$ver" <<<"$meta" \
          || die "$(basename "$f") is not $ver (its metadata says: $(sed -n 's/^post-build=//p' <<<"$meta")). Get the official $ver ROM."
        grep -qE "^pre-device=([^,]*,)*$dev(,|$)" <<<"$meta" || die "$(basename "$f") is not a $dev ROM (pre-device=$(sed -n 's/^pre-device=//p' <<<"$meta"))"
        ok "$(basename "$f"): $dev $ver by its build metadata (MD5 $md5 not in my list; fine if it's Xiaomi's own file)" ;;
      *) [[ "$(basename "$f")" == *"$ver"* ]] || die "$(basename "$f"): can't confirm it's $ver"
         warn "$(basename "$f"): fastboot package, MD5 $md5 not in my list; trusting the file name ($ver)" ;;
    esac
  fi
  mkdir -p "$STATE_DIR"; echo "$sig" >> "$STATE_DIR/roms.verified"
}

# =============================== STAGE 1 =====================================
migrate_v3() { # one time, on a work dir that built the October (5.10, TopexGuy) ROM
  [[ -f "$STATE_DIR/trees.done" && ! -f "$STATE_DIR/v4" ]] || return 0
  log "Work dir was used for the 5.10 build: removing the old trees and kernel output (one time)"
  local p
  for p in "${V3_PATHS[@]}"; do
    # repo-managed checkouts have the manifest's remote names; v3 clones only have "origin"
    if [[ -d "$WORKDIR/$p/.git" && "$(git -C "$WORKDIR/$p" remote 2>/dev/null)" == origin ]]; then
      rm -rf "${WORKDIR:?}/$p"; ok "removed $p (v3 clone)"
    fi
  done
  if [[ -d "$WORKDIR/vendor/signify/keys" ]]; then
    if ls "$WORKDIR"/vendor/signify/keys/*.pk8 >/dev/null 2>&1 && [[ ! -f "$WORKDIR/$KEYS_REL/releasekey.pk8" ]]; then
      mkdir -p "$(dirname "$WORKDIR/$KEYS_REL")"; mv "$WORKDIR/vendor/signify/keys" "$WORKDIR/$KEYS_REL"
      sed -i "s#vendor/signify/keys/#$KEYS_REL/#g" "$WORKDIR/$KEYS_REL/keys.mk"; ok "moved your keys to $KEYS_REL"
    fi
    rm -rf "$WORKDIR/vendor/signify"
  fi
  rm -f "$WORKDIR/.repo/local_manifests/sky17.xml" "$WORKDIR/.repo/local_manifests/roomservice.xml"
  rm -rf "$WORKDIR/out/target/product/$CODENAME/obj/KERNEL_OBJ" "$WORKDIR/out/target/product/$CODENAME/obj/DLKM_OBJ"
  : > "$STATE_DIR/need_installclean"
  clear_from trees blobs configcheck build verify release
  : > "$STATE_DIR/v4"
}

install_local_manifest() {
  local lm="$WORKDIR/.repo/local_manifests" t
  mkdir -p "$lm"
  rm -f "$lm/sky17.xml" "$lm/roomservice.xml"   # v3 / breakfast leftovers
  t=$(mktemp)
  retry 3 10 curl -fsSL -o "$t" "$LOCAL_MANIFEST_URL" || die "could not download $LOCAL_MANIFEST_URL"
  xmllint --noout "$t" 2>/dev/null || die "sky.xml from $LOCAL_MANIFEST_URL is not valid XML"
  put "$lm/sky.xml" < "$t"; rm -f "$t"
}

sync_source() {
  CURRENT_STAGE="1-sync"
  cd "$WORKDIR"
  mkdir -p "$STATE_DIR"; [[ -d .repo ]] || : > "$STATE_DIR/v4"   # fresh work dir: nothing to migrate
  migrate_v3
  if stage_done sync && [[ -z "${RESYNC:-}" ]]; then log "STAGE 1: source already synced (RESYNC=1 to pull the newest commits)"; verify_source; return 0; fi
  log "STAGE 1: syncing PixelOS $ANDROID_BRANCH source + sky trees (~100GB+; the longest download)"
  if [[ ! -d .repo || "$(cat "$STATE_DIR/manifest_branch" 2>/dev/null)" != "$ANDROID_BRANCH" ]]; then
    retry 3 10 repo init -u "$MANIFEST_URL" -b "$ANDROID_BRANCH" --git-lfs --depth=1 --no-clone-bundle \
      || die "repo init failed"
    echo "$ANDROID_BRANCH" > "$STATE_DIR/manifest_branch"
  fi
  install_local_manifest
  restore_debug_edits
  local rc=1
  repo sync -c -j"$SYNC_JOBS" --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune && rc=0
  if (( rc )); then warn "sync incomplete, retrying with fewer jobs"; repo sync -c -j4 --force-sync --no-clone-bundle --no-tags --prune && rc=0; fi
  if (( rc )); then warn "retrying failed projects one at a time"; repo sync -c -j1 --fail-fast --force-sync --no-clone-bundle --no-tags && rc=0; fi
  (( rc == 0 )) || die "repo sync failed 3 times (network or disk). Rerun to resume; completed projects are kept."
  verify_source
  : > "$STATE_DIR/need_installclean"; clear_from configcheck build verify
  mark_done sync
}

verify_source() {
  local p missing=0
  for p in build/envsetup.sh build/soong vendor/custom/config/common_full_phone.mk \
           vendor/lineage/vars/aosp_target_release hardware/qcom-caf/common \
           hardware/qcom-caf/sm8450-6.6/audio/agm hardware/qcom-caf/sm8450-6.6/display/hal \
           device/qcom/sepolicy_vndr/sm8450 device/lineage/sepolicy/libion/sepolicy.mk \
           vendor/qcom/opensource/power vendor/qcom/opensource/usb vendor/qcom/opensource/vibrator \
           tools/extract-utils/extract_utils prebuilts/extract-tools prebuilts/clang/host/linux-x86 \
           packages/apps/Updater/tools/pixelos_feed.py; do
    [[ -e "$WORKDIR/$p" ]] || { printf '  ✘ missing after sync: %s\n' "$p"; missing=1; }
  done
  local t tp tu tb
  for t in "${TREES[@]}"; do
    IFS='|' read -r tp tu tb <<<"$t"
    [[ -e "$WORKDIR/$tp" ]] || { printf '  ✘ missing after sync: %s (from sky.xml)\n' "$tp"; missing=1; continue; }
    ok "$tp  @ $(git -C "$WORKDIR/$tp" rev-parse --short HEAD)  ($(git -C "$WORKDIR/$tp" log -1 --format='%cs: %s' | cut -c1-70))"
  done
  (( missing == 0 )) || die "Source is incomplete (paths above). Rerun with RESYNC=1."
  ok "source tree complete ($(sed -n 's/^aosp_target_release=//p' "$WORKDIR/vendor/lineage/vars/aosp_target_release" | tr -d ' ') release)"
}

# =============================== STAGE 2 =====================================
blob_sig() { # everything the extracted vendor depends on
  { cat "$WORKDIR"/device/xiaomi/sky/{proprietary-files.txt,proprietary-firmware.txt,extract-files.py,setup-makefiles.py} \
        "$WORKDIR"/device/xiaomi/sm4450-common/{proprietary-files.txt,extract-files.py,setup-makefiles.py} 2>/dev/null
    find "$WORKDIR/device/xiaomi/sm4450-common/blob-patches" -type f -print0 2>/dev/null | sort -z | xargs -0 cat 2>/dev/null
    git -C "$WORKDIR/tools/extract-utils" rev-parse HEAD 2>/dev/null
    echo "$1|$2|$FLASH_FIRMWARE"; } | sha256sum | cut -c1-16
}

extract_blobs() {
  CURRENT_STAGE="2-blobs"
  local sky mist sig
  if stage_done blobs && [[ -z "${REEXTRACT:-}" ]]; then
    IFS='|' read -r mist sky < "$STATE_DIR/blobs.roms" 2>/dev/null || true
    if [[ -n "$sky" && "$(cat "$STATE_DIR/blobs.sig" 2>/dev/null)" == "$(blob_sig "$mist" "$sky")" ]]; then
      log "STAGE 2: vendor blobs already extracted (REEXTRACT=1 to redo)"; check_vendor; return 0
    fi
    log "STAGE 2: the blob lists changed since the last extraction: extracting again"
  else log "STAGE 2: vendor blobs from Xiaomi's stock ROMs"; fi
  mkdir -p "$ROM_DIR"
  sky=$(fetch_rom SKY "${SKY_ROM:-}" "$SKY_ROM_VERSION")
  mist=$(fetch_rom MIST "${MIST_ROM:-}" "$MIST_ROM_VERSION")
  verify_rom "$sky" "$SKY_ROM_VERSION" sky "$SKY_ROM_MD5S"
  verify_rom "$mist" "$MIST_ROM_VERSION" mist "$MIST_ROM_MD5S"

  local tmp="$WORKDIR/.tmp-extract" fw=()
  rm -rf "$tmp"; mkdir -p "$tmp"
  (( $(gb_free "$WORKDIR") >= 25 )) || die "need ~25GB free to unpack the stock ROMs"
  [[ "$FLASH_FIRMWARE" == 1 ]] || fw=(--skip-firmware)
  _extract() { # _extract <log> args...
    local lg=$1; shift
    ( cd "$WORKDIR/device/xiaomi/sky" && export PYTHONPATH="$WORKDIR/tools/extract-utils" TMPDIR="$tmp" \
        && python3 extract-files.py "$@" ) > "$LOG_DIR/$lg.log" 2>&1
  }
  log "extracting common blobs from $(basename "$mist") (10-20 min)"
  _extract extract-common --only-common "$mist" \
    || { tail -30 "$LOG_DIR/extract-common.log"; die "common blob extraction failed (log: $LOG_DIR/extract-common.log)"; }
  ok "vendor/xiaomi/sm4450-common extracted"
  log "extracting sky blobs$([[ "$FLASH_FIRMWARE" == 1 ]] && echo ' + firmware') from $(basename "$sky")"
  _extract extract-sky --only-target "${fw[@]}" "$sky" \
    || { tail -30 "$LOG_DIR/extract-sky.log"; die "sky blob extraction failed (log: $LOG_DIR/extract-sky.log)"; }
  ok "vendor/xiaomi/sky extracted"
  rm -rf "$tmp"
  check_vendor
  echo "$(basename "$mist")|$(basename "$sky")" > "$STATE_DIR/blobs.roms"
  blob_sig "$(basename "$mist")" "$(basename "$sky")" > "$STATE_DIR/blobs.sig"
  : > "$STATE_DIR/need_installclean"; clear_from configcheck build verify
  mark_done blobs
}

firmware_images() { # partition names in proprietary-firmware.txt
  sed -e 's/#.*//' -e 's/[;|].*//' -e 's/[[:space:]]//g' "$WORKDIR/device/xiaomi/sky/proprietary-firmware.txt" \
    | sed -n 's/\.img$//p'
}

check_vendor() {
  local v="$WORKDIR/vendor/xiaomi"
  [[ -f "$v/sm4450-common/sm4450-common-vendor.mk" && -f "$v/sm4450-common/Android.bp" ]] || die "vendor/xiaomi/sm4450-common incomplete (REEXTRACT=1)"
  [[ -f "$v/sky/sky-vendor.mk" && -f "$v/sky/Android.bp" ]] || die "vendor/xiaomi/sky incomplete (REEXTRACT=1)"
  check_blob_list "$WORKDIR/device/xiaomi/sm4450-common/proprietary-files.txt" "$v/sm4450-common"
  check_blob_list "$WORKDIR/device/xiaomi/sky/proprietary-files.txt" "$v/sky"
  if [[ "$FLASH_FIRMWARE" == 1 ]]; then
    local f missing=()
    for f in $(firmware_images); do [[ -s "$v/sky/radio/$f.img" ]] || missing+=("$f"); done
    (( ${#missing[@]} == 0 )) || die "firmware images missing from vendor/xiaomi/sky/radio: ${missing[*]} (REEXTRACT=1)"
    grep -aqF "QC_IMAGE_VERSION_STRING=$FIRMWARE_TZ_VERSION" "$v/sky/radio/tz.img" \
      || soft_fail "tz.img is not $FIRMWARE_TZ_VERSION, so this isn't OS2.0.210 firmware. Don't ship it without checking (or FLASH_FIRMWARE=0)"
    ok "firmware: $(firmware_images | wc -l) images, $FIRMWARE_TZ_VERSION (OS2.0.210)"
  fi
}

check_blob_list() { # every file in proprietary-files.txt present in the extracted vendor
  local list=$1 v=$2 line src dst total=0 missing=0 base
  base="$v/proprietary"; [[ -d "$base" ]] || base="$v"
  local miss_file; miss_file="$STATE_DIR/missing_blobs_$(basename "$v").txt"; : > "$miss_file"
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"; [[ -z "$line" ]] && continue
    line="${line#-}"; line="${line%%|*}"; line="${line%%;*}"
    src="${line%%:*}"; dst="$src"; [[ "$line" == *:* ]] && dst="${line#*:}"
    total=$((total+1))
    [[ -e "$base/$dst" || -e "$base/$src" ]] || { missing=$((missing+1)); echo "$dst" >> "$miss_file"; }
  done < "$list"
  (( total > 0 )) || die "$list is empty or unreadable"
  if (( missing == 0 )); then ok "$(basename "$v") blobs: all $total files present"
  elif (( missing * 100 / total < 3 )); then
    warn "$missing of $total $(basename "$v") files missing (list: $miss_file). First few:"; head -5 "$miss_file" | sed 's/^/   /'
  else
    head -15 "$miss_file" | sed 's/^/   /'
    soft_fail "$missing of $total $(basename "$v") files missing: wrong stock ROM for this blob list?"
  fi
}

# =============================== STAGE 3 =====================================
put() { # put <file> : write stdin to <file> only if the content differs (keeps incremental builds fast)
  local f=$1 t; t=$(mktemp)
  cat > "$t"
  if [[ -f "$f" ]] && cmp -s "$t" "$f"; then rm -f "$t"
  else mkdir -p "$(dirname "$f")"; mv "$t" "$f"; chmod 644 "$f"; ok "updated ${f#"$WORKDIR"/}"; fi
}

mk_list() { # mk_list <makefile> <VAR> : values of a (possibly multi-line) VAR := a \ b \ c
  awk -v var="$2" '
    $0 ~ "^"var"[ \t]*[:+]?=" {f=1; sub("^"var"[ \t]*[:+]?=", "")}
    f { c = ($0 ~ /\\[ \t]*$/); gsub(/\\/, ""); n = split($0, a); for (i = 1; i <= n; i++) print a[i]; if (!c) f = 0 }
  ' "$1"
}

restore_debug_edits() { # DEBUG_BOOT edits are the only local changes this script makes to a tree
  local d="$WORKDIR/device/xiaomi/sky" f
  [[ -d "$d/.git" || -f "$d/.git" ]] || return 0
  for f in BoardConfig.mk device.mk; do
    if grep -qs '# >>> sky17 debug-boot' "$d/$f"; then git -C "$d" checkout -q -- "$f"; ok "restored $f (debug-boot edits removed)"; fi
  done
  rm -rf "$d/sky17-debug"
}

setup_trees() {
  CURRENT_STAGE="3-trees"
  log "STAGE 3: signing keys and tree checks"
  cd "$WORKDIR"
  restore_debug_edits
  local d="$WORKDIR/device/xiaomi/sky"
  if [[ -n "${DEBUG_BOOT:-}" ]]; then
    if [[ "$BUILD_TYPE" == user ]]; then BUILD_TYPE=userdebug; warn "DEBUG_BOOT needs a userdebug build; building userdebug this time"; fi
    write_debug_files "$d/sky17-debug"
    printf '%s\n' '' '# >>> sky17 debug-boot' 'PRODUCT_PRODUCT_PROPERTIES += \' '    ro.adb.secure=0 \' '    persist.sys.usb.config=adb \' '    ro.debuggable=1' 'PRODUCT_COPY_FILES += \' '    device/xiaomi/sky/sky17-debug/sky17_bootwatch.sh:$(TARGET_COPY_OUT_VENDOR)/etc/sky17_bootwatch.sh \' '    device/xiaomi/sky/sky17-debug/sky17_bootwatch.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/sky17_bootwatch.rc' '# <<< sky17 debug-boot' >> "$d/device.mk"
    printf '%s\n' '' '# >>> sky17 debug-boot' 'BOARD_BOOTCONFIG += androidboot.selinux=permissive' '# <<< sky17 debug-boot' >> "$d/BoardConfig.mk"
    warn "DEBUG_BOOT build: boot logs to /metadata, open adb, permissive SELinux. For diagnosing only."
  fi
  setup_signing
  validate_trees
  # configuration changed since the last build? refresh installed images (compiled objects are kept)
  local sig
  sig=$( { git -C "$d" rev-parse HEAD; git -C "$WORKDIR/device/xiaomi/sm4450-common" rev-parse HEAD
           git -C "$WORKDIR/kernel/xiaomi/sm4450" rev-parse HEAD; cat "$STATE_DIR/blobs.sig" 2>/dev/null
           echo "$BUILD_TYPE $SIGN $FLASH_FIRMWARE ${DEBUG_BOOT:-}"; } | sha256sum | cut -c1-16 )
  echo "$sig" > "$STATE_DIR/config.sig.pending"
  if [[ "$(cat "$STATE_DIR/config.sig" 2>/dev/null)" != "$sig" ]]; then
    : > "$STATE_DIR/need_installclean"; ok "build configuration changed: installed images will be refreshed"
  fi
  mark_done trees
}

setup_signing() { # your release keys in vendor/lineage-priv/keys: restored from your backup, else made once
  local k="$WORKDIR/$KEYS_REL"
  if [[ "$SIGN" != 1 ]]; then
    [[ -f "$k/keys.mk" ]] && warn "SIGN=0 but $KEYS_REL exists: PixelOS will still sign with it (move it away for test-keys)"
    return 0
  fi
  local tgz="${KEYS_TGZ:-}" c
  if [[ ! -f "$k/keys.mk" || ! -f "$k/releasekey.pk8" ]]; then
    if [[ -z "$tgz" ]]; then
      for c in "$HOME/sky17-signing-keys.tgz" "$WORKDIR/sky17-signing-keys.tgz" "$ROM_DIR/sky17-signing-keys.tgz"; do
        [[ -f "$c" ]] && { tgz=$c; break; }
      done
    fi
    if [[ -n "$tgz" ]]; then
      [[ -f "$tgz" ]] || die "KEYS_TGZ: no such file: $tgz"
      local listing; listing=$(tar tzf "$tgz") || die "$tgz is not a readable .tgz"
      grep -qx "$KEYS_REL/releasekey.pk8" <<<"$listing" || die "$tgz doesn't contain $KEYS_REL/releasekey.pk8"
      tar xzf "$tgz" -C "$WORKDIR" "$KEYS_REL" || die "could not unpack $tgz"
      ok "restored your release keys from $tgz (same keys as the October build: users can update without wiping)"
    else
      warn "No key backup found (~/sky17-signing-keys.tgz). Making NEW release keys: users coming from the October build must clean flash."
      local sg="$STATE_DIR/signify"
      rm -rf "$sg"; mkdir -p "$sg"
      ( cd "$sg" && git init -q && git remote add origin "$SIGNIFY_REPO" \
        && retry 3 10 git fetch -q --depth=1 origin "$SIGNIFY_COMMIT" && git checkout -q FETCH_HEAD ) \
        || die "could not download the signing tool ($SIGNIFY_REPO @ ${SIGNIFY_COMMIT:0:12})"
      [[ -f "$WORKDIR/development/tools/make_key" ]] || die "development/tools/make_key missing (RESYNC=1)"
      ( cd "$sg/main" && ROM_ROOT="$WORKDIR" KEYS_DIR="$KEYS_REL" KEY_SIZE=4096 SKIP_OTA=true \
          SUBJECT_INFO='/C=US/ST=California/L=Mountain View/O=Android/OU=Android/CN=Android/emailAddress=android@android.com' \
          bash keys.sh ) >"$LOG_DIR/signing.log" 2>&1 || true   # AOSP make_key exits 1 even on success; checked below
    fi
  fi
  grep -q "^PRODUCT_DEFAULT_DEV_CERTIFICATE := $KEYS_REL/releasekey$" "$k/keys.mk" || die "$KEYS_REL/keys.mk doesn't point at your releasekey"
  local missing=()
  for c in releasekey platform shared media networkstack sdk_sandbox bluetooth nfc \
           $(grep -oP '(?<=:)[a-zA-Z0-9._-]+' "$k/keys.mk" | sort -u); do
    [[ -s "$k/$c.pk8" && -s "$k/$c.x509.pem" ]] || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) || die "signing keys missing: ${missing[*]:0:8} (delete $KEYS_REL and rerun)"
  grep -qs "^-*include $KEYS_REL/keys.mk" "$WORKDIR/vendor/lineage/config/common.mk" \
    || die "vendor/lineage/config/common.mk no longer includes $KEYS_REL/keys.mk: the build would use test-keys"
  local bk="$WORKDIR/sky17-signing-keys.tgz"
  if [[ ! -f "$bk" || "$k/keys.mk" -nt "$bk" ]]; then tar czf "$bk" -C "$WORKDIR" "$KEYS_REL"; chmod 600 "$bk"; fi
  ok "signed build: $(ls "$k"/*.pk8 | wc -l) release keys in $KEYS_REL (backup: $bk; keep it private)"
}

write_debug_files() { # boot watcher: saves a timeline + logs to /metadata (readable from recovery)
  mkdir -p "$1"
  cat > "$1/sky17_bootwatch.sh" <<'DBGEOF'
#!/vendor/bin/sh
d=/metadata/sky17_boot
rm -rf $d; mkdir -p $d
echo "watcher started $(cat /proc/uptime)" > $d/started.txt
j=0
while [ $j -lt 100 ]; do
  echo "$(cut -d' ' -f1 /proc/uptime) listeners=$(/system/bin/getprop vendor.sys.listeners.registered) keymint=$(/system/bin/getprop init.svc.vendor.keymint-qti) qseecomd=$(/system/bin/getprop init.svc.vendor.qseecomd) vold=$(/system/bin/getprop init.svc.vold) boot=$(/system/bin/getprop sys.boot_completed)" >> $d/timeline.txt
  sleep 0.2
  j=$((j+1))
done
i=0
while [ $i -lt 12 ]; do
  n=$d/snap$i; mkdir -p $n
  cat /proc/uptime > $n/uptime.txt
  /system/bin/getprop > $n/props.txt 2>&1
  /system/bin/dmesg > $n/dmesg.txt 2>&1
  /system/bin/logcat -b all -d > $n/logcat.txt 2>&1
  /system/bin/ps -A -o PID,PPID,STAT,WCHAN,TIME,NAME > $n/ps.txt 2>&1
  cat /sys/fs/pstore/* > $n/pstore.txt 2>&1
  sync
  [ "$(/system/bin/getprop sys.boot_completed)" = "1" ] && echo done > $d/boot_completed.txt && break
  sleep 20
  i=$((i+1))
done
DBGEOF
  printf '%s\n' 'service sky17_bootwatch /vendor/bin/sh /vendor/etc/sky17_bootwatch.sh' '    user root' \
    '    group root log readproc system shell' '    seclabel u:r:su:s0' '    oneshot' '    disabled' '' \
    'on init' '    start sky17_bootwatch' > "$1/sky17_bootwatch.rc"
}

lfs_pointers_in() { # count Git-LFS placeholder files (not real content)
  { find "$1" -type f -size -200c -not -path '*/.git/*' -exec grep -l '^version https://git-lfs' {} + 2>/dev/null || true; } | wc -l
}

validate_trees() {
  log "Validating trees"
  cd "$WORKDIR"
  local d=device/xiaomi/sky cm=device/xiaomi/sm4450-common k=kernel/xiaomi/sm4450 km=kernel/xiaomi/sm4450-modules
  local f c n bad=0
  for f in AndroidProducts.mk BoardConfig.mk device.mk custom_sky.mk proprietary-files.txt proprietary-firmware.txt; do
    [[ -f "$d/$f" ]] || die "device tree missing $f"; done
  for f in BoardConfigCommon.mk common.mk proprietary-files.txt; do [[ -f "$cm/$f" ]] || die "common tree missing $f"; done
  grep -q '^PRODUCT_NAME := custom_sky$' "$d/custom_sky.mk" || die "custom_sky.mk doesn't define custom_sky"
  for f in vendor/custom/config/common_full_phone.mk hardware/qcom-caf/sm8450-6.6/audio/primary-hal \
           vendor/qcom/opensource/power/config/parrot/powerhint.xml hardware/xiaomi/vintf; do
    [[ -e "$f" ]] || { echo "   missing: $f"; bad=1; }; done
  (( bad == 0 )) || die "the trees need paths that don't exist (above)"
  ok "device trees + PixelOS product OK"

  [[ -f "$k/Makefile" ]] || die "kernel source missing"
  local kv; kv=$(sed -n 's/^VERSION = //p;s/^PATCHLEVEL = //p;s/^SUBLEVEL = //p' "$k/Makefile" | paste -sd.)
  [[ "$kv" == 6.6.* ]] || die "kernel/xiaomi/sm4450 is $kv, expected 6.6"
  for c in $(mk_list "$cm/BoardConfigCommon.mk" TARGET_KERNEL_CONFIG); do
    [[ -f "$k/arch/arm64/configs/$c" ]] || die "kernel config $c missing from $k"; done
  grep -q '^CONFIG_SCHED_WALT=m' "$k/arch/arm64/configs/vendor/parrot_perf.config" || die "WALT is not enabled in parrot_perf.config"
  for c in $(mk_list "$cm/BoardConfigCommon.mk" TARGET_KERNEL_EXT_MODULES); do
    [[ -d "$km/$c" ]] || die "kernel module source $km/$c missing"; done
  [[ -d kernel/xiaomi/sm4450-devicetrees ]] || die "kernel/xiaomi/sm4450-devicetrees missing"
  n=$(lfs_pointers_in "$k"); (( n == 0 )) || die "kernel has $n Git-LFS placeholder files (RESYNC=1)"
  ok "kernel: $kv ($(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' "$k/arch/arm64/configs/vendor/parrot_perf.config"), WALT), $(mk_list "$cm/BoardConfigCommon.mk" TARGET_KERNEL_EXT_MODULES | wc -l) external module dirs"
}

# =============================== STAGE 4 =====================================
load_build_env() {
  cd "$WORKDIR"
  set +e +u +o pipefail; trap - ERR           # AOSP scripts aren't strict-mode safe
  export LC_ALL=C
  # shellcheck disable=SC1091
  source build/envsetup.sh >/dev/null 2>&1
  # lunch directly: breakfast runs roomservice, which could pull the old PixelOS sky repos back in
  local rel ok_=0
  : > "$LOG_DIR/lunch.log"
  for rel in "$(sed -n 's/^aosp_target_release=//p' vendor/lineage/vars/aosp_target_release | tr -d ' ')" cp2a cp1a trunk_staging; do
    [[ -z "$rel" ]] && continue
    lunch "custom_${CODENAME}-${rel}-${BUILD_TYPE}" >>"$LOG_DIR/lunch.log" 2>&1 && { ok_=1; break; }
  done
  (( ok_ )) || { tail -25 "$LOG_DIR/lunch.log"; die "lunch failed (log: $LOG_DIR/lunch.log)"; }
  local dev plat
  dev=$(get_build_var TARGET_DEVICE 2>/dev/null); plat=$(get_build_var PLATFORM_VERSION 2>/dev/null)
  [[ "$dev" == "$CODENAME" ]] || die "lunch selected device '$dev', expected $CODENAME"
  ok "lunch: $TARGET_PRODUCT-$TARGET_RELEASE-$TARGET_BUILD_VARIANT  (Android $plat, device $dev)"
  [[ "$plat" == 17* ]] || soft_fail "PLATFORM_VERSION is '$plat', expected 17"
  if [[ "$SIGN" == 1 ]]; then
    local cert; cert=$(get_build_var DEFAULT_SYSTEM_DEV_CERTIFICATE 2>/dev/null)
    [[ "$cert" == "$KEYS_REL/releasekey" ]] || die "build would sign with '$cert', not $KEYS_REL/releasekey"
    ok "signing: $cert"
  fi
}

run_m() { # run_m <logname> targets...   -> returns m's exit code
  local name=$1; shift
  m -j"$JOBS" "$@" > "$LOG_DIR/$name.log" 2>&1
  local rc=$?
  return $rc
}

show_failure() { # summarize a failed m log
  local lf=$1
  echo "------- error summary ($lf) -------"
  local nf; nf=$(grep -c '^FAILED:' "$lf" 2>/dev/null || true)
  echo "failed build steps: ${nf:-0}"
  grep '^FAILED:' "$lf" 2>/dev/null | cut -c1-220 | sort -u | head -40 || true
  echo "--- first failure in detail ---"
  { grep -n -A12 -m1 '^FAILED:' "$lf"; grep -n -E 'error:|Error:|ERROR:|syntax error|\*\*\* |undefined reference|neverallow|checkpolicy|VINTF|incompatible' "$lf" | grep -v -E 'warning:|license metadata|thiserror|liberror' | sort -t: -k2 -u; } 2>/dev/null | head -80 || true
  echo "-----------------------------------"
  local ad="$WORKDIR/out/target/product/$CODENAME/obj/PACKAGING/apkcerts_intermediates"
  if grep -q 'apkcerts-soong-doublecheck' "$lf" 2>/dev/null && [[ -d "$ad" ]]; then
    echo "------- apkcerts difference (send me this) -------"
    diff "$ad"/*-apkcerts-soong-doublecheck.txt "$ad"/*-apkcerts-soong_apkcerts_file_with_soong_and_make_modules_removed.txt | head -40 || true
    echo "---------------------------------------------------"
  fi
  if grep -qiE 'too large|exceeds|out of space|size of the partition' "$lf" 2>/dev/null; then
    echo "------- image sizes -------"; ls -la "$WORKDIR/out/target/product/$CODENAME/"*.img 2>/dev/null
  fi
}

config_check() {
  CURRENT_STAGE="4-configcheck"
  log "STAGE 4: fast configuration checks (catches most port errors before the long build)"
  load_build_env
  log "4a. build graph analysis (m nothing)"
  run_m configcheck-analysis nothing || { show_failure "$LOG_DIR/configcheck-analysis.log"; die "Build configuration invalid. Send me the error summary above."; }
  ok "build graph OK"
  log "4b. SELinux policy compile"
  run_m configcheck-sepolicy selinux_policy || { show_failure "$LOG_DIR/configcheck-sepolicy.log"; die "SELinux policy fails to compile. Send me the error summary above."; }
  ok "SELinux policy compiles"
  log "4c. VINTF compatibility (device vs Android 17 framework)"
  if run_m configcheck-vintf check-vintf-all; then ok "VINTF compatible"
  elif grep -qiE "unknown target|no rule to make target" "$LOG_DIR/configcheck-vintf.log"; then
    warn "check-vintf-all target not available; VINTF is still enforced during the full build"
  else show_failure "$LOG_DIR/configcheck-vintf.log"; die "VINTF incompatibility (the ROM would not boot). Send me the error summary above."; fi
  if [[ -z "${SKIP_KERNEL_CHECK:-}" ]]; then
    log "4d. kernel 6.6 + modules + boot images (15-30 min; a kernel error shows up here, not after hours)"
    run_m configcheck-kernel bootimage vendorbootimage dtboimage \
      || { show_failure "$LOG_DIR/configcheck-kernel.log"; die "Kernel/boot images fail to build. Send me the error summary above."; }
    local kr; kr=$(cat "$WORKDIR/out/target/product/$CODENAME/obj/KERNEL_OBJ/include/config/kernel.release" 2>/dev/null || true)
    [[ "$kr" == 6.6.* ]] || die "kernel built, but its version is '$kr', not 6.6"
    ok "kernel $kr + boot, vendor_boot, dtbo images built"
  fi
  mark_done configcheck
}

# =============================== STAGE 5 =====================================
setup_ccache() {
  [[ -z "${NO_CCACHE:-}" ]] && command -v ccache >/dev/null || return 0
  export USE_CCACHE=1 CCACHE_EXEC; CCACHE_EXEC=$(command -v ccache)
  export CCACHE_DIR="${CCACHE_DIR:-$WORKDIR/.ccache}" CCACHE_COMPRESS=1
  ccache -M 50G >/dev/null 2>&1 || true
  ok "ccache: $CCACHE_DIR (50GB; makes rebuilds much faster)"
}

full_build() {
  CURRENT_STAGE="5-build"
  [[ -n "${TARGET_PRODUCT:-}" ]] || load_build_env
  log "STAGE 5: full build (m pixelos -j$JOBS). Log: $LOG_DIR/build.log"
  local t0=$SECONDS
  if [[ -f "$STATE_DIR/need_installclean" ]]; then
    log "trees or blobs changed: clearing previously installed images (m installclean; compiled objects are kept)"
    run_m installclean installclean || { show_failure "$LOG_DIR/installclean.log"; die "m installclean failed"; }
    rm -f "$STATE_DIR/need_installclean"; ok "installclean done"
  fi
  if [[ -f "$STATE_DIR/config.sig.pending" ]]; then mv -f "$STATE_DIR/config.sig.pending" "$STATE_DIR/config.sig"; fi
  # -k 0: keep building everything that doesn't depend on a failure, so one run shows ALL errors
  if ! NINJA_ARGS="${NINJA_ARGS:+$NINJA_ARGS }-k 0" run_m build pixelos; then
    show_failure "$LOG_DIR/build.log"
    die "Build failed. Fix, then rerun: it resumes incrementally (no re-sync)."
  fi
  ok "build finished in $(( (SECONDS - t0) / 60 )) min"
  mark_done build
}

# =============================== STAGE 6 =====================================
verify_output() {
  CURRENT_STAGE="6-verify"
  log "STAGE 6: verifying output"
  local out="$WORKDIR/out/target/product/$CODENAME" zip tf abp f
  zip=$(ls -t "$out"/PixelOS_*.zip 2>/dev/null | head -1 || true)
  [[ -n "$zip" && -f "$zip" ]] || die "no PixelOS zip in $out"
  local size_mb=$(( $(stat -c %s "$zip") / 1048576 ))
  (( size_mb > 700 )) || die "zip is only ${size_mb}MB, too small to be a full ROM"
  local listing; listing=$(unzip -l "$zip")
  local e; for e in payload.bin payload_properties.txt META-INF/com/android/metadata; do
    grep -qF "$e" <<<"$listing" || die "zip is missing $e (not a valid OTA package)"; done
  local meta; meta=$(unzip -p "$zip" META-INF/com/android/metadata)
  grep -q "^pre-device=$CODENAME" <<<"$meta" || die "zip targets '$(sed -n 's/^pre-device=//p' <<<"$meta")', not $CODENAME"
  local sdk; sdk=$(sed -n 's/^post-sdk-level=//p' <<<"$meta")
  for e in boot.img vendor_boot.img dtbo.img vbmeta.img recovery.img; do [[ -f "$out/$e" ]] || die "$e was not produced"; done
  tf=$(ls -td "$out"/obj/PACKAGING/target_files_intermediates/*-target_files*/ 2>/dev/null | head -1)
  abp="${tf}META/ab_partitions.txt"
  [[ -f "$abp" ]] || die "can't find the OTA partition list ($abp)"
  if [[ "$FLASH_FIRMWARE" == 1 ]]; then
    local miss=()
    for f in $(firmware_images); do grep -qx "$f" "$abp" || miss+=("$f"); done
    (( ${#miss[@]} == 0 )) || die "OTA zip is missing firmware: ${miss[*]}. Don't flash; send me this."
    ok "firmware in the OTA zip: $(firmware_images | wc -l) partitions (OS2.0.210, $FIRMWARE_TZ_VERSION)"
  else
    for f in $(firmware_images); do ! grep -qx "$f" "$abp" || die "FLASH_FIRMWARE=0 but $f is in the OTA zip"; done
    ok "OTA zip carries no firmware (FLASH_FIRMWARE=0)"
  fi
  local kr; kr=$(cat "$out/obj/KERNEL_OBJ/include/config/kernel.release" 2>/dev/null || true)
  [[ "$kr" == 6.6.* ]] || die "kernel version is '$kr', expected 6.6"
  local bp="$out/system/build.prop" tags
  tags=$(grep -m1 '^ro.build.tags=' "$bp" 2>/dev/null | cut -d= -f2)
  if [[ "$SIGN" == 1 ]]; then
    # the real proof: the OTA certificate and the platform certificate are YOUR keys
    local want got ac fr
    want=$(openssl x509 -in "$WORKDIR/$KEYS_REL/releasekey.x509.pem" -noout -fingerprint -sha256 2>/dev/null)
    got=$(unzip -p "$out/system/etc/security/otacerts.zip" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
    [[ -n "$want" && "$want" == "$got" ]] || die "the ROM's OTA certificate is not your releasekey (not signed with your keys)"
    ac="${tf}META/apkcerts.txt"
    fr=$(grep -m1 'name="framework-res.apk"' "$ac" 2>/dev/null || true)
    if [[ -n "$fr" && "$fr" != *"$KEYS_REL/platform"* ]]; then die "framework-res.apk is not signed with your platform key: $fr"; fi
    [[ "$tags" == release-keys ]] || die "signed with your keys, but tagged '$tags' instead of release-keys"
    ok "signed with your own keys (OTA + platform certificates checked), tagged release-keys"
  fi
  local up; up=$(find "$out/system_ext" -path '*/priv-app/Updater/Updater.apk' 2>/dev/null | head -1)
  if [[ -n "$up" ]]; then ok "Updater app included (OTA updates)"; else warn "Updater.apk not found under system_ext/priv-app: check OTA updates work on the phone"; fi
  grep -qs '^net.pixelos.version=' "$out/system_ext/etc/build.prop" "$out/system/build.prop" "$out/product/etc/build.prop" \
    || warn "net.pixelos.version not found in build.prop: the Updater will refuse to check for updates"
  if [[ -z "${DEBUG_BOOT:-}" ]]; then
    grep -qs 'androidboot.selinux=permissive' "$WORKDIR"/device/xiaomi/{sky/BoardConfig.mk,sm4450-common/BoardConfigCommon.mk} && die "SELinux permissive flag in a BoardConfig"
    ok "SELinux: enforcing (no permissive override); build type $BUILD_TYPE"
  fi
  local rel; rel=$(grep -m1 '^ro.build.version.release=' "$bp" 2>/dev/null | cut -d= -f2)
  [[ "$rel" == 17* ]] || soft_fail "Android version is '$rel', expected 17"
  sha256sum "$zip" > "$zip.sha256"
  ok "zip: $(basename "$zip") (${size_mb}MB), device=$CODENAME, Android ${rel:-?} (SDK ${sdk:-?}), kernel $kr"
  mark_done verify
  ok "BUILD COMPLETE: $(basename "$zip")"
}

# =============================== STAGE 7 =====================================
# Release package: fastboot zip + OTA zip + recovery.img + docs + checksums + Updater feed.
REL_IMGS=(boot vendor_boot dtbo vbmeta vbmeta_system)   # physical, non-firmware partitions the fastboot zip flashes
REL_NOT_FLASHED=(recovery)                               # in the OTA, deliberately not in the fastboot zip
RELEASE_DIR="${RELEASE_DIR:-$HOME/release}"
STATUS_FILE="$WORKDIR/release-status.conf"

in_list() { local x=$1 y; shift; for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done; return 1; }
link_or_copy() { ln -f "$1" "$2" 2>/dev/null || cp -f "$1" "$2"; }

fill_template() { # fill_template <template> <output>   (@KEY@ from REL_* env + status file)
  python3 - "$1" "$2" "$STATUS_FILE" <<'PY'
import os, re, sys
tpl, dst, st = sys.argv[1:4]
v = {k[4:]: val for k, val in os.environ.items() if k.startswith("REL_")}
for line in open(st, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, val = (x.strip() for x in line.split("=", 1))
    v[k if k == "EXTRA_ISSUES" else "S_" + k] = val
s = open(tpl, encoding="utf-8").read()
extra = [x.strip() for x in v.get("EXTRA_ISSUES", "").split("|") if x.strip()]
s = s.replace("- @EXTRA_ISSUES@\n", "".join("- %s\n" % x for x in extra))
s = "".join(l for l in s.splitlines(True)
            if not (re.fullmatch(r"@([A-Z_]+)@\n?", l) and v.get(l.strip().strip("@"), None) == ""))
s = re.sub(r"@([A-Z_]+)@", lambda m: v.get(m.group(1), m.group(0)), s)
left = sorted(set(re.findall(r"@[A-Z_]+@", s)))
if left:
    sys.exit("unfilled placeholders: " + " ".join(left))
open(dst, "w", encoding="utf-8").write(s)
PY
}

write_status_template() { # what you tested; RELEASE_NOTES.md is generated from this
  cat > "$STATUS_FILE" <<'STEOF'
# Device status for RELEASE_NOTES.md. Edit after testing, then regenerate the notes (takes seconds):
#     RELEASE_ONLY=1 ./build_pixelos17_sky.sh
# Suggested values:  ✅ Working   ⚠️ Partly (say what)   ❌ Broken   ❔ Not tested yet
WIFI=❔ Not tested yet
BT=❔ Not tested yet
RIL=❔ Not tested yet
AUDIO=❔ Not tested yet
CAM=❔ Not tested yet
FP_FPC=❔ Not tested yet
FP_GDX=❔ Not tested yet
GPS=❔ Not tested yet
SENS=❔ Not tested yet
NFC=❔ Not tested yet
DISP=❔ Not tested yet
USB=❔ Not tested yet
OTA=❔ Not tested yet
# Recovery install: set RECOVERY=yes only after a sideload of this build worked for you
# (with the ROM's own recovery.img, or e.g. OrangeFox), and RECOVERY_WITH to what you used
RECOVERY=no
RECOVERY_WITH=
# Extra known issues, separated by " | " (leave empty for none)
EXTRA_ISSUES=
STEOF
}

package_release() {
  CURRENT_STAGE="7-release"
  set +e +o pipefail; trap - ERR     # same as the build stages: every step below is checked explicitly
  log "STAGE 7: release package (fastboot zip + OTA zip + docs + checksums + Updater feed)"
  local out="$WORKDIR/out/target/product/$CODENAME" zip name rdir tf abp misc fw
  zip=$(ls -t "$out"/PixelOS_*.zip 2>/dev/null | head -1 || true)
  [[ -n "$zip" && -f "$zip" ]] || die "no PixelOS zip in $out (build first)"
  name=$(basename "$zip" .zip)
  rdir="$RELEASE_DIR/$name"
  tf=$(ls -td "$out"/obj/PACKAGING/target_files_intermediates/*-target_files*/ 2>/dev/null | head -1)
  abp="${tf}META/ab_partitions.txt"; misc="${tf}META/misc_info.txt"
  [[ -f "$abp" && -f "$misc" ]] || die "target-files metadata not found in $out (build first)"
  [[ -f "$STATUS_FILE" ]] || write_status_template
  grep -q '^OTA=' "$STATUS_FILE" || echo 'OTA=❔ Not tested yet' >> "$STATUS_FILE"   # added in v4
  mkdir -p "$rdir" || die "can't create $rdir"
  mapfile -t fw < <(firmware_images)

  # --- the fastboot package flashes what the ROM updates minus firmware and recovery: REL_IMGS + super ---
  local dyn p unexpected=()
  dyn=$(grep -E '^(dynamic_partition_list|super_[a-z_]+_partition_list)=' "$misc" | cut -d= -f2- | tr ' ' '\n' | sort -u | xargs)
  [[ -n "${dyn// /}" ]] || die "no dynamic partition list in $misc"
  while read -r p; do
    [[ -z "$p" ]] && continue
    # shellcheck disable=SC2086
    in_list "$p" "${fw[@]}" "${REL_IMGS[@]}" "${REL_NOT_FLASHED[@]}" $dyn || unexpected+=("$p")
  done < "$abp"
  (( ${#unexpected[@]} == 0 )) || die "the ROM updates partitions the fastboot installer doesn't flash: ${unexpected[*]}. Send me this."
  for p in "${REL_IMGS[@]}"; do
    grep -qx "$p" "$abp" || die "$p is not in the ROM's partition list"
    [[ -s "$out/$p.img" ]] || die "$out/$p.img missing"
  done
  ok "fastboot ROM contents: ${REL_IMGS[*]} + $dyn; no firmware, bootloader or recovery"

  local fz="$rdir/$name-fastboot.zip" psig
  local rec rec_with bt='`'
  rec=$(sed -n 's/^RECOVERY=//p' "$STATUS_FILE" | tail -1 | tr -d ' '); rec_with=$(sed -n 's/^RECOVERY_WITH=//p' "$STATUS_FILE" | tail -1)
  if [[ "$rec" == yes ]]; then
    export REL_RECOVERY_STATUS="Tested with ${rec_with:-a custom recovery}" \
      REL_RECOVERY_STEPS="Tested with **${rec_with:-the ROM recovery}**. Coming from another ROM or stock: 1. ${bt}fastboot flash recovery $name-recovery.img${bt} (or your custom recovery), 2. boot it (Power + Volume Up), 3. **Format Data / Factory reset**, 4. ${bt}adb sideload $name.zip${bt}, 5. reboot. Updating this ROM: use Settings → System → Updater, or sideload the new zip (no format)."
    export REL_RECOVERY_NOTE=""
  else
    export REL_RECOVERY_STATUS="Not tested yet: use the fastboot ROM for a first install" \
      REL_RECOVERY_STEPS="Not tested yet for this build: install with fastboot (above). The OTA zip is published for the built-in Updater, which installs later updates without a PC."
    export REL_RECOVERY_NOTE="- Installing from a custom recovery isn't tested yet for this build: use the fastboot ROM for the first install
"
  fi
  psig="img-zip-v6"   # bump when the fastboot zip layout changes
  if [[ -f "$fz" && "$fz" -nt "$zip" && -z "${REPACK:-}" && "$(cat "$STATE_DIR/pkg-$name.sig" 2>/dev/null)" == "$psig" ]]; then
    ok "fastboot package already up to date (REPACK=1 to rebuild it)"
  else
    local need_gb=12 free; free=$(gb_free "$RELEASE_DIR")
    (( free >= need_gb )) || die "only ${free}GB free for the release (need ~${need_gb}GB)"
    if [[ ! -s "$out/super_empty.img" || "$out/system.img" -nt "$out/super_empty.img" ]]; then
      [[ -n "${TARGET_PRODUCT:-}" ]] || load_build_env
      log "building super_empty.img (the partition layout 'fastboot update' needs)"
      run_m superimage_empty superimage_empty || { show_failure "$LOG_DIR/superimage_empty.log"; die "m superimage_empty failed"; }
      [[ -s "$out/super_empty.img" ]] || die "super_empty.img was not produced"
    fi
    # Standard AOSP image zip, flashed with one command: fastboot update <zip>
    local stg="$rdir/.stage"
    rm -rf "$stg"; mkdir -p "$stg" || die "can't create $stg"
    # images come from ONE place so their verified-boot hashes match: the target-files IMAGES/ the
    # OTA was made from, falling back to out/. Sparse images are expanded (fastboot flashes super raw).
    local src="${tf}IMAGES" s2i
    for p in "${REL_IMGS[@]}" $dyn; do [[ -s "$src/$p.img" ]] || { src="$out"; break; }; done
    s2i=$(command -v simg2img || ls "$WORKDIR"/out/host/linux-x86/bin/simg2img 2>/dev/null | head -1)
    ok "images taken from ${src#"$WORKDIR"/}"
    # shellcheck disable=SC2086
    for p in "${REL_IMGS[@]}" $dyn; do
      [[ -s "$src/$p.img" ]] || die "$src/$p.img missing"
      if [[ "$(head -c4 "$src/$p.img" | od -An -tx1 | tr -d ' \n')" == "3aff26ed" ]]; then
        [[ -n "$s2i" ]] || die "$p.img is sparse and simg2img wasn't found"
        "$s2i" "$src/$p.img" "$stg/$p.img" || die "simg2img $p.img failed"
      else
        link_or_copy "$src/$p.img" "$stg/$p.img" || die "copy $p.img failed"
      fi
    done
    local hb="$WORKDIR/out/host/linux-x86/bin"
    [[ -x "$hb/lpdump" && -x "$hb/lpmake" ]] || { [[ -n "${TARGET_PRODUCT:-}" ]] || load_build_env; run_m lptools lpdump lpmake || die "can't build lpdump/lpmake"; }
    rel_fix_super_empty > "$stg/fix_super_empty.py"
    python3 "$stg/fix_super_empty.py" "$hb" "$out/super_empty.img" "$stg/super_empty.img" || die "could not make a readonly super_empty.img"
    rm -f "$stg/fix_super_empty.py"
    ok "super_empty.img: all partitions readonly (one-step fastboot flashing)"
    printf 'require board=%s\n' "$CODENAME" > "$stg/android-info.txt"
    { echo "version 1"
      echo "erase misc"   # clears a stale 'boot into recovery' request left by any earlier failed flash
      for p in "${REL_IMGS[@]}"; do
        case "$p" in vbmeta*) echo "flash --apply-vbmeta $p" ;; *) echo "flash $p" ;; esac
      done
      echo "reboot fastboot"; echo "update-super"
      for p in $dyn; do echo "flash $p"; done
    } > "$stg/fastboot-info.txt"
    for f in "${fw[@]}" recovery; do [[ ! -e "$stg/$f.img" ]] || die "$f.img must not be in the fastboot zip"; done
    log "zipping the fastboot ROM (several minutes)"
    rm -f "$fz.tmp"
    ( cd "$stg" && zip -q -6 "$fz.tmp" android-info.txt fastboot-info.txt ./*.img ) || die "zip failed"
    unzip -tq "$fz.tmp" >/dev/null || die "fastboot zip failed its integrity test"
    [[ "$(unzip -Z1 "$fz.tmp" | grep -c '\.img$')" == "$(( ${#REL_IMGS[@]} + $(wc -w <<<"$dyn") + 1 ))" ]] || die "fastboot zip has the wrong number of images"
    mv -f "$fz.tmp" "$fz"; rm -rf "$stg"; echo "$psig" > "$STATE_DIR/pkg-$name.sig"
    ok "fastboot package: $(basename "$fz") ($(( $(stat -c %s "$fz") / 1048576 ))MB)"
  fi
  # OTA zip (Updater + sideload) and the ROM's own recovery are always published
  link_or_copy "$zip" "$rdir/$name.zip" || die "copy OTA zip failed"
  link_or_copy "$out/recovery.img" "$rdir/$name-recovery.img" || die "copy recovery.img failed"
  export REL_OTA_ROW="| \`$name.zip\` | OTA zip: used by the built-in Updater; recovery sideload: $REL_RECOVERY_STATUS. Carries OS2.0.210 firmware |
| \`$name-recovery.img\` | The ROM's own recovery (only for sideloading; optional) |"
  [[ "$FLASH_FIRMWARE" == 1 ]] || REL_OTA_ROW=${REL_OTA_ROW//. Carries OS2.0.210 firmware/}
  local sums=("$name-fastboot.zip" "$name.zip" "$name-recovery.img")

  # --- checksums + docs (regenerated every time, so RELEASE_ONLY=1 refreshes the status table) ---
  ( cd "$rdir" && sha256sum "${sums[@]}" > SHA256SUMS ) || die "checksum failed"
  local bp="$out/system/build.prop" kver
  kver=$(cat "$out/obj/KERNEL_OBJ/include/config/kernel.release" 2>/dev/null || true)
  local t="$rdir/.tpl"; mkdir -p "$t"
  rel_install_md > "$t/INSTALL.tpl"; rel_release_notes_md > "$t/NOTES.tpl"
  export REL_NAME="$name" REL_MAINTAINER="$ROM_MAINTAINER" REL_KERNEL="${kver:-6.6}" \
    REL_DATE="$(date -u -d "@$(grep -m1 '^ro.build.date.utc=' "$bp" | cut -d= -f2)" +%F 2>/dev/null || date -u +%F)" \
    REL_RELEASE="$(grep -m1 '^ro.build.id=' "$bp" | cut -d= -f2)" \
    REL_SPL="$(grep -m1 '^ro.build.version.security_patch=' "$bp" | cut -d= -f2)" \
    REL_SHA="$(cat "$rdir/SHA256SUMS")"
  fill_template "$t/INSTALL.tpl" "$rdir/INSTALL.md" || die "INSTALL.md generation failed"
  fill_template "$t/NOTES.tpl" "$rdir/RELEASE_NOTES.md" || die "RELEASE_NOTES.md generation failed (check $STATUS_FILE)"
  rm -rf "$t"

  # --- Updater feed: ota/<branch>/sky.json + changelog, for github.com/once-human/pixelos-sky ---
  local branch base month feed="$WORKDIR/packages/apps/Updater/tools/pixelos_feed.py"
  branch=$(grep -hm1 '^net.pixelos.version=' "$out"/system_ext/etc/build.prop "$out"/system/build.prop "$out"/product/etc/build.prop 2>/dev/null | cut -d= -f2)
  month=${REL_DATE:0:7}
  base="${OTA_URL_BASE:-https://sourceforge.net/projects/pixelos-sky/files/17/$month}"
  mkdir -p "$rdir/ota/${branch:-seventeen}/changelogs"
  if python3 -I "$feed" generate-ota "$rdir/$name.zip" --url "${base%/}/$name.zip" \
       --version "$(v=$(grep -hm1 '^ro.custom.version=' "$bp" "$out"/*/etc/build.prop 2>/dev/null | head -1 | cut -d= -f2 | cut -d- -f1); echo "${v:-17.0}")" \
       --output "$rdir/ota/${branch:-seventeen}/$CODENAME.json" >"$LOG_DIR/ota-feed.log" 2>&1; then
    cp -f "$rdir/RELEASE_NOTES.md" "$rdir/ota/${branch:-seventeen}/changelogs/$CODENAME.md"
    ok "Updater feed: ota/${branch:-seventeen}/$CODENAME.json (download URL ${base%/}/$name.zip)"
  else
    warn "Updater feed not generated (log: $LOG_DIR/ota-feed.log); the release itself is fine"
  fi
  mark_done release
  ok "release folder: $rdir"
  ls -la "$rdir" | sed 's/^/    /'

  cat <<MSG

${C_G}================= RELEASE READY =================${C_0}
Folder: $rdir
  $name-fastboot.zip    <- first install (fastboot -w update)
  $name.zip             <- OTA zip (Updater / sideload)
  $name-recovery.img    <- the ROM's recovery (optional)
  INSTALL.md  RELEASE_NOTES.md  SHA256SUMS
  ota/${branch:-seventeen}/$CODENAME.json + changelogs/  <- copy into the pixelos-sky repo AFTER uploading the zip
                                      to ${base%/}/

On your PC (in bash), download it:
  scp -o ControlPath=none -P ${SSH_PORT:-22} -r ${USER:-$(id -un)}@${SSH_HOST:-$(hostname -f 2>/dev/null || hostname)}:${rdir#"$HOME"/} ~/
Your signing keys (download once, keep private, never publish):
  scp -o ControlPath=none -P ${SSH_PORT:-22} ${USER:-$(id -un)}@${SSH_HOST:-$(hostname -f 2>/dev/null || hostname)}:${WORKDIR#"$HOME"/}/sky17-signing-keys.tgz ~/
After testing, edit $STATUS_FILE and run:  RELEASE_ONLY=1 $0
MSG
}

# ------------------- release docs (embedded; written by package_release) -------------------
rel_install_md() { cat <<'__SKY17_REL_INSTALL_MD__'
# PixelOS 17 for Redmi 12 5G / POCO M6 Pro 5G / Redmi Note 12R (sky): installation

Build: **@NAME@**. Android 17, PixelOS, unofficial, Linux 6.6 kernel. Maintainer: **@MAINTAINER@**

## Requirements

| | |
|---|---|
| **Device** | Any sky: Redmi 12 5G, POCO M6 Pro 5G, Redmi Note 12R, any region |
| **Bootloader** | Unlocked (Mi Unlock) |
| **Firmware** | Stock **HyperOS 2** firmware, **OS2.0.210** (Global) recommended. See [Firmware](#firmware) |
| **PC** | Google's **platform-tools 35 or newer** (`fastboot --version`) |
| **Data** | Coming from any other ROM, **including the October 5.10 PixelOS build**: clean install (wipes the phone, back up first) |

## Downloads

| File | Use |
|---|---|
| `@NAME@-fastboot.zip` | **Fastboot ROM: the first install.** Don't extract it: fastboot reads it directly |
@OTA_ROW@
| `SHA256SUMS` | Checksums (`sha256sum -c SHA256SUMS`) |

## Install (fastboot)

1. Install the latest platform-tools:
   - **Windows:** "SDK Platform-Tools for Windows" from developer.android.com; open a terminal in that folder. Install the Xiaomi/Google USB driver if the phone isn't found.
   - **Linux:** Arch `sudo pacman -S android-tools` · Debian/Ubuntu `sudo apt install fastboot` (or Google's zip if your distro's is old)
   - **macOS:** `brew install android-platform-tools`
2. Phone off → hold **Power + Volume Down** → **FASTBOOT** → connect USB. Check: `fastboot devices` shows the phone (Linux: use `sudo fastboot`).
3. Flash:

| | Command |
|---|---|
| **Clean install** (from stock, another ROM, or the October 5.10 build; wipes data) | `fastboot -w update @NAME@-fastboot.zip` |
| **Update** (over an earlier 6.6 build of this ROM; keeps data) | `fastboot update @NAME@-fastboot.zip`, or just use the Updater |

fastboot checks the zip is for sky, flashes everything from the bootloader in one go, and reboots by itself. First boot takes **5-10 minutes**. The fastboot ROM never flashes firmware, the bootloader or recovery.

## Updates

Settings → System → **Updater** finds new builds and installs them in the background (A/B: the phone keeps working, one reboot at the end).

## Recovery ROM

@RECOVERY_STEPS@

## Firmware

The OTA zip (Updater, sideload) **brings OS2.0.210 firmware** with it, so phones on other HyperOS 2 firmware end up on the tested one. The fastboot ROM keeps whatever firmware the phone has.

- On **newer firmware than OS2.0.210** (a later HyperOS update): don't sideload the OTA zip; use the fastboot ROM.
- If the ROM doesn't boot within 15 minutes, or the phone came from HyperOS 1: hold **Power + Volume Down** to get back to fastboot (always possible), flash Xiaomi's official **OS2.0.210.0.VMWMIXM** fastboot ROM with MiFlash **"clean all"** (never "clean all and lock"), boot it once, then do the clean install above.

## Troubleshooting

| Problem | Fix |
|---|---|
| `fastboot devices` shows nothing | Another USB port/cable (not a hub). Windows: USB driver. Linux: `sudo fastboot ...` |
| "requirement board=sky not met" | This ROM is only for sky |
| It says "Rebooting into fastboot" and then hangs | Your fastboot is too old. Update platform-tools, get back to bootloader mode, run `fastboot erase misc`, then the install command again |
| The phone keeps booting into recovery after flashing | In bootloader mode: `fastboot erase misc` then `fastboot reboot` |
| A step failed mid-way | Don't reboot. Fix the connection and run the same command again: it's safe to repeat |
| Stuck on the boot logo > 15 minutes | See [Firmware](#firmware) |
| Reporting a bug | Developer options → USB debugging, then `adb bugreport bug.zip`; open an issue at github.com/once-human/pixelos-sky |

## Credits

Venkat and the xiaomi-ravelin team (sm4450 6.6 LineageOS bring-up) · Suvojeet (6.6 kernel) · TopexGuy (sky Android 17, kernel fixes) · moinator856 (ramoops) · lostark13 · anonytry · PixelOS and LineageOS teams · build, kernel tuning and packaging: **@MAINTAINER@**
__SKY17_REL_INSTALL_MD__
}
rel_release_notes_md() { cat <<'__SKY17_REL_RELEASE_NOTES_MD__'
# PixelOS 17 (Android 17) for sky: @NAME@

**Devices:** Redmi 12 5G · POCO M6 Pro 5G · Redmi Note 12R (codename `sky`)
**Status:** Unofficial · **Maintainer:** @MAINTAINER@ · **Build date:** @DATE@

## Highlights

- PixelOS 17 on Android 17 (`@RELEASE@`), security patch **@SPL@**
- **Linux @KERNEL@** ("Nimbus"): new GKI 6.6 kernel built from source, Qualcomm's WALT scheduler kept for battery life, BBR + FQ networking, lazy RCU
- New device trees from the LineageOS-style sm4450 6.6 bring-up; HyperOS 3 (mist OS3.0.306) common blobs, sky OS2.0.210 device blobs and firmware
- Smoother and lighter: zram lz4 with zstd recompression of idle pages, MGLRU, THP only where asked, mq-deadline I/O, tuned dalvik heap and LMK, Settings/SystemUI compiled ahead of time, faster boot (device links settle on a timeout)
- **Built-in OTA updates** (Settings → System → Updater)
- **User build**: SELinux **enforcing**, signed with private **release keys**

## Device status

| Feature | Status |
|---|---|
| Boot, UI, Google apps | ✅ Working |
| Wi-Fi | @S_WIFI@ |
| Bluetooth (audio, devices) | @S_BT@ |
| Calls, SMS, mobile data, VoLTE | @S_RIL@ |
| Speaker, earpiece, microphone, headphones | @S_AUDIO@ |
| Camera (rear, front, video) | @S_CAM@ |
| Fingerprint: FPC units | @S_FP_FPC@ |
| Fingerprint: Goodix units | @S_FP_GDX@ |
| GPS | @S_GPS@ |
| Sensors (rotation, brightness, proximity) | @S_SENS@ |
| NFC (models that have it) | @S_NFC@ |
| 90 Hz display, brightness | @S_DISP@ |
| Charging, USB file transfer | @S_USB@ |
| OTA updates (Updater) | @S_OTA@ |
| SELinux | ✅ Enforcing |

## Known issues

@RECOVERY_NOTE@- Coming from the October (5.10) build: clean install required (new kernel, new trees)
- @EXTRA_ISSUES@

## Install

See **INSTALL.md**. Short version: unlocked bootloader + HyperOS 2 firmware (OS2.0.210 recommended) + platform-tools 35+ → fastboot mode (Power + Volume Down) → `fastboot -w update @NAME@-fastboot.zip`. Later updates: the Updater app.

## Checksums

```
@SHA@
```

## Credits

Venkat and the xiaomi-ravelin team (sm4450 6.6 bring-up) · Suvojeet (6.6 kernel) · TopexGuy · moinator856 · lostark13 · anonytry · PixelOS and LineageOS teams.
__SKY17_REL_RELEASE_NOTES_MD__
}
rel_fix_super_empty() { cat <<'__SKY17_FIX_SUPER_EMPTY__'
#!/usr/bin/env python3
"""Rebuild super_empty.img with every partition marked readonly (needed for fastboot's
one-step super flashing). Everything else (sizes, groups, slots, flags) is copied."""
import re, subprocess, sys

HOST = sys.argv[1]          # out/host/linux-x86/bin
SRC, DST = sys.argv[2], sys.argv[3]

def dump(path):
    return subprocess.run([f"{HOST}/lpdump", path], capture_output=True, text=True, check=True).stdout

def parse(txt):
    g = lambda pat: (re.search(pat, txt, re.M) or sys.exit(f"lpdump: '{pat}' not found")).group(1)
    info = {
        "version": g(r"^Metadata version: (\S+)"),
        "msize": g(r"^Metadata max size: (\d+) bytes"),
        "slots": g(r"^Metadata slot count: (\d+)"),
        "hflags": (re.search(r"^Header flags: (.*)$", txt, re.M) or [None, "none"])[1].strip(),
    }
    part_tbl = txt.split("Partition table:", 1)[1].split("Super partition layout:", 1)[0]
    blk_tbl = txt.split("Block device table:", 1)[1].split("Group table:", 1)[0]
    grp_tbl = txt.split("Group table:", 1)[1]
    info["parts"] = re.findall(r"Name: (\S+)\n\s+Group: (\S+)\n\s+Attributes: ([^\n]*)", part_tbl)
    info["blocks"] = re.findall(r"Partition name: (\S+)\n\s+First sector: (\d+)\n\s+Size: (\d+) bytes", blk_tbl)
    info["groups"] = re.findall(r"Name: (\S+)\n\s+Maximum size: (\d+) bytes", grp_tbl)
    return info

src = parse(dump(SRC))
if len(src["blocks"]) != 1:
    sys.exit(f"expected one super block device, got {src['blocks']}")
bname, _, bsize = src["blocks"][0]
cmd = [f"{HOST}/lpmake", "--metadata-size", src["msize"], "--metadata-slots", src["slots"],
       "--device", f"{bname}:{bsize}", "--super-name", bname, "--output", DST]
if "virtual_ab" in src["hflags"]:
    cmd.append("--virtual-ab")
for name, size in src["groups"]:
    if name != "default":
        cmd += ["--group", f"{name}:{size}"]
for name, group, _ in src["parts"]:
    cmd += ["--partition", f"{name}:readonly:0:{group}"]
print("partitions:", " ".join(p[0] for p in src["parts"]))
subprocess.run(cmd, check=True)

new = parse(dump(DST))
bad = [p for p in new["parts"] if "readonly" not in p[2]]
same = (src["version"], src["msize"], src["slots"], src["hflags"], src["blocks"][0][2], src["groups"],
        [(n, g) for n, g, _ in src["parts"]]) == \
       (new["version"], new["msize"], new["slots"], new["hflags"], new["blocks"][0][2], new["groups"],
        [(n, g) for n, g, _ in new["parts"]])
if bad or not same:
    sys.exit(f"CHECK FAILED: not readonly={bad} layout_identical={same}\nold={src}\nnew={new}")
print(f"OK: {len(new['parts'])} partitions readonly; layout identical (super {bsize} bytes, "
      f"metadata {src['msize']}x{src['slots']}, flags: {src['hflags']})")
__SKY17_FIX_SUPER_EMPTY__
}

main() {
  maybe_tmux "$@"
  mkdir -p "$WORKDIR"
  setup_logging
  if [[ -n "${RELEASE_ONLY:-}" ]]; then   # just (re)make the release folder from the last build
    stage_done verify || die "no verified build yet: run the full script first"
    package_release; return 0
  fi
  preflight
  if [[ -n "${CHECK_ONLY:-}" ]]; then
    log "CHECK_ONLY: all preflight checks passed. Nothing was downloaded or changed."
    return 0
  fi
  export PATH="$HOME/.bin:$PATH"
  if [[ -n "${RESYNC:-}${REEXTRACT:-}" ]]; then clear_from configcheck build verify; fi
  sync_source
  extract_blobs
  setup_trees
  setup_ccache
  if ! stage_done configcheck || [[ -f "$STATE_DIR/need_installclean" ]]; then config_check
  else log "STAGE 4: configuration already checked"; fi
  full_build
  verify_output
  package_release
}

main "$@"
