//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

// MEGA folder downloads need AES in ECB / CBC / CTR modes (for node keys,
// attributes, and file content). CryptoKit only exposes AEAD ciphers, so we use
// CommonCrypto's lower-level CCCryptor API instead. See MegaDownloader.swift.
#import <CommonCrypto/CommonCrypto.h>

// APFS copy-on-write clones (`clonefile`) for instant, zero-extra-space same-volume copies.
// Not exposed by the default Darwin overlay, so import the header. See DriveWriter.copyItem.
#include <sys/clonefile.h>
