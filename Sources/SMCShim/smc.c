/*
 * smc.c — AppleSMC IOKit implementation for MacFanControl.
 * Verified on Apple M5 Max, macOS 26.4. See memory/MEMORY.md for the
 * full list of M5-specific quirks (mode latch, clobber interval, etc).
 */

#include "SMCShim.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>

/* ---- Canonical SMC constants (hholtmann/smcFanControl) ---- */

#define KERNEL_INDEX_SMC        2

#define SMC_CMD_READ_BYTES      5
#define SMC_CMD_WRITE_BYTES     6
#define SMC_CMD_READ_INDEX      8
#define SMC_CMD_READ_KEYINFO    9

typedef char              SMCBytes_t[32];

typedef struct {
    char            major;
    char            minor;
    char            build;
    char            reserved[1];
    uint16_t        release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t        version;
    uint16_t        length;
    uint32_t        cpuPLimit;
    uint32_t        gpuPLimit;
    uint32_t        memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t        dataSize;
    uint32_t        dataType;
    uint8_t         dataAttributes;
} SMCKeyData_keyInfo_t;

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

/* ---- FourCC ---- */

uint32_t smc_fourcc(const char *s) {
    if (!s) return 0;
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] <<  8) |
           ((uint32_t)(uint8_t)s[3]);
}

void smc_fourcc_to_str(uint32_t key, char out[5]) {
    out[0] = (char)((key >> 24) & 0xff);
    out[1] = (char)((key >> 16) & 0xff);
    out[2] = (char)((key >>  8) & 0xff);
    out[3] = (char)((key      ) & 0xff);
    out[4] = '\0';
}

/* ---- Connection ---- */

static io_connect_t g_conn = 0;

int smc_open(void) {
    if (g_conn != 0) return 0;
    io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return (kr == KERN_SUCCESS) ? 0 : -2;
}

void smc_close(void) {
    if (g_conn) {
        IOServiceClose(g_conn);
        g_conn = 0;
    }
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    if (!g_conn) return KERN_FAILURE;
    size_t inSize = sizeof(*in);
    size_t outSize = sizeof(*out);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                     in, inSize, out, &outSize);
}

/* ---- Read primitives ---- */

bool smc_read_keyinfo(uint32_t key, uint32_t *outSize, uint32_t *outType) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS) return false;
    if (out.result != 0) return false;
    if (outSize) *outSize = out.keyInfo.dataSize;
    if (outType) *outType = out.keyInfo.dataType;
    return true;
}

bool smc_read_bytes(uint32_t key, uint32_t size, uint8_t outBytes[32]) {
    if (size == 0 || size > 32) return false;
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != KERN_SUCCESS) return false;
    if (out.result != 0) return false;
    memcpy(outBytes, out.bytes, 32);
    return true;
}

bool smc_read_key(uint32_t key, uint32_t *outSize, uint32_t *outType,
                  uint8_t outData[32]) {
    uint32_t size = 0, type = 0;
    if (!smc_read_keyinfo(key, &size, &type)) return false;
    if (size == 0 || size > 32) return false;
    if (!smc_read_bytes(key, size, outData)) return false;
    if (outSize) *outSize = size;
    if (outType) *outType = type;
    return true;
}

uint32_t smc_key_count(void) {
    uint32_t size = 0, type = 0;
    uint8_t buf[32] = {0};
    if (!smc_read_key(smc_fourcc("#KEY"), &size, &type, buf)) return 0;
    uint64_t v = 0;
    if (!smc_decode_ui(buf, size, &v)) return 0;
    return (uint32_t)v;
}

uint32_t smc_key_at_index(uint32_t index) {
    SMCKeyData_t in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    if (smc_call(&in, &out) != KERN_SUCCESS) return 0;
    if (out.result != 0) return 0;
    return out.key;
}

/* ---- Write primitives ---- */

bool smc_write_flt(uint32_t key, float value) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = 4;
    in.keyInfo.dataType = smc_fourcc("flt ");
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, &value, 4);
    if (smc_call(&in, &out) != KERN_SUCCESS) return false;
    return out.result == 0;
}

bool smc_write_u8(uint32_t key, uint8_t value) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = 1;
    in.keyInfo.dataType = smc_fourcc("ui8 ");
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.bytes[0] = value;
    if (smc_call(&in, &out) != KERN_SUCCESS) return false;
    return out.result == 0;
}

/* ---- Decoders ---- */

bool smc_decode_flt(const uint8_t *bytes, uint32_t size, double *out) {
    if (size != 4) return false;
    float f;
    memcpy(&f, bytes, 4);
    *out = (double)f;
    return true;
}

bool smc_decode_fpe2(const uint8_t *bytes, uint32_t size, double *out) {
    if (size != 2) return false;
    uint16_t v = ((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1];
    *out = (double)(v >> 2);
    return true;
}

bool smc_decode_sp78(const uint8_t *bytes, uint32_t size, double *out) {
    if (size != 2) return false;
    int16_t v = (int16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
    *out = (double)v / 256.0;
    return true;
}

bool smc_decode_ui(const uint8_t *bytes, uint32_t size, uint64_t *out) {
    if (size == 0 || size > 8) return false;
    uint64_t v = 0;
    for (uint32_t i = 0; i < size; i++) v = (v << 8) | bytes[i];
    *out = v;
    return true;
}

bool smc_decode_si(const uint8_t *bytes, uint32_t size, int64_t *out) {
    if (size == 0 || size > 8) return false;
    uint64_t v = 0;
    for (uint32_t i = 0; i < size; i++) v = (v << 8) | bytes[i];
    uint64_t sign = (uint64_t)1 << (size * 8 - 1);
    if (v & sign) v |= ~((sign << 1) - 1);
    *out = (int64_t)v;
    return true;
}
