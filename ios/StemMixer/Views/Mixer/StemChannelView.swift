import SwiftUI

struct StemChannelView: View {
    let name: String
    @Binding var channel: StemChannel
    let hasSolo: Bool
    let onVolumeChange: (Float) -> Void
    let onPanChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onSoloToggle: () -> Void

    @State private var dragStartVolume: Float = 1.0

    private var accentColor: Color { stemColor(name) }
    private var isDimmed: Bool { channel.muted || (hasSolo && !channel.soloed) }

    var body: some View {
        VStack(spacing: 6) {
            // Stem label
            Text(name.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accentColor)
                .frame(maxWidth: .infinity)

            // Volume fader (vertical)
            VerticalFader(value: $channel.volume) { v in
                onVolumeChange(v)
            }
            .frame(height: 160)
            .opacity(isDimmed ? 0.3 : 1)

            // Volume readout
            Text(String(format: "%.0f%%", channel.volume * 100))
                .font(.system(size: 9))
                .foregroundStyle(.gray)

            // Pan knob
            PanKnob(value: $channel.pan) { p in onPanChange(p) }
                .frame(width: 36, height: 36)

            // Pan readout
            Text(panLabel(channel.pan))
                .font(.system(size: 9))
                .foregroundStyle(.gray)

            // Mute button
            Button(action: onMuteToggle) {
                Text("M")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 22)
                    .background(channel.muted ? Color.red : Color(hex: "#2a2a2a"))
                    .foregroundStyle(channel.muted ? .white : .gray)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Solo button
            Button(action: onSoloToggle) {
                Text("S")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 22)
                    .background(channel.soloed ? Color.yellow : Color(hex: "#2a2a2a"))
                    .foregroundStyle(channel.soloed ? .black : .gray)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "#1e1e1e"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(accentColor.opacity(0.3), lineWidth: 1)
                )
        )
        .opacity(isDimmed ? 0.6 : 1)
    }

    private func panLabel(_ p: Float) -> String {
        if abs(p) < 0.02 { return "C" }
        let pct = Int(abs(p) * 100)
        return p < 0 ? "L\(pct)" : "R\(pct)"
    }
}

// MARK: - Vertical fader

struct VerticalFader: View {
    @Binding var value: Float
    let onChange: (Float) -> Void

    @GestureState private var dragOffset: CGFloat = 0
    @State private var dragStartValue: Float = 0

    var body: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let thumbY = trackHeight * (1 - CGFloat(value))

            ZStack(alignment: .top) {
                // Track
                Capsule()
                    .fill(Color(hex: "#2a2a2a"))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)

                // Fill
                Capsule()
                    .fill(
                        LinearGradient(colors: [.green, .yellow, .orange],
                                       startPoint: .bottom, endPoint: .top)
                    )
                    .frame(width: 4, height: max(0, trackHeight - thumbY))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .offset(y: thumbY)

                // Thumb
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                    .frame(width: 24, height: 8)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(y: thumbY - 4)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let delta = Float(-g.translation.height / trackHeight)
                        let newVal = max(0, min(1, dragStartValue + delta))
                        value = newVal
                        onChange(newVal)
                    }
                    .onEnded { _ in dragStartValue = value }
            )
            .onAppear { dragStartValue = value }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Pan knob

struct PanKnob: View {
    @Binding var value: Float  // -1..1
    let onChange: (Float) -> Void

    @GestureState private var dragOffset: CGFloat = 0
    @State private var dragStartValue: Float = 0

    private var angle: Double { Double(value) * 135 }  // -135..+135 degrees

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "#2a2a2a"))
                .overlay(Circle().stroke(Color(hex: "#404040"), lineWidth: 1))

            // Pointer
            Capsule()
                .fill(Color.white)
                .frame(width: 3, height: 10)
                .offset(y: -6)
                .rotationEffect(.degrees(angle))
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let delta = Float(g.translation.width / 100)
                    let newVal = max(-1, min(1, dragStartValue + delta))
                    value = newVal
                    onChange(newVal)
                }
                .onEnded { _ in dragStartValue = value }
        )
        .onTapGesture(count: 2) {
            value = 0
            onChange(0)
            dragStartValue = 0
        }
        .onAppear { dragStartValue = value }
    }
}

// MARK: - Stem color map

func stemColor(_ name: String) -> Color {
    switch name {
    case "drums":  return Color(hex: "#ff8c42")
    case "bass":   return Color(hex: "#b44fff")
    case "vocals": return Color(hex: "#3ecfff")
    case "guitar": return Color(hex: "#ff5c8d")
    case "piano":  return Color(hex: "#ffd166")
    case "other":  return Color(hex: "#06d6a0")
    default:       return Color(hex: "#3ecfff")
    }
}
