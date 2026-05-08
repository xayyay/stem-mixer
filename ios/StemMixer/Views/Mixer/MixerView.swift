import SwiftUI

struct MixerView: View {
    @EnvironmentObject var vm: MixerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPresets = false
    @State private var showNewPreset = false
    @State private var newPresetName = ""
    @State private var showExportSheet: URL? = nil
    @State private var showMetadataEdit = false

    var body: some View {
        ZStack {
            Color(hex: "#111111").ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().background(Color(hex: "#2a2a2a"))

                if !vm.isLoaded {
                    loadingView
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            stemGrid
                                .padding()
                            masterSection
                                .padding(.horizontal)
                            transportSection
                                .padding()
                        }
                    }
                }
            }
        }
        .onAppear { vm.loadAudio() }
        .alert("Load Error", isPresented: .constant(vm.loadError != nil)) {
            Button("OK") { vm.loadError = nil }
        } message: {
            Text(vm.loadError ?? "")
        }
        .sheet(isPresented: $showPresets) {
            PresetsSheet()
                .environmentObject(vm)
        }
        .alert("Save Preset", isPresented: $showNewPreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                vm.savePreset(name: newPresetName.isEmpty ? "Preset" : newPresetName)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        }
        .sheet(item: $showExportSheet) { url in
            ShareSheet(url: url)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.white)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.song.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !vm.song.artist.isEmpty {
                    Text(vm.song.artist)
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Presets menu
            Menu {
                Button("Save Preset…") { showNewPreset = true }
                if !vm.presets.isEmpty {
                    Divider()
                    ForEach(vm.presets) { p in
                        Button(p.name) { vm.loadPreset(p) }
                    }
                    Divider()
                    Button("Manage Presets") { showPresets = true }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(hex: "#1a1a1a"))
    }

    // MARK: - Stem grid

    private var stemGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                            count: min(vm.song.stemNames.count, 4))
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(vm.song.stemNames, id: \.self) { name in
                if let binding = channelBinding(for: name) {
                    StemChannelView(
                        name: name,
                        channel: binding,
                        hasSolo: vm.mixerState.hasSolo,
                        onVolumeChange: { v in vm.setVolume(v, for: name) },
                        onPanChange:    { p in vm.setPan(p, for: name) },
                        onMuteToggle:   { vm.toggleMute(name) },
                        onSoloToggle:   { vm.toggleSolo(name) }
                    )
                    .contextMenu {
                        if let url = vm.exportURL(for: name) {
                            Button {
                                showExportSheet = url
                            } label: {
                                Label("Export \(name).wav", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
        }
    }

    private func channelBinding(for name: String) -> Binding<StemChannel>? {
        guard vm.mixerState.stems[name] != nil else { return nil }
        return Binding(
            get: { vm.mixerState.stems[name] ?? StemChannel() },
            set: { _ in } // mutations go through vm methods
        )
    }

    // MARK: - Master volume

    private var masterSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("MASTER")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(String(format: "%.0f%%", vm.mixerState.masterVolume * 100))
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
            Slider(value: Binding(
                get: { Double(vm.mixerState.masterVolume) },
                set: { vm.setMasterVolume(Float($0)) }
            ), in: 0...1)
            .tint(Color(hex: "#3ecfff"))
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "#1e1e1e"))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
    }

    // MARK: - Transport

    private var transportSection: some View {
        VStack(spacing: 0) {
            TransportView(
                audio: vm.audio,
                duration: vm.audio.duration,
                bpm: vm.song.bpm,
                isLooping: vm.isLooping,
                onLoopToggle: { vm.toggleLoop() }
            )
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "#1e1e1e"))
        )
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color(hex: "#3ecfff"))
                .scaleEffect(1.5)
            Text("Loading stems…")
                .foregroundStyle(.gray)
            Spacer()
        }
    }
}

// MARK: - Presets sheet

struct PresetsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var vm: MixerViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(vm.presets) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name).foregroundStyle(.white)
                            Text(preset.createdAt, style: .date)
                                .font(.caption).foregroundStyle(.gray)
                        }
                        Spacer()
                        Button("Load") { vm.loadPreset(preset); dismiss() }
                            .buttonStyle(.bordered)
                            .tint(Color(hex: "#3ecfff"))
                    }
                }
                .onDelete { idxSet in
                    idxSet.forEach { vm.deletePreset(vm.presets[$0]) }
                }
            }
            .navigationTitle("Presets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Identifiable URL for sheet(item:)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
