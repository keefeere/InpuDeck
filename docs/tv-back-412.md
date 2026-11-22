# LG Back: Linux keycode 412 → consumer usage 0x01A4 (verified)

The maintainer supplied this input-hook table:
https://gist.github.com/Simon34545/31c528bfe8540880936fc4c580723a02

It lists `BACK 412`, `ENTER 28`, `UP 103`, `TV 377`, `TV_VIDEO 241`, `REWIND 168`.
The linked comment describes reading those numbers from the TV's live input-hook
logs, so they are **internal Linux input codes**, not JavaScript webOS keycodes
and not USB HID usages.

Linux's `include/uapi/linux/input-event-codes.h` defines `KEY_PREVIOUS` as
`0x19c` (decimal 412). Its HID driver maps consumer usage `0x01A4` (AL Previous
Task/Application) to `KEY_PREVIOUS`:
https://github.com/torvalds/linux/blob/master/drivers/hid/hid-input.c

So Back sends consumer **0x01A4**, never the literal 412.

**Verified on the maintainer's LG C1 with 3.6.12 (2026-11-22):** that button acts
as Back. Consumer `0x0224` (`KEY_BACK`), consumer `0x01CD`, keyboard `Escape` and
keyboard `Backspace` are all ignored by the TV, so they stay out of the template.

The same table plus Linux's mapping also produced the Input candidate:

| LG table entry | Linux code | Consumer usage | C1 status |
| --- | --- | --- | --- |
| `BACK 412` | `KEY_PREVIOUS` | `0x01A4` | works (shipped) |
| `TV_VIDEO 241` | `KEY_VIDEO_NEXT` | `0x0082` | untested candidate for Вхід |
| `TV 377` | `KEY_TV` | `0x0089` | switches to the TV input, not the input list |
| `MENU 139` | `KEY_MENU` | `0x0040` | works |
| `EXIT 174` | `KEY_EXIT` | `0x0094` | works |
| `MUTE 113` | `KEY_MUTE` | `0x00E2` | works |
| `VOLUMEUP/DOWN 115/114` | `KEY_VOLUMEUP/DOWN` | `0x00E9/0x00EA` | works |

Equal numbers across webOS DOM keycodes, Linux codes and HID usages mean nothing
by themselves; the chain that matters is LG table → Linux code → HID usage, and
only the maintainer's TV confirms the last step. No firmware change was needed:
the existing bridge forwards a 16-bit consumer usage untouched.
