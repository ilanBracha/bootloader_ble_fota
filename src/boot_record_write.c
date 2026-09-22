/***********************************************************************************************************************
 * Boot record write path - BOOTLOADER side.
 *
 * The bootloader is the only code that writes the boot record. An application requests a swap through the RAM
 * mailbox (see boot_mailbox.h); everything persistent happens here.
 **********************************************************************************************************************/

#include "boot_record.h"
#include "boot_record_write.h"
#include "boot_flash.h"

/** Record staged in RAM. Must not live in flash and must stay valid for the duration of the write. */
static boot_record_t g_staged_record;

/***********************************************************************************************************************
 * Loads the current record, or defaults when it is blank/corrupt/an older version.
 **********************************************************************************************************************/
static void boot_record_load (boot_record_t * p_record)
{
    if (boot_record_read(p_record))
    {
        p_record->sequence++;
    }
    else
    {
        boot_record_defaults(p_record);
    }
}

/***********************************************************************************************************************
 * Erases the record block and programs the new contents, then reads back to verify.
 **********************************************************************************************************************/
static fsp_err_t boot_record_commit (boot_record_t * p_record)
{
    p_record->crc16 = boot_record_crc16((const uint8_t *) p_record, BOOT_RECORD_CRC_LENGTH);

    fsp_err_t err = boot_flash_erase(BOOT_RECORD_ADDRESS, BOOT_RECORD_SIZE);

    if (FSP_SUCCESS == err)
    {
        err = boot_flash_write(BOOT_RECORD_ADDRESS, p_record, BOOT_RECORD_SIZE);
    }

    if (FSP_SUCCESS != err)
    {
        return err;
    }

    boot_record_t check;

    return boot_record_read(&check) ? FSP_SUCCESS : FSP_ERR_WRITE_FAILED;
}

/***********************************************************************************************************************
 * Public API
 **********************************************************************************************************************/

fsp_err_t boot_record_request_swap (uint8_t swap_type, uint32_t crc_staged)
{
    if ((swap_type < (uint8_t) BOOT_SWAP_TYPE_PERM) || (swap_type > (uint8_t) BOOT_SWAP_TYPE_REVERT))
    {
        return FSP_ERR_INVALID_ARGUMENT;
    }

    /* Clear the progress log FIRST. It is then either empty (no swap in flight) or a description of the swap that
     * is running right now - never a leftover from a previous, already completed swap. */
    fsp_err_t err = boot_flash_erase(BOOT_SWAP_LOG_ADDRESS, BOOT_SWAP_LOG_SIZE);

    if (FSP_SUCCESS != err)
    {
        return err;
    }

    boot_record_load(&g_staged_record);

    g_staged_record.swap_type = swap_type;
    g_staged_record.copy_done = 0U;
    g_staged_record.image_ok  = ((uint8_t) BOOT_SWAP_TYPE_TEST == swap_type) ? (uint8_t) 0U : (uint8_t) 1U;

    /* The reference the exchange will be checked against. Written before the first byte moves, so it describes the
     * image as it was staged - and it is re-read, not recomputed, if the swap has to be resumed after a power cut. */
    g_staged_record.crc32_staged  = crc_staged;
    g_staged_record.crc32_primary = BOOT_CRC32_UNSET;

    return boot_record_commit(&g_staged_record);
}

fsp_err_t boot_record_swap_complete (uint8_t swap_type, uint8_t image_ok, uint32_t crc_primary)
{
    /* boot_record_load() keeps crc32_staged from the armed record, so it stays available for diagnostics. */
    boot_record_load(&g_staged_record);

    g_staged_record.swap_type     = swap_type;
    g_staged_record.copy_done     = 1U;
    g_staged_record.image_ok      = image_ok;
    g_staged_record.crc32_primary = crc_primary;

    return boot_record_commit(&g_staged_record);
}

fsp_err_t boot_record_set_image_ok (void)
{
    boot_record_load(&g_staged_record);

    g_staged_record.swap_type = (uint8_t) BOOT_SWAP_TYPE_NONE;
    g_staged_record.image_ok  = 1U;

    return boot_record_commit(&g_staged_record);
}