/***********************************************************************************************************************
 * Boot record write path - BOOTLOADER side.
 *
 * The bootloader is the only code that writes the boot record: an application requests a swap through the RAM
 * mailbox (see boot_mailbox.h) and the bootloader applies it here after a reset.
 *
 * One data flash block holds the record, so an update is: erase 1 block, write BOOT_RECORD_SIZE bytes.
 * Uses the generic flash_instance_t API (r_flash_hp) through boot_flash.c.
 **********************************************************************************************************************/

#ifndef BOOT_RECORD_WRITE_H
#define BOOT_RECORD_WRITE_H

#include "hal_data.h"
#include "boot_layout.h"

#ifdef __cplusplus
extern "C" {
#endif

/***********************************************************************************************************************
 * Marks a swap of type @p swap_type as pending and clears the progress log. Call before starting the exchange.
 *
 * @param[in] crc_staged  CRC32 of the secondary slot measured NOW, before anything moves. It is stored in the record
 *                        so it survives a power cut and can be compared against the primary slot once the exchange
 *                        finishes, however many boots that takes. Pass BOOT_CRC32_UNSET to skip verification.
 **********************************************************************************************************************/
fsp_err_t boot_record_request_swap(uint8_t swap_type, uint32_t crc_staged);

/** Records a finished sector exchange: copy_done = 1, the new swap intent, and the CRC32 measured over the primary. */
fsp_err_t boot_record_swap_complete(uint8_t swap_type, uint8_t image_ok, uint32_t crc_primary);

/** Confirms the running image so a trial boot is not reverted (phase 2). */
fsp_err_t boot_record_set_image_ok(void);

#ifdef __cplusplus
}
#endif

#endif                                 /* BOOT_RECORD_WRITE_H */