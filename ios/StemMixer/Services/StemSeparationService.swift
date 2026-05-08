import Foundation
import CoreML
import AVFoundation
import Accelerate

// MARK: - Errors

enum SeparationError: LocalizedError {
    case modelNotFound
    case modelLoadFailed(Error)
    case audioLoadFailed
    case inferenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Demucs.mlpackage not found in app bundle. See convert_to_coreml.py."
        case .modelLoadFailed(let e):
            return "Model load failed: \(e.localizedDescription)"
        case .audioLoadFailed:
            return "Could not read audio file."
        case .inferenceFailed(let e):
            return "Inference failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - StemSeparationService

final class StemSeparationService {
    static let shared = StemSeparationService()

    // These must match what convert_to_coreml.py produces.
    static let targetSampleRate: Double = 44100
    static let segmentSamples = 352800   // 8 seconds @ 44100
    static let overlap = 0.25            // 25% overlap-add
    static let stemNames = ["drums", "bass", "vocals", "other"] // htdemucs 4-stem order

    private var model: MLModel?

    private init() {}

    // MARK: - Model loading

    func loadModelIfNeeded() throws {
        guard model == nil else { return }
        guard let url = Bundle.main.url(forResource: "Demucs", withExtension: "mlpackage") else {
            throw SeparationError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all  // Neural Engine + GPU + CPU
        do {
            model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            throw SeparationError.modelLoadFailed(error)
        }
    }

    var isModelAvailable: Bool {
        Bundle.main.url(forResource: "Demucs", withExtension: "mlpackage") != nil
    }

    // MARK: - Separation

    /// Separates `audioURL` into stems, writing WAV files to `outputDir`.
    /// - Returns: dictionary of stemName → file URL
    func separate(audioURL: URL,
                  outputDir: URL,
                  progress: @escaping (Double) -> Void) async throws -> [String: URL] {
        try loadModelIfNeeded()
        guard let model else { throw SeparationError.modelNotFound }

        // Load & resample audio
        let (leftPCM, rightPCM) = try loadAudio(from: audioURL)

        let segLen = Self.segmentSamples
        let hopLen = Int(Double(segLen) * (1.0 - Self.overlap))
        let total  = leftPCM.count

        // Accumulator arrays (interleaved L/R per stem)
        var stemAccum:  [[Float]] = Self.stemNames.map { _ in [Float](repeating: 0, count: total * 2) }
        var weightAccum: [Float]  = [Float](repeating: 0, count: total)

        let window = hannWindow(size: segLen)

        var segStart = 0
        var segCount = 0
        var segTotal = max(1, Int(ceil(Double(total) / Double(hopLen))))

        while segStart < total {
            let segEnd = min(segStart + segLen, total)
            let actualLen = segEnd - segStart

            let left  = padToLength(Array(leftPCM[segStart..<segEnd]),  length: segLen)
            let right = padToLength(Array(rightPCM[segStart..<segEnd]), length: segLen)

            let stemChunks = try runModel(model: model, left: left, right: right)

            for (stemIdx, chunk) in stemChunks.enumerated() {
                // chunk = [L0,L1,...L(segLen-1), R0,R1,...] interleaved per channel
                for i in 0..<actualLen {
                    let w = window[i]
                    stemAccum[stemIdx][(segStart + i) * 2]     += chunk[i] * w           // L
                    stemAccum[stemIdx][(segStart + i) * 2 + 1] += chunk[segLen + i] * w  // R
                }
            }
            for i in 0..<actualLen {
                weightAccum[segStart + i] += window[i]
            }

            segCount += 1
            let p = Double(segCount) / Double(segTotal)
            await MainActor.run { progress(p) }

            if segEnd == total { break }
            segStart += hopLen
        }

        // Normalize by accumulated weights
        for stemIdx in 0..<stemAccum.count {
            for i in 0..<total {
                if weightAccum[i] > 1e-8 {
                    stemAccum[stemIdx][i * 2]     /= weightAccum[i]
                    stemAccum[stemIdx][i * 2 + 1] /= weightAccum[i]
                }
            }
        }

        // Write WAV files
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        var result: [String: URL] = [:]

        for (stemIdx, stemName) in Self.stemNames.enumerated() {
            let outURL = outputDir.appendingPathComponent("\(stemName).wav")
            try writeWAV(interleaved: stemAccum[stemIdx], sampleRate: Self.targetSampleRate, to: outURL)
            result[stemName] = outURL
        }

        return result
    }

    // MARK: - CoreML inference

    private func runModel(model: MLModel, left: [Float], right: [Float]) throws -> [[Float]] {
        let segLen = Self.segmentSamples
        // Input shape: [1, 2, segLen]
        let inputArray = try MLMultiArray(shape: [1, 2, segLen as NSNumber], dataType: .float32)
        for i in 0..<segLen {
            inputArray[[0, 0, i] as [NSNumber]] = NSNumber(value: left[i])
            inputArray[[0, 1, i] as [NSNumber]] = NSNumber(value: right[i])
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["audio": inputArray])
        let output = try model.prediction(from: inputFeatures)

        // Output name "stems", shape [1, 4, 2, segLen] — we flatten per stem
        guard let stemsArray = output.featureValue(for: "stems")?.multiArrayValue else {
            throw SeparationError.inferenceFailed(NSError(domain: "StemSep", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No 'stems' output from model"]))
        }

        let nStems = 4
        var chunks: [[Float]] = []
        for s in 0..<nStems {
            var leftChannel  = [Float](repeating: 0, count: segLen)
            var rightChannel = [Float](repeating: 0, count: segLen)
            for i in 0..<segLen {
                leftChannel[i]  = stemsArray[[0, s, 0, i] as [NSNumber]].floatValue
                rightChannel[i] = stemsArray[[0, s, 1, i] as [NSNumber]].floatValue
            }
            chunks.append(leftChannel + rightChannel) // L then R
        }
        return chunks
    }

    // MARK: - Audio I/O

    private func loadAudio(from url: URL) throws -> ([Float], [Float]) {
        let asset = AVURLAsset(url: url)
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Self.targetSampleRate, channels: 2)!

        guard let assetReader = try? AVAssetReader(asset: asset),
              let track = try? asset.tracks(withMediaType: .audio).first else {
            throw SeparationError.audioLoadFailed
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        assetReader.add(output)
        assetReader.startReading()

        var leftSamples:  [Float] = []
        var rightSamples: [Float] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            // interleaved stereo: L R L R ...
            stride(from: 0, to: floats.count - 1, by: 2).forEach { i in
                leftSamples.append(floats[i])
                rightSamples.append(floats[i + 1])
            }
        }

        guard !leftSamples.isEmpty else { throw SeparationError.audioLoadFailed }
        return (leftSamples, rightSamples)
    }

    private func writeWAV(interleaved samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frameCount = samples.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let L = buffer.floatChannelData?[0],
              let R = buffer.floatChannelData?[1] else { return }
        for i in 0..<frameCount {
            L[i] = samples[i * 2]
            R[i] = samples[i * 2 + 1]
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    // MARK: - DSP helpers

    private func hannWindow(size: Int) -> [Float] {
        (0..<size).map { i in
            0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(size - 1)))
        }
    }

    private func padToLength(_ arr: [Float], length: Int) -> [Float] {
        if arr.count >= length { return arr }
        return arr + [Float](repeating: 0, count: length - arr.count)
    }
}
