# OpenAstro boot artwork

`grub-background.png` is a 1920×1080, 8-bit RGB PNG for GRUB's graphical
terminal. It places the existing OpenAstro logo at its original 602×334
size at `(1238, 120)` on a dark RGB `(9, 14, 22)` background, leaving the
left side clear for the boot menu. No runtime image-generation dependency
is needed.

Logo source, retrieved 2026-10-23:
https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png

Original logo SHA256:
`d2365f38f47e912819eba43accafffee0eded8a1b4d58a0d6df44b8a860f4327`

The logo is the OpenAstro project's artwork and retains its original rights.
This background does not replace the board's UEFI/CIX firmware artwork or
the kernel's compiled-in logo. No Plymouth splash or quiet-boot settings
are added.
