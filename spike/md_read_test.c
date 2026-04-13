/* md_read_test.c — verify whether F0md=1 still makes F0Ac readable
 * after the FEna/FPSt state change. Bounces md=1, reads, md=0, reads. */
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef char SMCBytes_t[32];
typedef struct { char a,b,c,d; uint16_t e; } SMCKeyData_vers_t;
typedef struct { uint16_t a,b; uint32_t c,d,e; } SMCKeyData_pLimitData_t;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    uint32_t key; SMCKeyData_vers_t vers; SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo; uint8_t result; uint8_t status; uint8_t data8;
    uint32_t data32; SMCBytes_t bytes;
} SMCKeyData_t;

static uint32_t FC(const char *s) {
    return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|
           ((uint32_t)(uint8_t)s[2]<<8)|((uint32_t)(uint8_t)s[3]);
}

static io_connect_t conn;
static int kcall(SMCKeyData_t *i, SMCKeyData_t *o) {
    size_t a=sizeof(*i), b=sizeof(*o);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, i,a,o,&b);
}
static int rp(uint32_t key, uint8_t buf[32], uint32_t *sz) {
    SMCKeyData_t i={0},o={0}; i.key=key; i.data8=SMC_CMD_READ_KEYINFO;
    if (kcall(&i,&o)||o.result) return 0;
    uint32_t s=o.keyInfo.dataSize;
    SMCKeyData_t i2={0},o2={0}; i2.key=key; i2.keyInfo.dataSize=s; i2.data8=SMC_CMD_READ_BYTES;
    if (kcall(&i2,&o2)||o2.result) return 0;
    memcpy(buf,o2.bytes,32);
    if (sz)*sz=s;
    return 1;
}
static int w_u8(uint32_t key, uint8_t v) {
    SMCKeyData_t i={0},o={0};
    i.key=key; i.keyInfo.dataSize=1; i.keyInfo.dataType=FC("ui8 ");
    i.data8=SMC_CMD_WRITE_BYTES; i.bytes[0]=v;
    if (kcall(&i,&o)) return 0;
    return o.result==0;
}
static float r_flt(uint32_t key) {
    uint8_t b[32]={0}; uint32_t s=0;
    if (!rp(key,b,&s) || s!=4) return -1;
    float f; memcpy(&f,b,4); return f;
}
static uint8_t r_u8(uint32_t key) {
    uint8_t b[32]={0}; uint32_t s=0;
    if (!rp(key,b,&s) || s!=1) return 255;
    return b[0];
}

static void dump(const char *tag) {
    float f0ac=r_flt(FC("F0Ac")), f0tg=r_flt(FC("F0Tg"));
    float f0mn=r_flt(FC("F0Mn"));
    uint8_t f0md=r_u8(FC("F0md"));
    uint8_t fena=r_u8(FC("FEna")), fpst=r_u8(FC("FPSt"));
    fprintf(stderr, "%-20s F0Ac=%6.0f F0Tg=%6.0f F0Mn=%6.0f F0md=%u FEna=0x%02x FPSt=%u\n",
            tag, (double)f0ac, (double)f0tg, (double)f0mn, f0md, fena, fpst);
}

int main(void) {
    io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"));
    if (!svc) return 1;
    if (IOServiceOpen(svc, mach_task_self(), 0, &conn)) { IOObjectRelease(svc); return 1; }
    IOObjectRelease(svc);

    dump("start (md=0)");

    fprintf(stderr, "\nwriting F0md=1...\n");
    w_u8(FC("F0md"), 1);
    usleep(300*1000);
    dump("after md=1");
    usleep(1000*1000);
    dump("after md=1 +1s");

    fprintf(stderr, "\nwriting F0md=0...\n");
    w_u8(FC("F0md"), 0);
    usleep(300*1000);
    dump("after md=0");
    usleep(1000*1000);
    dump("after md=0 +1s");
    usleep(2000*1000);
    dump("after md=0 +3s");

    IOServiceClose(conn);
    return 0;
}
