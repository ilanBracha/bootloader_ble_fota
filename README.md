# OTA bootloader (FPB-RA6E2)

Scratch-based **swap** bootloader for the R7FA6E2BB3CFM. The application is linked once, at a single
execution address, and ships as a plain `.bin` — no image header, no post-build tooling, no metadata from
the sender.

Design reference: `SWAP-MODE.MD`.

## Why swap

The application executes in place from flash, so its vector table, literal pools and branch targets are all
absolute addresses fixed at link time. An image built for one address cannot run at another. The RA6E2 has
no dual-bank remap (`BSP_FEATURE_FLASH_HP_SUPPORTS_DUAL_BANK == 0`), so the hardware cannot hide that.

Swap solves it in software: **the application always runs from the primary slot**. A new image is staged in
the secondary slot, and the bootloader physically exchanges the two slots before anything runs. The staged
image therefore ends up at exactly the address it was linked for, which is why one build configuration is
enough.

## Flash map

Defined once in [`src/boot_layout.h`](src/boot_layout.h). Retargeting should need only that file and
`<config>/memory_regions.ld`.

```
0x00000000  bootloader     16 KB  (2 x 8 KB)
0x00004000  spare          16 KB  (headroom; bootloader currently uses 7412 B)
0x00008000  scratch        32 KB  (4 x 8 KB  = one slot sector)
0x00010000  primary slot   96 KB  (3 x 32 KB)  <- the ONLY execution address
0x00028000  secondary slot 96 KB  (3 x 32 KB)  <- staging only, never executed
0x08000000  data flash     block 0 = boot record, block 1 = swap progress log
```

The geometry is forced by the silicon: code flash erases in 8 KB blocks below `0x10000` and 32 KB blocks
above it, and scratch must hold one whole slot sector. Two 96 KB slots only fit in the 32 KB region, so
scratch is 32 KB and lives down in the 8 KB region.

## What an application has to do

Almost nothing, and that is deliberate. The whole application-facing interface is two files in the
application project — [`boot_ota.h` / `boot_ota.c`](../ota_fw_app_ra6e2/src/boot_ota.h) — exposing three
functions:

```c
boot_ota_swap_and_reset(BOOT_SWAP_TYPE_PERM);   /* after writing the new image to BOOT_SECONDARY_BASE */
boot_ota_confirm_and_reset();                   /* only if you used BOOT_SWAP_TYPE_TEST */
boot_ota_last_result(&result);                  /* what happened on this boot */
```

The application writes the downloaded image into the secondary slot, asks for a swap, and resets. It does
not choose a slot, read or write the boot record, validate images, or move anything — the bootloader is the
sole owner of all boot state. An invalid request is refused and reported back through the mailbox, so the
board always comes back up.

Because the two projects build separately they cannot share a header, so `boot_ota.*` is a copy of
`src/boot_layout.h` and `src/boot_mailbox.h`. Run `script/check_contract.ps1` after changing either side; it
compares the constants, the mailbox struct field-by-field, and the `RAM_LENGTH` reserve in both `fsp.ld`
files.

## What the bootloader does on every boot

1. **Read the RAM mailbox.** There is no interrupt and nothing is polled — *the reset is the trigger*. The
   application leaves a request at a fixed RAM address and resets; SRAM survives a warm reset. A swap
   request is validated (the staged image must have a plausible, primary-linked vector table) before
   anything is written, so a bad request can never strand the product.
2. **Perform or resume the exchange.** Each of the 3 sectors is swapped in 3 legs:

   ```
   leg 0:  scratch           <- secondary[sector]
   leg 1:  secondary[sector] <- primary[sector]
   leg 2:  primary[sector]   <- scratch
   ```

   A 4-byte entry is appended to the data flash log after each completed leg, so a power cut resumes from
   the first unfinished leg rather than restarting. The source of every leg stays intact until the leg after
   it completes, which is what makes a repeated (interrupted) leg harmless.
3. **Roll back an unconfirmed trial image.** See below.
4. **Validate the primary slot and jump.** If it holds no usable image the bootloader traps rather than
   branching into nothing.
5. **Acknowledge.** The outcome is written back to the mailbox just before the jump, so the application can
   report what happened (CLI `status`).

## Trial boot and rollback

A swap can be permanent (`BOOT_SWAP_TYPE_PERM`, CLI `swap`) or on trial (`BOOT_SWAP_TYPE_TEST`, CLI
`test`). A trial swap installs the new image and leaves the record at `swap_type = REVERT, image_ok = 0`.
From there exactly one of two things happens:

- The new image proves itself and sends `BOOT_CMD_CONFIRM` (CLI `confirm`). The flag is cleared and the
  image is permanent.
- **Anything else** — a crash, a watchdog reset, a power cycle, a user pressing reset — lands on the next
  boot with the flag still set, and the bootloader runs the exchange a second time, putting the previous
  image back.

The rollback costs no extra code: the exchange is symmetric, and the previous image is still sitting in the
secondary slot exactly where the first swap left it. If that image is *not* bootable, the bootloader keeps
the trial image instead and stops trying — a running image beats a guaranteed brick.

### The watchdog is the application's job, not the bootloader's

A trial image that **crashes** resets itself, so the rollback runs. A trial image that **hangs** does not —
it would run unconfirmed forever, and the whole mechanism would quietly do nothing. Closing that hole needs
a watchdog, and a watchdog belongs to the **application**: the bootloader must never be watched, because a
96 KB swap takes far longer than any sensible timeout.

This is therefore a **requirement on the real application**, documented in
[`../ota_fw_app_ra6e2/README.md`](../ota_fw_app_ra6e2/README.md). The demo application deliberately has no
watchdog code — it is a placeholder, and carrying a watchdog it does not need only obscured the contract.

The key constraint if you add one: use **register-start** mode, which the default `OFS0` already selects
(the configurator labels it "IWDT Start Mode = Disabled", meaning auto-start is disabled). Auto-start would
arm the counter the moment the MCU leaves reset — while the *bootloader* is running — and the board would
reset itself mid-swap forever. Register start means the bootloader is inherently exempt, with no refresh
calls anywhere in the swap loop.

Two gaps remain by construction: an image that hangs *before* it starts the watchdog is never caught, and
with no watchdog at all a hung trial image is never rolled back.

## Boot record and swap log (data flash)

Data flash is directly readable, so reads need no driver; writes go through `r_flash_hp`.

- **Block 0** — 64-byte boot record: magic, version, `swap_type`, `copy_done`, `image_ok`, sequence,
  per-slot CRC32, CRC16 over the rest.
- **Block 1** — swap progress log: 9 append-only 4-byte entries. The data flash write unit is 4 bytes, so
  each entry is programmed independently and **no erase is needed mid-swap**. The block is erased once at
  the *start* of a swap, so it is always either empty or a description of the swap in flight.

### Erased data flash does not read as 0xFF

On FLASH_HP parts the value **read** from an erased data flash cell is undefined. On a well-cycled part it can
still read as the value programmed there before the erase. The log is therefore counted with the FCU blank check
(`boot_flash_df_blank()`): an entry counts only if the FCU reports it programmed **and** it holds the expected
value. Arming a swap also blank-checks the erased log and refuses the request if it is not provably empty.

Before this fix the log was a plain memory read. On the QA board, entry 0 still read `0xA5A50000` right after the
erase, so every swap started at step 1. Leg 2 then copied a stale scratch sector into primary[0], the CRC check
failed, and the primary slot could not boot. v1.0 hung in `boot_fatal()`. v1.1.0 recovered through
`boot_recover_primary()`, but that recovery left the stale sector in secondary[0], so the log showed
"rollback to @0x00028000 - empty". Regression: `bash test/host_swap_sim/run.sh`. Hardware proof:
`script/prove_df_stale.jlink`.

The J-Link scripts (`verify_swap.ps1`, `verify_resume.ps1`, `dump_state.ps1`) still read the log with plain reads.
On such a part they can report entries that are not really there.

## Code flash programming

`g_flash0` must have **Code Flash Programming enabled** (configurator → Stacks → g_flash0). With that
option FSP places the whole program/erase sequence in RAM (`.ram_from_flash`), which is what makes it legal
to erase code flash while running from it. Verify after any regeneration:

```powershell
powershell -File script/check_ramcode.ps1
```

`flash_hp_enter_pe_cf_mode`, `flash_hp_cf_erase`, `flash_hp_cf_write` and `flash_hp_pe_mode_exit` must all
report addresses in `0x2000xxxx`.

## Build

```powershell
powershell -File script/build_bl.ps1      # bootloader, with size and RAM-placement report
```

`script/fsp.ld` caps `FLASH_LENGTH` at 16 KB and trims `RAM_LENGTH` by `0x20` for the mailbox.
**"Generate Project Content" overwrites it** — re-apply both after every regeneration; the size guard in
`makefile.targets` catches the first, `script/check_ramcode.ps1` the second.

## Flashing and test tooling

| Script | Purpose |
|---|---|
| `flash.ps1` | Program bootloader / primary / secondary, optionally erase the data flash state |
| `stage_secondary.ps1` | Patch the build tag in a copy of the app and program it into the secondary slot |
| `verify_swap.ps1` | End-to-end: clean install → stage → swap → swap back |
| `verify_trial.ps1` | Trial swap, rollback on an unconfirmed image, and `confirm` making it permanent |
| `verify_resume.ps1` | Interrupt a swap at several points and confirm it resumes correctly |
| `verify_arm.ps1` | Deferred requests over the CLI: `arm` / `cancel` / reset-later (**needs the serial port free**) |
| `check_contract.ps1` | Confirm the application's copy of the OTA contract still matches this one |
| `dump_state.ps1`, `dump_tags.ps1` | Inspect the mailbox, record, log and slot contents |
| `check_ramcode.ps1` | List which functions execute from RAM |

First download:

```powershell
powershell -File script/flash.ps1 -Bootloader Debug/bootloader.bin `
                                  -App ..\ota_fw_app_ra6e2\Debug\app.bin -EraseState
```

### Three traps the verification scripts had to work around

J-Link's `connect` halts the core, so a fresh session never observes the effect of a boot. Anything that
depends on the bootloader having run must reset, run, wait and read **inside one commander session** — see
`Invoke-BootAndRead` in `jlink_common.ps1`.

Halting the core mid-swap leaves the flash controller in P/E mode, where code flash cannot be read;
disconnecting in that state hangs the next `connect`. The cut sessions therefore issue a reset *before*
disconnecting. And `verify_resume.ps1` reprograms both slots from scratch for every cut point rather than
swapping back: interrupting the flash controller can leave a sector partially erased, and swapping would
carry that damage into the next iteration, making later failures look like firmware bugs.

**Peripheral registers wider than a byte read back as zero over `mem8`** — `IWDTCR`, `IWDTSR` and `RSTSR1`
all need `mem32`. Related: the reset-cause flags cannot be trusted after the fact, because connecting resets
the part. And if you ever add a watchdog back, note that **the IWDT does not count while a debug probe is
attached**, so it cannot be tested from the debugger at all — a test has to disconnect J-Link entirely and
let the board run alone.

## Current status

| | |
|---|---|
| Bootloader | 7412 / 16384 bytes (45%) |
| Application | 9244 / 98304 bytes (9.4%) |
| `verify_swap.ps1` | 14 / 14 PASS |
| `verify_trial.ps1` | 26 / 26 PASS |
| `verify_resume.ps1` | 17 / 17 PASS, every cut point a genuine mid-swap interruption (1–7 legs) |
| `check_contract.ps1` | PASS (no hardware needed) |
| `verify_arm.ps1` | 14 / 14 PASS — arm does not reset, cancel really un-arms, request survives to a later reset |

## Not implemented yet

- **Image integrity.** `boot_image_ok_at()` checks 8 bytes of vector table. It is a misplacement and
  blank-slot detector, not an image validator. The per-slot CRC32 in the record is computed after a swap but
  is not yet checked on boot. Nothing here authenticates an image — that needs signing, which was out of
  scope.
- **Swap size.** The full 96 KB is always exchanged (9 erase/program operations of 32 KB, ~1.1 s). Limiting
  it to the actual image length would cut that substantially without changing the on-flash format.
- **OTA transport.** The demo application has no code flash driver; staging is done over J-Link by
  `stage_secondary.ps1`. The real application will receive an image and write the secondary slot itself.
- **Watchdog.** No longer present in the demo application — see above. Until the real application provides
  one, a trial image that hangs is never rolled back.
- **Real power-cut testing.** Resume is proven against debugger halts, which is not quite the same as losing
  the supply rail mid-erase.
