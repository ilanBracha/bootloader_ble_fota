/***********************************************************************************************************************
 * Slot swap engine. See boot_swap.h for the three-leg algorithm.
 **********************************************************************************************************************/

#include "boot_swap.h"
#include "boot_layout.h"
#include "boot_record.h"
#include "boot_record_write.h"
#include "boot_flash.h"

/***********************************************************************************************************************
 * Counts the leading, well formed entries in the progress log.
 *
 * Entries are written in order, so the first empty or unexpected entry marks where the last attempt stopped.
 **********************************************************************************************************************/
uint32_t boot_swap_log_count (void)
{
    const volatile uint32_t * p_log = (const volatile uint32_t *) BOOT_SWAP_LOG_ADDRESS;
    uint32_t                  count = 0U;

    while (count < BOOT_SWAP_STEP_COUNT)
    {
        if (BOOT_SWAP_LOG_ENTRY(count) != p_log[count])
        {
            break;
        }

        count++;
    }

    return count;
}

/***********************************************************************************************************************
 * Executes one leg of the exchange for @p sector.
 **********************************************************************************************************************/
static fsp_err_t boot_swap_leg (uint32_t sector, uint32_t leg)
{
    switch (leg)
    {
        case 0U:
        {
            /* Park the staged image so the primary sector can be overwritten. */
            return boot_flash_copy(BOOT_SCRATCH_BASE, boot_secondary_sector(sector), BOOT_SLOT_SECTOR_SIZE);
        }

        case 1U:
        {
            /* The old image moves to the secondary slot, where it stays available for a revert. */
            return boot_flash_copy(boot_secondary_sector(sector), boot_primary_sector(sector),
                                   BOOT_SLOT_SECTOR_SIZE);
        }

        case 2U:
        {
            /* The staged image lands at the address it was linked for. */
            return boot_flash_copy(boot_primary_sector(sector), BOOT_SCRATCH_BASE, BOOT_SLOT_SECTOR_SIZE);
        }

        default:
        {
            return FSP_ERR_INVALID_ARGUMENT;
        }
    }
}

/***********************************************************************************************************************
 * Public API
 **********************************************************************************************************************/

fsp_err_t boot_swap_start (uint8_t swap_type)
{
    /* Refuse to exchange in something that could never run. The staged image is linked for the PRIMARY slot, so it
     * is validated against the primary base even though it currently sits in the secondary slot. */
    if (!boot_secondary_image_ok())
    {
        return FSP_ERR_INVALID_DATA;
    }

    /* Fingerprint the staged image BEFORE anything moves. Stored in the record, so the exchange can be verified
     * against it later even if it takes several boots to finish. */
    return boot_record_request_swap(swap_type, boot_crc32(BOOT_SECONDARY_BASE, BOOT_SECONDARY_SIZE));
}

boot_swap_result_t boot_swap_process (void)
{
    uint8_t swap_type = boot_record_swap_type();

    if ((uint8_t) BOOT_SWAP_TYPE_NONE == swap_type)
    {
        return BOOT_SWAP_RESULT_NONE;
    }

    if (!boot_record_swap_in_progress())
    {
        if (!boot_record_revert_pending())
        {
            /* A completed swap whose intent was already cleared. Nothing to do. */
            return BOOT_SWAP_RESULT_NONE;
        }

        /* A trial image was installed and never confirmed itself. Put the previous image back.
         *
         * The exchange is symmetric, so the revert is the SAME three-leg operation - the previous image is sitting
         * in the secondary slot exactly where the swap left it. */
        if (!boot_secondary_image_ok())
        {
            /* The image we would revert to is not bootable, so reverting would brick the board. Keep the trial
             * image and stop trying: a running image beats a guaranteed brick. */
            return (FSP_SUCCESS == boot_record_set_image_ok()) ? BOOT_SWAP_RESULT_NONE : BOOT_SWAP_RESULT_ERROR;
        }

        /* A revert is armed exactly like a swap, reference CRC included - the image about to be moved back in is
         * the one currently in the secondary slot. */
        if (FSP_SUCCESS !=
            boot_record_request_swap((uint8_t) BOOT_SWAP_TYPE_REVERT,
                                     boot_crc32(BOOT_SECONDARY_BASE, BOOT_SECONDARY_SIZE)))
        {
            return BOOT_SWAP_RESULT_ERROR;
        }

        swap_type = (uint8_t) BOOT_SWAP_TYPE_REVERT;
    }

    /* Read the reference before the exchange overwrites the slot it describes. */
    uint32_t crc_staged = boot_record_staged_crc();

    /* Resume from wherever the last attempt stopped. On a fresh request the log was erased, so this is 0. */
    for (uint32_t step = boot_swap_log_count(); step < BOOT_SWAP_STEP_COUNT; step++)
    {
        uint32_t sector = step / BOOT_SWAP_LEGS_PER_SECTOR;
        uint32_t leg    = step % BOOT_SWAP_LEGS_PER_SECTOR;

        if (FSP_SUCCESS != boot_swap_leg(sector, leg))
        {
            return BOOT_SWAP_RESULT_ERROR;
        }

        if (FSP_SUCCESS != boot_flash_log_write(BOOT_SWAP_LOG_ADDRESS + (step * 4U), BOOT_SWAP_LOG_ENTRY(step)))
        {
            return BOOT_SWAP_RESULT_ERROR;
        }
    }

    /* Did the image that was staged actually arrive? Every flash operation reported success, but that only says the
     * driver was happy - it does not say the bytes at the destination are the ones we set out to move. Comparing the
     * primary slot against the fingerprint taken before the first leg does.
     *
     * An unset reference means the record predates this check (or was rewritten by an older bootloader); there is
     * nothing to compare against, so the swap is accepted rather than failed on a missing measurement. */
    uint32_t crc_primary = boot_crc32(BOOT_PRIMARY_BASE, BOOT_PRIMARY_SIZE);
    bool     crc_ok      = (BOOT_CRC32_UNSET == crc_staged) || (crc_primary == crc_staged);

    /* A TEST swap stays flagged until the new image confirms itself; anything else is final. */
    uint8_t next_type = ((uint8_t) BOOT_SWAP_TYPE_TEST == swap_type) ? (uint8_t) BOOT_SWAP_TYPE_REVERT
                                                                     : (uint8_t) BOOT_SWAP_TYPE_NONE;
    uint8_t image_ok  = ((uint8_t) BOOT_SWAP_TYPE_TEST == swap_type) ? (uint8_t) 0U : (uint8_t) 1U;

    /* Record completion even when the CRC disagrees. The slots have already been exchanged, so leaving the swap
     * marked in flight would only make the next boot repeat an exchange that cannot improve the result. */
    if (FSP_SUCCESS != boot_record_swap_complete(next_type, image_ok, crc_primary))
    {
        return BOOT_SWAP_RESULT_ERROR;
    }

    if (!crc_ok)
    {
        /* Report it and stop here. Deciding to swap back automatically would risk a boot loop between two images
         * that both fail the same check, so the call is left to the layer above: hal_entry() still refuses to jump
         * into a primary slot that does not look bootable, and a TEST swap reverts on its own when the installed
         * image fails to confirm. */
        return BOOT_SWAP_RESULT_CRC_FAIL;
    }

    /* Covers both a freshly armed revert and one that was interrupted and resumed. */
    return ((uint8_t) BOOT_SWAP_TYPE_REVERT == swap_type) ? BOOT_SWAP_RESULT_REVERTED : BOOT_SWAP_RESULT_DONE;
}