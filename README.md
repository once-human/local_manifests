# PixelOS 17 for Xiaomi sky

Local manifest for building **PixelOS 17 (Android 17)** with the **Linux 6.6** kernel for the Redmi 12 5G, POCO M6 Pro 5G and Redmi Note 12R (`sky`).

| Path | Source (branch) |
|---|---|
| `device/xiaomi/sky` | [once-human/android_device_xiaomi_sky](https://github.com/once-human/android_device_xiaomi_sky) (`seventeen`) |
| `device/xiaomi/sm4450-common` | [once-human/android_device_xiaomi_sm4450-common](https://github.com/once-human/android_device_xiaomi_sm4450-common) (`seventeen`) |
| `kernel/xiaomi/sm4450` | [once-human/android_kernel_xiaomi_sm4450](https://github.com/once-human/android_kernel_xiaomi_sm4450) (`seventeen`, 6.6 "Nimbus") |
| `kernel/xiaomi/sm4450-modules` | [once-human/android_kernel_xiaomi_sm4450-modules](https://github.com/once-human/android_kernel_xiaomi_sm4450-modules) (`seventeen`) |
| `kernel/xiaomi/sm4450-devicetrees` | [once-human/android_kernel_xiaomi_sm4450-devicetrees](https://github.com/once-human/android_kernel_xiaomi_sm4450-devicetrees) (`seventeen`) |
| `hardware/xiaomi` | [once-human/android_hardware_xiaomi](https://github.com/once-human/android_hardware_xiaomi) (`seventeen-6.6`) |
| `vendor/xiaomi/sky`, `vendor/xiaomi/sm4450-common` | **extracted** from Xiaomi's stock ROMs: sky OS2.0.210.0.VMWMIXM, mist OS3.0.306.0.WPUINXM |

The device trees come from the LineageOS-style sm4450 6.6 bring-up by the xiaomi-ravelin team, and the kernel from Suvojeet's 6.6 kernel. Every change on top is a commit on the `seventeen` branches.

The October 2026 setup (5.10, TopexGuy trees) is on the [`seventeen-5.10`](https://github.com/once-human/local_manifests/tree/seventeen-5.10) branch.

## Build

The script does everything: preflight, sync, blob extraction from the stock ROMs, a fast configuration and kernel check, the signed user build, verification, and the release folder with the Updater feed.

```bash
mkdir -p ~/stock-roms   # put Xiaomi's official recovery zips here (or pass SKY_ROM= / MIST_ROM= paths or URLs)
curl -fLO https://raw.githubusercontent.com/once-human/local_manifests/seventeen/scripts/build_pixelos17_sky.sh
chmod +x build_pixelos17_sky.sh
CHECK_ONLY=1 ./build_pixelos17_sky.sh   # checks only
./build_pixelos17_sky.sh                # full run, inside tmux, resumes when rerun
```

By hand:

```bash
repo init -u https://github.com/PixelOS-AOSP/android_manifest.git -b seventeen --git-lfs
mkdir -p .repo/local_manifests
curl -fLo .repo/local_manifests/sky.xml https://raw.githubusercontent.com/once-human/local_manifests/seventeen/sky.xml
repo sync -c -j"$(nproc)" --force-sync --no-clone-bundle --no-tags
cd device/xiaomi/sky
./extract-files.py --only-common <mist OS3.0.306.0.WPUINXM zip>
./extract-files.py --only-target <sky OS2.0.210.0.VMWMIXM zip>
cd -
source build/envsetup.sh
lunch custom_sky-cp2a-user
m pixelos
```

Release builds are signed with private keys in `vendor/lineage-priv/keys` (never published), which PixelOS includes automatically.

## Install

Downloads and guides: **[once-human/pixelos-sky](https://github.com/once-human/pixelos-sky)**.

## Credits

See [CREDITS.md](https://github.com/once-human/pixelos-sky/blob/main/CREDITS.md).
