import Accelerate
import AVFoundation
import MediaToolbox
import Synchronization

nonisolated final class Spectrum: Sendable {
    static let size = 4096

    private struct Ring {
        var samples = [Float](repeating: 0, count: Spectrum.size)
        var head = 0
        var rate = 44100.0
    }

    private let ring = Mutex(Ring())
    private let open = Atomic(true)

    init() {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        let silence = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        defer {
            silence.deallocate()
            free(list.unsafeMutablePointer)
        }

        silence.initialize(repeating: 0, count: 2)
        for count in 1...2 {
            list.count = count
            for index in 0..<count { list[index] = AudioBuffer(mNumberChannels: UInt32(3 - count), mDataByteSize: 8 / UInt32(count), mData: silence) }
            write(list, frames: 1)
        }
        ring.withLock { $0.head = 0 }
    }

    var listening: Bool {
        get { open.load(ordering: .relaxed) }
        set { open.store(newValue, ordering: .relaxed) }
    }

    func prepare(rate: Double) {
        guard rate > 0 else { return }

        ring.withLock { $0.rate = rate }
    }

    func write(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0, !list.isEmpty, listening else { return }

        ring.withLockIfAvailable { ring in
            let interleaved = list.count == 1
            let channels = interleaved ? max(Int(list[0].mNumberChannels), 1) : list.count
            let stride = interleaved ? channels : 1
            var count = frames
            for index in 0..<list.count {
                guard list[index].mData != nil else { return }

                count = min(count, Int(list[index].mDataByteSize) / (MemoryLayout<Float>.size * stride))
            }

            let size = ring.samples.count
            let first = max(count - size, 0)
            let start = ring.head
            let scale = 1 / Float(channels)
            ring.samples.withUnsafeMutableBufferPointer { out in
                for channel in 0..<channels {
                    let data = list[interleaved ? 0 : channel].mData.unsafelyUnwrapped.assumingMemoryBound(to: Float.self)
                    let offset = interleaved ? channel : 0
                    var head = start
                    for frame in first..<count {
                        let value = data[frame * stride + offset] * scale
                        out[head] = channel == 0 ? value : out[head] + value
                        head = head + 1 == size ? 0 : head + 1
                    }
                }
            }
            ring.head = (start + count - first) % size
        }
    }

    func copy(into target: UnsafeMutableBufferPointer<Float>) -> Double {
        ring.withLock { ring in
            let size = ring.samples.count
            let tail = size - ring.head
            ring.samples.withUnsafeBufferPointer { samples in
                guard target.count >= size, let source = samples.baseAddress, let out = target.baseAddress else { return }

                out.update(from: source + ring.head, count: tail)
                (out + tail).update(from: source, count: ring.head)
            }
            return ring.rate
        }
    }

    func tap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<Spectrum>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<Spectrum>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(rate: format.pointee.mSampleRate)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }

                Unmanaged<Spectrum>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .write(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(self).release()
            Log.player.error("spectrum tap failed", metadata: ["status": "\(status)"])
            return nil
        }

        return tap
    }
}

final class Analyzer {
    static let floor: Float = -72
    static let ceiling: Float = -12
    static let low = 40.0
    static let high = 16000.0

    private let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(Spectrum.size))), radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Spectrum.size, isHalfWindow: false)
    private var samples = [Float](repeating: 0, count: Spectrum.size)
    private var real = [Float](repeating: 0, count: Spectrum.size / 2)
    private var imaginary = [Float](repeating: 0, count: Spectrum.size / 2)
    private var magnitudes = [Float](repeating: 0, count: Spectrum.size / 2)
    private var bands: [(low: Double, high: Double, tilt: Float)] = []
    private var shape = (count: 0, rate: 0.0)
    private(set) var levels: [Float] = []
    private var last: Double?

    var idle: Bool { levels.allSatisfy { $0 < 0.001 } }

    func update(_ spectrum: Spectrum, count: Int, active: Bool, time: Double) -> [Float] {
        let rate = active ? measure(spectrum) : shape.rate
        if shape.count != count || shape.rate != rate { layout(count, rate) }

        let elapsed = last.map { min(max(time - $0, 0), 0.1) } ?? 0
        last = time
        let rise = Float(1 - exp(-elapsed / 0.03))
        let fall = Float(1 - exp(-elapsed / 0.22))

        for index in levels.indices {
            let target = active ? level(bands[index]) : 0
            let current = levels[index]
            levels[index] = current + (target - current) * (target > current ? rise : fall)
        }

        return levels
    }

    private func measure(_ spectrum: Spectrum) -> Double {
        let size = Spectrum.size
        let rate = samples.withUnsafeMutableBufferPointer { samples in
            let rate = spectrum.copy(into: samples)
            window.withUnsafeBufferPointer { vDSP_vmul(samples.baseAddress!, 1, $0.baseAddress!, 1, samples.baseAddress!, 1, vDSP_Length(size)) }
            return rate
        }

        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                guard let realp = real.baseAddress, let imagp = imaginary.baseAddress else { return }

                var split = DSPSplitComplex(realp: realp, imagp: imagp)
                samples.withUnsafeBytes { raw in
                    guard let complex = raw.bindMemory(to: DSPComplex.self).baseAddress else { return }

                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                }
                fft?.forward(input: split, output: &split)
                imagp[0] = 0
                var scale = 2 / Float(size)
                magnitudes.withUnsafeMutableBufferPointer {
                    vDSP_zvabs(&split, 1, $0.baseAddress!, 1, vDSP_Length(size / 2))
                    vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
        return rate
    }

    private func layout(_ count: Int, _ rate: Double) {
        shape = (count, rate)
        levels = [Float](repeating: 0, count: count)
        guard count > 0, rate > 0 else { return bands = [] }

        let resolution = rate / Double(Spectrum.size)
        let high = min(Self.high, rate / 2)
        let ratio = high / Self.low
        bands = (0..<count).map { index in
            let low = Self.low * pow(ratio, Double(index) / Double(count))
            let high = Self.low * pow(ratio, Double(index + 1) / Double(count))
            return (low / resolution, high / resolution, Float(3 * log2(sqrt(low * high) / 1000)))
        }
    }

    private func level(_ band: (low: Double, high: Double, tilt: Float)) -> Float {
        let last = magnitudes.count - 1
        var magnitude: Float = 0
        if band.high - band.low < 2 {
            let center = min((band.low + band.high) / 2, Double(last))
            let index = Int(center)
            let next = min(index + 1, last)
            let fraction = Float(center - Double(index))
            magnitude = magnitudes[index] * (1 - fraction) + magnitudes[next] * fraction
        } else {
            for index in Int(band.low.rounded(.up))...min(Int(band.high), last) { magnitude = max(magnitude, magnitudes[index]) }
        }

        let decibels = 20 * log10(max(magnitude, 1e-9)) + band.tilt
        return min(max((decibels - Self.floor) / (Self.ceiling - Self.floor), 0), 1)
    }
}
