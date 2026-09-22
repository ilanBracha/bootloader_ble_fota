/*
                  Linker File for Renesas FSP

    OTA bootloader build:
      The bootloader must fit inside its reserved region at the start of code flash. FLASH_LENGTH from the
      generated memory_regions.ld (whole device flash) is overridden below so the linker fails loudly instead
      of silently spilling into the scratch area.

      Keep BOOTLOADER_SIZE in sync with BOOT_BOOTLOADER_SIZE in src/boot_layout.h.

      NOTE: "Generate Project Content" in e2 studio OVERWRITES this file and removes the override.
      Re-apply it after every regeneration. The bootloader-size rule in makefile.targets catches it.
*/

INCLUDE memory_regions.ld

BOOTLOADER_SIZE = 0x4000;              /* 16 KB */
FLASH_LENGTH    = BOOTLOADER_SIZE;

/* Reserve the top of SRAM for the boot mailbox (see src/boot_mailbox.h). Must match BOOT_MAILBOX_RESERVE
 * and be applied identically in every application image so the mailbox address is the same everywhere. */
RAM_LENGTH = RAM_LENGTH - 0x20;

INCLUDE fsp_gen.ld

ASSERT(__ddsc_FLASH_END <= (FLASH_START + BOOTLOADER_SIZE),
       "Bootloader image exceeds its 16 KB reserved region (see src/boot_layout.h)")