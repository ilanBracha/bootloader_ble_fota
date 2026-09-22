/***********************************************************************************************************************
 * Boot mailbox - a small RAM handshake so an application can REQUEST a slot swap without touching the boot record.
 *
 * The application and the bootloader never run at the same time, so the request is passed across a reset through a
 * fixed RAM location that survives a warm reset (NVIC_SystemReset does not clear SRAM):
 *
 *   application : boot_request_swap()  -> fills the mailbox, then NVIC_SystemReset()
 *   bootloader  : on startup, if the mailbox holds a valid request it validates the staged image, records the
 *                 intent and performs the sector exchange (the bootloader is the ONLY code that writes the boot
 *                 record or moves images), clears the mailbox, then boots the primary slot.
 *
 * There is no "which slot" argument any more: the application always runs from the primary slot, and a swap simply
 * exchanges primary and secondary.
 *
 * The mailbox sits just above the top of the linker's RAM window. script/fsp.ld trims RAM_LENGTH by
 * BOOT_MAILBOX_RESERVE in BOTH the bootloader and the application image, so:
 *   - the address is identical in both images (this file computes it the same way),
 *   - it is never used as stack/heap/.bss, so startup does not clear it.
 *
 * Keep BOOT_MAILBOX_RESERVE in sync with the "RAM_LENGTH = RAM_LENGTH - ..." line in script/fsp.ld.
 **********************************************************************************************************************/

#ifndef BOOT_MAILBOX_H
#define BOOT_MAILBOX_H

#include <stdint.h>
#include <stdbool.h>
#include "bsp_api.h"
#include "boot_layout.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Bytes carved off the top of RAM for the mailbox (must match script/fsp.ld). */
#define BOOT_MAILBOX_RESERVE         (0x20UL)

/** Fixed mailbox address: top of SRAM, just above the trimmed RAM window. Same in every image. */
#define BOOT_MAILBOX_ADDRESS         (BOOT_RAM_BASE + BOOT_RAM_SIZE - BOOT_MAILBOX_RESERVE)

/** 'B','O','R','Q' little endian - present only while a request is pending. */
#define BOOT_MAILBOX_MAGIC           (0x51524F42UL)

/** 'B','A','C','K' little endian - present once the bootloader has reported the outcome of the last boot. */
#define BOOT_ACK_MAGIC               (0x4B434142UL)

/** Mailbox commands. */
typedef enum e_boot_command
{
    BOOT_CMD_NONE    = 0,              ///< No request
    BOOT_CMD_SWAP    = 1,              ///< Exchange primary and secondary; 'arg' carries a boot_swap_type_t
    BOOT_CMD_CONFIRM = 2,              ///< Confirm the running trial image so it is not reverted (phase 2)
} boot_command_t;

/** Outcome of the last bootloader run, reported back to the application through the mailbox. */
typedef enum e_boot_status
{
    BOOT_STATUS_NONE        = 0,       ///< No report (should not be observed)
    BOOT_STATUS_OK          = 1,       ///< Booted the primary slot; nothing was staged
    BOOT_STATUS_SWAPPED     = 2,       ///< A swap completed and the new image is now running
    BOOT_STATUS_CONFIRMED   = 3,       ///< The running image was confirmed, no revert will happen
    BOOT_STATUS_REVERTED    = 4,       ///< A trial image failed to confirm and was swapped back
    BOOT_STATUS_ERR_IMAGE   = 5,       ///< REJECTED: the secondary slot holds no usable image
    BOOT_STATUS_ERR_WRITE   = 6,       ///< REJECTED: writing the boot record failed
    BOOT_STATUS_ERR_REQUEST = 7,       ///< REJECTED: malformed command
    BOOT_STATUS_ERR_SWAP    = 8,       ///< A swap was started but a flash operation failed part way through
    BOOT_STATUS_ERR_CRC     = 9,       ///< The swap ran to the end but the installed image does not match the CRC32
                                       ///< taken of the staged image before the exchange started
} boot_status_t;

/** Reported in boot_mailbox_t::req_cmd when the boot was not caused by a request. */
#define BOOT_CMD_NOT_REQUESTED       (0xFFU)

/** 32-byte RAM handshake: a request written by the application, and a result written by the bootloader. */
typedef struct st_boot_mailbox
{
    /* Request - written by the application, cleared by the bootloader once consumed. */
    uint32_t magic;                    ///< BOOT_MAILBOX_MAGIC when a request is pending
    uint8_t  command;                  ///< boot_command_t
    uint8_t  arg;                      ///< BOOT_CMD_SWAP: boot_swap_type_t to apply
    uint8_t  reserved[2];              ///< padding
    uint32_t check;                    ///< integrity check, see boot_mailbox_check()

    /* Result - written by the bootloader on every boot, read by the application. Never cleared by the bootloader. */
    uint32_t ack_magic;                ///< BOOT_ACK_MAGIC once the bootloader has filled this section
    uint8_t  status;                   ///< boot_status_t
    uint8_t  req_cmd;                  ///< command that was requested, or BOOT_CMD_NOT_REQUESTED
    uint8_t  detail;                   ///< swap legs completed, for diagnosing an interrupted exchange
    uint8_t  ack_reserved;             ///< padding
    uint32_t ack_check;                ///< integrity check, see boot_mailbox_ack_check()

    uint32_t spare[2];                 ///< keeps the struct at BOOT_MAILBOX_RESERVE bytes
} boot_mailbox_t;

/** The mailbox instance at its fixed address. */
#define BOOT_MAILBOX                 (*(volatile boot_mailbox_t *) BOOT_MAILBOX_ADDRESS)

/** Integrity value over command + arg. Rejects random SRAM contents after a cold power-on. */
static inline uint32_t boot_mailbox_check (uint8_t command, uint8_t arg)
{
    return BOOT_MAILBOX_MAGIC ^ 0xA5A5A5A5UL ^ ((uint32_t) command << 8) ^ (uint32_t) arg;
}

/** True when the mailbox currently holds a valid, self-consistent request. */
static inline bool boot_mailbox_pending (void)
{
    const volatile boot_mailbox_t * p = &BOOT_MAILBOX;

    return (BOOT_MAILBOX_MAGIC == p->magic) && (p->check == boot_mailbox_check(p->command, p->arg));
}

/** Invalidate the mailbox so the request is processed exactly once. */
static inline void boot_mailbox_clear (void)
{
    BOOT_MAILBOX.magic = 0U;
    BOOT_MAILBOX.check = 0U;
}

/** Integrity value over the result fields. Rejects random SRAM contents after a cold power-on. */
static inline uint32_t boot_mailbox_ack_check (uint8_t status, uint8_t req_cmd, uint8_t detail)
{
    return BOOT_ACK_MAGIC ^ 0x5A5A5A5AUL ^ ((uint32_t) status << 16) ^ ((uint32_t) req_cmd << 8) ^
           (uint32_t) detail;
}

/** True when the bootloader has left a self-consistent result in the mailbox. */
static inline bool boot_mailbox_ack_valid (void)
{
    const volatile boot_mailbox_t * p = &BOOT_MAILBOX;

    return (BOOT_ACK_MAGIC == p->ack_magic) &&
           (p->ack_check == boot_mailbox_ack_check(p->status, p->req_cmd, p->detail));
}

/** Bootloader only: report the outcome of this boot. Magic written last so a partial write is never accepted. */
static inline void boot_mailbox_set_ack (uint8_t status, uint8_t req_cmd, uint8_t detail)
{
    volatile boot_mailbox_t * p = &BOOT_MAILBOX;

    p->ack_magic    = 0U;
    p->status       = status;
    p->req_cmd      = req_cmd;
    p->detail       = detail;
    p->ack_reserved = 0U;
    p->ack_check    = boot_mailbox_ack_check(status, req_cmd, detail);

    __DMB();

    p->ack_magic = BOOT_ACK_MAGIC;

    __DSB();
}

/** Human readable form of a boot_status_t. */
static inline const char * boot_status_name (uint8_t status)
{
    switch (status)
    {
        case BOOT_STATUS_OK:
        {
            return "OK - booted the primary slot";
        }

        case BOOT_STATUS_SWAPPED:
        {
            return "SWAPPED - the staged image is now running";
        }

        case BOOT_STATUS_CONFIRMED:
        {
            return "CONFIRMED - the running image is permanent";
        }

        case BOOT_STATUS_REVERTED:
        {
            return "REVERTED - trial image did not confirm, previous image restored";
        }

        case BOOT_STATUS_ERR_IMAGE:
        {
            return "REJECTED - the secondary slot holds no usable image";
        }

        case BOOT_STATUS_ERR_WRITE:
        {
            return "REJECTED - boot record write failed";
        }

        case BOOT_STATUS_ERR_REQUEST:
        {
            return "REJECTED - malformed request";
        }

        case BOOT_STATUS_ERR_SWAP:
        {
            return "ERROR - swap interrupted by a flash failure, will resume on next boot";
        }

        case BOOT_STATUS_ERR_CRC:
        {
            return "ERROR - swap completed but the installed image failed its CRC check";
        }

        default:
        {
            return "none";
        }
    }
}

#ifdef __cplusplus
}
#endif

#endif                                 /* BOOT_MAILBOX_H */
