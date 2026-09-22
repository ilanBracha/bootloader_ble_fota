/***********************************************************************************************************************
 * Boot record access (read only side, used by the bootloader).
 **********************************************************************************************************************/

#ifndef BOOT_RECORD_H
#define BOOT_RECORD_H

#include <stdbool.h>
#include <stdint.h>
#include "boot_layout.h"

#ifdef __cplusplus
extern "C" {
#endif

/** CRC16-CCITT (poly 0x1021, init 0xFFFF) used to protect the boot record. */
uint16_t boot_record_crc16(const uint8_t * p_data, uint32_t length);

/** Copies the record out of data flash. Returns true when magic, version and CRC all check out. */
bool boot_record_read(boot_record_t * p_record);

/** Fills @p p_record with the defaults used when the stored record is blank, corrupt or an older version. */
void boot_record_defaults(boot_record_t * p_record);

/** Swap intent for this boot (boot_swap_type_t). Returns BOOT_SWAP_TYPE_NONE for a blank/corrupt record. */
uint8_t boot_record_swap_type(void);

/** True when a swap was started but never completed, so it has to be resumed. */
bool boot_record_swap_in_progress(void);

/** True when a completed TEST swap was never confirmed by the image it installed, so it must be swapped back. */
bool boot_record_revert_pending(void);

/** Reference CRC32 recorded when the swap was armed, or BOOT_CRC32_UNSET when there is nothing to verify against. */
uint32_t boot_record_staged_crc(void);

#ifdef __cplusplus
}
#endif

#endif                                 /* BOOT_RECORD_H */
