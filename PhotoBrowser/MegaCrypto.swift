import Foundation

/// The AES primitives MEGA's protocol needs, built on CommonCrypto (exposed via
/// the bridging header). CryptoKit only ships AEAD ciphers (AES-GCM / ChaChaPoly),
/// but MEGA uses raw AES in three modes:
///   • ECB — to unwrap node keys with the folder master key,
///   • CBC (zero IV, no padding) — to decrypt a node's attribute blob (its name),
///   • CTR — to decrypt the streamed file content.
/// All functions are `nonisolated` and pure so they can run on a background task.
enum MegaCrypto {

    /// Decodes MEGA's URL-safe, unpadded base64 (`-` `_`, no `=`) to raw bytes.
    nonisolated static func base64ToBytes(_ s: String) -> [UInt8] {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
                   .replacingOccurrences(of: ",", with: "")
        while str.count % 4 != 0 { str.append("=") }
        guard let data = Data(base64Encoded: str) else { return [] }
        return [UInt8](data)
    }

    /// AES-128-ECB decrypt, no padding. `data` must be a non-empty multiple of 16.
    nonisolated static func aesEcbDecrypt(key: [UInt8], data: [UInt8]) -> [UInt8] {
        guard key.count == 16, data.count >= 16, data.count % 16 == 0 else { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, key.count, nil,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count, &moved)
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return [] }
        return Array(out.prefix(moved))
    }

    /// AES-128-CBC decrypt with a zero IV and no padding.
    nonisolated static func aesCbcDecryptZeroIV(key: [UInt8], data: [UInt8]) -> [UInt8] {
        guard key.count == 16, data.count >= 16, data.count % 16 == 0 else { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let iv = [UInt8](repeating: 0, count: 16)
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                data.withUnsafeBytes { dataPtr in
                    out.withUnsafeMutableBytes { outPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(0),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outPtr.count, &moved)
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { return [] }
        return Array(out.prefix(moved))
    }

    /// Decrypts a node's base64 attribute blob and returns its filename. The
    /// plaintext is `MEGA` + JSON (`{"n":"name",…}`) zero-padded to a 16-byte block.
    nonisolated static func decryptAttributeName(_ attrB64: String, key: [UInt8]) -> String? {
        var enc = base64ToBytes(attrB64)
        guard !enc.isEmpty else { return nil }
        if enc.count % 16 != 0 { enc.append(contentsOf: [UInt8](repeating: 0, count: 16 - enc.count % 16)) }
        let dec = aesCbcDecryptZeroIV(key: key, data: enc)
        guard dec.count >= 4, dec.prefix(4).elementsEqual("MEGA".utf8) else { return nil }
        let jsonBytes = Array(dec.dropFirst(4).prefix { $0 != 0 })   // strip trailing zero padding
        guard let json = try? JSONSerialization.jsonObject(with: Data(jsonBytes)) as? [String: Any],
              let name = json["n"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// Streams AES-128-CTR (big-endian counter) decryption from `input` to `output`
    /// in 1 MB chunks, so even multi-GB videos decrypt without large memory use.
    nonisolated static func decryptCTR(input: URL, output: URL, key: [UInt8], iv: [UInt8]) throws {
        guard key.count == 16, iv.count == 16 else { throw MegaError.crypto }

        var cryptorRef: CCCryptorRef?
        let create = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
                                        CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE),
                                        &cryptorRef)
            }
        }
        guard create == Int32(kCCSuccess), let cryptor = cryptorRef else { throw MegaError.crypto }
        defer { CCCryptorRelease(cryptor) }

        let fm = FileManager.default
        fm.createFile(atPath: output.path, contents: nil)
        guard let inHandle = try? FileHandle(forReadingFrom: input),
              let outHandle = try? FileHandle(forWritingTo: output) else { throw MegaError.io }
        defer { try? inHandle.close(); try? outHandle.close() }

        let chunkSize = 1 << 20   // 1 MB
        while true {
            guard let chunk = try inHandle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            var out = [UInt8](repeating: 0, count: chunk.count)   // CTR output == input length
            var moved = 0
            let status = chunk.withUnsafeBytes { inPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCryptorUpdate(cryptor, inPtr.baseAddress, chunk.count,
                                    outPtr.baseAddress, outPtr.count, &moved)
                }
            }
            guard status == Int32(kCCSuccess) else { throw MegaError.crypto }
            try outHandle.write(contentsOf: Data(out.prefix(moved)))
        }
    }

    /// One-shot AES-128-CTR decrypt of an in-memory buffer. Used for parallel range
    /// chunks: `iv` already encodes the chunk's starting block counter, so each
    /// chunk decrypts independently (CTR is seekable). The chunk's byte offset must
    /// be 16-aligned for the counter in `iv` to line up.
    nonisolated static func decryptCTRData(_ data: Data, key: [UInt8], iv: [UInt8]) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw MegaError.crypto }
        var cryptorRef: CCCryptorRef?
        let create = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
                                        CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE),
                                        &cryptorRef)
            }
        }
        guard create == Int32(kCCSuccess), let cryptor = cryptorRef else { throw MegaError.crypto }
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = data.withUnsafeBytes { inPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, data.count, outPtr.baseAddress, outPtr.count, &moved)
            }
        }
        guard status == Int32(kCCSuccess) else { throw MegaError.crypto }
        return Data(out.prefix(moved))
    }
}
