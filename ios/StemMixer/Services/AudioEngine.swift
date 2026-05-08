import AVFoundation
import Combine

@MainActor
final class AudioEngine: ObservableObject {

    // MARK: - Published state
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    // MARK: - Private engine graph
    private let engine = AVAudioEngine()
    private let masterMixer = AVAudioMixerNode()

    // Per-stem nodes keyed by stem name
    private var players: [String: AVAudioPlayerNode] = [:]
    private var gainNodes: [String: AVAudioMixerNode] = [:]

    private var stemBuffers: [String: AVAudioPCMBuffer] = [:]
    private var sampleRate: Double = 44100

    // Playback position tracking
    private var seekPosition: Double = 0        // seconds at last play()
    private var playStartHostTime: UInt64 = 0   // mach_absolute_time at scheduled start
    private var isLooping = false

    private var displayTimer: AnyCancellable?

    // MARK: - Init

    init() {
        setupGraph()
        setupAudioSession()
    }

    private func setupGraph() {
        engine.attach(masterMixer)
        engine.connect(masterMixer, to: engine.mainMixerNode, format: nil)
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    // MARK: - Loading stems

    func loadStems(urls: [String: URL]) throws {
        stopEngine()

        // Detach old nodes
        for p in players.values  { engine.detach(p) }
        for g in gainNodes.values { engine.detach(g) }
        players.removeAll(); gainNodes.removeAll(); stemBuffers.removeAll()

        var maxFrames: AVAudioFrameCount = 0

        for (name, url) in urls {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else { continue }
            try file.read(into: buffer)
            buffer.frameLength = AVAudioFrameCount(file.length)
            stemBuffers[name] = buffer
            maxFrames = max(maxFrames, buffer.frameLength)
            sampleRate = file.processingFormat.sampleRate

            let player = AVAudioPlayerNode()
            let gain   = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(gain)
            engine.connect(player, to: gain, format: file.processingFormat)
            engine.connect(gain, to: masterMixer, format: file.processingFormat)
            players[name] = player
            gainNodes[name] = gain
        }

        duration = Double(maxFrames) / sampleRate
        seekPosition = 0
        currentTime = 0
    }

    // MARK: - Transport

    func play() throws {
        guard !players.isEmpty else { return }

        if engine.isRunning {
            // already running — just reschedule from seekPosition
            for p in players.values { p.stop() }
        } else {
            try engine.start()
        }

        let startFrame = AVAudioFramePosition(seekPosition * sampleRate)

        for (name, player) in players {
            guard let buffer = stemBuffers[name] else { continue }
            guard let slice = makeSlice(buffer: buffer, from: startFrame) else { continue }
            if isLooping {
                player.scheduleBuffer(slice, at: nil, options: .loops)
            } else {
                player.scheduleBuffer(slice, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in self?.handlePlaybackEnd() }
                }
            }
        }

        // Synchronize: give 80ms for all scheduling to complete then start together
        let delaySeconds: TimeInterval = 0.08
        let delayHostTime = AVAudioTime.hostTime(forSeconds: delaySeconds)
        let startHostTime = mach_absolute_time() + delayHostTime
        let syncTime = AVAudioTime(hostTime: startHostTime)

        for p in players.values { p.play(at: syncTime) }

        playStartHostTime = startHostTime
        isPlaying = true
        startDisplayLink()
    }

    func pause() {
        guard isPlaying else { return }
        seekPosition = liveCurrentTime()
        for p in players.values { p.pause() }
        isPlaying = false
        stopDisplayLink()
    }

    func stop() {
        for p in players.values { p.stop() }
        seekPosition = 0
        currentTime = 0
        isPlaying = false
        stopDisplayLink()
    }

    func seek(to time: Double) {
        let wasPlaying = isPlaying
        if isPlaying { pause() }
        seekPosition = max(0, min(time, duration))
        currentTime = seekPosition
        if wasPlaying { try? play() }
    }

    var looping: Bool {
        get { isLooping }
        set { isLooping = newValue }
    }

    // MARK: - Mixer controls

    func setVolume(_ v: Float, for stem: String) {
        gainNodes[stem]?.outputVolume = max(0, min(1, v))
    }

    func setPan(_ p: Float, for stem: String) {
        gainNodes[stem]?.pan = max(-1, min(1, p))
    }

    func setMasterVolume(_ v: Float) {
        masterMixer.outputVolume = max(0, min(1, v))
    }

    // MARK: - Private helpers

    private func stopEngine() {
        if engine.isRunning {
            for p in players.values { p.stop() }
            engine.stop()
        }
        isPlaying = false
        stopDisplayLink()
    }

    private func handlePlaybackEnd() {
        guard isPlaying, !isLooping else { return }
        stop()
    }

    private func liveCurrentTime() -> Double {
        guard isPlaying,
              let firstPlayer = players.values.first,
              let nodeTime = firstPlayer.lastRenderTime,
              nodeTime.isSampleTimeValid else {
            return seekPosition
        }
        let hostNow = nodeTime.hostTime
        if hostNow < playStartHostTime { return seekPosition }
        let elapsed = AVAudioTime.seconds(forHostTime: hostNow - playStartHostTime)
        let t = seekPosition + max(0, elapsed)
        return min(t, duration)
    }

    private func makeSlice(buffer: AVAudioPCMBuffer, from startFrame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let totalFrames = AVAudioFramePosition(buffer.frameLength)
        guard startFrame < totalFrames else { return nil }
        let sliceFrames = AVAudioFrameCount(totalFrames - startFrame)
        guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: sliceFrames) else { return nil }
        slice.frameLength = sliceFrames
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            guard let src = buffer.floatChannelData?[ch],
                  let dst = slice.floatChannelData?[ch] else { continue }
            memcpy(dst, src.advanced(by: Int(startFrame)), Int(sliceFrames) * MemoryLayout<Float>.size)
        }
        return slice
    }

    private func startDisplayLink() {
        displayTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.isPlaying else { return }
                let t = self.liveCurrentTime()
                self.currentTime = t
                if t >= self.duration && !self.isLooping { self.stop() }
            }
    }

    private func stopDisplayLink() {
        displayTimer?.cancel()
        displayTimer = nil
    }
}
