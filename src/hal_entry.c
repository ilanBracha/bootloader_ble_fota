/*
* Copyright (c) 2020 - 2026 Renesas Electronics Corporation and/or its affiliates
*
* SPDX-License-Identifier: BSD-3-Clause
*/

/*
 * OTA bootloader entry point.
 *
 * Runs from 0x00000000 (see src/boot_layout.h). The application always executes from the primary slot, so this code
 * does not choose between images - it makes sure the right image IS the primary slot, then hands over.
 *
 * On every boot:
 *   1. Apply a pending request from the RAM mailbox (a swap is validated and recorded, never applied blindly).
 *   2. Perform or RESUME the sector exchange described by the boot record. A power cut during a swap is picked up
 *      here on the next boot and continued from the first unfinished leg. This step also REVERTS a trial image
 *      that was installed but never confirmed itself.
 *   3. Sanity check the primary slot and jump to it.
 */

#include "hal_data.h"
#include "boot_layout.h"
#include "boot_record.h"
#include "boot_record_write.h"
#include "boot_mailbox.h"
#include "boot_flash.h"
#include "boot_swap.h"
#include "boot_jump.h"

static void boot_fatal(void);
static void boot_process_mailbox(void);
static void boot_process_swap(void);

/** Outcome of this boot, reported back to the application through the mailbox. */
static uint8_t g_boot_status = BOOT_STATUS_OK;
static uint8_t g_boot_req    = BOOT_CMD_NOT_REQUESTED;

/*******************************************************************************************************************//**
 * @brief  Bootloader main.
 **********************************************************************************************************************/
void hal_entry (void)
{
    boot_process_mailbox();
    boot_process_swap();

    /* The flash driver must not be left open across the hand-off. */
    boot_flash_close();

    if (!boot_primary_image_ok())
    {
        boot_mailbox_set_ack(BOOT_STATUS_ERR_IMAGE, g_boot_req, 0U);
        boot_fatal();
    }

    boot_mailbox_set_ack(g_boot_status, g_boot_req, (uint8_t) boot_swap_log_count());

    boot_jump_to_primary();

    /* boot_jump_to_primary() does not return. */
    boot_fatal();
}

/*******************************************************************************************************************//**
 * @brief  Applies a pending request left by the application in the RAM mailbox.
 *
 * The application cannot write the boot record or move images; it only fills this mailbox and resets. A swap request
 * is validated here - if the secondary slot does not hold a usable image the request is rejected and nothing is
 * touched, so a bad request can never strand the product.
 *
 * The request is cleared so it runs exactly once; the outcome is reported later by hal_entry().
 **********************************************************************************************************************/
static void boot_process_mailbox (void)
{
    if (!boot_mailbox_pending())
    {
        return;
    }

    volatile boot_mailbox_t * p_mail = &BOOT_MAILBOX;

    uint8_t command = p_mail->command;
    uint8_t arg     = p_mail->arg;

    g_boot_req = command;

    if (BOOT_CMD_SWAP == command)
    {
        uint8_t swap_type = ((uint8_t) BOOT_SWAP_TYPE_TEST == arg) ? (uint8_t) BOOT_SWAP_TYPE_TEST
                                                                   : (uint8_t) BOOT_SWAP_TYPE_PERM;

        fsp_err_t err = boot_swap_start(swap_type);

        if (FSP_ERR_INVALID_DATA == err)
        {
            g_boot_status = BOOT_STATUS_ERR_IMAGE;
        }
        else if (FSP_SUCCESS != err)
        {
            g_boot_status = BOOT_STATUS_ERR_WRITE;
        }
    }
    else if (BOOT_CMD_CONFIRM == command)
    {
        if (!boot_record_revert_pending())
        {
            /* Nothing is on trial, so the running image is already permanent. Report success without burning a
             * data flash erase cycle on a record that would not change. */
            g_boot_status = BOOT_STATUS_CONFIRMED;
        }
        else
        {
            g_boot_status = (FSP_SUCCESS == boot_record_set_image_ok()) ? BOOT_STATUS_CONFIRMED
                                                                        : BOOT_STATUS_ERR_WRITE;
        }
    }
    else
    {
        g_boot_status = BOOT_STATUS_ERR_REQUEST;
        g_boot_req    = BOOT_CMD_NOT_REQUESTED;
    }

    boot_mailbox_clear();
}

/*******************************************************************************************************************//**
 * @brief  Carries out, or resumes, the sector exchange the boot record asks for.
 **********************************************************************************************************************/
static void boot_process_swap (void)
{
    boot_swap_result_t result = boot_swap_process();

    if (BOOT_SWAP_RESULT_DONE == result)
    {
        /* Do not mask an earlier rejection with a success from a resumed swap. */
        if ((BOOT_STATUS_OK == g_boot_status) || (BOOT_STATUS_CONFIRMED == g_boot_status))
        {
            g_boot_status = BOOT_STATUS_SWAPPED;
        }
    }
    else if (BOOT_SWAP_RESULT_REVERTED == result)
    {
        /* A revert always wins the report: it is the most important thing that happened this boot. */
        g_boot_status = BOOT_STATUS_REVERTED;
    }
    else if (BOOT_SWAP_RESULT_ERROR == result)
    {
        g_boot_status = BOOT_STATUS_ERR_SWAP;
    }
    else if (BOOT_SWAP_RESULT_CRC_FAIL == result)
    {
        /* The exchange finished but the primary slot does not match the image that was staged. Report it and carry
         * on: hal_entry() still validates the primary slot before jumping, and a trial swap that installed a broken
         * image will fail to confirm and be reverted on the next reset. */
        g_boot_status = BOOT_STATUS_ERR_CRC;
    }
    else
    {
        /* Nothing staged. */
    }
}

/*******************************************************************************************************************//**
 * @brief  No bootable image found. Trap so a debugger can be attached.
 **********************************************************************************************************************/
static void boot_fatal (void)
{
    __disable_irq();

    while (1)
    {
        __NOP();
    }
}
