# LG Back experiment: Linux keycode 412

The maintainer supplied this input-hook table:
https://gist.github.com/Simon34545/31c528bfe8540880936fc4c580723a02

It lists `BACK 412`, `ENTER 28`, `UP 103`, and `REWIND 168`.
These are internal Linux input codes, not JavaScript webOS codes or USB usages.
The linked comment describes observing those codes in LG Input Hook's live logs.

Linux's `include/uapi/linux/input-event-codes.h` defines `KEY_PREVIOUS` as
`0x19c` (decimal 412). Its HID driver maps consumer usage `0x01A4` (AL Previous
Task/Application) to `KEY_PREVIOUS`:
https://github.com/torvalds/linux/blob/master/drivers/hid/hid-input.c

Therefore the next Back experiment sends consumer **0x01A4**, not 412 itself.
This is a source-backed candidate, not proof that the C1's USB input path uses
that mapping. TV firmware may classify external HID differently from its remote.
The maintainer must test actual Back behavior in the relevant apps and menus.

The previous consumer `0x01CD` experiment failed. Equal numbers from webOS DOM
keycodes and HID usages do not establish a mapping. No firmware change is needed
for this new experiment: the existing bridge forwards a 16-bit consumer usage.
Home/Win, layout, and all other buttons are unchanged.
