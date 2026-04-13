/*
 * SMCShim.h — Swift-visible C API for AppleSMC IOKit access.
 *
 * Designed for Apple Silicon (verified on M5 Max, macOS 26.4). All fan
 * keys on Apple Silicon use the 'flt ' dataType (little-endian IEEE754).
 * Temperature keys are mostly 'flt ' too; some use 'sp78', 'ioft', etc.
 *
 * Safety: this header exposes a minimal, opinionated C API. Callers do
 * NOT manipulate SMCKeyData_t directly — the wrapper functions keep the
 * driver-level keyinfo-prime-then-read pattern that is mandatory for
 * reads on M5 Max to return non-zero data.
 */

#ifndef SMCSHIM_H
#define SMCSHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Make a 4-byte big-endian FourCC from a 4-character C string.
 * Example: smc_fourcc("F0Ac") -> 0x46304163. */
uint32_t smc_fourcc(const char *s);

/* Decode a FourCC back into a 5-byte C string (null-terminated). */
void smc_fourcc_to_str(uint32_t key, char out[5]);

/* Open the AppleSMC user client. Returns 0 on success. */
int smc_open(void);

/* Close the connection. Safe to call multiple times. */
void smc_close(void);

/* Total number of SMC keys (the '#KEY' key). Returns 0 on failure. */
uint32_t smc_key_count(void);

/* Read the FourCC of the N-th key (0-indexed). Returns 0 on failure. */
uint32_t smc_key_at_index(uint32_t index);

/* Read a key's metadata: dataSize (bytes) and dataType (FourCC).
 * Returns true on success. Mandatory call before smc_read_bytes for
 * correct M5 Max behavior. */
bool smc_read_keyinfo(uint32_t key, uint32_t *outSize, uint32_t *outType);

/* Read up to 32 bytes of a key's value. Always call smc_read_keyinfo
 * first (or use smc_read_key which does both). Returns true on success. */
bool smc_read_bytes(uint32_t key, uint32_t size, uint8_t out[32]);

/* Convenience: read keyinfo + bytes in one call. Fills outSize, outType,
 * and up to 32 bytes into outData. Returns true on success. */
bool smc_read_key(uint32_t key, uint32_t *outSize, uint32_t *outType,
                  uint8_t outData[32]);

/* Write a 'flt ' (4-byte float) value to a key. Requires root. */
bool smc_write_flt(uint32_t key, float value);

/* Write a 'ui8 ' (1-byte) value to a key. Requires root. */
bool smc_write_u8(uint32_t key, uint8_t value);

/* Decoders for common dataTypes. Return true on success. */
bool smc_decode_flt(const uint8_t *bytes, uint32_t size, double *out);
bool smc_decode_fpe2(const uint8_t *bytes, uint32_t size, double *out);
bool smc_decode_sp78(const uint8_t *bytes, uint32_t size, double *out);
bool smc_decode_ui(const uint8_t *bytes, uint32_t size, uint64_t *out);
bool smc_decode_si(const uint8_t *bytes, uint32_t size, int64_t *out);

#ifdef __cplusplus
}
#endif

#endif /* SMCSHIM_H */
