# PixelOS 17 for Xiaomi sky

Local manifest for building **PixelOS 17 (Android 17)** for the Redmi 12 5G, POCO M6 Pro 5G and Redmi Note 12R (`sky`).

| Path | Source |
|---|---|
| `device/xiaomi/sky` | [once-human/device_xiaomi_sky](https://github.com/once-human/device_xiaomi_sky) (`seventeen`), based on TopexGuy's tree |
| `vendor/xiaomi/sky` | [topexguy/vendor_xiaomi_sky](https://github.com/topexguy/vendor_xiaomi_sky) (OS2.0.210 blobs) |
| `kernel/xiaomi/sky` | [topexguy/kernel_xiaomi_sky](https://github.com/topexguy/kernel_xiaomi_sky) (5.10, built from source) |
| `kernel/xiaomi/sm8450-modules` | [topexguy/kernel_xiaomi_sm8450-modules](https://github.com/topexguy/kernel_xiaomi_sm8450-modules) |
| `hardware/xiaomi` | [once-human/android_hardware_xiaomi](https://github.com/once-human/android_hardware_xiaomi) (`seventeen`) |
| `hardware/dolby` | [anonytry/hardware_dolby](https://github.com/anonytry/hardware_dolby) |
| `vendor/qcom/opensource/vibrator` | [anonytry/android_vendor_qcom_opensource_vibrator](https://github.com/anonytry/android_vendor_qcom_opensource_vibrator) |

Third-party repos are pinned to the exact commits the release was built from.

## Build

```bash
repo init -u https://github.com/PixelOS-AOSP/android_manifest.git -b seventeen --git-lfs
mkdir -p .repo/local_manifests
curl -fLo .repo/local_manifests/sky.xml https://raw.githubusercontent.com/once-human/local_manifests/seventeen/sky.xml
repo sync -c -j"$(nproc)" --force-sync --no-clone-bundle --no-tags

source build/envsetup.sh
lunch custom_sky-cp2a-user
m pixelos
```

Release builds are signed with private keys in `vendor/lineage-priv/keys` (never published), which PixelOS includes automatically.

## Install

See **[docs/INSTALL.md](docs/INSTALL.md)**. In short: unlocked bootloader, stock HyperOS 2 firmware (OS2.0.210 tested), platform-tools 35 or newer, then in fastboot mode:

```bash
fastboot -w update PixelOS_sky-<version>-fastboot.zip
```

The fastboot ROM never flashes firmware, the bootloader or recovery.

## Repository contents

| Path | What |
|---|---|
| `sky.xml` | Local manifest (the sources) |
| `docs/INSTALL.md` | Installation guide for the first release |
| `scripts/build_pixelos17_sky.sh` | The all-in-one script the first release was built with: syncs PixelOS, applies the same changes as the `seventeen` branches above on top of TopexGuy's tree, builds a signed user build, verifies it and packages the release. New builds should use the manifest instead. |

## Credits

TopexGuy (device, vendor, kernel) · anonytry (hardware/xiaomi, Dolby, vibrator) · PixelOS and LineageOS teams.
