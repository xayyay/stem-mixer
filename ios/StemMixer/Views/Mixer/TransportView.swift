import SwiftUI

struct TransportView: View {
    @ObservedObject var audio: AudioEngine
    let duration: Double
    let bpm: Double?
    let isLooping: Bool
    let onLoopToggle: () -> Void

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var displayTime: Double { isScrubbing ? scrubTime : audio.currentTime }

    var body: some View {
        VStack(spacing: 10) {
            // Seek bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(hex: "#2a2a2a"))
                        .frame(height: 4)

                    Capsule()
                        .fill(
                            LinearGradient(colors: [Color(hex: "#3ecfff"), Color(hex: "#b44fff")],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * CGFloat(progressFraction), height: 4)

                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .offset(x: geo.size.width * CGFloat(progressFraction) - 7)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            isScrubbing = true
                            let fraction = max(0, min(1, g.location.x / geo.size.width))
                            scrubTime = fraction * duration
                        }
                        .onEnded { _ in
                            audio.seek(to: scrubTime)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 14)

            // Time labels
            HStack {
                Text(formatDuration(displayTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.gray)
                Spacer()
                if let bpm {
                    Text(String(format: "♩ %.0f BPM", bpm))
                        .font(.caption)
                        .foregroundStyle(Color(hex: "#3ecfff").opacity(0.8))
                }
                Spacer()
                Text(formatDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.gray)
            }

            // Transport buttons
            HStack(spacing: 28) {
                // Stop
                Button { audio.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }

                // Play/Pause
                Button {
                    if audio.isPlaying { audio.pause() }
                    else { try? audio.play() }
                } label: {
                    Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color(hex: "#3ecfff"))
                        .shadow(color: Color(hex: "#3ecfff").opacity(0.4), radius: 8)
                }

                // Loop
                Button(action: onLoopToggle) {
                    Image(systemName: "repeat")
                        .font(.title3)
                        .foregroundStyle(isLooping ? Color(hex: "#3ecfff") : .white.opacity(0.4))
                }
            }
        }
    }

    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, displayTime / duration)
    }
}
