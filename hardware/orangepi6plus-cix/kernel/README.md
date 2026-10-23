# ZWO HID kernel requirements

Orange Pi 6 Plus port, 2026-10-23 (GPLv2). These portable requirements are
carried over from the Orange Pi 4 Pro:

- [`hid-support.config`](hid-support.config): the two config changes,
  `CONFIG_HIDRAW=y` and `CONFIG_USB_HIDDEV=y`, as a small reference fragment.
- [`hid-usbhid-paper-over-wrong-bNumDescriptors.patch`](hid-usbhid-paper-over-wrong-bNumDescriptors.patch):
  the exact upstream project's backport of Linux commit
  `f28beb69c51517aec7067dfb2074e7c751542384`, repairing the malformed HID
  descriptor count reported by ZWO accessories.

## Current image

**These files are reference inputs, not patches applied by the image builder.**
The inspected Armbian `6.18.45-current-arm64` kernel already enables both
options, and Linux stable 6.18.45 already contains the descriptor fix.
Applying the patch again would duplicate an existing change.

The 4 Pro's full `linux-sun60iw2-vendor.config` is deliberately not copied:
it targets the Allwinner A733, not the 6 Plus's CIX hardware.

## If a future kernel needs rebuilding

Start with that kernel's **ARM64/CIX-compatible** Armbian config. Ensure the
two options above are enabled; the fragment alone is not a complete config.
Check `drivers/hid/usbhid/hid-core.c` for the existing descriptor repair
before attempting the backport. This saved patch targets the old 6.6 source
and may need adapting to another version.

Use the selected Armbian kernel family's actual userpatch location, not the
4 Pro's `sun60iw2-opi-vendor` directory. Feed the matching kernel packages
to `build/build-openastro-image.sh` through `KERNEL_DEBS` as documented in
the top-level README. Real ZWO device testing is still required.
