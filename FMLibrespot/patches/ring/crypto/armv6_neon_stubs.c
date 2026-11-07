// FoxMusic patch: armv6 has no NEON, so the assembly for these isn't built, but ring's Rust code still
// refers to them. ring only calls them after detecting NEON, which never happens on iOS: its feature
// detection for 32-bit Apple targets reports nothing. See FMLibrespot/patches/README.md.

#include <ring-core/base.h>

#if defined(__APPLE__) && defined(OPENSSL_ARM) && !defined(__ARM_NEON__)

#define NEON_STUB(name) \
  void name(void);      \
  void name(void) { __builtin_trap(); }

NEON_STUB(CRYPTO_poly1305_finish_neon)
NEON_STUB(CRYPTO_poly1305_init_neon)
NEON_STUB(CRYPTO_poly1305_update_neon)
NEON_STUB(ChaCha20_ctr32_neon)
NEON_STUB(bn_mul8x_mont_neon)
NEON_STUB(bsaes_ctr32_encrypt_blocks)
NEON_STUB(gcm_ghash_neon)
NEON_STUB(gcm_gmult_neon)
NEON_STUB(gcm_init_neon)
NEON_STUB(sha256_block_data_order_neon)
NEON_STUB(sha512_block_data_order_neon)
NEON_STUB(vpaes_ctr32_encrypt_blocks)
NEON_STUB(vpaes_encrypt_key_to_bsaes)
NEON_STUB(vpaes_set_encrypt_key)

#endif
