/*
 * restore_fpst.c — tiny fix-up: write FPSt = 3 to restore the fan
 * driver's normal power state after a probe left it at 0.
 * Also attempts to re-seed F0Tg / F1Tg = F0Mn so thermalmonitord has
 * a sensible starting point.
 */
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#define KERNEL_INDEX_SMC        2
#define SMC_CMD_READ_BYTES      5
#define SMC_CMD_WRITE_BYTES     6
#define SMC_CMD_READ_KEYINFO    9

typedef char              SMCBytes_t[32];
typedef struct { char a,b,c,d; uint16_t e; } SMCKeyData_vers_t;
typedef struct { uint16_t a,b; uint32_t c,d,e; } SMCKeyData_pLimitData_t;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    uint32_t                  key;
    SMCKeyData_vers_t         vers;
    SMCKeyData_pLimitData_t   pLimitData;
    SMCKeyData_keyInfo_t      keyInfo;
    uint8_t                   result;
    uint8_t                   status;
    uint8_t                   data8;
    uint32_t                  data32;
    SMCBytes_t                bytes;
} SMCKeyData_t;

static uint32_t FOURCC(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] <<  8) | ((uint32_t)(uint8_t)s[3]);
}

static io_connect_t g_conn = 0;

static kern_return_t call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t inSize = sizeof(*in), outSize = sizeof(*out);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, inSize, out, &outSize);
}

static int read_primed(uint32_t key, uint8_t buf[32], uint32_t *outSize) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.data8 = SMC_CMD_READ_KEYINFO;
    if (call(&in, &out) != KERN_SUCCESS || out.result) return 0;
    uint32_t size = out.keyInfo.dataSize;
    SMCKeyData_t in2 = {0}, out2 = {0};
    in2.key = key; in2.keyInfo.dataSize = size; in2.data8 = SMC_CMD_READ_BYTES;
    if (call(&in2, &out2) != KERN_SUCCESS || out2.result) return 0;
    memcpy(buf, out2.bytes, 32);
    if (outSize) *outSize = size;
    return 1;
}

static int write_u8(uint32_t key, uint8_t val) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.keyInfo.dataSize = 1; in.keyInfo.dataType = FOURCC("ui8 ");
    in.data8 = SMC_CMD_WRITE_BYTES; in.bytes[0] = val;
    if (call(&in, &out) != KERN_SUCCESS) return 0;
    return out.result == 0;
}

static int write_flt(uint32_t key, float val) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.keyInfo.dataSize = 4; in.keyInfo.dataType = FOURCC("flt ");
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, &val, 4);
    if (call(&in, &out) != KERN_SUCCESS) return 0;
    return out.result == 0;
}

int main(void) {
    io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr, "no AppleSMC\n"); return 1; }
    if (IOServiceOpen(svc, mach_task_self(), 0, &g_conn) != KERN_SUCCESS) {
        fprintf(stderr, "open failed\n"); IOObjectRelease(svc); return 1;
    }
    IOObjectRelease(svc);

    uint8_t buf[32] = {0}; uint32_t sz;

    /* before */
    read_primed(FOURCC("FPSt"), buf, &sz);
    fprintf(stderr, "FPSt before = %u\n", buf[0]);

    /* restore FPSt to 3 */
    fprintf(stderr, "writing FPSt = 3 ...\n");
    if (!write_u8(FOURCC("FPSt"), 3)) fprintf(stderr, "  FAILED\n");
    usleep(200*1000);
    read_primed(FOURCC("FPSt"), buf, &sz);
    fprintf(stderr, "FPSt after = %u\n", buf[0]);

    /* seed F0Tg and F1Tg to Mn so they aren't stuck at 0 */
    float f0mn = 0, f1mn = 0;
    read_primed(FOURCC("F0Mn"), buf, &sz); memcpy(&f0mn, buf, 4);
    read_primed(FOURCC("F1Mn"), buf, &sz); memcpy(&f1mn, buf, 4);
    fprintf(stderr, "F0Mn=%.0f F1Mn=%.0f ; seeding Tg = Mn\n", (double)f0mn, (double)f1mn);
    write_flt(FOURCC("F0Tg"), f0mn);
    write_flt(FOURCC("F1Tg"), f1mn);

    /* make sure both are in auto mode */
    write_u8(FOURCC("F0md"), 0);
    write_u8(FOURCC("F1md"), 0);
    usleep(500*1000);

    /* final readout */
    read_primed(FOURCC("F0Ac"), buf, &sz); float f0ac; memcpy(&f0ac, buf, 4);
    read_primed(FOURCC("F1Ac"), buf, &sz); float f1ac; memcpy(&f1ac, buf, 4);
    read_primed(FOURCC("F0Tg"), buf, &sz); float f0tg; memcpy(&f0tg, buf, 4);
    read_primed(FOURCC("F1Tg"), buf, &sz); float f1tg; memcpy(&f1tg, buf, 4);
    fprintf(stderr, "AFTER: F0Ac=%.0f F0Tg=%.0f F1Ac=%.0f F1Tg=%.0f\n",
            (double)f0ac, (double)f0tg, (double)f1ac, (double)f1tg);

    IOServiceClose(g_conn);
    return 0;
}
