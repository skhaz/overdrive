import AudioToolbox
import Foundation

enum FileInfo {
    private static let cache = NSCache<NSURL, NSArray>()
    private static let vorbis: AudioFormatID = 0x766F_7262
    private static let lossless: Set<AudioFormatID> = [kAudioFormatAppleLossless, kAudioFormatFLAC, kAudioFormatLinearPCM]

    static func lines(_ url: URL) -> [String] {
        if let lines = cache.object(forKey: url as NSURL) as? [String] { return lines }

        let lines = read(url)
        cache.setObject(lines as NSArray, forKey: url as NSURL)
        return lines
    }

    private static func read(_ url: URL) -> [String] {
        var lines: [String] = []
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var file: AudioFileID?

        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file {
            defer { AudioFileClose(file) }

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let known = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr

            if known {
                lines.append("Format: \(name(format.mFormatID))")
                lines.append("Sample Rate: \((format.mSampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
                lines.append("Channels: \(format.mChannelsPerFrame == 1 ? "Mono" : format.mChannelsPerFrame == 2 ? "Stereo" : String(format.mChannelsPerFrame))")
            }

            var depth: Int32 = 0
            size = UInt32(MemoryLayout<Int32>.size)
            if known, lossless.contains(format.mFormatID), AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &depth) == noErr, depth > 0 {
                lines.append("Bit Depth: \(depth)-bit")
            }

            var rate: UInt32 = 0
            var duration = 0.0
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &rate)
            size = UInt32(MemoryLayout<Double>.size)
            AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)

            if rate == 0, duration > 1 { rate = UInt32(clamping: Int((Double(bytes) * 8 / duration).rounded())) }
            if rate > 0 { lines.append("Bit Rate: \((UInt64(rate) + 500) / 1000) kbps\(known && format.mFormatID == kAudioFormatMPEGLayer3 && MPEG.variable(url) ? " (VBR)" : "")") }
        }

        lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
        return lines
    }

    private static func name(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatMPEG4AAC_HE: "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: "HE-AAC v2"
        case kAudioFormatAppleLossless: "Apple Lossless"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatOpus: "Opus"
        case vorbis: "Vorbis"
        case kAudioFormatLinearPCM: "PCM"
        default: String(bytes: withUnsafeBytes(of: id.bigEndian, Array.init), encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        }
    }
}
