/*
 * fan_write_probe2.c — Phase 0 refinement
 *
 * v1 established that F0md=1 + F0Tg write physically ramps the fan on M5 Max.
 * v1 also showed F0Tg auto-flipping from 3500 -> 7826 one second after the
 * write, and F0Ac converging to ~6839 (near Mx).
 *
 * Two hypotheses to distinguish:
 *   H1: F0md=1 means "force max speed"; the written F0Tg is ignored.
 *       -> Fan will always go to Mx regardless of what we keep writing.
 *   H2: F0md=1 means "manual target"; something (thermalmonitord or the
 *       fan controller) clobbers F0Tg after ~1s if we don't keep refreshing.
 *       -> Tight-loop re-writing F0Tg should keep it at 3500 and the fan
 *          should converge to 3500, not 7826.
 *
 * v2 also fixes the broken reads from v1: always call SMC_CMD_READ_KEYINFO
 * before SMC_CMD_READ_BYTES (v1 returned 0 because the driver needs the
 * keyinfo round trip to prime each key).
 *
 * Strategy:
 *   1. snapshot original state (with proper reads)
 *   2. write F0md = 1
 *   3. write F0Tg = 3500 repeatedly every 200ms for 8 seconds
 *      logging F0Tg, F0Ac, F0md every loop
 *   4. restore
 *
 * Safety cap 3500 rpm. atexit + SIGINT/SIGTERM restore.
 */

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
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
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] <<  8) |
           ((uint32_t)(uint8_t)s[3]);
}

static io_connect_t g_conn = 0;

static kern_return_t smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"));
    if (!svc) return KERN_FAILURE;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return kr;
}
static void smc_close(void) { if (g_conn) { IOServiceClose(g_conn); g_conn = 0; } }

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t inSize = sizeof(*in), outSize = sizeof(*out);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, inSize, out, &outSize);
}

/* keyinfo-primed read: call keyinfo first to populate driver state,
 * then read with the returned dataSize. This is what smc_dump did. */
static kern_return_t smc_read_primed(uint32_t key, uint8_t buf[32],
                                     uint32_t *sizeOut, uint32_t *typeOut) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return KERN_FAILURE;
    uint32_t size = out.keyInfo.dataSize;
    uint32_t type = out.keyInfo.dataType;
    if (size == 0 || size > 32) return KERN_FAILURE;

    SMCKeyData_t in2 = {0}, out2 = {0};
    in2.key = key;
    in2.keyInfo.dataSize = size;
    in2.data8 = SMC_CMD_READ_BYTES;
    kr = smc_call(&in2, &out2);
    if (kr != KERN_SUCCESS) return kr;
    if (out2.result != 0) return KERN_FAILURE;
    memcpy(buf, out2.bytes, 32);
    if (sizeOut) *sizeOut = size;
    if (typeOut) *typeOut = type;
    return KERN_SUCCESS;
}

static kern_return_t smc_write(uint32_t key, uint32_t dataType, uint32_t size,
                               const uint8_t *buf) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = size;
    in.keyInfo.dataType = dataType;
    in.data8 = SMC_CMD_WRITE_BYTES;
    if (size > 32) return KERN_FAILURE;
    memcpy(in.bytes, buf, size);
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return KERN_FAILURE;
    return KERN_SUCCESS;
}

static int read_flt(uint32_t key, float *out) {
    uint8_t buf[32] = {0}; uint32_t size = 0;
    if (smc_read_primed(key, buf, &size, NULL) != KERN_SUCCESS) return 0;
    if (size != 4) return 0;
    memcpy(out, buf, 4);
    return 1;
}
static int read_u8(uint32_t key, uint8_t *out) {
    uint8_t buf[32] = {0}; uint32_t size = 0;
    if (smc_read_primed(key, buf, &size, NULL) != KERN_SUCCESS) return 0;
    if (size != 1) return 0;
    *out = buf[0];
    return 1;
}
static int write_flt(uint32_t key, float val) {
    uint8_t buf[4]; memcpy(buf, &val, 4);
    return smc_write(key, FOURCC("flt "), 4, buf) == KERN_SUCCESS;
}
static int write_u8(uint32_t key, uint8_t val) {
    uint8_t buf[1] = { val };
    return smc_write(key, FOURCC("ui8 "), 1, buf) == KERN_SUCCESS;
}

/* ---- restore ---- */

typedef struct {
    int valid;
    float f0_tg, f0_mn, f1_tg, f1_mn;
    uint8_t f0_md, f1_md;
} FanState;

static FanState g_orig = {0};
static int g_need_restore = 0;

static void snapshot(FanState *s) {
    s->valid = 0;
    if (!read_flt(FOURCC("F0Tg"), &s->f0_tg)) return;
    if (!read_flt(FOURCC("F0Mn"), &s->f0_mn)) return;
    if (!read_flt(FOURCC("F1Tg"), &s->f1_tg)) return;
    if (!read_flt(FOURCC("F1Mn"), &s->f1_mn)) return;
    if (!read_u8 (FOURCC("F0md"), &s->f0_md)) return;
    if (!read_u8 (FOURCC("F1md"), &s->f1_md)) return;
    s->valid = 1;
}

static void restore(void) {
    if (!g_need_restore || !g_orig.valid || !g_conn) return;
    fprintf(stderr, "[restore] ...\n");
    write_u8 (FOURCC("F0md"), g_orig.f0_md);
    write_u8 (FOURCC("F1md"), g_orig.f1_md);
    write_flt(FOURCC("F0Mn"), g_orig.f0_mn);
    write_flt(FOURCC("F1Mn"), g_orig.f1_mn);
    write_flt(FOURCC("F0Tg"), g_orig.f0_tg);
    write_flt(FOURCC("F1Tg"), g_orig.f1_tg);
    g_need_restore = 0;
    fprintf(stderr, "[restore] done\n");
}
static void on_exit_handler(void) { restore(); smc_close(); }
static void on_signal(int sig) { (void)sig; restore(); smc_close(); _exit(1); }

/* ---- ---- */

#define DESIRED_TARGET 3500.0f

int main(void) {
    if (geteuid() != 0) { fprintf(stderr, "must run as root\n"); return 2; }
    if (smc_open() != KERN_SUCCESS) { fprintf(stderr, "smc_open failed\n"); return 1; }
    atexit(on_exit_handler);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    snapshot(&g_orig);
    if (!g_orig.valid) { fprintf(stderr, "snapshot failed\n"); return 1; }
    g_need_restore = 1;
    fprintf(stderr, "ORIG F0: Tg=%.0f Mn=%.0f md=%u | F1: Tg=%.0f Mn=%.0f md=%u\n",
            (double)g_orig.f0_tg, (double)g_orig.f0_mn, g_orig.f0_md,
            (double)g_orig.f1_tg, (double)g_orig.f1_mn, g_orig.f1_md);

    /* Step 1: put fan 0 in mode 1 */
    fprintf(stderr, "\nwriting F0md = 1 ...\n");
    if (!write_u8(FOURCC("F0md"), 1)) {
        fprintf(stderr, "F0md=1 FAILED\n");
        return 3;
    }
    usleep(100 * 1000);
    uint8_t md = 0; read_u8(FOURCC("F0md"), &md);
    fprintf(stderr, "F0md readback = %u\n", md);

    /* Step 2: tight loop re-writing F0Tg = 3500 every 200ms for 10s */
    fprintf(stderr, "\nretarget loop: writing F0Tg=%.0f every 200ms for 10s\n",
            (double)DESIRED_TARGET);
    fprintf(stderr, "%-4s %-8s %-8s %-4s  note\n", "t", "F0Tg", "F0Ac", "md");
    for (int i = 0; i < 50; i++) {
        int w = write_flt(FOURCC("F0Tg"), DESIRED_TARGET);
        float tg = 0, ac = 0; uint8_t m = 0;
        read_flt(FOURCC("F0Tg"), &tg);
        read_flt(FOURCC("F0Ac"), &ac);
        read_u8 (FOURCC("F0md"), &m);
        fprintf(stderr, "%-4d %-8.0f %-8.0f %-4u  w=%d\n",
                i * 200, (double)tg, (double)ac, m, w);
        usleep(200 * 1000);
    }

    /* Step 3: stop re-writing, watch for clobber */
    fprintf(stderr, "\nstop rewriting, observe clobber for 4s\n");
    for (int i = 0; i < 8; i++) {
        float tg = 0, ac = 0; uint8_t m = 0;
        read_flt(FOURCC("F0Tg"), &tg);
        read_flt(FOURCC("F0Ac"), &ac);
        read_u8 (FOURCC("F0md"), &m);
        fprintf(stderr, "t+%04d F0Tg=%.0f F0Ac=%.0f md=%u\n",
                i * 500, (double)tg, (double)ac, m);
        usleep(500 * 1000);
    }

    fprintf(stderr, "\ndone. restoring.\n");
    restore();
    return 0;
}
