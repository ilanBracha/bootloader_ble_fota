/***********************************************************************************************************************
 * Slot swap engine - exchanges the primary and secondary slots through the scratch area.
 *
 * The application always executes from the primary slot, so a new image staged in the secondary slot has to be
 * physically moved before it can run. Each sector is exchanged in three legs:
 *
 *      leg 0:  scratch          <- secondary[sector]
 *      leg 1:  secondary[sector] <- primary[sector]
 *      leg 2:  primary[sector]  <- scratch
 *
 * After each leg a 4 byte entry is appended to the data flash log, so a power cut is resumed from the first
 * unfinished leg rather than restarting the whole exchange. The source of every leg stays intact until the leg
 * after it has completed, which is what makes a repeated (interrupted) leg harmless.
 *
 * VERIFICATION
 *
 * A successful return from the flash driver says the controller accepted the operation, not that the destination now
 * holds the bytes that were meant to land there. So the staged image is fingerprinted with a CRC32 at the moment the
 * swap is armed - before anything moves - and that value is written into the boot record. Once the last leg is done
 * the primary slot is measured the same way and the two are compared.
 *
 * Taking the reference at arm time, and keeping it in flash rather than in RAM, is what makes the check survive an
 * interrupted swap: a swap resumed on a later boot is still verified against the image as it was originally staged.
 * A mismatch is reported as BOOT_SWAP_RESULT_CRC_FAIL.
 **********************************************************************************************************************/

#ifndef BOOT_SWAP_H
#define BOOT_SWAP_H

#include <stdint.h>
#include <stdbool.h>
#include "hal_data.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Outcome of boot_swap_process(). */
typedef enum e_boot_swap_result
{
    BOOT_SWAP_RESULT_NONE = 0,         ///< Nothing to do
    BOOT_SWAP_RESULT_DONE,             ///< A swap was carried out (or resumed) and completed
    BOOT_SWAP_RESULT_REVERTED,         ///< A trial image never confirmed itself; the previous image was put back
    BOOT_SWAP_RESULT_ERROR,            ///< A flash operation failed; the log still describes where it stopped
    BOOT_SWAP_RESULT_CRC_FAIL,         ///< Every leg reported success but the primary slot does not match the
                                       ///< fingerprint taken when the swap was armed
} boot_swap_result_t;

/***********************************************************************************************************************
 * Trial boot (BOOT_SWAP_TYPE_TEST)
 *
 * A TEST swap installs the staged image and leaves the record at swap_type = REVERT, image_ok = 0. The new image is
 * then expected to prove itself and send BOOT_CMD_CONFIRM, which clears that state. If it does not - because it
 * crashed, hung until the watchdog fired, or simply never got that far - the next reset finds the unconfirmed flag
 * and boot_swap_process() runs the exchange a second time, putting the previous image back where it was.
 *
 * The revert costs no extra code: the exchange is symmetric and the previous image is still sitting in the secondary
 * slot, exactly where the first swap left it.
 **********************************************************************************************************************/

/***********************************************************************************************************************
 * Stages a swap: validates the secondary slot, then records the intent and clears the progress log.
 *
 * Does NOT move any data - the exchange itself happens in boot_swap_process(), which also handles the case where
 * this board was reset in the middle of a previous attempt.
 **********************************************************************************************************************/
fsp_err_t boot_swap_start(uint8_t swap_type);

/** Performs or resumes a pending swap. Safe (and cheap) to call on every boot. */
boot_swap_result_t boot_swap_process(void);

/** Number of swap legs already completed according to the data flash log (0 .. BOOT_SWAP_STEP_COUNT). */
uint32_t boot_swap_log_count(void);

#ifdef __cplusplus
}
#endif

#endif                                 /* BOOT_SWAP_H */
