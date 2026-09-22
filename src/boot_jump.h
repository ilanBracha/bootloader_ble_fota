/***********************************************************************************************************************
 * Hand-off to the application in the primary slot.
 *
 * With the swap layout there is only one execution address, so there is no slot argument: whatever currently sits at
 * BOOT_PRIMARY_BASE is what runs.
 **********************************************************************************************************************/

#ifndef BOOT_JUMP_H
#define BOOT_JUMP_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Never returns: de-initialises the core, retargets VTOR/MSP and branches to the primary slot's reset handler. */
void boot_jump_to_primary(void);

#ifdef __cplusplus
}
#endif

#endif                                 /* BOOT_JUMP_H */
