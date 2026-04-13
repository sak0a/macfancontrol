/*
 * smc_dump.c — Phase 0 spike
 *
 * Opens the AppleSMC user client, enumerates every key via #KEY +
 * SMC_CMD_READ_INDEX, and prints each key's FourCC, dataType, size,
 * and a best-effort decoded value. Used to answer:
 *
 *   1. Does the canonical SMCKeyData_t IOKit pattern work on M5 Max /
 *      macOS 26.4?
 *   2. Which fan keys exist (FNum, F%dAc, F%dMn, F%dMx, F%dTg, F%dMd, ...)?
 *   3. What dataType do fan keys report — 'flt ' (float) or 'fpe2'?
 *   4. Which T* temperature keys does M5 Max expose via SMC?
 *
 * Runs as normal user (reads only). Build:
 *   clang -O2 -Wall -framework IOKit -framework CoreFoundation \
 *       spike/smc_dump.c -o /tmp/smc_dump
 */

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

/* ---- Canonical SMC constants (hholtmann/smcFanControl) ---- */

#define KERNEL_INDEX_SMC        2

#define SMC_CMD_READ_BYTES      5
#define SMC_CMD_WRITE_BYTES     6
#define SMC_CMD_READ_INDEX      8
#define SMC_CMD_READ_KEYINFO    9
#define SMC_CMD_READ_PLIMIT     11
#define SMC_CMD_READ_VERS       12

typedef char              SMCBytes_t[32];
typedef char              UInt32Char_t[5];

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

/* ---- FourCC helpers (big-endian in the wire/struct) ---- */

static uint32_t fourcc(const char s[4]) {
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] <<  8) |
           ((uint32_t)(uint8_t)s[3]);
}

static void fourcc_to_str(uint32_t v, char out[5]) {
    out[0] = (char)((v >> 24) & 0xff);
    out[1] = (char)((v >> 16) & 0xff);
    out[2] = (char)((v >>  8) & 0xff);
    out[3] = (char)((v      ) & 0xff);
    out[4] = '\0';
}

/* ---- SMC connection ---- */

static io_connect_t g_conn = 0;

static kern_return_t smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(
        0, /* kIOMainPortDefault (0 is the documented wildcard) */
        IOServiceMatching("AppleSMC"));
    if (!service) {
        fprintf(stderr, "AppleSMC service not found\n");
        return KERN_FAILURE;
    }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &g_conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "IOServiceOpen failed: 0x%x\n", kr);
    }
    return kr;
}

static void smc_close(void) {
    if (g_conn) {
        IOServiceClose(g_conn);
        g_conn = 0;
    }
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t inSize = sizeof(*in);
    size_t outSize = sizeof(*out);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                     in, inSize, out, &outSize);
}

static kern_return_t smc_read_keyinfo(uint32_t key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return KERN_FAILURE;
    *info = out.keyInfo;
    return KERN_SUCCESS;
}

static kern_return_t smc_read_bytes(uint32_t key, uint32_t size,
                                    uint8_t buf[32]) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return KERN_FAILURE;
    memcpy(buf, out.bytes, 32);
    return KERN_SUCCESS;
}

static kern_return_t smc_read_index(uint32_t index, uint32_t *keyOut) {
    SMCKeyData_t in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return KERN_FAILURE;
    *keyOut = out.key;
    return KERN_SUCCESS;
}

/* ---- Decoders ---- */

static int decode_flt(const uint8_t *b, uint32_t size, double *out) {
    if (size != 4) return 0;
    /* 'flt ' on arm64 is little-endian IEEE 754 single */
    float f;
    memcpy(&f, b, 4);
    *out = (double)f;
    return 1;
}

static int decode_fpe2(const uint8_t *b, uint32_t size, double *out) {
    /* fpe2: 2-byte big-endian 14.2 fixed-point */
    if (size != 2) return 0;
    uint16_t v = ((uint16_t)b[0] << 8) | (uint16_t)b[1];
    *out = (double)(v >> 2);
    return 1;
}

static int decode_sp78(const uint8_t *b, uint32_t size, double *out) {
    /* sp78: signed 8.8 fixed-point big-endian (common for temps) */
    if (size != 2) return 0;
    int16_t v = (int16_t)(((uint16_t)b[0] << 8) | (uint16_t)b[1]);
    *out = (double)v / 256.0;
    return 1;
}

static int decode_ui(const uint8_t *b, uint32_t size, uint64_t *out) {
    if (size == 0 || size > 8) return 0;
    uint64_t v = 0;
    /* SMC uiNN are big-endian */
    for (uint32_t i = 0; i < size; i++) v = (v << 8) | b[i];
    *out = v;
    return 1;
}

static int decode_si(const uint8_t *b, uint32_t size, int64_t *out) {
    if (size == 0 || size > 8) return 0;
    uint64_t v = 0;
    for (uint32_t i = 0; i < size; i++) v = (v << 8) | b[i];
    /* sign-extend */
    uint64_t sign = (uint64_t)1 << (size * 8 - 1);
    if (v & sign) v |= ~((sign << 1) - 1);
    *out = (int64_t)v;
    return 1;
}

static void print_value(uint32_t dataType, uint32_t size, const uint8_t *b) {
    char tstr[5]; fourcc_to_str(dataType, tstr);

    if (dataType == fourcc("flt ")) {
        double d; if (decode_flt(b, size, &d)) { printf("%.3f", d); return; }
    }
    if (dataType == fourcc("fpe2")) {
        double d; if (decode_fpe2(b, size, &d)) { printf("%.2f", d); return; }
    }
    if (dataType == fourcc("sp78")) {
        double d; if (decode_sp78(b, size, &d)) { printf("%.2f", d); return; }
    }
    if (dataType == fourcc("ui8 ") || dataType == fourcc("ui16") ||
        dataType == fourcc("ui32")) {
        uint64_t u; if (decode_ui(b, size, &u)) { printf("%llu", (unsigned long long)u); return; }
    }
    if (dataType == fourcc("si8 ") || dataType == fourcc("si16") ||
        dataType == fourcc("si32")) {
        int64_t s; if (decode_si(b, size, &s)) { printf("%lld", (long long)s); return; }
    }
    if (dataType == fourcc("flag")) {
        printf("%s", b[0] ? "true" : "false"); return;
    }
    if (dataType == fourcc("ch8*")) {
        int printable = 1;
        for (uint32_t i = 0; i < size; i++) {
            if (b[i] == 0) break;
            if (b[i] < 0x20 || b[i] > 0x7e) { printable = 0; break; }
        }
        if (printable) {
            printf("\"");
            for (uint32_t i = 0; i < size && b[i]; i++) putchar(b[i]);
            printf("\"");
            return;
        }
    }
    /* raw hex */
    printf("0x");
    for (uint32_t i = 0; i < size; i++) printf("%02x", b[i]);
}

/* ---- main ---- */

int main(void) {
    if (smc_open() != KERN_SUCCESS) return 1;

    /* #KEY -> ui32 key count */
    uint8_t buf[32] = {0};
    SMCKeyData_keyInfo_t nkeyInfo;
    if (smc_read_keyinfo(fourcc("#KEY"), &nkeyInfo) != KERN_SUCCESS) {
        fprintf(stderr, "failed to read #KEY info\n"); smc_close(); return 1;
    }
    if (smc_read_bytes(fourcc("#KEY"), nkeyInfo.dataSize, buf) != KERN_SUCCESS) {
        fprintf(stderr, "failed to read #KEY bytes\n"); smc_close(); return 1;
    }
    uint64_t nkeys = 0;
    decode_ui(buf, nkeyInfo.dataSize, &nkeys);
    printf("#KEY = %llu\n", (unsigned long long)nkeys);
    printf("%-6s %-6s %-5s %s\n", "KEY", "TYPE", "SIZE", "VALUE");

    int fans = 0, temps = 0;
    for (uint32_t i = 0; i < (uint32_t)nkeys; i++) {
        uint32_t key = 0;
        if (smc_read_index(i, &key) != KERN_SUCCESS) continue;

        SMCKeyData_keyInfo_t info;
        if (smc_read_keyinfo(key, &info) != KERN_SUCCESS) continue;
        if (info.dataSize == 0 || info.dataSize > 32) continue;

        uint8_t data[32] = {0};
        kern_return_t kr = smc_read_bytes(key, info.dataSize, data);
        if (kr != KERN_SUCCESS) continue;

        char kstr[5]; fourcc_to_str(key, kstr);
        char tstr[5]; fourcc_to_str(info.dataType, tstr);

        /* Filter: show F*, T*, #KEY is already printed, show also Ftst */
        int show = (kstr[0] == 'F' || kstr[0] == 'T' || kstr[0] == '#');
        if (!show) continue;

        printf("%-6s %-6s %-5u ", kstr, tstr, info.dataSize);
        print_value(info.dataType, info.dataSize, data);
        printf("\n");

        if (kstr[0] == 'F') fans++;
        if (kstr[0] == 'T') temps++;
    }

    printf("\n-- summary: %d fan-prefix keys, %d temperature-prefix keys\n",
           fans, temps);

    smc_close();
    return 0;
}
