# PixelOS 17 for Redmi 12 5G / POCO M6 Pro 5G / Redmi Note 12R (sky): installation

Build: **PixelOS_sky-17.0-20260930-1940**. Android 17, PixelOS, unofficial. Maintainer: **Onkar Yaglewad**

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
| `PixelOS_sky-17.0-20260930-1940-fastboot.zip` | **Fastboot ROM.** Don't extract it: fastboot reads it directly |
| `PixelOS_sky-17.0-20260930-1940.zip` | Recovery ROM (OTA zip). Not supported yet (see below): use the fastboot ROM |
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
| **Clean install** (from stock or another ROM; wipes data) | `fastboot -w update PixelOS_sky-17.0-20260930-1940-fastboot.zip` |
| **Update** (over an earlier build of this ROM; keeps data) | `fastboot update PixelOS_sky-17.0-20260930-1940-fastboot.zip` |

fastboot checks the zip is for sky before flashing, writes the ROM to the current slot, and reboots. First boot takes **5-10 minutes**.

(On Windows, if `fastboot` isn't found, use `.\fastboot` from inside the platform-tools folder, with the full path to the zip.)

## Recovery ROM

Not supported in this build yet: sideloading in OrangeFox failed in testing (its installer could not map the system partitions). Use the fastboot install. The recovery zip is provided for testers.

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

TopexGuy (sky Android 17 device, vendor, kernel) · anonytry (hardware/xiaomi, Dolby, vibrator) · PixelOS and LineageOS teams · everyone behind earlier sky bring-ups · build and packaging: **Onkar Yaglewad**
