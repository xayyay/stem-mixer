import Foundation
import AVFoundation

/// Port of the energy-peak BPM algorithm from the web app's index.html
enum BPMDetector {

    static func detect(from url: URL) -> Double? {
        guard let samples = loadMonoSamples(from: url) else { return nil }
        return detectFromSamples(samples, sampleRate: 44100)
    }

    static func detectFromSamples(_ samples: [Float], sampleRate: Double) -> Double? {
        let hopSize = Int(0.01 * sampleRate)   // 10 ms frames
        guard hopSize > 0 else { return nil }

        // Energy per frame
        var energyFrames: [Float] = []
        var i = 0
        while i + hopSize <= samples.count {
            let frame = samples[i..<(i + hopSize)]
            let e = frame.reduce(0) { $0 + $1 * $1 } / Float(hopSize)
            energyFrames.append(e)
            i += hopSize
        }
        guard energyFrames.count > 10 else { return nil }

        let meanEnergy = energyFrames.reduce(0, +) / Float(energyFrames.count)
        let threshold  = meanEnergy * 1.5

        // Peak detection (must be local max, above threshold, min 20 frames apart)
        let minSpacing = 20
        var peaks: [Int] = []
        var lastPeak = -minSpacing

        for idx in 1..<(energyFrames.count - 1) {
            let e = energyFrames[idx]
            guard e > threshold,
                  e >= energyFrames[idx - 1],
                  e >= energyFrames[idx + 1],
                  idx - lastPeak >= minSpacing else { continue }
            peaks.append(idx)
            lastPeak = idx
        }
        guard peaks.count > 2 else { return nil }

        // Average inter-peak interval → BPM
        var intervals: [Int] = []
        for k in 1..<peaks.count { intervals.append(peaks[k] - peaks[k - 1]) }
        let avgInterval = Double(intervals.reduce(0, +)) / Double(intervals.count)
        let bpm = 60.0 / (avgInterval * Double(hopSize) / sampleRate)

        guard bpm >= 40, bpm <= 300 else { return nil }
        return (bpm * 10).rounded() / 10
    }

    private static func loadMonoSamples(from url: URL) -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset),
              let track = try? asset.tracks(withMediaType: .audio).first else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()

        var result: [Float] = []
        while let buf = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buf) {
            let len = CMBlockBufferGetDataLength(block)
            var raw = [UInt8](repeating: 0, count: len)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &raw)
            raw.withUnsafeBytes { ptr in
                result.append(contentsOf: ptr.bindMemory(to: Float.self))
            }
        }
        return result.isEmpty ? nil : result
    }
}
