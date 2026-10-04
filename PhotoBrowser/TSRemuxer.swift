import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// MPEG-TS → MP4 remux in pure Swift, no re-encode and no FFmpeg.
///
/// Why this exists: HLS streams from most tube/VOD sites arrive as MPEG-2 transport-stream
/// segments. Concatenating them gives a valid `.ts`, but **iOS can't play a `.ts` file**: AVFoundation
/// has no file-level transport-stream demuxer (it only consumes TS *inside* an HLS session), so
/// `AVURLAsset` reports no tracks, the old AVAssetReader-based remux fell through, and the download
/// was saved as an unplayable `.ts` (adultdvdempire.com was the report). FFmpegKit isn't linked.
///
/// So this walks the transport stream itself: PAT → PMT → elementary PIDs, reassembles PES
/// packets, and hands the **already-compressed** frames to `AVAssetWriter` as passthrough samples:
/// * video: H.264 (`stream_type 0x1B`) or HEVC (`0x24`). Annex-B NAL units become 4-byte
///   length-prefixed (AVCC/HVCC) samples; SPS/PPS(/VPS) go into the format description; IDR/CRA/BLA
///   frames are marked as sync samples; the first emitted frame is always a sync frame.
/// * audio: AAC in ADTS (`0x0F`). Each ADTS frame becomes one 1024-sample packet with an
///   AudioSpecificConfig cookie built from the ADTS header. Other audio codecs (MP3/AC-3/LATM) are
///   skipped: the video is still saved, silent, rather than nothing at all.
/// Timestamps are the stream's own 90 kHz PTS/DTS, unwrapped at the 33-bit boundary, re-based to
/// zero, and nudged across any discontinuity so DTS stays monotonic (what the writer requires).
/// Video sample durations come from one-sample look-ahead on DTS.
///
/// Two passes over the file — all video, then all audio — mirror the existing fMP4 mux and avoid
/// interleaving stalls; memory stays at one PES packet per track. Everything is `nonisolated` and
/// runs detached: it's pure file + CoreMedia work.
nonisolated enum TSRemuxer {
    static let timescale: Int32 = 90_000

    /// Remuxes the MPEG-TS at `src` into an MP4 at `out`. False if the stream isn't H.264/HEVC,
    /// is scrambled, or the writer fails — the caller then keeps the `.ts`.
    nonisolated static func remux(_ src: URL, to out: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let probe = TSDemuxer(url: src) else { return false }
            probe.probe(limitBytes: 64 << 20)
            guard let vFormat = probe.formats.video, let base = probe.earliestTime else { return false }
            let formats = probe.formats

            try? FileManager.default.removeItem(at: out)
            guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else { return false }
            writer.shouldOptimizeForNetworkUse = true
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
            vInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(vInput) else { return false }
            writer.add(vInput)
            var aInput: AVAssetWriterInput?
            if let aFormat = formats.audio {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aFormat)
                ai.expectsMediaDataInRealTime = false
                if writer.canAdd(ai) { writer.add(ai); aInput = ai }
            }
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            guard let vDemux = TSDemuxer(url: src, base: base, emitVideo: true, emitAudio: false, formats: formats) else {
                writer.cancelWriting(); return false
            }
            let videoOK = await pump(vInput, from: vDemux)
            if let aInput {
                if let aDemux = TSDemuxer(url: src, base: base, emitVideo: false, emitAudio: true, formats: formats) {
                    _ = await pump(aInput, from: aDemux)
                } else {
                    aInput.markAsFinished()
                }
            }
            guard videoOK, writer.status == .writing else { writer.cancelWriting(); return false }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
            return writer.status == .completed
        }.value
    }

    /// Converts a `.ts` already on the drive into a sibling `.mp4` with the same base name (" 1"
    /// appended on a clash), keeps the original's modification date, removes the `.ts` on success
    /// and returns the new URL. The caller re-keys metadata (`library.itemMoved`). nil on failure —
    /// the `.ts` is left exactly as it was.
    nonisolated static func convertInPlace(_ ts: URL) async -> URL? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("tsremux_\(UUID().uuidString).mp4")
        guard await remux(ts, to: tmp) else { try? fm.removeItem(at: tmp); return nil }
        let base = ts.deletingPathExtension()
        var dest = base.appendingPathExtension("mp4")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) \(n)").appendingPathExtension("mp4")
            n += 1
        }
        let modified = (try? ts.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        do { try await DriveWriter.shared.commit(tmp, to: dest) } catch { try? fm.removeItem(at: tmp); return nil }
        if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: dest.path) }
        try? fm.removeItem(at: ts)
        return dest
    }

    /// Drains one demuxer into one writer input, copying compressed samples as-is. True if at least
    /// one sample was written and none was refused.
    nonisolated private static func pump(_ input: AVAssetWriterInput, from demux: TSDemuxer) async -> Bool {
        let queue = DispatchQueue(label: "tsremux.pump")
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // The ready-block can fire again after we finish; resuming twice is a hard crash, so
            // `finished` (serialized on `queue`) makes the resume happen exactly once.
            var finished = false
            var appended = 0
            input.requestMediaDataWhenReady(on: queue) {
                if finished { return }
                while input.isReadyForMoreMediaData {
                    guard let sb = demux.nextSampleBuffer() else {
                        finished = true; input.markAsFinished(); cont.resume(returning: appended > 0); return
                    }
                    if !input.append(sb) {
                        finished = true; input.markAsFinished(); cont.resume(returning: false); return
                    }
                    appended += 1
                }
            }
        }
    }
}

// MARK: - Demuxer

/// Streams one transport-stream file and yields compressed samples for one or both tracks.
/// Confined to the pump's serial queue (or the probe's task) — never shared.
private final class TSDemuxer: @unchecked Sendable {
    struct Formats {
        var video: CMFormatDescription?
        var audio: CMFormatDescription?
        var audioRate: Int32 = 0
    }
    struct Sample {
        let isVideo: Bool
        let bytes: [UInt8]
        let pts: Int64        // 90 kHz, re-based
        let dts: Int64
        let sync: Bool
    }
    private enum VideoCodec { case h264, hevc }

    private let handle: FileHandle
    private let base: Int64
    private let emitVideo: Bool
    private let emitAudio: Bool
    private(set) var formats: Formats
    private(set) var earliestTime: Int64?        // min(first video DTS, first audio PTS), before re-basing
    private var firstVideoTime: Int64?
    private var firstAudioTime: Int64?
    private(set) var bytesRead = 0
    private var eof = false
    private var scrambled = false

    private var carry: [UInt8] = []
    private var pending: [Sample] = []
    private var pendingIndex = 0
    private var pendingVideo: Sample?
    private var lastVideoDuration: Int64 = 3003

    private var pmtPID = -1
    private var videoPID = -1
    private var audioPID = -1
    private var videoCodec: VideoCodec?
    private var audioIsAAC = false

    private var videoPES: [UInt8] = []
    private var audioPES: [UInt8] = []
    private var videoPESOpen = false
    private var audioPESOpen = false

    private var vps: [[UInt8]] = []
    private var sps: [[UInt8]] = []
    private var pps: [[UInt8]] = []
    private var seenSync = false

    private var videoWrap = TSWrap()
    private var audioWrap = TSWrap()
    private var offset: Int64 = 0                 // discontinuity correction, shared by both tracks
    private var lastVideoDTS: Int64?
    private var lastVideoPTS: Int64?
    private var audioBasePTS: Int64?
    private var audioFramesSinceBase: Int64 = 0
    private var audioLeftover: [UInt8] = []

    private static let packetSize = 188
    private static let chunkPackets = 2048
    private static let aacSampleRates: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    init?(url: URL, base: Int64 = 0, emitVideo: Bool = true, emitAudio: Bool = true, formats: Formats = Formats()) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        handle = h
        self.base = base
        self.emitVideo = emitVideo
        self.emitAudio = emitAudio
        self.formats = formats
    }
    deinit { try? handle.close() }

    /// Reads until both tracks' formats and first timestamps are known (or the limit / EOF).
    func probe(limitBytes: Int) {
        while !eof, bytesRead < limitBytes {
            let audioSettled = audioPID < 0 || !audioIsAAC || (formats.audio != nil && firstAudioTime != nil)
            if formats.video != nil, firstVideoTime != nil, audioSettled, bytesRead > (2 << 20) { break }
            _ = nextSample()
        }
        // Drain whatever is parsed so an audio-only tail can't bias the probe; times are already set.
        var times: [Int64] = []
        if let v = firstVideoTime { times.append(v) }
        if let a = firstAudioTime { times.append(a) }
        earliestTime = times.min()
    }

    // MARK: Samples out

    /// The next sample buffer for this demuxer's track, or nil at end of stream. Video gets a
    /// one-sample look-ahead so each frame's duration is the DTS gap to the next.
    func nextSampleBuffer() -> CMSampleBuffer? {
        if emitVideo {
            while true {
                guard let s = nextSample() else {
                    guard let pv = pendingVideo else { return nil }
                    pendingVideo = nil
                    return makeBuffer(pv, duration: CMTime(value: lastVideoDuration, timescale: TSRemuxer.timescale))
                }
                guard s.isVideo else { continue }
                if let pv = pendingVideo {
                    let gap = max(1, s.dts - pv.dts)
                    lastVideoDuration = gap
                    pendingVideo = s
                    return makeBuffer(pv, duration: CMTime(value: gap, timescale: TSRemuxer.timescale))
                }
                pendingVideo = s
            }
        }
        while let s = nextSample() {
            guard !s.isVideo else { continue }
            return makeBuffer(s, duration: CMTime(value: 1024, timescale: max(1, formats.audioRate)))
        }
        return nil
    }

    private func makeBuffer(_ s: Sample, duration: CMTime) -> CMSampleBuffer? {
        guard let fd = s.isVideo ? formats.video : formats.audio else { return nil }
        let n = s.bytes.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = s.bytes.withUnsafeBytes { raw -> OSStatus in
            guard let p = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: p, blockBuffer: block, offsetIntoDestination: 0, dataLength: n)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: CMTime(value: s.pts, timescale: TSRemuxer.timescale),
                                        decodeTimeStamp: s.isVideo ? CMTime(value: s.dts, timescale: TSRemuxer.timescale) : .invalid)
        var size = n
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        if s.isVideo, !s.sync,
           let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }

    /// The next parsed sample of either track in stream order, or nil at EOF.
    private func nextSample() -> Sample? {
        while pendingIndex >= pending.count {
            guard !eof, !scrambled else { return nil }
            pending.removeAll(keepingCapacity: true); pendingIndex = 0
            readChunk()
        }
        let s = pending[pendingIndex]; pendingIndex += 1
        return s
    }

    // MARK: Packets

    private func readChunk() {
        let want = Self.packetSize * Self.chunkPackets
        let chunk = (try? handle.read(upToCount: want)) ?? Data()
        if chunk.isEmpty {
            eof = true
            if videoPESOpen { finalizeVideoPES() }
            if audioPESOpen { finalizeAudioPES() }
            return
        }
        bytesRead += chunk.count
        var data = carry; data.append(contentsOf: chunk)
        var i = 0
        let n = data.count
        while i + Self.packetSize <= n {
            guard data[i] == 0x47 else { i += 1; continue }          // resync on a lost packet boundary
            parsePacket(data, at: i)
            i += Self.packetSize
        }
        carry = i < n ? Array(data[i...]) : []
    }

    private func parsePacket(_ d: [UInt8], at i: Int) {
        let b1 = d[i + 1], b2 = d[i + 2], b3 = d[i + 3]
        if b1 & 0x80 != 0 { return }                                  // transport error indicator
        let pusi = b1 & 0x40 != 0
        let pid = Int(b1 & 0x1F) << 8 | Int(b2)
        if (b3 >> 6) & 3 != 0 { scrambled = true; return }          // encrypted at the TS layer: not ours to read
        let afc = (b3 >> 4) & 3
        var off = 4
        if afc & 2 != 0 { off += 1 + Int(d[i + 4]) }
        guard afc & 1 != 0, off < Self.packetSize else { return }
        let start = i + off, end = i + Self.packetSize
        if pid == 0 {
            parsePAT(d, start, end, pusi: pusi)
        } else if pid == pmtPID {
            parsePMT(d, start, end, pusi: pusi)
        } else if pid == videoPID {
            if pusi {
                if videoPESOpen { finalizeVideoPES() }
                videoPES.removeAll(keepingCapacity: true); videoPESOpen = true
            }
            if videoPESOpen { videoPES.append(contentsOf: d[start..<end]) }
        } else if pid == audioPID {
            if pusi {
                if audioPESOpen { finalizeAudioPES() }
                audioPES.removeAll(keepingCapacity: true); audioPESOpen = true
            }
            if audioPESOpen { audioPES.append(contentsOf: d[start..<end]) }
        }
    }

    private func parsePAT(_ d: [UInt8], _ start: Int, _ end: Int, pusi: Bool) {
        guard pusi, pmtPID < 0 else { return }
        var s = start + 1 + Int(d[start])                               // pointer_field
        guard s + 8 <= end, d[s] == 0x00 else { return }
        let sectionLength = Int(d[s + 1] & 0x0F) << 8 | Int(d[s + 2])
        let sectionEnd = min(end, s + 3 + sectionLength - 4)           // minus CRC
        s += 8
        while s + 4 <= sectionEnd {
            let program = Int(d[s]) << 8 | Int(d[s + 1])
            let pid = Int(d[s + 2] & 0x1F) << 8 | Int(d[s + 3])
            if program != 0 { pmtPID = pid; return }
            s += 4
        }
    }

    private func parsePMT(_ d: [UInt8], _ start: Int, _ end: Int, pusi: Bool) {
        guard pusi, videoPID < 0 else { return }
        var s = start + 1 + Int(d[start])
        guard s + 12 <= end, d[s] == 0x02 else { return }
        let sectionLength = Int(d[s + 1] & 0x0F) << 8 | Int(d[s + 2])
        let sectionEnd = min(end, s + 3 + sectionLength - 4)
        let programInfoLength = Int(d[s + 10] & 0x0F) << 8 | Int(d[s + 11])
        s += 12 + programInfoLength
        while s + 5 <= sectionEnd {
            let type = d[s]
            let pid = Int(d[s + 1] & 0x1F) << 8 | Int(d[s + 2])
            let esLength = Int(d[s + 3] & 0x0F) << 8 | Int(d[s + 4])
            switch type {
            case 0x1B where videoPID < 0: videoPID = pid; videoCodec = .h264
            case 0x24 where videoPID < 0: videoPID = pid; videoCodec = .hevc
            case 0x0F:
                // Prefer AAC over any other audio stream already noted.
                if audioPID < 0 || !audioIsAAC { audioPID = pid; audioIsAAC = true }
            case 0x03, 0x04, 0x11, 0x81, 0x87:
                if audioPID < 0 { audioPID = pid; audioIsAAC = false }   // noted so the probe knows audio exists; not emitted
            default: break
            }
            s += 5 + esLength
        }
    }

    // MARK: PES

    /// (pts, dts, payloadStart) from a PES header, or nil if it isn't one.
    private func parsePESHeader(_ pes: [UInt8]) -> (pts: Int64?, dts: Int64?, payload: Int)? {
        guard pes.count >= 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return nil }
        let flags = pes[7]
        let headerLength = Int(pes[8])
        var pts: Int64?, dts: Int64?
        if flags & 0x80 != 0, pes.count >= 14 { pts = Self.readTimestamp(pes, 9) }
        if flags & 0x40 != 0, pes.count >= 19 { dts = Self.readTimestamp(pes, 14) }
        let payload = 9 + headerLength
        guard payload <= pes.count else { return nil }
        return (pts, dts, payload)
    }

    private static func readTimestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        (Int64(b[i] >> 1 & 0x07) << 30) | (Int64(b[i + 1]) << 22) | (Int64(b[i + 2] >> 1) << 15) | (Int64(b[i + 3]) << 7) | Int64(b[i + 4] >> 1)
    }

    private func finalizeVideoPES() {
        videoPESOpen = false
        guard let codec = videoCodec, let hdr = parsePESHeader(videoPES) else { return }
        let payload = videoPES
        var out: [UInt8] = []
        var sync = false
        for r in Self.nalRanges(payload, from: hdr.payload) {
            let header = payload[r.lowerBound]
            var keep = true
            switch codec {
            case .h264:
                let type = header & 0x1F
                switch type {
                case 7: Self.remember(&sps, Array(payload[r])); keep = false
                case 8: Self.remember(&pps, Array(payload[r])); keep = false
                case 9, 12: keep = false                                  // AUD, filler
                case 5: sync = true
                default: break
                }
            case .hevc:
                let type = (header >> 1) & 0x3F
                switch type {
                case 32: Self.remember(&vps, Array(payload[r])); keep = false
                case 33: Self.remember(&sps, Array(payload[r])); keep = false
                case 34: Self.remember(&pps, Array(payload[r])); keep = false
                case 35, 38: keep = false                                 // AUD, filler
                case 16...21: sync = true                                 // BLA / IDR / CRA
                default: break
                }
            }
            if keep {
                let len = UInt32(r.count).bigEndian
                withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
                out.append(contentsOf: payload[r])
            }
        }
        if formats.video == nil { formats.video = makeVideoFormat(codec) }
        guard !out.isEmpty, formats.video != nil, let rawPTS = hdr.pts else { return }
        // Never start on a non-key frame: the writer requires the first video sample to be sync.
        if !seenSync { if sync { seenSync = true } else { return } }

        let ptsU = videoWrap.unwrap(rawPTS)
        let dtsU = hdr.dts.map { videoWrap.unwrap($0) } ?? ptsU
        var dts = dtsU + offset
        var pts = ptsU + offset
        if let last = lastVideoDTS {
            let gap = dts - last
            if gap <= 0 || gap > 10 * Int64(TSRemuxer.timescale) {
                // A discontinuity (spliced segments, a reset clock): continue the timeline instead of
                // handing the writer a backwards or wildly forward DTS.
                let fix = (last + lastVideoDuration) - dts
                offset += fix; dts += fix; pts += fix
            } else {
                lastVideoDuration = gap
            }
        }
        lastVideoDTS = dts
        lastVideoPTS = pts
        if firstVideoTime == nil { firstVideoTime = min(dts, pts) }
        if emitVideo {
            pending.append(Sample(isVideo: true, bytes: out, pts: pts - base, dts: dts - base, sync: sync))
        }
    }

    private func finalizeAudioPES() {
        audioPESOpen = false
        guard audioIsAAC, let hdr = parsePESHeader(audioPES) else { return }
        if let rawPTS = hdr.pts, audioLeftover.isEmpty {
            audioBasePTS = audioWrap.unwrap(rawPTS) + offset
            audioFramesSinceBase = 0
        }
        var buf = audioLeftover
        buf.append(contentsOf: audioPES[hdr.payload...])
        var i = 0
        let n = buf.count
        while i + 7 <= n {
            guard buf[i] == 0xFF, buf[i + 1] & 0xF6 == 0xF0 else { i += 1; continue }   // ADTS sync
            let protectionAbsent = buf[i + 1] & 0x01 != 0
            let profile = Int(buf[i + 2] >> 6) & 0x03
            let rateIndex = Int(buf[i + 2] >> 2) & 0x0F
            let channels = Int(buf[i + 2] & 0x01) << 2 | Int(buf[i + 3] >> 6) & 0x03
            let frameLength = Int(buf[i + 3] & 0x03) << 11 | Int(buf[i + 4]) << 3 | Int(buf[i + 5] >> 5) & 0x07
            let headerLength = protectionAbsent ? 7 : 9
            guard frameLength > headerLength, rateIndex < Self.aacSampleRates.count else { i += 1; continue }
            guard i + frameLength <= n else { break }                     // partial frame → next PES
            if formats.audio == nil {
                formats.audio = makeAudioFormat(profile: profile, rateIndex: rateIndex, channels: channels == 0 ? 2 : channels)
                formats.audioRate = Self.aacSampleRates[rateIndex]
            }
            if let basePTS = audioBasePTS, formats.audio != nil {
                let rate = Int64(formats.audioRate)
                let pts = basePTS + audioFramesSinceBase * 1024 * Int64(TSRemuxer.timescale) / rate
                audioFramesSinceBase += 1
                if firstAudioTime == nil { firstAudioTime = pts }
                if emitAudio {
                    pending.append(Sample(isVideo: false, bytes: Array(buf[(i + headerLength)..<(i + frameLength)]),
                                          pts: pts - base, dts: pts - base, sync: true))
                }
            }
            i += frameLength
        }
        audioLeftover = i < n ? Array(buf[i...]) : []
    }

    // MARK: Formats

    private func makeVideoFormat(_ codec: VideoCodec) -> CMFormatDescription? {
        let sets: [[UInt8]]
        switch codec {
        case .h264: guard !sps.isEmpty, !pps.isEmpty else { return nil }; sets = sps + pps
        case .hevc: guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { return nil }; sets = vps + sps + pps
        }
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in
                switch codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pp.baseAddress!, parameterSetSizes: sp.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                        parameterSetPointers: pp.baseAddress!, parameterSetSizes: sp.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                }
            }
        }
        return status == noErr ? fd : nil
    }

    private func makeAudioFormat(profile: Int, rateIndex: Int, channels: Int) -> CMFormatDescription? {
        let rate = Self.aacSampleRates[rateIndex]
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(rate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        // AudioSpecificConfig: 5 bits object type (ADTS profile + 1), 4 bits rate index, 4 bits channels.
        let objectType = UInt8(profile + 1)
        let cookie: [UInt8] = [objectType << 3 | UInt8(rateIndex >> 1), UInt8(rateIndex & 1) << 7 | UInt8(channels) << 3]
        var fd: CMFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }

    // MARK: Helpers

    /// Byte ranges of each NAL unit in an Annex-B stream (start codes 00 00 01 / 00 00 00 01 excluded).
    private static func nalRanges(_ b: [UInt8], from start: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let n = b.count
        var i = start
        var nalStart: Int?
        while i + 2 < n {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if let s = nalStart {
                    var e = i
                    if e > s, b[e - 1] == 0 { e -= 1 }                // 4-byte start code: the leading zero belongs to the code
                    if e > s { out.append(s..<e) }
                }
                i += 3
                nalStart = i
                continue
            }
            i += 1
        }
        if let s = nalStart, s < n { out.append(s..<n) }
        return out
    }

    private static func remember(_ list: inout [[UInt8]], _ set: [UInt8]) {
        if !list.contains(set) { list.append(set) }
    }
}

/// Unwraps 33-bit MPEG timestamps that roll over every ~26.5 h into a monotonic 64-bit value.
private struct TSWrap {
    private var last: Int64?
    private var wraps: Int64 = 0
    mutating func unwrap(_ raw: Int64) -> Int64 {
        if let last, raw < last - (1 << 32) { wraps += 1 }
        last = raw
        return raw + (wraps << 33)
    }
}
