/***********************************************************************************************************************
 * Hand-off to the application in the primary slot.
 **********************************************************************************************************************/

#include "bsp_api.h"
#include "boot_layout.h"
#include "boot_jump.h"

/** Number of NVIC ICER/ICPR registers to clear (covers all Cortex-M33 external interrupts). */
#define BOOT_NVIC_REG_COUNT          (8U)

/***********************************************************************************************************************
 * Hands control over to the application in the primary slot. Does not return.
 **********************************************************************************************************************/
void boot_jump_to_primary (void)
{
    uint32_t                  base   = BOOT_PRIMARY_BASE;
    const volatile uint32_t * p_vect = (const volatile uint32_t *) base;

    uint32_t sp = p_vect[BOOT_VECTOR_INITIAL_SP];
    uint32_t pc = p_vect[BOOT_VECTOR_RESET_HANDLER];

    /* Leave the core in a reset-like state for the application. */
    __disable_irq();

    SysTick->CTRL = 0U;
    SysTick->LOAD = 0U;
    SysTick->VAL  = 0U;

    for (uint32_t i = 0U; i < BOOT_NVIC_REG_COUNT; i++)
    {
        NVIC->ICER[i] = 0xFFFFFFFFU;
        NVIC->ICPR[i] = 0xFFFFFFFFU;
    }

    __DSB();
    __ISB();

    /* Retarget the vector table. The application startup code sets VTOR again to the same value. */
    SCB->VTOR = base;
    __DSB();
    __ISB();

#if defined(__ARM_ARCH_8M_MAIN__) || defined(__ARM_ARCH_8M_BASE__) || defined(__ARM_ARCH_8_1M_MAIN__)

    /* Remove the stack limit inherited from the bootloader before moving the stack pointer. */
    __set_MSPLIM(0U);
#endif

    __set_CONTROL(0U);
    __ISB();

    __enable_irq();

    /* Switch stacks and branch in one step so nothing touches the old stack afterwards. */
    __asm volatile ("mov sp, %0\n"
                    "bx  %1\n"
                    :
                    : "r" (sp), "r" (pc)
                    : "memory");

    /* Not reached. */
    while (1)
    {
        ;
    }
}