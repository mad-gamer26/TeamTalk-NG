import AVFoundation
import SwiftUI

/// Settings → Sound system: what the desktop's Sound System tab has, and
/// the iPhone's own audio routes.
struct SoundSystemView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speaker") private var speaker = true
    @AppStorage("bluetoothMic") private var bluetoothMic = false
    @AppStorage("preferredInput") private var preferredInput = ""
    @AppStorage("mixWithOthers") private var mixWithOthers = true
    /// The desktop's "Test Selected" while it runs.
    @State private var soundTest: TtSoundLoop?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Play along with other apps", isOn: $mixWithOthers)
                Toggle("Play through the speaker", isOn: $speaker)
                Toggle("Use Bluetooth headset microphones", isOn: $bluetoothMic)
                // A menu, with the iPhone's own microphone as a submenu:
                // bottom (mono), or front or back in stereo. With echo
                // cancellation (voice chat) it's just the iPhone's
                // microphone, as iOS sets it up for calls.
                let echo = model.audio.echoCancellation
                let builtIn = AudioSession.inputs.first { $0.portType == .builtInMic }
                // With echo cancellation a front/back/bottom choice reads as the microphone itself.
                let selection = Binding<String>(
                    get: {
                        guard echo, let mic = builtIn, AudioSession.BuiltInMic(tag: preferredInput) != nil else { return preferredInput }
                        return mic.uid
                    },
                    set: { preferredInput = $0 })
                Menu {
                    Picker("Microphone", selection: selection) {
                        Text("Automatic").tag("")
                        ForEach(AudioSession.inputs.filter { echo || $0.portType != .builtInMic }, id: \.uid) {
                            Text($0.portName).tag($0.uid)
                        }
                    }
                    if !echo, let mic = builtIn {
                        Menu(mic.portName) {
                            Picker(mic.portName, selection: $preferredInput) {
                                ForEach(AudioSession.BuiltInMic.allCases) { Text($0.label).tag($0.tag) }
                            }
                        }
                    }
                } label: {
                    LabeledContent("Microphone", value: AudioSession.inputLabel(preferredInput, echoCancellation: echo))
                }
                .id("\(model.routeChanges)-\(echo)")  // rebuilt when a device comes or goes
                .accessibilityLabel("Microphone")
                .accessibilityValue(AudioSession.inputLabel(preferredInput, echoCancellation: echo))
                // The choices as VoiceOver actions, reversed; the chosen one
                // says so.
                .accessibilityActions {
                    let choices: [(String, String)] = [("Automatic", "")]
                        + AudioSession.inputs.filter { echo || $0.portType != .builtInMic }.map { ($0.portName, $0.uid) }
                        + (echo ? [] : builtIn.map { m in AudioSession.BuiltInMic.allCases.map { ("\(m.portName), \($0.label)", $0.tag) } } ?? [])
                    ForEach(choices.reversed(), id: \.1) { c in
                        Button(c.1 == selection.wrappedValue ? "\(c.0), on" : c.0) { selection.wrappedValue = c.1 }
                    }
                }
            } header: {
                Text("Where sound goes")
            } footer: {
                Text("Along with other apps, music and other sounds keep playing while you're connected. Without the speaker, sound comes from the earpiece when nothing is plugged in. Bluetooth microphones sound like a phone call, both ways. The iPhone's front and back microphones send stereo in channels whose codec is stereo, with echo cancellation off (Apple's echo cancellation is mono).")
            }
            Section {
                // The desktop's "Test Selected": hear your microphone through
                // the speaker, with these settings.
                Button(soundTest == nil ? "Test Selected" : "Stop Test") {
                    if let t = soundTest {
                        t.stop(); soundTest = nil
                    } else {
                        AudioSession.activate()
                        do { soundTest = try startSoundTest(devices: .default, settings: model.audio) } catch { announce(words(error)) }
                    }
                }
                Toggle("Echo cancellation", isOn: $model.audio.echoCancellation)
                Toggle("Automatic gain control", isOn: $model.audio.gainControl)
                Toggle("Noise suppression", isOn: $model.audio.noiseSuppression)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Echo cancellation uses the iPhone's own (as in phone calls), so the others don't hear what your speaker plays. A channel with a fixed volume sets the gain itself.")
            }
            Section {
                Toggle("Send video files' pictures too", isOn: $model.streamVideo)
            } header: {
                Text("Streaming")
            } footer: {
                Text("To hear the files you stream, turn on your own media file subscription (your entry in the channel list), as on the desktop: the server sends your stream back to you.")
            }
            Section("Levels") {
                level("Microphone gain", $model.audio.micGain)
                level("Master volume", $model.audio.outputVolume)
                level("Media file vs. voice volume", $model.audio.mediaVolume)
            }
        }
        .navigationTitle("Sound system")
        .navigationBarTitleDisplayMode(.inline)
        // (The session is set up at launch, so iOS lists the microphones;
        // opening this screen doesn't set it up again.)
        .onDisappear { soundTest?.stop(); soundTest = nil }
        .onChange(of: speaker) { AudioSession.activate() }
        .onChange(of: bluetoothMic) { AudioSession.activate() }
        .onChange(of: preferredInput) { AudioSession.activate() }
        .onChange(of: model.audio.echoCancellation) { AudioSession.activate() }
        .onChange(of: mixWithOthers) { AudioSession.activate() }
    }

    private func level(_ label: String, _ v: Binding<Int32>) -> some View {
        // The desktop's scale: 0–100 in steps of 1 (50: normal; media
        // files: 100 as loud as voices).
        NamedSlider(label, int: Binding(get: { Int(v.wrappedValue) }, set: { v.wrappedValue = Int32($0) }), in: 0...100,
                    spoken: { "\($0) percent" })
    }
}

/// Settings → Recording, as the desktop's Record Conversations settings.
struct RecordingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                NavigationLink("Recordings") { RecordingsView() }
            }
            Section {
                Picker("Format", selection: $model.recordMP3) {
                    Text("MP3 (small)").tag(true)
                    Text("WAV (exact)").tag(false)
                }
                Toggle("One file for everyone", isOn: $model.recordOneFile)
                Toggle("A file for each person", isOn: $model.recordEachPerson)
                Toggle("Include media files", isOn: $model.recordMediaFiles)
                    .disabled(!model.recordOneFile)
            } header: {
                Text("Record conversations")
            } footer: {
                Text("Start from a server's More menu. Recordings go to Recordings in TeamTalk NG's folder in the Files app.")
            }
            Section {
                Toggle("Save chat to text files", isOn: $model.saveChatLogs)
            } footer: {
                Text("As the desktop: a .clog file per channel (Channel logs) and a .ulog file per person (User logs), for each server, in Chat logs in the Files app.")
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// My connection's numbers, as the desktop speaks them.
struct ClientStatisticsView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    @State private var st: ClientStatistics?

    var body: some View {
        NavigationStack {
            Form {
                if let st {
                    Section {
                        row("Ping", st.udpPingMs >= 0 ? "\(st.udpPingMs) ms (voice), \(st.tcpPingMs) ms (commands)" : "Not measured yet")
                        row("Last heard from the server", "\(min(st.udpSilenceS, st.tcpSilenceS)) seconds ago")
                    }
                    Section("Sent and received") {
                        row("Everything", bytes(st.udpBytesSent, st.udpBytesReceived))
                        row("Voice", bytes(st.voiceBytesSent, st.voiceBytesReceived))
                        row("Media files", bytes(st.mediaFileBytesSent, st.mediaFileBytesReceived))
                        row("Video", bytes(st.videoBytesSent, st.videoBytesReceived))
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Connection statistics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Update") { Task { await load(speak: true) } } }
            }
            .task { await load(speak: true) }
        }
    }

    private func load(speak: Bool) async {
        st = await connection.clientStatistics()
        if speak, let st {
            announce(st.udpPingMs >= 0 ? "Ping \(st.udpPingMs) milliseconds" : "Not connected")
        }
    }

    private func bytes(_ s: Int64, _ r: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: s, countStyle: .binary)) sent, \(ByteCountFormatter.string(fromByteCount: r, countStyle: .binary)) received"
    }

    private func row(_ l: String, _ v: String) -> some View {
        LabeledContent(l, value: v).accessibilityElement(children: .ignore).accessibilityLabel(l).accessibilityValue(v)
    }
}
