/***********************************************************************************************************************
 * OTA boot layout - single source of truth for the flash map shared by the bootloader and the application.
 *
 * Retargeting to another board/MCU should require editing ONLY this file and Debug/memory_regions.ld.
 *
 * Current target: FPB-RA6E2 (R7FA6E2BB3CFM) - 256 KB code flash, 40 KB SRAM, 4 KB data flash.
 * Code flash erase blocks: 8 KB below 0x10000 (region 0), 32 KB above (region 1).
 *
 * SWAP layout (MCUboot "swap using scratch"):
 *
 *   0x00000000 - 0x00003FFF  bootloader     16 KB  (2 x 8 KB)
 *   0x00004000 - 0x00007FFF  spare          16 KB  (bootloader headroom, unused)
 *   0x00008000 - 0x0000FFFF  scratch        32 KB  (4 x 8 KB - holds exactly one slot sector)
 *   0x00010000 - 0x00027FFF  primary slot   96 KB  (3 x 32 KB)  <- the ONLY execution address
 *   0x00028000 - 0x0003FFFF  secondary slot 96 KB  (3 x 32 KB)  <- staging only, never executed
 *   0x08000000               data flash block 0: boot record
 *   0x08000040               data flash block 1: swap progress log
 *
 * The application is linked once, at BOOT_PRIMARY_BASE, and ships as a plain .bin. A new image is staged into the
 * secondary slot; the bootloader then physically exchanges the two slots so the new image ends up at the address it
 * was linked for. That is why there is only one application build configuration.
 **********************************************************************************************************************/

#ifndef BOOT_LAYOUT_H
#define BOOT_LAYOUT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**********************************************************************************************************************
 * Flash map
 *********************************************************************************************************************/

#define BOOT_BOOTLOADER_BASE         (0x00000000UL)
#define BOOT_BOOTLOADER_SIZE         (0x00004000UL) /* 16 KB - must match BOOTLOADER_SIZE in script/fsp.ld */

/** Scratch area used to exchange one sector at a time. Must be >= BOOT_SLOT_SECTOR_SIZE. */
#define BOOT_SCRATCH_BASE            (0x00008000UL)
#define BOOT_SCRATCH_SIZE            (0x00008000UL) /* 32 KB (4 x 8 KB region-0 blocks) */

/** Execution slot. The application vector table always lives here. */
#define BOOT_PRIMARY_BASE            (0x00010000UL)
#define BOOT_PRIMARY_SIZE            (0x00018000UL) /* 96 KB */

/** Staging slot. Holds a downloaded image until the bootloader swaps it in. Never executed in place. */
#define BOOT_SECONDARY_BASE          (0x00028000UL)
#define BOOT_SECONDARY_SIZE          (0x00018000UL) /* 96 KB */

/** Erase block size inside the slots (code flash region 1). Both slots must use the same geometry. */
#define BOOT_SLOT_SECTOR_SIZE        (0x00008000UL) /* 32 KB */

/** Number of sectors exchanged by a swap. */
#define BOOT_SLOT_SECTOR_COUNT       (BOOT_PRIMARY_SIZE / BOOT_SLOT_SECTOR_SIZE) /* 3 */

/** Legs per sector: secondary->scratch, primary->secondary, scratch->primary. */
#define BOOT_SWAP_LEGS_PER_SECTOR    (3U)

/** Total number of resumable swap steps. Must fit in the data flash log block. */
#define BOOT_SWAP_STEP_COUNT         (BOOT_SLOT_SECTOR_COUNT * BOOT_SWAP_LEGS_PER_SECTOR) /* 9 */

/* RAM window used to sanity check the stack pointer of a candidate image. */
#define BOOT_RAM_BASE                (0x20000000UL)
#define BOOT_RAM_SIZE                (0x0000A000UL) /* 40 KB */

/**********************************************************************************************************************
 * Boot record (data flash block 0)
 *********************************************************************************************************************/

/** Address of the boot record. Data flash on FLASH_HP parts is directly readable, so reads need no driver. */
#define BOOT_RECORD_ADDRESS          (0x08000000UL)

/** Data flash erase block size == record size on this MCU family. */
#define BOOT_RECORD_SIZE             (64U)

/** 'B','O','O','T' little endian. */
#define BOOT_RECORD_MAGIC            (0x544F4F42UL)

#define BOOT_RECORD_VERSION          (3U)

/** Value stored in a CRC32 field that has never been measured (erased data flash). */
#define BOOT_CRC32_UNSET             (0xFFFFFFFFUL)

/** boot_record_t::swap_type - what the bootloader should do with the secondary slot on this boot. */
typedef enum e_boot_swap_type
{
    BOOT_SWAP_TYPE_NONE   = 0,         ///< Nothing staged, boot primary as-is
    BOOT_SWAP_TYPE_PERM   = 1,         ///< Swap and keep the result permanently
    BOOT_SWAP_TYPE_TEST   = 2,         ///< Swap, then run the new image on trial until it confirms (phase 2)
    BOOT_SWAP_TYPE_REVERT = 3,         ///< Trial image failed to confirm, swap back (phase 2)
} boot_swap_type_t;

/** Boot record layout. Exactly BOOT_RECORD_SIZE bytes so it maps onto one data flash block. */
typedef struct st_boot_record
{
    uint32_t magic;                    ///< BOOT_RECORD_MAGIC
    uint8_t  version;                  ///< BOOT_RECORD_VERSION
    uint8_t  swap_type;                ///< boot_swap_type_t - pending/ongoing swap intent
    uint8_t  copy_done;                ///< 1 once the sector exchange completed, 0/0xFF while in flight
    uint8_t  image_ok;                 ///< 1 once the running image confirmed itself (phase 2)
    uint32_t sequence;                 ///< Incremented on every successful record update
    uint32_t crc32_staged;             ///< CRC32 of the SECONDARY slot, measured when the swap was armed. This is
                                       ///< the reference the exchange is verified against - see boot_swap.h.
    uint32_t crc32_primary;            ///< CRC32 of the PRIMARY slot, measured once the exchange completed. Equal to
                                       ///< crc32_staged when every sector was moved faithfully.
    uint32_t reserved[10];             ///< Reserved, written as 0xFFFFFFFF
    uint16_t reserved16;               ///< Padding, written as 0xFFFF
    uint16_t crc16;                    ///< CRC16-CCITT over the first (BOOT_RECORD_SIZE - 2) bytes
} boot_record_t;

/** Number of bytes protected by boot_record_t::crc16. */
#define BOOT_RECORD_CRC_LENGTH       ((uint32_t) (BOOT_RECORD_SIZE - 2U))

/**********************************************************************************************************************
 * Swap progress log (data flash block 1)
 *
 * Append-only: BOOT_SWAP_STEP_COUNT entries of 4 bytes, one written after each completed leg. The data flash write
 * unit is 4 bytes, so each entry is programmed independently without disturbing its neighbours - no erase is needed
 * in the middle of a swap. The block is erased once at the START of a swap, so it is always either empty (no swap in
 * flight) or a description of the swap currently in flight. Completion is recorded by boot_record_t::copy_done.
 *********************************************************************************************************************/

#define BOOT_SWAP_LOG_ADDRESS        (BOOT_RECORD_ADDRESS + BOOT_RECORD_SIZE)
#define BOOT_SWAP_LOG_SIZE           (64U)

/** Value of an unwritten (erased) log entry. */
#define BOOT_SWAP_LOG_EMPTY          (0xFFFFFFFFUL)

/** Encoding of a completed step. The tag makes random/erased data easy to reject. */
#define BOOT_SWAP_LOG_TAG            (0xA5A50000UL)
#define BOOT_SWAP_LOG_ENTRY(step)    (BOOT_SWAP_LOG_TAG | ((uint32_t) (step) & 0xFFFFU))

/**********************************************************************************************************************
 * Helpers shared by bootloader and application
 *********************************************************************************************************************/

/** Base address of the Nth sector of the primary slot. */
static inline uint32_t boot_primary_sector (uint32_t sector)
{
    return BOOT_PRIMARY_BASE + (sector * BOOT_SLOT_SECTOR_SIZE);
}

/** Base address of the Nth sector of the secondary slot. */
static inline uint32_t boot_secondary_sector (uint32_t sector)
{
    return BOOT_SECONDARY_BASE + (sector * BOOT_SLOT_SECTOR_SIZE);
}

/** Vector table entries used when validating an image. */
#define BOOT_VECTOR_INITIAL_SP       (0U)
#define BOOT_VECTOR_RESET_HANDLER    (1U)

/***********************************************************************************************************************
 * Sanity checks the vector table of an image at @p base, assuming it is linked to run from @p link_base.
 *
 * For the primary slot base == link_base. For the secondary slot the image is staged but linked for primary, so its
 * reset handler points into the PRIMARY slot - pass link_base = BOOT_PRIMARY_BASE to check a staged image.
 **********************************************************************************************************************/
static inline bool boot_image_ok_at (uint32_t base, uint32_t link_base, uint32_t size)
{
    const volatile uint32_t * p_vect = (const volatile uint32_t *) base;

    uint32_t sp = p_vect[BOOT_VECTOR_INITIAL_SP];
    uint32_t pc = p_vect[BOOT_VECTOR_RESET_HANDLER];

    /* Blank (erased) flash. */
    if ((0xFFFFFFFFU == sp) || (0xFFFFFFFFU == pc))
    {
        return false;
    }

    /* The initial stack pointer must land inside RAM and be 8 byte aligned. */
    if ((sp < BOOT_RAM_BASE) || (sp > (BOOT_RAM_BASE + BOOT_RAM_SIZE)) || (0U != (sp & 0x7U)))
    {
        return false;
    }

    /* The reset handler must be a Thumb address inside the region the image was linked for. */
    if (0U == (pc & 0x1U))
    {
        return false;
    }

    uint32_t handler = pc & ~0x1U;

    if ((handler < link_base) || (handler >= (link_base + size)))
    {
        return false;
    }

    return true;
}

/** True when the primary slot holds a bootable image. This is the only slot that ever executes. */
static inline bool boot_primary_image_ok (void)
{
    return boot_image_ok_at(BOOT_PRIMARY_BASE, BOOT_PRIMARY_BASE, BOOT_PRIMARY_SIZE);
}

/** True when the secondary slot holds an image that looks like a valid, primary-linked application. */
static inline bool boot_secondary_image_ok (void)
{
    return boot_image_ok_at(BOOT_SECONDARY_BASE, BOOT_PRIMARY_BASE, BOOT_PRIMARY_SIZE);
}

#ifdef __cplusplus
}
#endif

#endif                                 /* BOOT_LAYOUT_H */
