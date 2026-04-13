/*
 * fan_write_probe.c — Phase 0 GATE: does fan override work on M5 Max?
 *
 * Key finding from smc_dump.c on M5 Max / macOS 26.4:
 *   - Ftst key does NOT exist (agoodkind M1-M4 unlock mechanism obsolete)
 *   - Fan mode key is lowercase 'F0md' (not 'F0Md'), currently reads 0
 *   - Fan target writes as 'flt ' (4-byte LE float)
 *   - Two fans: F0, F1; range 2317..7826 rpm; idle target ~2317
 *
 * This probe tries multiple write strategies non-destructively, with
 * a hard safety cap (never exceed 3500 rpm), and always restores state
 * via atexit + signal handler. It reports which strategy actually
 * causes F0Ac to converge toward the requested target.
 *
 *   STRATEGY 1: Direct write F0Tg (target). If stable for >2s, win.
 *   STRATEGY 2: Write F0Mn (min floor). Raises thermalmonitord's lower
 *               bound. Often works on Apple Silicon without any unlock.
 *   STRATEGY 3: Write F0md = 1 (manual). Observe; then write F0Tg.
 *   STRATEGY 4: Blind write Ftst = 1 (in case key is not enumerated).
 *               Then F0md = 1, then F0Tg.
 *
 * Build:
 *   clang -O2 -Wall -framework IOKit -framework CoreFoundation \
 *       spike/fan_write_probe.c -o /tmp/fan_write_probe
 * Run:
 *   sudo /tmp/fan_write_probe
 */

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

/* ---- SMC constants ---- */
#define KERNEL_INDEX_SMC        2
#define SMC_CMD_READ_BYTES      5
#define SMC_CMD_WRITE_BYTES     6
#define SMC_CMD_READ_INDEX      8
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

static void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t inSize = sizeof(*in), outSize = sizeof(*out);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, inSize, out, &outSize);
}

static kern_return_t smc_keyinfo(uint32_t key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key; in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t kr = smc_call(&in, &out);
    if (kr != KERN_SUCCESS) return kr;
    if (out.result != 0) return KERN_FAILURE;
    *info = out.keyInfo;
    return KERN_SUCCESS;
}

static kern_return_t smc_read(uint32_t key, uint32_t size, uint8_t buf[32]) {
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

/* ---- High-level helpers for our specific keys ---- */

static int read_flt(uint32_t key, float *out) {
    uint8_t buf[32] = {0};
    if (smc_read(key, 4, buf) != KERN_SUCCESS) return 0;
    memcpy(out, buf, 4); /* little-endian on arm64 host */
    return 1;
}

static int write_flt(uint32_t key, float val) {
    uint8_t buf[4]; memcpy(buf, &val, 4);
    return smc_write(key, FOURCC("flt "), 4, buf) == KERN_SUCCESS;
}

static int read_u8(uint32_t key, uint8_t *out) {
    uint8_t buf[32] = {0};
    if (smc_read(key, 1, buf) != KERN_SUCCESS) return 0;
    *out = buf[0];
    return 1;
}

static int write_u8(uint32_t key, uint8_t val) {
    uint8_t buf[1] = { val };
    return smc_write(key, FOURCC("ui8 "), 1, buf) == KERN_SUCCESS;
}

/* ---- State snapshot + restore ---- */

typedef struct {
    int   valid;
    float f0_tg, f0_mn;
    float f1_tg, f1_mn;
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
    fprintf(stderr, "[restore] restoring fan state...\n");
    write_u8 (FOURCC("F0md"), g_orig.f0_md);
    write_u8 (FOURCC("F1md"), g_orig.f1_md);
    write_flt(FOURCC("F0Mn"), g_orig.f0_mn);
    write_flt(FOURCC("F1Mn"), g_orig.f1_mn);
    write_flt(FOURCC("F0Tg"), g_orig.f0_tg);
    write_flt(FOURCC("F1Tg"), g_orig.f1_tg);
    /* Try Ftst=0 blind in case we touched it */
    write_u8(FOURCC("Ftst"), 0);
    g_need_restore = 0;
    fprintf(stderr, "[restore] done\n");
}

static void on_exit_handler(void) { restore(); smc_close(); }
static void on_signal(int sig) { (void)sig; restore(); smc_close(); _exit(1); }

/* ---- Observation helpers ---- */

static void snap_print(const char *tag) {
    float ac, tg, mn; uint8_t md;
    read_flt(FOURCC("F0Ac"), &ac);
    read_flt(FOURCC("F0Tg"), &tg);
    read_flt(FOURCC("F0Mn"), &mn);
    read_u8 (FOURCC("F0md"), &md);
    fprintf(stderr, "  %-20s F0: Ac=%6.0f Tg=%6.0f Mn=%6.0f md=%u\n",
            tag, ac, tg, mn, md);
}

static void observe_for(const char *tag, int seconds) {
    for (int i = 0; i < seconds; i++) {
        usleep(1000 * 1000);
        char buf[64]; snprintf(buf, sizeof buf, "%s t+%ds", tag, i + 1);
        snap_print(buf);
    }
}

/* ---- Strategies ---- */

#define SAFE_TARGET 3500.0f  /* never exceed this */

static int strategy_direct_Tg(void) {
    fprintf(stderr, "\n[S1] Direct write F0Tg -> %.0f\n", (double)SAFE_TARGET);
    snap_print("before");
    if (!write_flt(FOURCC("F0Tg"), SAFE_TARGET)) {
        fprintf(stderr, "  F0Tg write FAILED (IOKit returned error)\n");
        return 0;
    }
    fprintf(stderr, "  F0Tg write returned success\n");
    observe_for("S1", 4);
    /* success criterion: F0Ac converging toward SAFE_TARGET (>= 3000) */
    float ac = 0; read_flt(FOURCC("F0Ac"), &ac);
    int ok = (ac >= 3000.0f);
    /* revert F0Tg so the next strategy starts clean */
    write_flt(FOURCC("F0Tg"), g_orig.f0_tg);
    usleep(300 * 1000);
    fprintf(stderr, "[S1] %s (F0Ac last = %.0f)\n", ok ? "WIN" : "no effect", (double)ac);
    return ok;
}

static int strategy_direct_Mn(void) {
    fprintf(stderr, "\n[S2] Direct write F0Mn -> %.0f (raise floor)\n", (double)SAFE_TARGET);
    snap_print("before");
    if (!write_flt(FOURCC("F0Mn"), SAFE_TARGET)) {
        fprintf(stderr, "  F0Mn write FAILED\n");
        return 0;
    }
    fprintf(stderr, "  F0Mn write returned success\n");
    observe_for("S2", 4);
    float ac = 0; read_flt(FOURCC("F0Ac"), &ac);
    int ok = (ac >= 3000.0f);
    write_flt(FOURCC("F0Mn"), g_orig.f0_mn);
    usleep(300 * 1000);
    fprintf(stderr, "[S2] %s (F0Ac last = %.0f)\n", ok ? "WIN" : "no effect", (double)ac);
    return ok;
}

static int strategy_md_then_Tg(void) {
    fprintf(stderr, "\n[S3] Write F0md=1, then F0Tg -> %.0f\n", (double)SAFE_TARGET);
    snap_print("before");
    if (!write_u8(FOURCC("F0md"), 1)) {
        fprintf(stderr, "  F0md=1 write FAILED\n");
    } else {
        fprintf(stderr, "  F0md=1 write returned success\n");
    }
    usleep(300 * 1000);
    uint8_t md_after = 0; read_u8(FOURCC("F0md"), &md_after);
    fprintf(stderr, "  F0md readback = %u\n", md_after);

    if (!write_flt(FOURCC("F0Tg"), SAFE_TARGET)) {
        fprintf(stderr, "  F0Tg write FAILED\n");
    } else {
        fprintf(stderr, "  F0Tg write returned success\n");
    }
    observe_for("S3", 4);
    float ac = 0; read_flt(FOURCC("F0Ac"), &ac);
    int ok = (ac >= 3000.0f);
    /* revert */
    write_u8(FOURCC("F0md"), g_orig.f0_md);
    write_flt(FOURCC("F0Tg"), g_orig.f0_tg);
    usleep(300 * 1000);
    fprintf(stderr, "[S3] %s (F0Ac last = %.0f)\n", ok ? "WIN" : "no effect", (double)ac);
    return ok;
}

static int strategy_Ftst_blind(void) {
    fprintf(stderr, "\n[S4] Blind Ftst=1, F0md=1, F0Tg -> %.0f\n", (double)SAFE_TARGET);
    snap_print("before");
    int ftst_ok = write_u8(FOURCC("Ftst"), 1);
    fprintf(stderr, "  Ftst=1 write %s\n", ftst_ok ? "succeeded" : "FAILED");
    usleep(200 * 1000);
    int md_ok = write_u8(FOURCC("F0md"), 1);
    fprintf(stderr, "  F0md=1 write %s\n", md_ok ? "succeeded" : "FAILED");
    usleep(200 * 1000);
    int tg_ok = write_flt(FOURCC("F0Tg"), SAFE_TARGET);
    fprintf(stderr, "  F0Tg write %s\n", tg_ok ? "succeeded" : "FAILED");
    observe_for("S4", 4);
    float ac = 0; read_flt(FOURCC("F0Ac"), &ac);
    int ok = (ac >= 3000.0f);
    write_u8(FOURCC("F0md"), g_orig.f0_md);
    write_flt(FOURCC("F0Tg"), g_orig.f0_tg);
    write_u8(FOURCC("Ftst"), 0);
    usleep(300 * 1000);
    fprintf(stderr, "[S4] %s (F0Ac last = %.0f)\n", ok ? "WIN" : "no effect", (double)ac);
    return ok;
}

/* ---- main ---- */

int main(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "must run as root (sudo)\n");
        return 2;
    }
    if (smc_open() != KERN_SUCCESS) {
        fprintf(stderr, "smc_open failed\n");
        return 1;
    }
    atexit(on_exit_handler);
    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    snapshot(&g_orig);
    if (!g_orig.valid) {
        fprintf(stderr, "failed to snapshot original state\n");
        return 1;
    }
    g_need_restore = 1;
    fprintf(stderr, "ORIG  F0: Tg=%.0f Mn=%.0f md=%u | F1: Tg=%.0f Mn=%.0f md=%u\n",
            (double)g_orig.f0_tg, (double)g_orig.f0_mn, g_orig.f0_md,
            (double)g_orig.f1_tg, (double)g_orig.f1_mn, g_orig.f1_md);
    fprintf(stderr, "Safety cap: %.0f rpm\n", (double)SAFE_TARGET);

    int s1 = strategy_direct_Tg();
    int s2 = strategy_direct_Mn();
    int s3 = strategy_md_then_Tg();
    int s4 = strategy_Ftst_blind();

    fprintf(stderr, "\n=== RESULTS ===\n");
    fprintf(stderr, "S1 direct F0Tg          : %s\n", s1 ? "WIN" : "fail");
    fprintf(stderr, "S2 direct F0Mn          : %s\n", s2 ? "WIN" : "fail");
    fprintf(stderr, "S3 F0md=1 + F0Tg        : %s\n", s3 ? "WIN" : "fail");
    fprintf(stderr, "S4 Ftst=1 + md=1 + Tg   : %s\n", s4 ? "WIN" : "fail");

    restore();
    return (s1 || s2 || s3 || s4) ? 0 : 3;
}
