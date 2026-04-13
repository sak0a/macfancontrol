/* restore_fena.c — try to restore FEna=0x07 and FPSt=3 */
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

static uint32_t get_type(uint32_t key) {
    SMCKeyData_t i={0},o={0}; i.key=key; i.data8=SMC_CMD_READ_KEYINFO;
    if (kcall(&i,&o)||o.result) return 0;
    return o.keyInfo.dataType;
}
static int read_byte(uint32_t key, uint8_t *v) {
    SMCKeyData_t i={0},o={0}; i.key=key; i.data8=SMC_CMD_READ_KEYINFO;
    if (kcall(&i,&o)||o.result) return 0;
    uint32_t size = o.keyInfo.dataSize;
    SMCKeyData_t i2={0},o2={0}; i2.key=key; i2.keyInfo.dataSize=size; i2.data8=SMC_CMD_READ_BYTES;
    if (kcall(&i2,&o2)||o2.result) return 0;
    *v = o2.bytes[0];
    return 1;
}
static int write_byte(uint32_t key, uint32_t type, uint8_t v) {
    SMCKeyData_t i={0},o={0};
    i.key=key; i.keyInfo.dataSize=1; i.keyInfo.dataType=type;
    i.data8=SMC_CMD_WRITE_BYTES; i.bytes[0]=v;
    if (kcall(&i,&o)) return 0;
    return o.result == 0;
}

int main(void) {
    io_service_t svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"));
    if (!svc) return 1;
    if (IOServiceOpen(svc, mach_task_self(), 0, &conn)) { IOObjectRelease(svc); return 1; }
    IOObjectRelease(svc);

    /* discover actual types */
    uint32_t fena_t = get_type(FC("FEna"));
    uint32_t fpst_t = get_type(FC("FPSt"));
    char fena_s[5]={(fena_t>>24)&0xff,(fena_t>>16)&0xff,(fena_t>>8)&0xff,fena_t&0xff,0};
    char fpst_s[5]={(fpst_t>>24)&0xff,(fpst_t>>16)&0xff,(fpst_t>>8)&0xff,fpst_t&0xff,0};
    fprintf(stderr, "FEna type=%s  FPSt type=%s\n", fena_s, fpst_s);

    uint8_t fena=0, fpst=0;
    read_byte(FC("FEna"), &fena);
    read_byte(FC("FPSt"), &fpst);
    fprintf(stderr, "before: FEna=0x%02x FPSt=%u\n", fena, fpst);

    /* try several candidate values for FEna */
    uint8_t candidates[] = {0x07, 0x03, 0x01, 0x04};
    for (size_t i = 0; i < sizeof(candidates); i++) {
        int ok = write_byte(FC("FEna"), fena_t, candidates[i]);
        uint8_t after=0; read_byte(FC("FEna"), &after);
        fprintf(stderr, "  FEna=0x%02x write=%d readback=0x%02x\n",
                candidates[i], ok, after);
        if (after == candidates[i]) break;
    }
    /* try FPSt */
    int fpst_ok = write_byte(FC("FPSt"), fpst_t, 3);
    uint8_t fpst_after=0; read_byte(FC("FPSt"), &fpst_after);
    fprintf(stderr, "  FPSt=3 write=%d readback=%u\n", fpst_ok, fpst_after);

    usleep(500*1000);
    read_byte(FC("FEna"), &fena);
    read_byte(FC("FPSt"), &fpst);
    fprintf(stderr, "after: FEna=0x%02x FPSt=%u\n", fena, fpst);

    IOServiceClose(conn);
    return 0;
}
