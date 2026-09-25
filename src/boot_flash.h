/***********************************************************************************************************************
 * Flash access helpers for the bootloader.
 *
 * Wraps the generated r_flash_hp instance (g_flash0) so the swap engine does not have to care about:
 *   - code flash having two erase regions with different block sizes (8 KB below 0x10000, 32 KB above),
 *   - the 128 byte code flash / 4 byte data flash minimum write units,
 *   - copying flash to flash, which has to be staged through a RAM buffer.
 *
 * IMPORTANT: the FSP flash driver can only program code flash when FLASH_HP_CFG_CODE_FLASH_PROGRAMMING_ENABLE is 1
 * (configurator: g_flash0 -> Code Flash Programming -> Enabled). With that option the driver functions are placed in
 * RAM (.ram_from_flash) automatically, which is what makes it legal to erase code flash while running from it.
 *
 * The instance is opened lazily and stays open until boot_flash_close() is called just before the jump, so nested
 * operations (record write during a swap) cannot close the driver underneath each other.
 **********************************************************************************************************************/

#ifndef BOOT_FLASH_H
#define BOOT_FLASH_H

#include <stdint.h>
#include <stdbool.h>
#include "hal_data.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Opens the flash instance if it is not already open. Safe to call repeatedly. */
fsp_err_t boot_flash_open(void);

/** Closes the flash instance if it is open. Call once, immediately before handing over to the application. */
void boot_flash_close(void);

/** Erases @p bytes starting at @p address, working out the block count from the erase region. */
fsp_err_t boot_flash_erase(uint32_t address, uint32_t bytes);

/** Programs @p bytes from the RAM buffer @p p_src to @p dest. @p bytes must be a multiple of the write unit. */
fsp_err_t boot_flash_write(uint32_t dest, const void * p_src, uint32_t bytes);

/** Erases @p bytes at @p dest and copies @p bytes of flash from @p src into it, staging through a RAM buffer. */
fsp_err_t boot_flash_copy(uint32_t dest, uint32_t src, uint32_t bytes);

/** Appends one 4 byte entry to the data flash swap log. The block must already be erased at that offset. */
fsp_err_t boot_flash_log_write(uint32_t address, uint32_t value);

/***********************************************************************************************************************
 * FCU blank check of a DATA FLASH range. @p p_blank is set true only when the FCU reports the whole range erased.
 *
 * WHY THIS EXISTS: on FLASH_HP parts the value READ from an erased data flash cell is UNDEFINED (RA6E2 HW manual,
 * data flash section). It is not 0xFF, and in practice it is cell specific and can still look like the value that
 * was programmed there before the erase. A memory-mapped read can therefore never tell "erased" from "programmed" -
 * only the FCU blank check can. Anything that decides based on "is this entry written?" must use this.
 **********************************************************************************************************************/
fsp_err_t boot_flash_df_blank(uint32_t address, uint32_t bytes, bool * p_blank);

/** CRC32 (reflected, poly 0xEDB88320, init 0xFFFFFFFF, final xor) over a directly readable flash range. */
uint32_t boot_crc32(uint32_t address, uint32_t length);

#ifdef __cplusplus
}
#endif

#endif                                 /* BOOT_FLASH_H */
