/***********************************************************************************************************************
 * Boot record access (read only side, used by the bootloader).
 *
 * The record lives in one data flash block. Data flash on FLASH_HP parts is directly readable, so reading needs no
 * flash driver. Writes go through boot_record_write.c, which only the bootloader links.
 **********************************************************************************************************************/

#include <string.h>
#include "boot_record.h"

/***********************************************************************************************************************
 * CRC16-CCITT (poly 0x1021, init 0xFFFF), bitwise to keep the bootloader small.
 **********************************************************************************************************************/
uint16_t boot_record_crc16 (const uint8_t * p_data, uint32_t length)
{
    uint16_t crc = 0xFFFFU;

    for (uint32_t i = 0U; i < length; i++)
    {
        crc ^= (uint16_t) ((uint16_t) p_data[i] << 8);

        for (uint32_t bit = 0U; bit < 8U; bit++)
        {
            if (0U != (crc & 0x8000U))
            {
                crc = (uint16_t) (((uint16_t) (crc << 1)) ^ 0x1021U);
            }
            else
            {
                crc = (uint16_t) (crc << 1);
            }
        }
    }

    return crc;
}

/***********************************************************************************************************************
 * Copies the boot record out of data flash and validates it.
 **********************************************************************************************************************/
bool boot_record_read (boot_record_t * p_record)
{
    const volatile uint8_t * p_flash = (const volatile uint8_t *) BOOT_RECORD_ADDRESS;
    uint8_t                * p_dest  = (uint8_t *) p_record;

    for (uint32_t i = 0U; i < BOOT_RECORD_SIZE; i++)
    {
        p_dest[i] = p_flash[i];
    }

    if (BOOT_RECORD_MAGIC != p_record->magic)
    {
        return false;
    }

    if (BOOT_RECORD_VERSION != p_record->version)
    {
        return false;
    }

    uint16_t crc = boot_record_crc16(p_dest, BOOT_RECORD_CRC_LENGTH);

    return crc == p_record->crc16;
}

/***********************************************************************************************************************
 * Fills @p p_record with the defaults used when the record is blank, corrupt or from an older version.
 **********************************************************************************************************************/
void boot_record_defaults (boot_record_t * p_record)
{
    for (uint32_t i = 0U; i < (BOOT_RECORD_SIZE / 4U); i++)
    {
        ((uint32_t *) p_record)[i] = 0xFFFFFFFFU;
    }

    p_record->magic           = BOOT_RECORD_MAGIC;
    p_record->version         = BOOT_RECORD_VERSION;
    p_record->swap_type       = (uint8_t) BOOT_SWAP_TYPE_NONE;
    p_record->copy_done       = 1U;
    p_record->image_ok        = 1U;
    p_record->sequence        = 1U;
    p_record->crc32_staged    = BOOT_CRC32_UNSET;
    p_record->crc32_primary   = BOOT_CRC32_UNSET;
}

/***********************************************************************************************************************
 * Reference CRC32 of the staged image, measured over the secondary slot when the swap was armed.
 *
 * Returns BOOT_CRC32_UNSET when there is no usable record, which tells the swap engine it has nothing to verify
 * against (a record written by an older bootloader, or a swap armed before this check existed).
 **********************************************************************************************************************/
uint32_t boot_record_staged_crc (void)
{
    boot_record_t record;

    if (!boot_record_read(&record))
    {
        return BOOT_CRC32_UNSET;
    }

    return record.crc32_staged;
}

/***********************************************************************************************************************
 * Swap intent recorded for this boot. A blank/corrupt record means "nothing staged".
 **********************************************************************************************************************/
uint8_t boot_record_swap_type (void)
{
    boot_record_t record;

    if (!boot_record_read(&record))
    {
        return (uint8_t) BOOT_SWAP_TYPE_NONE;
    }

    if (record.swap_type > (uint8_t) BOOT_SWAP_TYPE_REVERT)
    {
        return (uint8_t) BOOT_SWAP_TYPE_NONE;
    }

    return record.swap_type;
}

/***********************************************************************************************************************
 * True when a swap was started but never reached copy_done - i.e. it must be resumed.
 **********************************************************************************************************************/
bool boot_record_swap_in_progress (void)
{
    boot_record_t record;

    if (!boot_record_read(&record))
    {
        return false;
    }

    if ((uint8_t) BOOT_SWAP_TYPE_NONE == record.swap_type)
    {
        return false;
    }

    return 1U != record.copy_done;
}

/***********************************************************************************************************************
 * True when a trial image is running and never confirmed itself, so it must be swapped back.
 *
 * This is the state a completed TEST swap leaves behind: the exchange finished (copy_done == 1), the intent was
 * rewritten to REVERT, and image_ok is still 0. The application clears it by sending BOOT_CMD_CONFIRM, which runs
 * before this check on the next boot. If the trial image crashed, hung (IWDT) or simply never confirmed, the next
 * reset lands here and the previous image is restored.
 **********************************************************************************************************************/
bool boot_record_revert_pending (void)
{
    boot_record_t record;

    if (!boot_record_read(&record))
    {
        return false;
    }

    if ((uint8_t) BOOT_SWAP_TYPE_REVERT != record.swap_type)
    {
        return false;
    }

    /* An unfinished exchange is resumed by boot_record_swap_in_progress(), not reverted. */
    if (1U != record.copy_done)
    {
        return false;
    }

    return 1U != record.image_ok;
}