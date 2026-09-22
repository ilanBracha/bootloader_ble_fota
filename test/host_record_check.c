/* Host-side check: recompute the boot record CRC with the target implementation and compare with the stored value.
 *
 * usage: host_record_check <record.bin>
 */
#include <stdio.h>
#include "../src/boot_record.c"

int main (int argc, char ** argv)
{
    if (argc < 2)
    {
        printf("usage: %s <record.bin>\n", argv[0]);
        return 2;
    }

    FILE * f = fopen(argv[1], "rb");
    if (NULL == f)
    {
        printf("cannot open %s\n", argv[1]);
        return 2;
    }

    uint8_t buf[BOOT_RECORD_SIZE];
    size_t  n = fread(buf, 1, sizeof(buf), f);
    fclose(f);

    if (BOOT_RECORD_SIZE != n)
    {
        printf("FAIL: expected %u bytes, got %u\n", (unsigned) BOOT_RECORD_SIZE, (unsigned) n);
        return 1;
    }

    boot_record_t * p   = (boot_record_t *) buf;
    uint16_t        crc = boot_record_crc16(buf, BOOT_RECORD_CRC_LENGTH);

    int ok = ((BOOT_RECORD_MAGIC == p->magic) && (BOOT_RECORD_VERSION == p->version) && (crc == p->crc16));

    printf("sizeof(boot_record_t)=%u magic=%08X version=%u swap_type=%u copy_done=%u image_ok=%u sequence=%u "
           "crc32_staged=%08X crc32_primary=%08X stored_crc=%04X calc_crc=%04X -> %s\n",
           (unsigned) sizeof(boot_record_t), (unsigned) p->magic, p->version, p->swap_type, p->copy_done,
           p->image_ok, (unsigned) p->sequence, (unsigned) p->crc32_staged, (unsigned) p->crc32_primary, p->crc16,
           crc, ok ? "OK" : "FAIL");

    return ok ? 0 : 1;
}
