import AVFoundation
import Darwin
import Testing
@testable import Overdrive

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

private nonisolated(unsafe) var watched: pthread_t?
private nonisolated(unsafe) var allocations = 0

private let hook: MallocLogger = { type, _, _, _, _, _ in
    guard type & 2 != 0, let thread = watched, pthread_equal(thread, pthread_self()) != 0 else { return }

    allocations += 1
}

private func counting(_ body: () -> Void) -> Int {
    let slot = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")!.assumingMemoryBound(to: MallocLogger?.self)
    allocations = 0
    watched = pthread_self()
    slot.pointee = hook
    body()
    slot.pointee = nil
    watched = nil
    return allocations
}

#if DEBUG
private let optimized = false
#else
private let optimized = true
#endif

@MainActor
@Suite(.enabled(if: optimized, "unoptimized code allocates in every loop; run with swift test -c release"))
struct SpectrumCostTests {
    @Test func theCounterSeesAllocations() {
        let count = counting { _ = [Int](repeating: 1, count: 1000) }
        #expect(count >= 1, "the allocation counter must work, or the zero checks below prove nothing")
    }

    @Test func theAudioThreadNeverAllocates() {
        let spectrum = Spectrum()
        let interleaved = AudioBufferList.allocate(maximumBuffers: 1)
        let separate = AudioBufferList.allocate(maximumBuffers: 2)
        let samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: 1024)
        defer {
            samples.deallocate()
            free(interleaved.unsafeMutablePointer)
            free(separate.unsafeMutablePointer)
        }
        samples.initialize(repeating: 0.5)
        interleaved[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096, mData: samples.baseAddress)
        separate[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: samples.baseAddress)
        separate[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 2048, mData: samples.baseAddress! + 512)

        let count = counting {
            for _ in 0..<1000 {
                spectrum.write(interleaved, frames: 512)
                spectrum.write(separate, frames: 512)
            }
        }
        #expect(count == 0, "the first song of a launch must not allocate on the audio thread either")
    }

    @Test func aFrameAllocatesNothing() {
        let spectrum = Spectrum()
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        let samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: 1024)
        defer {
            samples.deallocate()
            free(list.unsafeMutablePointer)
        }
        for index in samples.indices { samples[index] = Float(sin(Double(index) / 7)) }
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 4096, mData: samples.baseAddress)
        let analyzer = Analyzer()
        var sum: Float = 0
        _ = analyzer.update(spectrum, count: 180, active: true, time: 0)

        let count = counting {
            for frame in 1...600 {
                spectrum.write(list, frames: 512)
                for level in analyzer.update(spectrum, count: 180, active: frame % 100 != 0, time: Double(frame) / 60) { sum += level }
            }
        }
        #expect(count == 0, "a frame must not allocate; only a new width does")
        #expect(sum > 0)
    }
}
