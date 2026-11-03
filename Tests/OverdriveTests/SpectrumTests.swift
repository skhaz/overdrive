import AVFoundation
import Testing
@testable import Overdrive

@MainActor
struct SpectrumTests {
    private static func feed(_ spectrum: Spectrum, interleaved: Bool = true, frames: Int = Spectrum.size, _ sample: (Int) -> Float) {
        let channels = 2
        let buffers = interleaved ? 1 : channels
        let length = interleaved ? frames * channels : frames
        let list = AudioBufferList.allocate(maximumBuffers: buffers)
        let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: length * buffers)
        defer {
            storage.deallocate()
            free(list.unsafeMutablePointer)
        }

        for index in 0..<buffers {
            let base = storage.baseAddress! + index * length
            for offset in 0..<length { base[offset] = sample(interleaved ? offset / channels : offset) }
            list[index] = AudioBuffer(mNumberChannels: UInt32(interleaved ? channels : 1), mDataByteSize: UInt32(length * MemoryLayout<Float>.size), mData: base)
        }
        spectrum.write(list, frames: frames)
    }

    private static func settle(_ analyzer: Analyzer, _ spectrum: Spectrum, count: Int = 64, active: Bool = true) -> [Float] {
        var levels: [Float] = []
        for step in 0..<20 { levels = analyzer.update(spectrum, count: count, active: active, time: Double(step) / 10) }
        return levels
    }

    private static func band(of frequency: Double, count: Int, rate: Double) -> Int {
        Int(Double(count) * log(frequency / Analyzer.low) / log(min(Analyzer.high, rate / 2) / Analyzer.low))
    }

    @Test(arguments: [true, false])
    func aToneLightsItsBand(interleaved: Bool) {
        let spectrum = Spectrum()
        spectrum.prepare(rate: 48000)
        Self.feed(spectrum, interleaved: interleaved) { Float(0.5 * sin(2 * .pi * 1000 * Double($0) / 48000)) }

        let levels = Self.settle(Analyzer(), spectrum)
        let peak = levels.indices.max { levels[$0] < levels[$1] }!
        #expect(abs(peak - Self.band(of: 1000, count: 64, rate: 48000)) <= 1)
        #expect(levels[peak] > 0.8)
        #expect(levels[2] < 0.1, "a pure tone must not light the bass")
    }

    @Test func silenceShowsNothing() {
        let spectrum = Spectrum()
        Self.feed(spectrum) { _ in 0 }
        let analyzer = Analyzer()

        #expect(Self.settle(analyzer, spectrum).allSatisfy { $0 == 0 })
        #expect(analyzer.idle)
    }

    @Test func pausedBarsFallToZero() {
        let spectrum = Spectrum()
        Self.feed(spectrum) { Float(sin(2 * .pi * 440 * Double($0) / 44100)) }
        let analyzer = Analyzer()
        _ = Self.settle(analyzer, spectrum)
        #expect(!analyzer.idle)

        _ = Self.settle(analyzer, spectrum, active: false)
        #expect(analyzer.idle, "the bars must not freeze when the song pauses")
    }

    @Test func aShortBufferDoesNotOverrun() {
        let spectrum = Spectrum()
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }

        var samples: [Float] = [1, 1, 1, 1]
        samples.withUnsafeMutableBytes { bytes in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            spectrum.write(list, frames: 1000)
        }

        var out = [Float](repeating: 0, count: Spectrum.size)
        _ = out.withUnsafeMutableBufferPointer { spectrum.copy(into: $0) }
        #expect(out.suffix(2) == [1, 1])
        #expect(out.dropLast(2).allSatisfy { $0 == 0 })
    }

    @Test func theTapReleasesTheSpectrum() {
        weak var weak: Spectrum?
        do {
            let spectrum = Spectrum()
            weak = spectrum
            let tap = spectrum.tap()
            #expect(tap != nil)
        }
        #expect(weak == nil, "a tap of a gone song must not keep the spectrum")
    }

    @Test func theWidthSetsTheBars() {
        let analyzer = Analyzer()
        #expect(analyzer.update(Spectrum(), count: 10, active: true, time: 0).count == 10)
        #expect(analyzer.update(Spectrum(), count: 3, active: true, time: 0).count == 3)
    }

    @Test func aHiddenWindowSkipsTheSamples() {
        let spectrum = Spectrum()
        spectrum.listening = false
        Self.feed(spectrum) { _ in 1 }

        var out = [Float](repeating: 0, count: Spectrum.size)
        _ = out.withUnsafeMutableBufferPointer { spectrum.copy(into: $0) }
        #expect(out.allSatisfy { $0 == 0 }, "the audio thread must not copy samples that nobody sees")

        spectrum.listening = true
        Self.feed(spectrum) { _ in 1 }
        _ = out.withUnsafeMutableBufferPointer { spectrum.copy(into: $0) }
        #expect(out.allSatisfy { $0 == 1 })
    }

    @Test func theBarsRunOnlyWhileTheWindowShows() {
        #expect(SpectrumBar.running(shown: true, active: true, fading: false))
        #expect(SpectrumBar.running(shown: true, active: false, fading: true))
        #expect(!SpectrumBar.running(shown: true, active: false, fading: false))
        #expect(!SpectrumBar.running(shown: false, active: true, fading: false), "a window in the background must not draw")
        #expect(!SpectrumBar.running(shown: false, active: false, fading: true))
    }

    @Test func theBarsFillTheWidthAndRiseFromTheBottom() {
        let size = CGSize(width: 1078, height: SpectrumBar.height)
        let count = SpectrumBar.count(size.width)
        let first = SpectrumBar.bar(0, 0, count: count, in: size)
        let last = SpectrumBar.bar(count - 1, 1, count: count, in: size)

        #expect(first.minX == 0 && first.minY == 0, "a bar stands on the bottom edge")
        #expect(first.height == first.width, "a silent bar is a dot, not nothing")
        #expect(last.height == size.height, "a full bar takes the whole height")
        #expect(abs(last.maxX - size.width) < 0.001, "the bars take the full width")
        #expect(SpectrumBar.bar(0, 2, count: count, in: size).height == size.height * 2, "the analyzer caps the level, not the layout")
    }

    @Test func theLayersFollowTheWidthAndTheLevels() throws {
        let view = SpectrumView(spectrum: Spectrum())
        view.frame = CGRect(x: 0, y: 0, width: 600, height: SpectrumBar.height)
        view.layout()
        let mask = try #require(view.layer?.sublayers?.first?.mask)

        #expect(mask.sublayers?.count == SpectrumBar.count(600), "one layer per bar")
        #expect(mask.sublayers?.allSatisfy { $0.frame.height == $0.frame.width } == true, "a new view starts silent")

        view.frame.size.width = 300
        view.layout()
        #expect(mask.sublayers?.count == SpectrumBar.count(300), "a new width makes the bars again")

        let spectrum = Spectrum()
        Self.feed(spectrum) { Float(sin(Double($0) / 3)) }
        let live = SpectrumView(spectrum: spectrum)
        live.frame = CGRect(x: 0, y: 0, width: 600, height: SpectrumBar.height)
        live.layout()
        live.active = true
        for frame in 1...30 { live.advance(to: Double(frame) / 60) }
        let bars = try #require(live.layer?.sublayers?.first?.mask?.sublayers)
        #expect(bars.contains { $0.frame.height > $0.frame.width }, "a frame moves the bars with the sound")
    }

    @Test func theSettingIsOnByDefault() {
        #expect(Spectrum.enabled(nil), "no saved state means the spectrum is on")
        #expect(Spectrum.enabled(true))
        #expect(!Spectrum.enabled(false))
        #expect(Spectrum.enabled("off"), "a value that is not a bool is no saved state")
    }

    @Test func clearingEmptiesTheRing() {
        let spectrum = Spectrum()
        Self.feed(spectrum) { _ in 1 }
        var out = [Float](repeating: 0, count: Spectrum.size)
        _ = out.withUnsafeMutableBufferPointer { spectrum.copy(into: $0) }
        #expect(out.allSatisfy { $0 == 1 })

        spectrum.clear()
        _ = out.withUnsafeMutableBufferPointer { spectrum.copy(into: $0) }
        #expect(out.allSatisfy { $0 == 0 }, "a spectrum that comes back must not show the samples of the last song")
    }
}
