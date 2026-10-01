#!/usr/bin/env bash
# =============================================================================
#  build_pixelos17_sky.sh  v3  --  PixelOS 17 (Android 17) for Xiaomi "sky"
#  Redmi 12 5G / Redmi Note 12R / POCO M6 Pro 5G  (Snapdragon 4 Gen 2, "parrot")
#
#  v3 builds TopexGuy's maintained Android 17 sky trees, unmodified except for
#  the one thing PixelOS needs: a PixelOS product file (custom_sky.mk).
#    device   github.com/topexguy/device_xiaomi_sky                 (17)
#    vendor   github.com/topexguy/vendor_xiaomi_sky                 (17, OS2.0.210 blobs)
#    kernel   github.com/topexguy/kernel_xiaomi_sky                 (17, built from source)
#             github.com/topexguy/kernel_xiaomi_sm8450-modules      (17)
#    extra    github.com/anonytry/android_hardware_xiaomi           (default)
#             github.com/anonytry/hardware_dolby                    (17)
#             github.com/anonytry/android_vendor_qcom_opensource_vibrator (default)
#  These are the repos the tree's own vendorsetup.sh lists. vendorsetup.sh itself
#  is NOT run: it deletes paths and runs a remote script on every envsetup.
#  The tree ships OS2.0.210 firmware; the ROM flashes it (FLASH_FIRMWARE=0 to skip).
#
#  STAGES (each is checked; rerunning resumes where it stopped)
#    0. preflight   CPU, filesystem, disk, RAM+swap, tools, every repo reachable
#    1. sync        PixelOS 17 source (already done on your server: skipped)
#    2. trees       TopexGuy trees + PixelOS product file + firmware, validated
#    3. configcheck lunch + build graph + SELinux compile + VINTF (minutes)
#    4. build       m pixelos (kernel is compiled from source here)
#                   keys: generated once in vendor/lineage-priv/keys and reused; back them up
#    5. verify      zip contents, device, Android version, firmware inside, signed, enforcing
#    6. release     ~/release/<name>/: fastboot ROM (fastboot update zip: no firmware,
#                   no bootloader, no recovery), OTA zip, INSTALL.md, RELEASE_NOTES.md,
#                   SHA256SUMS. Device status in ~/pixelos17/release-status.conf
#
#  USAGE
#    ./build_pixelos17_sky.sh                 full run (auto-resumes)
#    CHECK_ONLY=1 ./build_pixelos17_sky.sh    stage 0 only; changes nothing
#    default: user build, SELinux enforcing, signed with your own release keys
#    BUILD_TYPE=userdebug ...                 (adds root/debug features)
#    SIGN=0          test-keys instead of your own keys
#    RESYNC=1        re-run repo sync
#    RESET_TREES=1   re-clone all sky trees
#    FLASH_FIRMWARE=0  don't put the OS2.0.210 firmware in the ROM (default 1)
#    DEBUG_BOOT=1    diagnostic build: boot logs saved to /metadata, adb open, permissive
#                    (forces userdebug; never for daily use)
#    RELEASE_ONLY=1  only redo stage 6 (e.g. after editing release-status.conf; seconds)
#    REPACK=1        with RELEASE_ONLY: also rebuild the fastboot zip
#    KEEP_PARTS=1    keep TopexTool (XiaomiParts) in the ROM (default: removed)
#    ROM_MAINTAINER="Name"   name shown in the docs (default: Onkar Yaglewad)
#    AUTO_SWAP=1 FORCE=1 NO_TMUX=1 JOBS=N   as before
# =============================================================================
set -Eeo pipefail
SCRIPT_VERSION="3.12"

# ------------------------------- config --------------------------------------
WORKDIR="${WORKDIR:-$HOME/pixelos17}"
BUILD_TYPE="${BUILD_TYPE:-user}"
SIGN="${SIGN:-1}"
ROM_MAINTAINER="${ROM_MAINTAINER:-Onkar Yaglewad}"
CODENAME="sky"
FLASH_FIRMWARE="${FLASH_FIRMWARE:-1}"

ANDROID_BRANCH="seventeen"
MANIFEST_URL="https://github.com/PixelOS-AOSP/android_manifest.git"

# path|url|branch(empty = default branch)
TREES=(
  "device/xiaomi/sky|https://github.com/topexguy/device_xiaomi_sky.git|17"
  "vendor/xiaomi/sky|https://github.com/topexguy/vendor_xiaomi_sky.git|17"
  "kernel/xiaomi/sky|https://github.com/topexguy/kernel_xiaomi_sky.git|17"
  "kernel/xiaomi/sm8450-modules|https://github.com/topexguy/kernel_xiaomi_sm8450-modules.git|17"
  "hardware/xiaomi|https://github.com/anonytry/android_hardware_xiaomi.git|"
  "hardware/dolby|https://github.com/anonytry/hardware_dolby.git|17"
  "vendor/qcom/opensource/vibrator|https://github.com/anonytry/android_vendor_qcom_opensource_vibrator.git|"
)
# left over from the v2 (PixelOS sixteen-qpr1 port) setup; must not stay in the tree
OBSOLETE_PATHS=(device/xiaomi/sky-kernel)
# PixelOS projects that clash with what the sky tree brings (removed via local manifest)
#   packages/apps/DolbyAtmos: PixelOS's Dolby app; the tree ships its own (hardware/dolby/LunarisDolby)
#   and both define preinstalled-packages-platform-dolby.xml
PIXELOS_REMOVE=("packages/apps/DolbyAtmos|PixelOS-AOSP/android_packages_apps_DolbyAtmos")
# firmware images the ROM must carry when FLASH_FIRMWARE=1 (OS2.0.210.0.VMWMIXM)
FIRMWARE_IMAGES=(abl aop aop_config bluetooth cpucp devcfg dsp featenabler hyp imagefv keymaster
                 modem qupfw qweslicstore shrm tz uefi uefisecapp xbl xbl_config xbl_ramdump)
FIRMWARE_TZ_VERSION="TZ.XF.5.18-31602-10"
# release-key signing, the way the sky tree does it (TopexGuy's Signify), pinned to a reviewed commit
SIGNIFY_REPO="https://github.com/TopexGuy/Signify.git"
SIGNIFY_COMMIT="c36d6fa5b4612baa915d5e0d05082637305e10cb"
# keys live where PixelOS expects private keys (its build tags those builds "release-keys");
# the device tree includes vendor/signify/keys/keys.mk, which becomes a one-line pointer here
KEYS_REL="vendor/lineage-priv/keys"
KEYS_TREE_REL="vendor/signify/keys"

STATE_DIR="$WORKDIR/.sky17"
LOG_DIR="$WORKDIR/logs"
CURRENT_STAGE="startup"

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
  for v in WORKDIR BUILD_TYPE RESYNC RESET_TREES AUTO_SWAP FORCE JOBS DEBUG_BOOT FLASH_FIRMWARE SIGN ROM_MAINTAINER KEEP_PARTS RELEASE_ONLY REPACK RELEASE_DIR; do
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

  # --- disk + inodes ---
  local free need_die need_warn
  free=$(gb_free "$WORKDIR")
  if [[ -d "$WORKDIR/.repo" ]]; then need_die=60; need_warn=150; else need_die=300; need_warn=380; fi
  if (( free < need_die )); then
    soft_fail "Only ${free}GB free in $WORKDIR (need ~400GB for a fresh build). Use a bigger disk: WORKDIR=/path/on/big/disk"
  elif (( free < need_warn )); then warn "${free}GB free in $WORKDIR: tight."
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
  if timeout 60 git ls-remote https://android.googlesource.com/platform/build/release refs/tags/android-17.0.0_r1 2>/dev/null | grep -q .; then
    ok "android.googlesource.com (AOSP android-17.0.0_r1)"
  else printf '  %s✘%s android.googlesource.com unreachable (AOSP source)\n' "$C_R" "$C_0"; bad=1; fi
  (( bad == 0 )) || soft_fail "Some sources are unreachable (see ✘ above). Check your internet/firewall, or the repo moved; nothing was downloaded."

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

# =============================== STAGE 1 =====================================
sync_source() {
  CURRENT_STAGE="1-sync"
  cd "$WORKDIR"
  if stage_done sync && [[ -z "${RESYNC:-}" ]]; then log "STAGE 1: source already synced (RESYNC=1 to redo)"; verify_source; return 0; fi
  log "STAGE 1: syncing PixelOS $ANDROID_BRANCH source (~100GB+; the longest download)"
  if [[ ! -d .repo || "$(cat "$STATE_DIR/manifest_branch" 2>/dev/null)" != "$ANDROID_BRANCH" ]]; then
    retry 3 10 repo init -u "$MANIFEST_URL" -b "$ANDROID_BRANCH" --git-lfs --depth=1 --no-clone-bundle \
      || die "repo init failed"
    echo "$ANDROID_BRANCH" > "$STATE_DIR/manifest_branch"
  fi
  local rc=1
  repo sync -c -j"$SYNC_JOBS" --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune && rc=0
  if (( rc )); then warn "sync incomplete, retrying with fewer jobs"; repo sync -c -j4 --force-sync --no-clone-bundle --no-tags --prune && rc=0; fi
  if (( rc )); then warn "retrying failed projects one at a time"; repo sync -c -j1 --fail-fast --force-sync --no-clone-bundle --no-tags && rc=0; fi
  (( rc == 0 )) || die "repo sync failed 3 times (network or disk). Rerun to resume; completed projects are kept."
  verify_source
  mark_done sync
}

verify_source() {
  local p missing=0
  for p in build/envsetup.sh build/soong vendor/custom/config/common_full_phone.mk \
           vendor/lineage/vars/aosp_target_release hardware/qcom-caf/common \
           hardware/qcom-caf/sm8450/audio/agm device/qcom/sepolicy_vndr/sm8450 \
           device/lineage/sepolicy/libion/sepolicy.mk hardware/lineage/compat \
           hardware/lineage/interfaces/power-libperfmgr system/memory/libion \
           hardware/google/pixel/pixelstats hardware/google/pixel/power-libperfmgr \
           prebuilts/kernel-build-tools prebuilts/clang/host/linux-x86; do
    [[ -e "$WORKDIR/$p" ]] || { printf '  ✘ missing after sync: %s\n' "$p"; missing=1; }
  done
  (( missing == 0 )) || die "Source is incomplete (paths above). Rerun with RESYNC=1."
  ok "source tree complete ($(sed -n 's/^aosp_target_release=//p' "$WORKDIR/vendor/lineage/vars/aosp_target_release" | tr -d ' ') release)"
}

# =============================== STAGE 2 =====================================
clone_repo() { # url branch(empty = default) path
  local url=$1 br=$2 path=$3
  mkdir -p "$(dirname "$WORKDIR/$path")"
  local args=(clone -q --depth=1); [[ -n "$br" ]] && args+=(-b "$br")
  _clone_once() { rm -rf "${WORKDIR:?}/${path:?}"; git "${args[@]}" "$url" "$WORKDIR/$path"; }
  retry 3 10 _clone_once || die "could not clone $url ${br}"
  (cd "$WORKDIR/$path" && git lfs pull >/dev/null 2>&1) || true
}

tree_matches() { # path url branch -> is $path a clone of url (at branch)?
  local p="$WORKDIR/$1" url=$2 br=$3
  [[ -d "$p/.git" ]] || return 1
  [[ "$(git -C "$p" remote get-url origin 2>/dev/null)" == "$url" ]] || return 1
  [[ -z "$br" || "$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "$br" ]]
}

# put <file> : write stdin to <file> only if the content differs (keeps incremental builds fast)
put() {
  local f=$1 t; t=$(mktemp)
  cat > "$t"
  if [[ -f "$f" ]] && cmp -s "$t" "$f"; then rm -f "$t"
  else mkdir -p "$(dirname "$f")"; mv "$t" "$f"; chmod 644 "$f"; ok "updated ${f#"$WORKDIR"/}"; fi
}
pristine() { git -C "$WORKDIR/device/xiaomi/sky" show "HEAD:$1"; }   # file as TopexGuy committed it

mk_list() { # mk_list <makefile> <VAR> : values of a (possibly multi-line) VAR := a \ b \ c
  awk -v var="$2" '
    $0 ~ "^"var"[ \t]*[:+]?=" {f=1; sub("^"var"[ \t]*[:+]?=", "")}
    f { c = ($0 ~ /\\[ \t]*$/); gsub(/\\/, ""); n = split($0, a); for (i = 1; i <= n; i++) print a[i]; if (!c) f = 0 }
  ' "$1"
}

write_local_manifest() {
  # PixelOS projects the sky tree replaces or clashes with: removed from the manifest so a
  # future repo sync doesn't bring them back.
  mkdir -p "$WORKDIR/.repo/local_manifests"
  local e p n
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<manifest>'
    echo '  <!-- sky (TopexGuy tree) uses anonytry/android_vendor_qcom_opensource_vibrator here instead -->'
    echo '  <remove-project name="LineageOS/android_vendor_qcom_opensource_vibrator" />'
    for e in "${PIXELOS_REMOVE[@]}"; do IFS='|' read -r p n <<<"$e"; echo "  <remove-project name=\"$n\" />"; done
    echo '</manifest>'
  } | put "$WORKDIR/.repo/local_manifests/sky17.xml"
  for e in "${PIXELOS_REMOVE[@]}"; do
    IFS='|' read -r p n <<<"$e"
    if [[ -e "$WORKDIR/$p" ]]; then rm -rf "${WORKDIR:?}/$p"; ok "removed $p (clashes with the sky tree)"; fi
  done
}

setup_trees() {
  CURRENT_STAGE="2-trees"
  log "STAGE 2: TopexGuy's Android 17 sky trees"
  cd "$WORKDIR"
  write_local_manifest
  local rs="$WORKDIR/.repo/local_manifests/roomservice.xml"
  if grep -qs 'xiaomi_sky\|xiaomi/sky' "$rs"; then rm -f "$rs"; ok "removed roomservice.xml (it pinned the old sky repos)"; fi

  local p entry path url br changed=0
  for p in "${OBSOLETE_PATHS[@]}"; do
    if [[ -e "$p" ]]; then rm -rf "${WORKDIR:?}/$p"; ok "removed old $p (v2 setup)"; changed=1; fi
  done
  for entry in "${TREES[@]}"; do
    IFS='|' read -r path url br <<<"$entry"
    if [[ -n "${RESET_TREES:-}" ]] || ! tree_matches "$path" "$url" "$br"; then
      log "cloning $path  <-  ${url#https://github.com/} ${br:+($br)}"
      clone_repo "$url" "$br" "$path"; changed=1
    fi
    ok "$path  @ $(git -C "$path" rev-parse --short HEAD)  ($(git -C "$path" log -1 --format='%cs: %s' | cut -c1-70))"
  done
  # same clean-ups the tree's vendorsetup.sh does
  if [[ -e hardware/xiaomi/dolby ]]; then rm -rf hardware/xiaomi/dolby; ok "removed hardware/xiaomi/dolby (hardware/dolby is used)"; fi
  if (( changed )); then
    mkdir -p "$STATE_DIR"; : > "$STATE_DIR/need_installclean"          # old v2 kernel modules/images must not linger in out/
    clear_from configcheck build verify
  fi

  local d="$WORKDIR/device/xiaomi/sky"
  # vendorsetup.sh runs on every "source build/envsetup.sh": it rm -rf's paths, re-clones, and
  # pipes a script from the internet into bash (signing-key generator). We did its job above.
  if [[ -e "$d/vendorsetup.sh" ]]; then rm -f "$d/vendorsetup.sh"; ok "disabled the tree's vendorsetup.sh (handled by this script)"; fi

  # --- PixelOS product: same as TopexGuy's lineage_sky.mk, but on PixelOS's common config ---
  pristine lineage_sky.mk | sed -e 's#vendor/lineage/config/common_full_phone.mk#vendor/custom/config/common_full_phone.mk#' \
      -e 's#^PRODUCT_NAME := lineage_sky#PRODUCT_NAME := custom_sky#' \
      -e 's#Inherit common Bliss configurations#Inherit common PixelOS configurations#' | put "$d/custom_sky.mk"
  grep -q '^\$(call inherit-product, vendor/custom/config/common_full_phone.mk)' "$d/custom_sky.mk" \
    && grep -q '^PRODUCT_NAME := custom_sky$' "$d/custom_sky.mk" || die "could not create custom_sky.mk (lineage_sky.mk changed upstream)"
  pristine AndroidProducts.mk | sed 's#\$(LOCAL_DIR)/lineage_sky\.mk#$(LOCAL_DIR)/custom_sky.mk#' | put "$d/AndroidProducts.mk"
  grep -q 'custom_sky\.mk' "$d/AndroidProducts.mk" || die "could not point AndroidProducts.mk at custom_sky.mk"

  # --- firmware (OS2.0.210) + debug options: generated from the pristine files every run ---
  local bc_extra="" dm_extra=""
  if [[ -n "${DEBUG_BOOT:-}" && "$BUILD_TYPE" == user ]]; then
    BUILD_TYPE=userdebug; warn "DEBUG_BOOT needs a userdebug build; building userdebug this time"
  fi
  if [[ "$FLASH_FIRMWARE" == 1 ]]; then prepare_firmware; fi
  rm -rf "$d/sky17-debug"
  if [[ -n "${DEBUG_BOOT:-}" ]]; then
    write_debug_files "$d/sky17-debug"
    dm_extra=$(printf '%s\n' '' '# >>> sky17 debug-boot' 'PRODUCT_PRODUCT_PROPERTIES += \' '    ro.adb.secure=0 \' '    persist.sys.usb.config=adb \' '    ro.debuggable=1' 'PRODUCT_COPY_FILES += \' '    device/xiaomi/sky/sky17-debug/sky17_bootwatch.sh:$(TARGET_COPY_OUT_VENDOR)/etc/sky17_bootwatch.sh \' '    device/xiaomi/sky/sky17-debug/sky17_bootwatch.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/sky17_bootwatch.rc' '# <<< sky17 debug-boot')
    bc_extra=$(printf '%s\n' '' '# >>> sky17 debug-boot' 'BOARD_BOOTCONFIG += androidboot.selinux=permissive' '# <<< sky17 debug-boot')
    warn "DEBUG_BOOT build: boot logs to /metadata, open adb, permissive SELinux. For diagnosing only."
  fi
  write_sky17_layer "$d/sky17"
  { if [[ "$FLASH_FIRMWARE" == 1 ]]; then pristine BoardConfig.mk
    else pristine BoardConfig.mk | sed 's#^-include device/xiaomi/sky/firmware\.mk#\# sky17: FLASH_FIRMWARE=0\n\# &#'; fi
    printf '%s\n' '' '# >>> sky17 additions (see device/xiaomi/sky/sky17)' \
      'BOARD_VENDOR_SEPOLICY_DIRS += device/xiaomi/sky/sky17/sepolicy/vendor' '# <<< sky17 additions'
    if [[ -n "$bc_extra" ]]; then printf '%s\n' "$bc_extra"; fi; } | put "$d/BoardConfig.mk"
  # sound_trigger.primary.parrot comes from vendor/qcom/opensource/audio-hal/st-hal-ar-legacy; only
  # drop it if this source doesn't have that project (optional HAL: hotword detection only)
  local st_sed='s/^$//'
  if [[ ! -f "$WORKDIR/vendor/qcom/opensource/audio-hal/st-hal-ar-legacy/Android.bp" ]]; then
    st_sed='s/[[:space:]]*sound_trigger\.primary\.parrot:64//'; warn "st-hal-ar-legacy not in source: building without the sound-trigger HAL"
  fi
  # TopexTool (the tree's XiaomiParts settings app) is left out: stock PixelOS experience
  local parts_sed='/^[[:space:]]*XiaomiParts[[:space:]]*$/d'
  [[ -n "${KEEP_PARTS:-}" ]] && parts_sed='s/^$//'
  { pristine device.mk | sed -e "$st_sed" -e "$parts_sed"
    printf '%s\n' '' '# >>> sky17 additions (see device/xiaomi/sky/sky17)' \
      'PRODUCT_COPY_FILES += \' \
      '    device/xiaomi/sky/sky17/init.sky17.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.sky17.rc' \
      '# <<< sky17 additions'
    if [[ -n "$dm_extra" ]]; then printf '%s\n' "$dm_extra"; fi; } | put "$d/device.mk"
  if [[ -z "${KEEP_PARTS:-}" ]]; then
    ! grep -qE '^[[:space:]]*XiaomiParts' "$d/device.mk" || die "could not remove XiaomiParts from device.mk"
    ok "TopexTool/XiaomiParts not included (KEEP_PARTS=1 to keep it)"
  fi
  patch_fingerprint_hal
  if [[ "$FLASH_FIRMWARE" == 1 ]]; then ok "firmware: OS2.0.210 will be flashed with the ROM"
  else warn "FLASH_FIRMWARE=0: the ROM will NOT update firmware (phone must already have OS2.0.210)"; fi

  setup_signing
  validate_trees
  # our generated files changed since the last build (e.g. an app removed)? clear installed images
  # so nothing stale is left in them (compiled objects are kept, so this costs minutes, not hours)
  local sig
  sig=$( { cat "$d/device.mk" "$d/BoardConfig.mk" "$d/custom_sky.mk" "$WORKDIR/hardware/xiaomi/aidl/fingerprint/Fingerprint.cpp"
           find "$d/sky17" -type f -print0 | sort -z | xargs -0 cat
           echo "$BUILD_TYPE $SIGN $FLASH_FIRMWARE ${DEBUG_BOOT:-}"; } | sha256sum | cut -c1-16 )
  echo "$sig" > "$STATE_DIR/config.sig.pending"
  if [[ "$(cat "$STATE_DIR/config.sig" 2>/dev/null)" != "$sig" ]]; then
    : > "$STATE_DIR/need_installclean"; ok "build configuration changed: installed images will be refreshed"
  fi
  mark_done trees
}

setup_signing() { # own release keys (vendor/signify/keys), generated once, reused on every rebuild
  local k="$WORKDIR/$KEYS_REL"
  if [[ "$SIGN" != 1 ]]; then
    [[ -f "$k/keys.mk" ]] && warn "SIGN=0 but $KEYS_REL exists: the device tree will still sign with it (move it away for test-keys)"
    return 0
  fi
  local want=0 have old="$WORKDIR/$KEYS_TREE_REL"
  # earlier versions kept the keys in vendor/signify/keys: move them (same keys, new place)
  if [[ ! -f "$k/releasekey.pk8" && -f "$old/releasekey.pk8" ]]; then
    mkdir -p "$(dirname "$k")" && mv "$old" "$k" || die "could not move your keys to $KEYS_REL"
    sed -i "s#$KEYS_TREE_REL/#$KEYS_REL/#g" "$k/keys.mk"
    ok "moved your signing keys to $KEYS_REL (same keys)"
  fi
  if [[ ! -f "$k/keys.mk" || ! -f "$k/releasekey.pk8" ]]; then
    log "Generating your release keys (one time, a few minutes)"
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
  grep -q "^PRODUCT_DEFAULT_DEV_CERTIFICATE := $KEYS_REL/releasekey$" "$k/keys.mk" || die "$KEYS_REL/keys.mk doesn't point at your releasekey"
  # every certificate keys.mk names must exist as a key pair
  local c missing=()
  for c in releasekey platform shared media networkstack sdk_sandbox bluetooth nfc \
           $(grep -oP '(?<=:)[a-zA-Z0-9._-]+' "$k/keys.mk" | sort -u); do
    want=$((want+1)); [[ -s "$k/$c.pk8" && -s "$k/$c.x509.pem" ]] || missing+=("$c")
  done
  (( ${#missing[@]} == 0 )) || die "signing keys missing: ${missing[*]:0:8} (delete $KEYS_REL and rerun)"
  # the device tree includes vendor/signify/keys/keys.mk: make that a pointer (no key files there,
  # or Soong would see every certificate module twice)
  if [[ -e "$old" && ! -f "$old/.sky17-pointer" ]]; then
    ls "$old"/*.pk8 >/dev/null 2>&1 && die "$KEYS_TREE_REL still contains keys next to $KEYS_REL; keep one copy (move them into $KEYS_REL)"
  fi
  mkdir -p "$old"
  # PixelOS's vendor/lineage/config/common.mk already includes vendor/lineage-priv/keys/keys.mk;
  # including it a second time doubles every PRODUCT_* value (broken sepolicy paths), so the
  # pointer only includes it when PixelOS doesn't
  if grep -qs "^-*include $KEYS_REL/keys.mk" "$WORKDIR/vendor/lineage/config/common.mk"; then
    printf '%s\n' "# sky17: the signing keys are in $KEYS_REL (included by vendor/lineage/config/common.mk)" | put "$old/keys.mk"
  else
    printf '%s\n' "# sky17: the signing keys are in $KEYS_REL" "\$(call inherit-product, $KEYS_REL/keys.mk)" | put "$old/keys.mk"
  fi
  : > "$old/.sky17-pointer"
  have=$(ls "$k"/*.pk8 | wc -l)
  local bk="$WORKDIR/sky17-signing-keys.tgz"
  if [[ ! -f "$bk" || "$k/keys.mk" -nt "$bk" ]]; then tar czf "$bk" -C "$WORKDIR" "$KEYS_REL"; chmod 600 "$bk"; fi
  ok "signed build: $have release keys in $KEYS_REL (backup: $bk; keep it private and download it)"
}

write_sky17_layer() { # our own additions, kept apart from TopexGuy's files
  local l=$1
  put "$l/init.sky17.rc" <<'RCEOF'
# sky17: additions to TopexGuy's sky tree for this PixelOS 17 build

on post-fs-data
    # Goodix fingerprint blobs (libgf_hal/libgf_ca) keep their data in /data/vendor/goodix and
    # FPC in /data/vendor/fpc. The tree only creates /data/vendor_de/0/goodix, so on Goodix
    # units the HAL module failed to open and fingerprint crashed.
    mkdir /data/vendor/goodix 0770 system system
    mkdir /data/vendor/goodix/gf_data 0770 system system
    mkdir /data/vendor/fpc 0770 system system
RCEOF
  put "$l/sepolicy/vendor/sky17.te" <<'TEEOF'
# sky17 vendor policy additions, from denials seen on a running device
# (all compiled and checked against Android 17 neverallow rules before use).

# Dolby DMS HAL stores its audio scenario in persist.vendor.audio.scenario
set_prop(hal_dms_default, vendor_audio_prop)

# mi_thermald reads battery state for its thermal scenarios
r_dir_file(mi_thermald, vendor_sysfs_battery_supply)

# QTI RIL reads the PD-locator debug switch
get_prop(rild, vendor_pd_locater_dbg_prop)

# Wi-Fi HAL probes the vendor tombstone directory; harmless, silence it
dontaudit hal_wifi_default vendor_tombstone_data_file:dir search;
TEEOF
}

patch_fingerprint_hal() { # never crash when no sensor module opens; just don't advertise a sensor
  local f="$WORKDIR/hardware/xiaomi/aidl/fingerprint/Fingerprint.cpp"
  git -C "$WORKDIR/hardware/xiaomi" show HEAD:aidl/fingerprint/Fingerprint.cpp | python3 -c '
import sys
s = sys.stdin.read()
a = "ndk::ScopedAStatus Fingerprint::getSensorProps(std::vector<SensorProps>* out) {\n"
b = "    CHECK(mSession == nullptr || mSession->isClosed()) << \"Open session already exists!\";\n"
if s.count(a) != 1 or s.count(b) != 1:
    sys.exit("pattern not found")
s = s.replace(a, a + "    if (!mDevice) {  // sky17: no module opened, report no sensor instead of crashing later\n"
                     "        ALOGE(\"No fingerprint HAL module opened; not advertising a sensor\");\n"
                     "        *out = {};\n        return ndk::ScopedAStatus::ok();\n    }\n")
s = s.replace(b, "    if (!mDevice) {  // sky17\n        return ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_STATE);\n    }\n" + b)
sys.stdout.write(s)
' > "$STATE_DIR/Fingerprint.cpp.new" || die "fingerprint HAL source changed upstream; patch needs updating"
  put "$f" < "$STATE_DIR/Fingerprint.cpp.new"
  grep -q 'sky17: no module opened' "$f" || die "fingerprint HAL patch not applied"
}

prepare_firmware() { # the tree stores dsp/modem split (GitHub file-size limit): verify + join
  local fw="$WORKDIR/device/xiaomi/sky/prebuilts/firmware" h base part sum s
  [[ -f "$WORKDIR/device/xiaomi/sky/firmware.mk" ]] || die "firmware.mk missing from the device tree"
  for h in "$fw"/*.img.hash; do
    [[ -e "$h" ]] || continue
    base="${h%.hash}"
    ( cd "$fw" && sha256sum --quiet --strict -c "$(basename "$h")" ) || die "firmware parts of $(basename "$base") are corrupt (RESET_TREES=1)"
    sum=0; for part in "$base".part*; do s=$(stat -c %s "$part"); sum=$((sum + s)); done
    if [[ ! -f "$base" ]] || (( $(stat -c %s "$base") != sum )); then
      cat "$base".part* > "$base.tmp" && mv "$base.tmp" "$base"; ok "joined $(basename "$base") ($((sum / 1048576))MB)"
    fi
  done
}

write_debug_files() { # boot watcher: saves a timeline + logs to /metadata (readable from OrangeFox)
  mkdir -p "$1"
  cat > "$1/sky17_bootwatch.sh" <<'DBGEOF'
#!/vendor/bin/sh
d=/metadata/sky17_boot
rm -rf $d; mkdir -p $d
echo "watcher started $(cat /proc/uptime)" > $d/started.txt
# first ~20 s: 5x/second timeline of the security stack that storage unlock depends on
j=0
while [ $j -lt 100 ]; do
  echo "$(cut -d' ' -f1 /proc/uptime) listeners=$(/system/bin/getprop vendor.sys.listeners.registered) keymint=$(/system/bin/getprop init.svc.vendor.keymint-qti) km41=$(/system/bin/getprop init.svc.vendor.keymaster-4-1) qseecomd=$(/system/bin/getprop init.svc.vendor.qseecomd) vold=$(/system/bin/getprop init.svc.vold) boot=$(/system/bin/getprop sys.boot_completed)" >> $d/timeline.txt
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
  local d=device/xiaomi/sky v=vendor/xiaomi/sky k=kernel/xiaomi/sky km=kernel/xiaomi/sm8450-modules
  local f n c bad=0

  # device tree + what its makefiles inherit from the PixelOS source
  for f in AndroidProducts.mk BoardConfig.mk device.mk custom_sky.mk proprietary-files.txt \
           modules.list.second_stage.sky modules.list.vendor_dlkm prebuilts/dtbo.img; do
    [[ -f "$d/$f" ]] || die "device tree missing $f"; done
  ls "$d"/prebuilts/dtbs/*.dtb >/dev/null 2>&1 || die "no .dtb files in $d/prebuilts/dtbs"
  for f in vendor/custom/config/common_full_phone.mk vendor/lineage/config/BoardConfigReservedSize.mk \
           hardware/dolby/dolby.mk hardware/lineage/interfaces/power-libperfmgr vendor/qcom/opensource/vibrator \
           prebuilts/kernel-build-tools/linux-x86/bin; do
    [[ -e "$f" ]] || { echo "   missing: $f"; bad=1; }; done
  (( bad == 0 )) || die "the device tree needs paths that don't exist (above)"
  n=$(lfs_pointers_in "$d"); (( n == 0 )) || die "device tree has $n Git-LFS placeholder files (RESET_TREES=1)"
  ok "device tree + PixelOS product file OK"

  # kernel: built from source with the clang version the tree asks for
  local clang_v; clang_v=$(mk_list "$d/BoardConfig.mk" TARGET_KERNEL_CLANG_VERSION | head -1)
  [[ -z "$clang_v" || -x "prebuilts/clang/host/linux-x86/clang-$clang_v/bin/clang" ]] \
    || die "kernel needs clang-$clang_v, not in prebuilts/clang/host/linux-x86 (RESYNC=1?)"
  [[ -f "$k/Makefile" ]] || die "kernel source missing"
  for c in $(mk_list "$d/BoardConfig.mk" TARGET_KERNEL_CONFIG); do
    [[ -f "$k/arch/arm64/configs/$c" ]] || die "kernel config $c missing from $k"; done
  for f in modules.list.msm.sky modules.vendor_blocklist.msm.sky; do [[ -f "$k/$f" ]] || die "kernel missing $f"; done
  for c in $(mk_list "$d/BoardConfig.mk" TARGET_KERNEL_EXT_MODULES); do
    [[ -d "$km/$c" ]] || die "kernel module source $km/$c missing"; done
  ok "kernel: $(sed -n 's/^VERSION = //p;s/^PATCHLEVEL = //p;s/^SUBLEVEL = //p' "$k/Makefile" | paste -sd.) source, clang-${clang_v:-default}, $(mk_list "$d/BoardConfig.mk" TARGET_KERNEL_EXT_MODULES | wc -l) external module dirs"

  # vendor blobs
  [[ -f "$v/sky-vendor.mk" && -f "$v/Android.bp" ]] || die "vendor/xiaomi/sky incomplete (sky-vendor.mk/Android.bp)"
  n=$(lfs_pointers_in "$v"); (( n == 0 )) || die "vendor tree has $n Git-LFS placeholder files (RESET_TREES=1)"
  check_blob_list "$d/proprietary-files.txt" "$v"

  # firmware
  if [[ "$FLASH_FIRMWARE" == 1 ]]; then
    local fw="$d/prebuilts/firmware" missing=()
    for f in "${FIRMWARE_IMAGES[@]}"; do [[ -s "$fw/$f.img" ]] || missing+=("$f"); done
    (( ${#missing[@]} == 0 )) || die "firmware images missing: ${missing[*]}"
    grep -aqF "QC_IMAGE_VERSION_STRING=$FIRMWARE_TZ_VERSION" "$fw/tz.img" \
      || die "tz.img is not $FIRMWARE_TZ_VERSION (firmware in the tree changed; tell me before flashing it)"
    grep -q '^-include device/xiaomi/sky/firmware.mk' "$d/BoardConfig.mk" || die "firmware.mk not included"
    ok "firmware: ${#FIRMWARE_IMAGES[@]} images, $FIRMWARE_TZ_VERSION (OS2.0.210)"
  fi
}

check_blob_list() { # every file in proprietary-files.txt present in vendor repo
  local list=$1 v=$2 line src dst total=0 missing=0 base
  base="$v/proprietary"; [[ -d "$base" ]] || base="$v"
  local miss_file="$STATE_DIR/missing_blobs.txt"; : > "$miss_file"
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"; [[ -z "$line" ]] && continue
    line="${line#-}"; line="${line%%|*}"; line="${line%%;*}"
    src="${line%%:*}"; dst="$src"; [[ "$line" == *:* ]] && dst="${line#*:}"
    total=$((total+1))
    [[ -e "$base/$dst" || -e "$base/$src" ]] || { missing=$((missing+1)); echo "$dst" >> "$miss_file"; }
  done < "$list"
  (( total > 0 )) || die "proprietary-files.txt is empty or unreadable"
  if (( missing == 0 )); then ok "vendor blobs: all $total files from proprietary-files.txt present"
  elif (( missing * 100 / total < 3 )); then
    warn "$missing of $total vendor files missing (list: $miss_file). Usually harmless leftovers; first few:"; head -5 "$miss_file" | sed 's/^/   /'
  else
    head -15 "$miss_file" | sed 's/^/   /'
    soft_fail "$missing of $total vendor files missing: vendor repo doesn't match the device tree"
  fi
}
# =============================== STAGE 3 =====================================
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
  { grep -n -A12 -m1 '^FAILED:' "$lf"; grep -n -E 'error:|Error:|ERROR:|neverallow|checkpolicy|VINTF|incompatible' "$lf" | grep -v 'warning:' | sort -t: -k2 -u; } 2>/dev/null | head -80 || true
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
  CURRENT_STAGE="3-configcheck"
  log "STAGE 3: fast configuration checks (catches most port errors in minutes)"
  load_build_env
  log "3a. build graph analysis (m nothing)"
  run_m configcheck-analysis nothing || { show_failure "$LOG_DIR/configcheck-analysis.log"; die "Build configuration invalid. Send me the error summary above."; }
  ok "build graph OK"
  log "3b. SELinux policy compile"
  run_m configcheck-sepolicy selinux_policy || { show_failure "$LOG_DIR/configcheck-sepolicy.log"; die "SELinux policy fails to compile. Send me the error summary above."; }
  ok "SELinux policy compiles"
  log "3c. VINTF compatibility (device vs Android 17 framework)"
  if run_m configcheck-vintf check-vintf-all; then ok "VINTF compatible"
  elif grep -qiE "unknown target|no rule to make target" "$LOG_DIR/configcheck-vintf.log"; then
    warn "check-vintf-all target not available; VINTF is still enforced during the full build"
  else show_failure "$LOG_DIR/configcheck-vintf.log"; die "VINTF incompatibility (the ROM would not boot). Send me the error summary above."; fi
  mark_done configcheck
}

# =============================== STAGE 4 =====================================
full_build() {
  CURRENT_STAGE="4-build"
  log "STAGE 4: full build (m pixelos -j$JOBS). Log: $LOG_DIR/build.log"
  local t0=$SECONDS
  if [[ -f "$STATE_DIR/need_installclean" ]]; then
    log "trees changed: clearing previously installed images/modules (m installclean; compiled objects are kept)"
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

# =============================== STAGE 5 =====================================
verify_output() {
  CURRENT_STAGE="5-verify"
  log "STAGE 5: verifying output"
  local out="$WORKDIR/out/target/product/$CODENAME" zip
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
  for e in boot.img vendor_boot.img dtbo.img vbmeta.img; do [[ -f "$out/$e" ]] || die "$e was not produced"; done
  if [[ "$FLASH_FIRMWARE" == 1 ]]; then
    local tf abp miss=() f
    tf=$(ls -td "$WORKDIR"/out/target/product/$CODENAME/obj/PACKAGING/target_files_intermediates/*-target_files*/ 2>/dev/null | head -1)
    abp="${tf}META/ab_partitions.txt"
    [[ -f "$abp" ]] || die "can't find the OTA partition list ($abp)"
    for f in "${FIRMWARE_IMAGES[@]}"; do grep -qx "$f" "$abp" || miss+=("$f"); done
    if (( ${#miss[@]} == 0 )); then ok "firmware in the OTA zip: ${#FIRMWARE_IMAGES[@]} partitions (OS2.0.210)"
    elif (( ${#miss[@]} == ${#FIRMWARE_IMAGES[@]} )); then
      # the tree's firmware.mk is included from BoardConfig.mk, where my-dir/add-radio-file don't exist yet,
      # so it adds nothing. The fastboot package (stage 6) carries the firmware from the tree instead.
      ok "OTA zip has no firmware (expected with this tree; the release is firmware-free by design)"
    else die "OTA zip has only part of the firmware (missing: ${miss[*]}). Don't flash; send me this."; fi
  fi
  local bp="$out/system/build.prop" tags dbg
  tags=$(grep -m1 '^ro.build.tags=' "$bp" 2>/dev/null | cut -d= -f2)
  dbg=$(grep -hm1 '^ro.debuggable=' "$out"/vendor_boot/*/*prop* "$out"/system/build.prop "$out"/vendor/build.prop "$out"/root/*.prop "$out"/ramdisk/*prop* 2>/dev/null | head -1 | cut -d= -f2)
  if [[ "$SIGN" == 1 ]]; then
    # the real proof: the OTA certificate and the platform certificate are YOUR keys
    local want got ac
    want=$(openssl x509 -in "$WORKDIR/$KEYS_REL/releasekey.x509.pem" -noout -fingerprint -sha256 2>/dev/null)
    got=$(unzip -p "$out/system/etc/security/otacerts.zip" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null)
    [[ -n "$want" && "$want" == "$got" ]] || die "the ROM's OTA certificate is not your releasekey (not signed with your keys)"
    ac="${tf:-$(ls -td "$out"/obj/PACKAGING/target_files_intermediates/*-target_files*/ 2>/dev/null | head -1)}META/apkcerts.txt"
    local fr; fr=$(grep -m1 'name="framework-res.apk"' "$ac" 2>/dev/null || true)
    if [[ -n "$fr" && "$fr" != *"$KEYS_REL/platform"* ]]; then die "framework-res.apk is not signed with your platform key: $fr"; fi
    [[ "$tags" == release-keys ]] || die "signed with your keys, but tagged '$tags' instead of release-keys (keys not in $KEYS_REL?)"
    ok "signed with your own keys (OTA + platform certificates checked), tagged release-keys"
  fi
  if [[ -z "${DEBUG_BOOT:-}" ]]; then
    grep -qs 'androidboot.selinux=permissive' "$WORKDIR/device/xiaomi/sky/BoardConfig.mk" && die "SELinux permissive flag left in BoardConfig"
    ok "SELinux: enforcing (no permissive override); build type $BUILD_TYPE"
  fi
  local rel; rel=$(grep -m1 '^ro.build.version.release=' "$out/system/build.prop" 2>/dev/null | cut -d= -f2)
  sha256sum "$zip" > "$zip.sha256"
  ok "zip: $(basename "$zip") (${size_mb}MB), device=$CODENAME, Android ${rel:-?} (SDK ${sdk:-?})"
  ok "images: boot, vendor_boot, dtbo, vbmeta present; sha256 saved"
  mark_done verify
  ok "BUILD COMPLETE: $(basename "$zip")"
}


# =============================== STAGE 6 =====================================
# Release package: fastboot zip (the supported install) + OTA zip + filled docs + checksums.
# Output: $RELEASE_DIR/<rom name>/
REL_IMGS=(boot vendor_boot dtbo vbmeta vbmeta_system)   # physical, non-firmware partitions the installers flash
RELEASE_DIR="${RELEASE_DIR:-$HOME/release}"
STATUS_FILE="$WORKDIR/release-status.conf"

in_list() { local x=$1 y; shift; for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done; return 1; }
link_or_copy() { ln -f "$1" "$2" 2>/dev/null || cp -f "$1" "$2"; }

write_status_template() { # what you tested; RELEASE_NOTES.md is generated from this
  cat > "$STATUS_FILE" <<'STEOF'
# Device status for RELEASE_NOTES.md. Edit after testing, then regenerate the notes (takes seconds):
#     RELEASE_ONLY=1 ./build_pixelos17_sky.sh
# Suggested values:  ✅ Working   ⚠️ Partly (say what)   ❌ Broken   ❔ Not tested yet
WIFI=❔ Not tested yet
BT=❔ Not tested yet
RIL=❔ Not tested yet
AUDIO=✅ Working
CAM=❔ Not tested yet
FP_FPC=❔ Not tested yet
FP_GDX=🔧 Fix included in this build, needs testing
GPS=❔ Not tested yet
SENS=❔ Not tested yet
NFC=❔ Not tested yet
DISP=❔ Not tested yet
USB=❔ Not tested yet
# Recovery install: set RECOVERY=yes only after a sideload of this build worked for you,
# and RECOVERY_WITH to the recovery + version you used (e.g. OrangeFox R12.0_1)
RECOVERY=no
RECOVERY_WITH=
# Extra known issues, separated by " | " (leave empty for none)
EXTRA_ISSUES=
STEOF
}

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
s = re.sub(r"@([A-Z_]+)@", lambda m: v.get(m.group(1), m.group(0)), s)
left = sorted(set(re.findall(r"@[A-Z_]+@", s)))
if left:
    sys.exit("unfilled placeholders: " + " ".join(left))
open(dst, "w", encoding="utf-8").write(s)
PY
}

package_release() {
  CURRENT_STAGE="6-release"
  set +e +o pipefail; trap - ERR     # same as the build stages: every step below is checked explicitly
  log "STAGE 6: release package (fastboot zip + OTA zip + docs + checksums)"
  local out="$WORKDIR/out/target/product/$CODENAME" zip name rdir tf abp misc
  zip=$(ls -t "$out"/PixelOS_*.zip 2>/dev/null | head -1 || true)
  [[ -n "$zip" && -f "$zip" ]] || die "no PixelOS zip in $out (build first)"
  name=$(basename "$zip" .zip)
  rdir="$RELEASE_DIR/$name"
  tf=$(ls -td "$out"/obj/PACKAGING/target_files_intermediates/*-target_files*/ 2>/dev/null | head -1)
  abp="${tf}META/ab_partitions.txt"; misc="${tf}META/misc_info.txt"
  [[ -f "$abp" && -f "$misc" ]] || die "target-files metadata not found in $out (build first)"
  [[ -f "$STATUS_FILE" ]] || write_status_template
  mkdir -p "$rdir" || die "can't create $rdir"

  # --- the fastboot package flashes exactly what the ROM updates, minus firmware (never touched): REL_IMGS + super ---
  local dyn p unexpected=()
  dyn=$(grep -E '^(dynamic_partition_list|super_[a-z_]+_partition_list)=' "$misc" | cut -d= -f2- | tr ' ' '\n' | sort -u | xargs)
  [[ -n "${dyn// /}" ]] || die "no dynamic partition list in $misc"
  while read -r p; do
    [[ -z "$p" ]] && continue
    # shellcheck disable=SC2086
    in_list "$p" "${FIRMWARE_IMAGES[@]}" "${REL_IMGS[@]}" $dyn || unexpected+=("$p")
  done < "$abp"
  (( ${#unexpected[@]} == 0 )) || die "the ROM updates partitions the fastboot installer doesn't flash: ${unexpected[*]}. Send me this."
  for p in "${REL_IMGS[@]}"; do
    grep -qx "$p" "$abp" || die "$p is not in the ROM's partition list"
    [[ -s "$out/$p.img" ]] || die "$out/$p.img missing"
  done
  ok "fastboot ROM contents: ${REL_IMGS[*]} + $dyn; no firmware, bootloader or recovery"

  local fz="$rdir/$name-fastboot.zip" psig
  # recovery install: documented as supported only after you tested it (RECOVERY=yes in the status file)
  local rec rec_with bt='`'
  rec=$(sed -n 's/^RECOVERY=//p' "$STATUS_FILE" | tail -1 | tr -d ' '); rec_with=$(sed -n 's/^RECOVERY_WITH=//p' "$STATUS_FILE" | tail -1)
  if [[ "$rec" == yes ]]; then
    export REL_RECOVERY_STATUS="Tested with ${rec_with:-a custom recovery}" \
      REL_RECOVERY_STEPS="Tested with **${rec_with:-a custom recovery}**. Coming from another ROM or stock: 1. boot the recovery, 2. **Format Data**, 3. ${bt}adb sideload $name.zip${bt}, 4. reboot to system. Updating this ROM: just sideload the new zip (no format). The recovery zip contains no firmware." \
      REL_RECOVERY_NOTE=""
  else
    export REL_RECOVERY_STATUS="Not supported yet (see below): use the fastboot ROM" \
      REL_RECOVERY_STEPS="Not supported in this build yet: sideloading in OrangeFox failed in testing (its installer could not map the system partitions). Use the fastboot install. The recovery zip is provided for testers." \
      REL_RECOVERY_NOTE="- Installing through a custom recovery isn't supported yet: use the fastboot ROM
"
  fi
  psig="img-zip-v4"   # bump when the fastboot zip layout changes
  if [[ -f "$fz" && "$fz" -nt "$zip" && -z "${REPACK:-}" && "$(cat "$rdir/.pkg.sig" 2>/dev/null)" == "$psig" ]]; then
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
    # (flat images + android-info.txt; no firmware, no bootloader, no recovery)
    local stg="$rdir/.stage"
    rm -rf "$stg"; mkdir -p "$stg" || die "can't create $stg"
    # images come from ONE place so their verified-boot hashes match: the target-files IMAGES/ the
    # OTA was made from (raw images), falling back to out/. fastboot can only flash super from the
    # bootloader with raw (non-sparse) images, so sparse ones are expanded.
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
    # fastboot only flashes super from the bootloader in one go if every partition in
    # super_empty.img is marked readonly; this tree's build leaves them writable -> rebuild it
    local hb="$WORKDIR/out/host/linux-x86/bin"
    [[ -x "$hb/lpdump" && -x "$hb/lpmake" ]] || { [[ -n "${TARGET_PRODUCT:-}" ]] || load_build_env; run_m lptools lpdump lpmake || die "can't build lpdump/lpmake"; }
    rel_fix_super_empty > "$stg/fix_super_empty.py"
    python3 "$stg/fix_super_empty.py" "$hb" "$out/super_empty.img" "$stg/super_empty.img" || die "could not make a readonly super_empty.img"
    rm -f "$stg/fix_super_empty.py"
    ok "super_empty.img: all partitions readonly (one-step fastboot flashing)"
    printf 'require board=%s\n' "$CODENAME" > "$stg/android-info.txt"
    # fastboot-info.txt: tells fastboot (platform-tools 34+) to build and flash super from the
    # bootloader in one go, on the phone's current slot, instead of rebooting into fastbootd
    # (which lives in recovery and varies per phone)
    { echo "version 1"
      for p in "${REL_IMGS[@]}"; do
        case "$p" in vbmeta*) echo "flash --apply-vbmeta $p" ;; *) echo "flash $p" ;; esac
      done
      echo "reboot fastboot"; echo "update-super"
      for p in $dyn; do echo "flash $p"; done
    } > "$stg/fastboot-info.txt"
    for f in "${FIRMWARE_IMAGES[@]}" recovery; do [[ ! -e "$stg/$f.img" ]] || die "$f.img must not be in the fastboot zip"; done
    log "zipping the fastboot ROM (several minutes)"
    rm -f "$fz.tmp"
    ( cd "$stg" && zip -q -6 "$fz.tmp" android-info.txt fastboot-info.txt ./*.img ) || die "zip failed"
    unzip -tq "$fz.tmp" >/dev/null || die "fastboot zip failed its integrity test"
    [[ "$(unzip -Z1 "$fz.tmp" | grep -c '\.img$')" == "$(( ${#REL_IMGS[@]} + $(wc -w <<<"$dyn") + 1 ))" ]] || die "fastboot zip has the wrong number of images"
    mv -f "$fz.tmp" "$fz"; rm -rf "$stg"; echo "$psig" > "$rdir/.pkg.sig"
    ok "fastboot package: $(basename "$fz") ($(( $(stat -c %s "$fz") / 1048576 ))MB)"
  fi
  link_or_copy "$zip" "$rdir/$name.zip" || die "copy OTA zip failed"

  # --- checksums + docs (regenerated every time, so RELEASE_ONLY=1 refreshes the status table) ---
  ( cd "$rdir" && sha256sum "$name-fastboot.zip" "$name.zip" > SHA256SUMS ) || die "checksum failed"
  local bp="$out/system/build.prop" kver kr
  kr=$(ls "$out"/obj/KERNEL_OBJ/include/config/kernel.release 2>/dev/null | head -1)
  if [[ -n "$kr" ]]; then kver=$(<"$kr"); else kver=$(strings -n 16 "$out/kernel" 2>/dev/null | grep -m1 -oP 'Linux version \K\S+' || true); fi
  local t="$rdir/.tpl"; mkdir -p "$t"
  rel_install_md > "$t/INSTALL.tpl"; rel_release_notes_md > "$t/NOTES.tpl"
  export REL_NAME="$name" REL_MAINTAINER="$ROM_MAINTAINER" REL_KERNEL="${kver:-5.10}" \
    REL_DATE="$(date -u -d "@$(grep -m1 '^ro.build.date.utc=' "$bp" | cut -d= -f2)" +%F 2>/dev/null || date -u +%F)" \
    REL_RELEASE="$(grep -m1 '^ro.build.id=' "$bp" | cut -d= -f2)" \
    REL_SPL="$(grep -m1 '^ro.build.version.security_patch=' "$bp" | cut -d= -f2)" \
    REL_SHA="$(cat "$rdir/SHA256SUMS")"
  fill_template "$t/INSTALL.tpl" "$rdir/INSTALL.md" || die "INSTALL.md generation failed"
  fill_template "$t/NOTES.tpl" "$rdir/RELEASE_NOTES.md" || die "RELEASE_NOTES.md generation failed (check $STATUS_FILE)"
  rm -rf "$t"
  mark_done release
  ok "release folder: $rdir"
  ls -la "$rdir" | sed 's/^/    /'

  cat <<MSG

${C_G}================= RELEASE READY =================${C_0}
Folder: $rdir
  $name-fastboot.zip   <- what users (and you) install
  $name.zip            <- OTA zip (recovery install not supported yet)
  INSTALL.md  RELEASE_NOTES.md  SHA256SUMS

On your PC (in bash), download it:
  scp -o ControlPath=none -P ${SSH_PORT:-22} -r ${USER:-$(id -un)}@${SSH_HOST:-$(hostname -f 2>/dev/null || hostname)}:${rdir#"$HOME"/} ~/
Install on the phone (fastboot mode, Power + Volume Down; latest platform-tools; don't unzip):
  cd ~/$name && fastboot -w update $name-fastboot.zip
Your signing keys (download once, keep private, never publish):
  scp -o ControlPath=none -P ${SSH_PORT:-22} ${USER:-$(id -un)}@${SSH_HOST:-$(hostname -f 2>/dev/null || hostname)}:${WORKDIR#"$HOME"/}/sky17-signing-keys.tgz ~/
After testing, edit $STATUS_FILE and run:  RELEASE_ONLY=1 $0
MSG
}

# ------------------- release docs (embedded; written by package_release) -------------------
rel_install_md() { cat <<'__SKY17_REL_INSTALL_MD__'
# PixelOS 17 for Redmi 12 5G / POCO M6 Pro 5G / Redmi Note 12R (sky): installation

Build: **@NAME@**. Android 17, PixelOS, unofficial. Maintainer: **@MAINTAINER@**

This ROM **never flashes firmware, the bootloader or recovery**. Fastboot mode keeps working whatever
happens, so a phone can always be restored with Xiaomi's official ROM.

## Requirements

| | |
|---|---|
| **Device** | Any sky: Redmi 12 5G, POCO M6 Pro 5G, Redmi Note 12R, any region |
| **Bootloader** | Unlocked (Mi Unlock) |
| **Firmware** | Stock **HyperOS 2** (Android 15) firmware. Tested on **OS2.0.210** (Global); other HyperOS 2 versions are expected to work. See [Firmware](#firmware) |
| **PC** | Google's **latest platform-tools** (`fastboot`). Old versions can't flash this ROM in one step |
| **Data** | A clean install wipes the phone: back up first |

## Downloads

| File | Use |
|---|---|
| `@NAME@-fastboot.zip` | **Fastboot ROM.** Don't extract it: fastboot reads it directly |
| `@NAME@.zip` | Recovery ROM (OTA zip). @RECOVERY_STATUS@ |
| `SHA256SUMS` | Checksums of both files |

## Install (fastboot)

1. Install the latest platform-tools:
   - **Windows:** "SDK Platform-Tools for Windows" from developer.android.com; open a terminal in that folder. Install the Xiaomi/Google USB driver if the phone isn't found.
   - **Linux:** Arch `sudo pacman -S android-tools` · Debian/Ubuntu `sudo apt install fastboot` (or Google's zip if your distro's is old)
   - **macOS:** `brew install android-platform-tools`
2. Phone off → hold **Power + Volume Down** → **FASTBOOT** → connect USB. Check: `fastboot devices` shows the phone.
3. Flash:

| | Command |
|---|---|
| **Clean install** (from stock or another ROM; wipes data) | `fastboot -w update @NAME@-fastboot.zip` |
| **Update** (over an earlier build of this ROM; keeps data) | `fastboot update @NAME@-fastboot.zip` |

fastboot checks the zip is for sky before flashing, writes the ROM to the current slot, and reboots. First boot takes **5-10 minutes**.

(On Windows, if `fastboot` isn't found, use `.\fastboot` from inside the platform-tools folder, with the full path to the zip.)

## Recovery ROM

@RECOVERY_STEPS@

## Firmware

This ROM keeps the firmware your phone already has. It was tested on HyperOS **OS2.0.210** firmware.

If the ROM doesn't boot within 15 minutes, or the phone came from HyperOS 1 or another custom ROM:
1. Hold **Power + Volume Down** to get back to fastboot (always possible: this ROM never touches the bootloader).
2. Flash Xiaomi's official **HyperOS 2 fastboot ROM**, preferably **OS2.0.210.0.VMWMIXM** (Global, the tested version), with MiFlash **"clean all"** (never "clean all and lock"), or its `flash_all.sh`. Xiaomi's own tools refuse versions that would trip anti-rollback.
3. Boot it once, then do the clean install above.

## Troubleshooting

| Problem | Fix |
|---|---|
| `fastboot devices` shows nothing | Another USB port/cable (not a hub). Windows: USB driver. Linux: `sudo fastboot ...` |
| "requirement board=sky not met" / wrong product | This ROM is only for sky |
| It says "Rebooting into fastboot" and then hangs | Your platform-tools are too old: update them and run the command again from bootloader mode (Power + Volume Down) |
| A step failed mid-way | Don't reboot. Fix the connection and run the same command again: it's safe to repeat |
| Stuck on the boot logo > 15 minutes | See [Firmware](#firmware) |
| Reporting a bug | Developer options → USB debugging, then `adb bugreport bug.zip`; share it with your HyperOS firmware version |

## Credits

TopexGuy (sky Android 17 device, vendor, kernel) · anonytry (hardware/xiaomi, Dolby, vibrator) · PixelOS and LineageOS teams · everyone behind earlier sky bring-ups · build and packaging: **@MAINTAINER@**
__SKY17_REL_INSTALL_MD__
}
rel_release_notes_md() { cat <<'__SKY17_REL_RELEASE_NOTES_MD__'
# PixelOS 17 (Android 17) for sky: @NAME@

**Devices:** Redmi 12 5G · POCO M6 Pro 5G · Redmi Note 12R (codename `sky`)
**Status:** Unofficial · **Maintainer:** @MAINTAINER@ · **Build date:** @DATE@

## Highlights

- PixelOS 17 on Android 17 (`@RELEASE@`), security patch **@SPL@**
- **User build**: SELinux **enforcing**, signed with private **release keys** (not test-keys)
- Kernel **@KERNEL@**, built from source (TopexGuy's sky kernel)
- Vendor blobs from HyperOS **OS2.0.210**; tested on OS2.0.210 firmware
- Clean PixelOS: no extra device-settings app. Dolby audio effects are included
- Standard AOSP **fastboot ROM**: one command, `fastboot -w update <zip>`, no scripts. It never touches firmware, the bootloader or recovery, so fastboot always keeps working

## Changes in this build (on top of TopexGuy's tree)

- Fingerprint (Goodix units): create the data directories the Goodix driver needs. Also, the fingerprint service no longer crashes when no sensor driver can be opened
- SELinux: fixed denials seen on a running device (Dolby DMS audio scenario, thermal daemon battery access, RIL debug property); everything compiled and checked against Android 17 policy rules
- Removed the TopexTool / XiaomiParts settings app for a stock PixelOS experience
- Firmware-free: uses the stock HyperOS 2 firmware already on the phone, any region

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
| SELinux | ✅ Enforcing |

## Known issues

@RECOVERY_NOTE@- Tested on OS2.0.210 (Global) firmware. If it doesn't boot or is unstable on your firmware, flash the official OS2.0.210 fastboot ROM first (INSTALL.md, "Firmware")
- @EXTRA_ISSUES@

## Install

See **INSTALL.md**. Short version: unlocked bootloader + stock HyperOS 2 firmware (OS2.0.210 tested) + latest platform-tools → fastboot mode (Power + Volume Down) → `fastboot -w update @NAME@-fastboot.zip`. Updates: `fastboot update @NAME@-fastboot.zip`.

## Checksums

```
@SHA@
```

## Credits

TopexGuy (sky Android 17 device, vendor, kernel) · anonytry (hardware/xiaomi, Dolby, vibrator) · PixelOS and LineageOS teams · everyone behind earlier sky bring-ups.
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
  if [[ -n "${RESYNC:-}${RESET_TREES:-}" ]]; then clear_from configcheck build verify; fi
  sync_source
  setup_trees
  config_check
  full_build
  verify_output
  package_release
}

main "$@"
