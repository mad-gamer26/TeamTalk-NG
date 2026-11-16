import SwiftUI

/// Making or editing a channel, with every setting the desktop has.
struct ChannelEditView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let sheet: ChannelSheet

    @State private var name = ""
    @State private var topic = ""
    @State private var password = ""
    @State private var changePassword = false
    @State private var opPassword = ""
    @State private var changeOpPassword = false
    @State private var maxUsers = ""
    @State private var quotaMB = ""
    @State private var permanent = true
    @State private var soloTransmit = false
    @State private var classroom = false
    @State private var operatorReceiveOnly = false
    @State private var noVoiceActivation = false
    @State private var noRecording = false
    @State private var hidden = false
    @State private var codec = opusDefault()
    @State private var originalCodec = opusDefault()
    @State private var fixedVolume = false
    @State private var fixedLevel = 30.0
    @State private var voiceLimit = ""
    @State private var mediaLimit = ""
    /// The desktop's "Join channel on exit" (checked; only those who may
    /// make lasting channels can leave it off).
    @State private var joinOnExit = true

    private var editing: Channel? { if case .edit(let c) = sheet { c } else { nil } }
    private var temporary: Bool { if case .new(_, let t) = sheet { t } else { false } }
    /// The desktop's modchannels: lasting channels, their size and disk space.
    private var canModify: Bool { connection.rights.modifyChannels && !temporary }

    static let sampleRates: [Int32] = [8000, 12000, 16000, 24000, 48000]
    static let frameSizes: [Int32] = [5, 10, 20, 40, 60, 80, 100, 120]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).accessibilityLabel("Name")
                    TextField("Topic", text: $topic).accessibilityLabel("Topic")
                    if editing != nil { Toggle("Change the password", isOn: $changePassword) }
                    if editing == nil || changePassword {
                        SecureField("Password (empty for none)", text: $password).accessibilityLabel("Password (empty for none)")
                    }
                    // The desktop: only with the right to modify channels
                    // (otherwise the channel is joined as it's made).
                    if editing == nil && canModify {
                        Toggle("Join it once it's made", isOn: $joinOnExit)
                    }
                }
                Section {
                        if editing != nil { Toggle("Change the operator password", isOn: $changeOpPassword) }
                        if editing == nil || changeOpPassword {
                            SecureField("Operator password (empty for none)", text: $opPassword).accessibilityLabel("Operator password (empty for none)")
                        }
                    } footer: {
                        Text("Whoever knows it can make themselves an operator of the channel.")
                    }
                    Section("Limits") {
                        // The desktop: these need the right to modify channels.
                        if canModify {
                            TextField("Most people allowed in (leave empty to keep it)", text: $maxUsers).accessibilityLabel("Most people allowed in (leave empty to keep it)").keyboardType(.numberPad)
                            TextField("Disk space for files, in MB (leave empty to keep it)", text: $quotaMB).accessibilityLabel("Disk space for files, in MB (leave empty to keep it)").keyboardType(.decimalPad)
                        }
                        TextField("Longest anyone may talk at once, in seconds (0: no limit)", text: $voiceLimit).accessibilityLabel("Longest anyone may talk at once, in seconds (0: no limit)").keyboardType(.numberPad)
                        TextField("Longest a media file may stream, in seconds (0: no limit)", text: $mediaLimit).accessibilityLabel("Longest a media file may stream, in seconds (0: no limit)").keyboardType(.numberPad)
                    }
                    Section("Type") {
                        if canModify { Toggle("Keep it when everyone leaves", isOn: $permanent) }
                        Toggle("No interruptions: one person talks at a time", isOn: $soloTransmit)
                        Toggle("Classroom: operators choose who may send", isOn: $classroom)
                        Toggle("Only operators see and hear the others", isOn: $operatorReceiveOnly)
                        Toggle("No voice activation (push to talk only)", isOn: $noVoiceActivation)
                        Toggle("No recording", isOn: $noRecording)
                        // The desktop: set when it's made, never changed after.
                        if editing == nil { Toggle("Hidden: joined by its path only", isOn: $hidden) }
                    }
                    codecSection
                    Section {
                        Toggle("Everyone at one fixed volume", isOn: $fixedVolume)
                        if fixedVolume {
                            NamedSlider("Fixed volume", value: $fixedLevel, in: 0...100, step: 5,
                                        spoken: { "\(Int($0)) percent of the loudest" })
                        }
                    } header: {
                        Text("Volume")
                    } footer: {
                        Text("With a fixed volume, everyone in the channel sounds as loud as each other.")
                    }
                if editing == nil && !canModify {
                    Section { Text("It goes away when the last person leaves.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(editing == nil ? "New channel" : "Edit channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Make" : "Save") { save(); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty && editing?.parentId != 0)
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder private var codecSection: some View {
        Section {
            Picker("Codec", selection: $codec.kind) {
                Text("Opus").tag(CodecKind.opus)
                Text("No audio (text only)").tag(CodecKind.noAudio)
                if originalCodec.kind == .speex { Text("Speex (as it is)").tag(CodecKind.speex) }
                if originalCodec.kind == .speexVbr { Text("Speex VBR (as it is)").tag(CodecKind.speexVbr) }
            }
            if codec.kind == .opus {
                Picker("Sample rate", selection: $codec.sampleRate) {
                    ForEach(Self.sampleRates, id: \.self) { Text("\($0 / 1000) kHz").tag($0) }
                }
                Picker("Sound", selection: $codec.channels) {
                    Text("Mono").tag(Int32(1))
                    Text("Stereo").tag(Int32(2))
                }
                Picker("Best for", selection: $codec.music) {
                    Text("Voice").tag(false)
                    Text("Music").tag(true)
                }
                NumberField("Bitrate (kbit/s)", value: Binding(
                    get: { Int(codec.bitrate / 1000) }, set: { codec.bitrate = Int32($0 * 1000) }), in: 6...510)
                Toggle("Variable bitrate", isOn: $codec.vbr)
                Toggle("Don't send silence (DTX)", isOn: $codec.dtx)
                Picker("Frame size", selection: $codec.frameSizeMs) {
                    ForEach(Self.frameSizes, id: \.self) { Text("\($0) ms").tag($0) }
                }
                NumberField("Transmit interval (ms)", int32: $codec.transmitIntervalMs, in: 20...500)
            } else if codec.kind != .noAudio {
                Text(codecWords(codec)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Everyone in the channel sends with these settings. Higher bitrates sound better and use more data.")
        }
    }

    private func load() {
        guard let c = editing else {
            if case .new(let parent, _) = sheet,
               let p = connection.snapshot?.channels.first(where: { $0.id == parent }), p.codec.kind == .opus {
                codec = p.codec
            }
            originalCodec = codec
            return
        }
        name = c.name
        topic = c.topic
        maxUsers = String(c.maxUsers)
        quotaMB = c.diskQuota > 0 ? String(format: "%g", Double(c.diskQuota) / 1_000_000) : "0"
        permanent = c.permanent
        soloTransmit = c.soloTransmit
        classroom = c.classroom
        operatorReceiveOnly = c.operatorReceiveOnly
        noVoiceActivation = c.noVoiceActivation
        noRecording = c.noRecording
        hidden = c.hidden
        codec = c.codec
        originalCodec = c.codec
        fixedVolume = c.fixedVolume
        fixedLevel = Double(c.fixedVolumeLevel)
        voiceLimit = String(c.voiceTimeoutMs / 1000)
        mediaLimit = String(c.mediaTimeoutMs / 1000)
    }

    private func save() {
        var parent: Int32 = 0
        if case .new(let p, _) = sheet { parent = p }
        let quota = Double(quotaMB.replacingOccurrences(of: ",", with: ".")).map { Int64($0 * 1_000_000) }
        let spec = ChannelSpec(
            parentId: parent, name: name.trimmingCharacters(in: .whitespaces), topic: topic,
            password: editing == nil || changePassword ? password : nil,
            maxUsers: canModify ? Int32(maxUsers) ?? 0 : (editing?.maxUsers ?? 0),
            permanent: canModify ? permanent : (editing?.permanent ?? false),
            soloTransmit: soloTransmit, classroom: classroom, operatorReceiveOnly: operatorReceiveOnly,
            noVoiceActivation: noVoiceActivation, noRecording: noRecording, hidden: hidden,
            operatorPassword: editing == nil || changeOpPassword ? opPassword : nil,
            diskQuota: canModify ? quota : nil,
            codec: codec == originalCodec && editing != nil ? nil : codec,
            fixedVolume: fixedVolume, fixedVolumeLevel: Int32(fixedLevel),
            voiceTimeoutMs: Int32(voiceLimit).map { $0 * 1000 }, mediaTimeoutMs: Int32(mediaLimit).map { $0 * 1000 })
        if let c = editing {
            connection.updateChannel(c, spec)
        } else {
            // As the desktop: made and joined unless "Join channel on exit"
            // is off (only possible with the right to make lasting channels).
            connection.makeChannel(spec, temporary: !canModify || joinOnExit)
        }
    }
}

/// A codec in words ("Opus, 48 kHz, mono, 64 kbit/s, voice").
func codecWords(_ c: AudioCodec) -> String {
    switch c.kind {
    case .noAudio: return "No audio (text only)"
    case .opus:
        return "Opus, \(c.sampleRate / 1000) kHz, \(c.channels == 2 ? "stereo" : "mono"), \(c.bitrate / 1000) kbit/s\(c.vbr ? " variable" : ""), \(c.music ? "music" : "voice"), \(c.frameSizeMs) ms frames"
    case .speex, .speexVbr:
        return "\(c.kind == .speex ? "Speex" : "Speex VBR"), \(c.sampleRate / 1000) kHz, quality \(c.quality)"
    }
}

/// A channel's information, all of it.
struct ChannelInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection
    let channelId: Int32

    var body: some View {
        let c = connection.snapshot?.channels.first { $0.id == channelId }
        let people = connection.snapshot?.users.filter { $0.channelId == channelId } ?? []
        NavigationStack {
            Form {
                if let c {
                    Section {
                        row("Name", c.parentId == 0 ? "Root channel" : c.name)
                        row("Path", connection.channelPathText(c))
                        row("Topic", c.topic.isEmpty ? "None" : c.topic)
                        row("People", people.isEmpty ? "Nobody" : people.map(\.displayName).joined(separator: ", "))
                        row("Most people", "\(c.maxUsers)")
                        row("Password", c.hasPassword ? "Yes" : "No")
                        if !c.operatorPassword.isEmpty { row("Operator password", c.operatorPassword) }
                        let ops = people.filter(\.operator).map(\.displayName)
                        row("Operators here", ops.isEmpty ? "None" : ops.joined(separator: ", "))
                        row("Disk space for files", c.diskQuota > 0 ? ByteCountFormatter.string(fromByteCount: c.diskQuota, countStyle: .file) : "None")
                        let files = connection.snapshot?.files.filter { $0.channelId == channelId }.count ?? 0
                        row("Files", "\(files)")
                    }
                    Section("Audio") {
                        row("Codec", codecWords(c.codec))
                        row("Fixed volume", c.fixedVolume ? "On, \(c.fixedVolumeLevel) percent of the loudest" : "Off")
                        row("Talking limit", c.voiceTimeoutMs > 0 ? "\(c.voiceTimeoutMs / 1000) seconds" : "None")
                        row("Media file limit", c.mediaTimeoutMs > 0 ? "\(c.mediaTimeoutMs / 1000) seconds" : "None")
                    }
                    Section("Type") {
                        let types = [
                            c.permanent ? "stays when empty" : "goes when empty",
                            c.soloTransmit ? "one person talks at a time" : nil,
                            c.classroom ? "classroom" : nil,
                            c.operatorReceiveOnly ? "only operators hear the others" : nil,
                            c.noVoiceActivation ? "push to talk only" : nil,
                            c.noRecording ? "no recording" : nil,
                            c.hidden ? "hidden" : nil,
                        ].compactMap { $0 }
                        Text(types.joined(separator: ", ").capitalizedFirst)
                    }
                } else {
                    Text("That channel is gone.")
                }
            }
            .navigationTitle("Channel information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}
