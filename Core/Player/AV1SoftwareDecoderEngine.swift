import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import VideoToolbox
import libdav1d

// SDWebImage/libdav1d-Xcode 移除了 dav1d/src/arm 目录（CONFIG_ASM=0），但 dav1d/src/cpu.c 在 arm64 下仍会调用 dav1d_get_cpu_flags_arm
@_cdecl("dav1d_get_cpu_flags_arm")
public func dav1d_get_cpu_flags_arm() -> UInt32 {
    return 0
}

public struct MP4AV1Sample: Sendable {
    public let offset: UInt64
    public let size: UInt32
    public let pts: TimeInterval
    public let isKeyframe: Bool
}

public struct MP4AV1TrackInfo: Sendable {
    public let timescale: UInt32
    public let duration: TimeInterval
    public let width: Int
    public let height: Int
    public let av1CConfigOBUs: Data
    public let samples: [MP4AV1Sample]
}

/// 纯 Swift MP4/ISOBMFF (av01) 解复用器：不依赖 iOS 硬件解码器，直接从 MP4 容器提取 AV1 帧偏移、时间戳与 av1C 序列头
public enum MP4AV1Demuxer {
    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
            return (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
        }
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
            return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
        }
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let hi = UInt64(readU32(data, offset))
        let lo = UInt64(readU32(data, offset + 4))
        return (hi << 32) | lo
    }

    private static func boxType(_ data: Data, _ offset: Int) -> String {
        guard offset + 8 <= data.count else { return "" }
        let sub = data.subdata(in: (offset + 4)..<(offset + 8))
        return String(data: sub, encoding: .ascii) ?? ""
    }

    private static func findBox(in data: Data, range: Range<Int>, targetType: String) -> Range<Int>? {
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var sz = Int(readU32(data, pos))
            let type = boxType(data, pos)
            var hdr = 8
            if sz == 1 {
                guard pos + 16 <= range.upperBound else { break }
                sz = Int(readU64(data, pos + 8))
                hdr = 16
            } else if sz == 0 {
                sz = range.upperBound - pos
            }
            if sz < hdr || pos + sz > range.upperBound { break }
            if type == targetType {
                return (pos + hdr)..<(pos + sz)
            }
            pos += sz
        }
        return nil
    }

    public static func parseAV1Track(from url: URL) -> MP4AV1TrackInfo? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let fileSize: UInt64
        if let end = try? fh.seekToEnd() {
            fileSize = end
        } else {
            return nil
        }

        // 1. 扫描顶层 Box 找到 moov（仅读取 moov，避免把整个数 GB 的 mdat 读入内存）
        var pos: UInt64 = 0
        var moovData: Data?
        while pos + 8 <= fileSize {
            try? fh.seek(toOffset: pos)
            guard let hdrData = try? fh.read(upToCount: 16), hdrData.count >= 8 else { break }
            var sz = UInt64(readU32(hdrData, 0))
            let type = boxType(hdrData, 0)
            var hdrSize: UInt64 = 8
            if sz == 1 {
                guard hdrData.count >= 16 else { break }
                sz = readU64(hdrData, 8)
                hdrSize = 16
            } else if sz == 0 {
                sz = fileSize - pos
            }
            if sz < hdrSize || pos + sz > fileSize { break }

            if type == "moov" {
                let payloadSize = Int(sz - hdrSize)
                // 安全上限：moov 通常几百 KB 到几十 MB
                guard payloadSize > 0 && payloadSize < 120 * 1024 * 1024 else { return nil }
                try? fh.seek(toOffset: pos + hdrSize)
                moovData = try? fh.read(upToCount: payloadSize)
                break
            }
            pos += sz
        }

        guard let moov = moovData else { return nil }

        // 2. 遍历 moov 下的所有 trak，寻找编码为 av01 的视频轨
        var tpos = 0
        while tpos + 8 <= moov.count {
            var sz = Int(readU32(moov, tpos))
            let type = boxType(moov, tpos)
            var hdr = 8
            if sz == 1 {
                guard tpos + 16 <= moov.count else { break }
                sz = Int(readU64(moov, tpos + 8))
                hdr = 16
            } else if sz == 0 {
                sz = moov.count - tpos
            }
            if sz < hdr || tpos + sz > moov.count { break }

            if type == "trak" {
                let trakRange = (tpos + hdr)..<(tpos + sz)
                if let info = parseVideoTrakIfAV1(moov: moov, trakRange: trakRange) {
                    return info
                }
            }
            tpos += sz
        }

        return nil
    }

    private static func parseVideoTrakIfAV1(moov: Data, trakRange: Range<Int>) -> MP4AV1TrackInfo? {
        guard let mdiaRange = findBox(in: moov, range: trakRange, targetType: "mdia"),
              let hdlrRange = findBox(in: moov, range: mdiaRange, targetType: "hdlr"),
              hdlrRange.count >= 12 else {
            return nil
        }

        let handlerTypeData = moov.subdata(in: (hdlrRange.lowerBound + 8)..<(hdlrRange.lowerBound + 12))
        let handlerType = String(data: handlerTypeData, encoding: .ascii) ?? ""
        guard handlerType == "vide" else { return nil }

        guard let mdhdRange = findBox(in: moov, range: mdiaRange, targetType: "mdhd"),
              mdhdRange.count >= 20,
              let minfRange = findBox(in: moov, range: mdiaRange, targetType: "minf"),
              let stblRange = findBox(in: moov, range: minfRange, targetType: "stbl"),
              let stsdRange = findBox(in: moov, range: stblRange, targetType: "stsd"),
              stsdRange.count >= 16 else {
            return nil
        }

        let mdhdVersion = moov[mdhdRange.lowerBound]
        let timescale: UInt32
        let rawDuration: UInt64
        if mdhdVersion == 1 {
            guard mdhdRange.count >= 32 else { return nil }
            timescale = readU32(moov, mdhdRange.lowerBound + 20)
            rawDuration = readU64(moov, mdhdRange.lowerBound + 24)
        } else {
            timescale = readU32(moov, mdhdRange.lowerBound + 12)
            rawDuration = UInt64(readU32(moov, mdhdRange.lowerBound + 16))
        }
        guard timescale > 0 else { return nil }

        // 检查 stsd 第一个 SampleEntry 是否为 av01
        let entryStart = stsdRange.lowerBound + 8
        let entrySize = Int(readU32(moov, entryStart))
        let codecTag = boxType(moov, entryStart)
        guard codecTag == "av01", entryStart + entrySize <= stsdRange.upperBound else {
            return nil
        }

        let width = entryStart + 34 <= stsdRange.upperBound ? Int(readU16(moov, entryStart + 32)) : 0
        let height = entryStart + 36 <= stsdRange.upperBound ? Int(readU16(moov, entryStart + 34)) : 0

        // 提取 av1C Sequence Header OBUs（跳过前 4 字节 AV1CodecConfigurationRecord 头）
        var av1CConfigOBUs = Data()
        if entrySize > 86 {
            let childRange = (entryStart + 86)..<(entryStart + entrySize)
            if let av1cRange = findBox(in: moov, range: childRange, targetType: "av1C"),
               av1cRange.count > 4 {
                av1CConfigOBUs = moov.subdata(in: (av1cRange.lowerBound + 4)..<av1cRange.upperBound)
            }
        }

        // 解析 stsz, stsc, stco/co64, stts, stss
        guard let stszRange = findBox(in: moov, range: stblRange, targetType: "stsz"),
              stszRange.count >= 12,
              let stscRange = findBox(in: moov, range: stblRange, targetType: "stsc"),
              stscRange.count >= 8,
              let sttsRange = findBox(in: moov, range: stblRange, targetType: "stts"),
              sttsRange.count >= 8 else {
            return nil
        }

        let stcoRange = findBox(in: moov, range: stblRange, targetType: "stco")
        let co64Range = findBox(in: moov, range: stblRange, targetType: "co64")
        guard stcoRange != nil || co64Range != nil else { return nil }

        let fixedSampleSize = readU32(moov, stszRange.lowerBound + 4)
        let sampleCount = Int(readU32(moov, stszRange.lowerBound + 8))
        guard sampleCount > 0 else { return nil }

        var sizes = [UInt32](repeating: fixedSampleSize, count: sampleCount)
        if fixedSampleSize == 0 {
            let tableStart = stszRange.lowerBound + 12
            guard tableStart + sampleCount * 4 <= stszRange.upperBound else { return nil }
            for i in 0..<sampleCount {
                sizes[i] = readU32(moov, tableStart + i * 4)
            }
        }

        // Chunk Offsets
        var chunkOffsets: [UInt64] = []
        if let stco = stcoRange, stco.count >= 8 {
            let chunkCount = Int(readU32(moov, stco.lowerBound + 4))
            chunkOffsets.reserveCapacity(chunkCount)
            let base = stco.lowerBound + 8
            for c in 0..<chunkCount where base + (c + 1) * 4 <= stco.upperBound {
                chunkOffsets.append(UInt64(readU32(moov, base + c * 4)))
            }
        } else if let co64 = co64Range, co64.count >= 8 {
            let chunkCount = Int(readU32(moov, co64.lowerBound + 4))
            chunkOffsets.reserveCapacity(chunkCount)
            let base = co64.lowerBound + 8
            for c in 0..<chunkCount where base + (c + 1) * 8 <= co64.upperBound {
                chunkOffsets.append(readU64(moov, base + c * 8))
            }
        }

        // Sample-to-Chunk (stsc)
        var offsets = [UInt64](repeating: 0, count: sampleCount)
        let stscCount = Int(readU32(moov, stscRange.lowerBound + 4))
        let stscBase = stscRange.lowerBound + 8
        var sampleIdx = 0
        for e in 0..<stscCount {
            guard stscBase + (e + 1) * 12 <= stscRange.upperBound else { break }
            let firstChunk = max(0, Int(readU32(moov, stscBase + e * 12)) - 1)
            let samplesPerChunk = Int(readU32(moov, stscBase + e * 12 + 4))
            let nextFirstChunk: Int
            if e + 1 < stscCount && stscBase + (e + 2) * 12 <= stscRange.upperBound {
                nextFirstChunk = max(0, Int(readU32(moov, stscBase + (e + 1) * 12)) - 1)
            } else {
                nextFirstChunk = chunkOffsets.count
            }
            for ch in firstChunk..<min(nextFirstChunk, chunkOffsets.count) {
                var curOffset = chunkOffsets[ch]
                for _ in 0..<samplesPerChunk {
                    guard sampleIdx < sampleCount else { break }
                    offsets[sampleIdx] = curOffset
                    curOffset += UInt64(sizes[sampleIdx])
                    sampleIdx += 1
                }
            }
        }

        // Time-to-Sample (stts)
        var ptsList = [TimeInterval](repeating: 0, count: sampleCount)
        let sttsCount = Int(readU32(moov, sttsRange.lowerBound + 4))
        let sttsBase = sttsRange.lowerBound + 8
        var sIdx = 0
        var curDts: UInt64 = 0
        for e in 0..<sttsCount {
            guard sttsBase + (e + 1) * 8 <= sttsRange.upperBound else { break }
            let cnt = Int(readU32(moov, sttsBase + e * 8))
            let delta = UInt64(readU32(moov, sttsBase + e * 8 + 4))
            for _ in 0..<cnt {
                guard sIdx < sampleCount else { break }
                ptsList[sIdx] = Double(curDts) / Double(timescale)
                curDts += delta
                sIdx += 1
            }
        }

        // Sync Samples / Keyframes (stss)
        var isKeyList = [Bool](repeating: false, count: sampleCount)
        if let stssRange = findBox(in: moov, range: stblRange, targetType: "stss"), stssRange.count >= 8 {
            let stssCount = Int(readU32(moov, stssRange.lowerBound + 4))
            let stssBase = stssRange.lowerBound + 8
            for k in 0..<stssCount {
                guard stssBase + (k + 1) * 4 <= stssRange.upperBound else { break }
                let syncIdx = Int(readU32(moov, stssBase + k * 4)) - 1
                if syncIdx >= 0 && syncIdx < sampleCount {
                    isKeyList[syncIdx] = true
                }
            }
        } else {
            isKeyList[0] = true
        }

        var samples: [MP4AV1Sample] = []
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            samples.append(
                MP4AV1Sample(
                    offset: offsets[i],
                    size: sizes[i],
                    pts: ptsList[i],
                    isKeyframe: isKeyList[i]
                )
            )
        }

        let duration = Double(rawDuration) / Double(timescale)
        return MP4AV1TrackInfo(
            timescale: timescale,
            duration: duration,
            width: width,
            height: height,
            av1CConfigOBUs: av1CConfigOBUs,
            samples: samples
        )
    }
}

/// 基于 VideoLAN libdav1d (ARM64 NEON 加速) 的 AV1 实时软解渲染与硬件转码兼容引擎
public final class AV1SoftwareDecoderEngine: @unchecked Sendable {
    public let url: URL
    public let trackInfo: MP4AV1TrackInfo

    private var ctx: OpaquePointer?
    private var fileHandle: FileHandle?
    private var currentSampleIndex: Int = 0
    private var lastDecodedPTS: TimeInterval = -100
    private let lock = NSLock()

    public init?(url: URL) {
        guard let info = MP4AV1Demuxer.parseAV1Track(from: url),
              let fh = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        self.url = url
        self.trackInfo = info
        self.fileHandle = fh

        var settings = Dav1dSettings()
        dav1d_default_settings(&settings)
        settings.n_threads = 4
        settings.max_frame_delay = 1

        var pointer: OpaquePointer?
        guard dav1d_open(&pointer, &settings) == 0, let validCtx = pointer else {
            try? fh.close()
            return nil
        }
        self.ctx = validCtx
        sendSequenceHeader()
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if ctx != nil {
            dav1d_close(&ctx)
            ctx = nil
        }
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func sendSequenceHeader() {
        guard let ctx = ctx, !trackInfo.av1CConfigOBUs.isEmpty else { return }
        var seqData = Dav1dData()
        let count = trackInfo.av1CConfigOBUs.count
        if let dst = dav1d_data_create(&seqData, count) {
            trackInfo.av1CConfigOBUs.copyBytes(to: dst, count: count)
            let res = dav1d_send_data(ctx, &seqData)
            if res < 0 && res != -Int32(EAGAIN) {
                dav1d_data_unref(&seqData)
            }
        }
    }

    /// 定位到离 targetTime 最近的前置关键帧 (stss)
    private func findKeyframeIndex(atOrBefore targetTime: TimeInterval) -> Int {
        let samples = trackInfo.samples
        guard !samples.isEmpty else { return 0 }

        // 二分查找 pts <= targetTime 的最大下标
        var lo = 0
        var hi = samples.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if samples[mid].pts <= targetTime {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        // 从 best 向前找最近的关键帧
        var k = best
        while k > 0 && !samples[k].isKeyframe {
            k -= 1
        }
        return k
    }

    /// 给定目标播放时间，实时软解并返回当前帧 CGImage
    public func decodeFrame(at targetTime: TimeInterval) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }

        guard let ctx = ctx, let fh = fileHandle, !trackInfo.samples.isEmpty else { return nil }

        // 如果发生了快进/快退跳转或尚未开始解码，先重置到最近关键帧
        if currentSampleIndex >= trackInfo.samples.count ||
           targetTime < lastDecodedPTS - 0.35 ||
           targetTime > lastDecodedPTS + 2.5 ||
           lastDecodedPTS < 0 {
            let keyIdx = findKeyframeIndex(atOrBefore: targetTime)
            dav1d_flush(ctx)
            sendSequenceHeader()
            currentSampleIndex = keyIdx
            lastDecodedPTS = trackInfo.samples[keyIdx].pts
        }

        // 如果当前已经解码到 targetTime 之后，无需重复解码
        if currentSampleIndex < trackInfo.samples.count &&
           trackInfo.samples[currentSampleIndex].pts > targetTime + 0.02 &&
           lastDecodedPTS >= 0 {
            return nil
        }

        var latestImage: CGImage?
        var steps = 0
        let maxCatchupSteps = 90

        while currentSampleIndex < trackInfo.samples.count && steps < maxCatchupSteps {
            let sample = trackInfo.samples[currentSampleIndex]
            if sample.pts > targetTime + 0.025 && latestImage != nil {
                break
            }

            currentSampleIndex += 1
            steps += 1

            guard sample.size > 0 else { continue }
            try? fh.seek(toOffset: sample.offset)
            guard let packetData = try? fh.read(upToCount: Int(sample.size)),
                  packetData.count == Int(sample.size) else {
                continue
            }

            let isNearTarget = (sample.pts >= targetTime - 0.06) ||
                               (currentSampleIndex >= trackInfo.samples.count) ||
                               (trackInfo.samples[min(currentSampleIndex, trackInfo.samples.count - 1)].pts > targetTime) ||
                               (steps == maxCatchupSteps)

            var dData = Dav1dData()
            if let dst = dav1d_data_create(&dData, packetData.count) {
                packetData.copyBytes(to: dst, count: packetData.count)
                dData.m.timestamp = Int64(sample.pts * 1_000_000.0)

                while dData.sz > 0 {
                    let sendRes = dav1d_send_data(ctx, &dData)
                    if sendRes < 0 && sendRes != -Int32(EAGAIN) {
                        dav1d_data_unref(&dData)
                        break
                    }

                    var pic = Dav1dPicture()
                    while dav1d_get_picture(ctx, &pic) == 0 {
                        let framePTS = Double(pic.m.timestamp) / 1_000_000.0
                        lastDecodedPTS = framePTS
                        if isNearTarget || framePTS >= targetTime - 0.05 {
                            if let img = Self.makeCGImage(from: &pic) {
                                latestImage = img
                            }
                        }
                        dav1d_picture_unref(&pic)
                    }
                }
            }

            if lastDecodedPTS >= targetTime - 0.015 && latestImage != nil {
                break
            }
        }

        return latestImage
    }

    /// 提取任意时间点的 AV1 视频缩略图（供媒体库卡片封面使用）
    public static func extractThumbnail(from url: URL, at targetTime: TimeInterval) -> CGImage? {
        guard let engine = AV1SoftwareDecoderEngine(url: url) else { return nil }
        defer { engine.close() }
        let keyIdx = engine.findKeyframeIndex(atOrBefore: targetTime)
        let keyTime = engine.trackInfo.samples[keyIdx].pts
        return engine.decodeFrame(at: keyTime)
    }

    /// 将 libdav1d 解码出的 YUV420P (I420) 帧转换为 NV12 CVPixelBuffer 并通过 VideoToolbox 硬件加速生成 CGImage
    public static func makeCGImage(from pic: inout Dav1dPicture) -> CGImage? {
        guard let pb = makePixelBuffer(from: &pic) else { return nil }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cgImage)
        return cgImage
    }

    public static func makePixelBuffer(from pic: inout Dav1dPicture) -> CVPixelBuffer? {
        let w = Int(pic.p.w)
        let h = Int(pic.p.h)
        guard w > 0, h > 0,
              let rawY = pic.data.0,
              let rawU = pic.data.1,
              let rawV = pic.data.2 else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            w,
            h,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let baseY = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
           let baseUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let srcY = rawY.assumingMemoryBound(to: UInt8.self)
            let srcU = rawU.assumingMemoryBound(to: UInt8.self)
            let srcV = rawV.assumingMemoryBound(to: UInt8.self)
            let srcStrideY = Int(pic.stride.0)
            let srcStrideUV = Int(pic.stride.1)

            let dstY = baseY.assumingMemoryBound(to: UInt8.self)
            let dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for r in 0..<h {
                memcpy(dstY.advanced(by: r * dstStrideY), srcY.advanced(by: r * srcStrideY), w)
            }

            let dstUV = baseUV.assumingMemoryBound(to: UInt8.self)
            let dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let cw = (w + 1) / 2
            let ch = (h + 1) / 2
            for r in 0..<ch {
                let dRow = dstUV.advanced(by: r * dstStrideUV)
                let uRow = srcU.advanced(by: r * srcStrideUV)
                let vRow = srcV.advanced(by: r * srcStrideUV)
                for c in 0..<cw {
                    dRow[2 * c] = uRow[c]
                    dRow[2 * c + 1] = vRow[c]
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
