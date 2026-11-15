import SwiftUI

// The desktop's Users and Channels menus (qtTeamTalk's mainwindow.ui), as
// actions on people and channels: the same items, order, words and spoken
// results. VoiceOver lists them reversed (the owner's choice); the
// touch-and-hold menus keep the desktop's order, with its submenus.

extension ServerConnection {
    /// Speaks something whatever the spoken events say (the desktop's
    /// addTextToSpeechMessage without an event).
    func speakAlways(_ text: String) { appModel?.speech.speak(text) }

    // MARK: Speak user / channel information, channel state

    /// The desktop's "Speak User Information".
    func speakUserInfo(_ u: User) {
        let female = u.gender == .female
        var s = "\(u.displayName): " + (u.admin ? (female ? "Administrator" : "Administrator") : "User")
        if pickedToMove.contains(u.id) { s += ", Selected for move" }
        if u.operator { s += ", Channel operator" }
        if u.talking { s += ", Talking" }
        switch u.status {
        case .available: s += ", Available"
        case .away: s += ", Away"
        case .question: s += ", Question"
        }
        if u.voiceMuted { s += ", Mute" }
        if u.streamingMedia { s += ", Streaming" }
        if u.mediaMuted { s += ", Mute media file" }
        if u.sendingVideo { s += ", Webcam" }
        if u.sharingDesktop { s += ", Desktop" }
        speakAlways(s)
    }

    /// The desktop's "Speak Channel Info".
    func speakChannelInfo(_ c: Channel) {
        guard let snap = snapshot else { return }
        let root = c.parentId == 0
        var s = "\(root ? snap.server.name : c.name): Channel" + (root ? " root" : "")
        if c.classroom { s += ", Classroom" }
        if c.hidden { s += ", Hidden" }
        if c.hasPassword { s += ", Password protected" }
        if !c.topic.isEmpty { s += ", Topic: \(c.topic)" }
        let n = snap.users.filter { $0.channelId == c.id }.count
        if n > 0 { s += ", \(n) users" }
        let files = snap.files.filter { $0.channelId == c.id }.count
        if (c.id == snap.myChannelId || snap.myRights.admin) && files > 0 { s += ", \(files) files" }
        speakAlways(s)
    }

    /// The desktop's "Speak Channel State": who's talking, streaming, on
    /// webcam, sharing a desktop in my channel.
    func speakChannelState() {
        guard let snap = snapshot else { return }
        let here = snap.users.filter { $0.channelId == snap.myChannelId && snap.myChannelId > 0 }
        var parts: [String] = []
        func add(_ title: String, _ who: [User]) {
            if !who.isEmpty { parts.append("\(title): " + who.map(\.displayName).joined(separator: ", ")) }
        }
        add("Talking", here.filter { $0.talking || ($0.id == snap.myUserId && transmitting) })
        add("Streaming", here.filter(\.streamingMedia))
        add("Webcam", here.filter(\.sendingVideo))
        add("Desktop", here.filter(\.sharingDesktop))
        speakAlways(parts.isEmpty ? "Nobody is active in this channel" : parts.joined(separator: ", "))
    }

    // MARK: Users menu items with the desktop's spoken results

    func toggleMuteVoice(_ u: User) {
        let on = !u.voiceMuted
        setMuted(u, on)
        noteMenu("Voice for \(u.displayName) \(on ? "disabled" : "enabled")")
    }

    func toggleMuteMedia(_ u: User) {
        let on = !u.mediaMuted
        setMediaMuted(u, on)
        noteMenu("Media files for \(u.displayName) \(on ? "disabled" : "enabled")")
    }

    /// Increase/Lower Voice or Media File Volume: a step of 1 on the
    /// desktop's scale.
    func stepVolume(_ u: User, media: Bool, by step: Int) {
        let now = Int(media ? u.mediaVolume : u.voiceVolume)
        let new = min(100, max(0, now + step))
        if media { setMediaVolume(u, percent: new) } else { setVolume(u, percent: new) }
        noteMenu("\(media ? "Media files volume" : "Voice volume") for \(u.displayName) \(step > 0 ? "increased" : "decreased") to \(new)%")
    }

    /// The desktop's "Speak Client Statistics": "RX: …, TX: …, PING: …".
    func speakClientStatistics() async {
        guard let st = await clientStatistics() else { return }
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        var s = "RX: \(size(st.udpBytesReceived)), TX: \(size(st.udpBytesSent))"
        if st.udpPingMs >= 0 { s += ", PING: \(st.udpPingMs)" }
        speakAlways(s)
    }

    func toggleSubscription(_ u: User, _ sub: Subscription) {
        setSubscription(u, sub, !u.mySubscriptions.on.contains(sub))
    }
}

/// The desktop's Users menu for one person: its items in its order, with
/// its submenus (Mute, Kick, Subscriptions, Transmit Control, Advanced).
struct UserMenu: View {
    let connection: ServerConnection
    let user: User
    let open: (UserSheet) -> Void
    /// For VoiceOver: one flat list, reversed; submenus open a list.
    var flatReversed = false

    enum UserSheet { case info, messages, volume, move, subscriptions, transmit, advanced, banServer, banChannel }

    private var rights: MyRights { connection.rights }

    private var items: [MenuItem] {
        var m: [MenuItem] = [
            .init("View User Information") { open(.info) },
            .init("Speak User Information") { connection.speakUserInfo(user) },
            .init("Messages") { open(.messages) },
        ]
        if connection.canModerate(channel: user.channelId) || rights.admin {
            m.append(.init(user.operator ? "Remove Op" : "Op") { connection.setOperator(user, !user.operator) })
        }
        let audio = connection.hasAudio
        if audio {
            m.append(.init("Volume") { open(.volume) })
            m.append(.init(user.voiceMuted ? "Unmute Voice" : "Mute Voice") { connection.toggleMuteVoice(user) })
            m.append(.init(user.mediaMuted ? "Unmute Media File" : "Mute Media File") { connection.toggleMuteMedia(user) })
        }
        if rights.kick || connection.canModerate(channel: user.channelId) {
            if user.channelId > 0 {
                m.append(.init("Kick From Channel") { connection.kick(user, fromChannel: true) })
                m.append(.init("Kick and Ban From Channel") { open(.banChannel) })
            }
        }
        if rights.kick { m.append(.init("Kick From Server") { connection.kick(user, fromChannel: false) }) }
        if rights.ban { m.append(.init("Kick and Ban From Server") { open(.banServer) }) }
        m.append(.init("Subscriptions") { open(.subscriptions) })
        // In any channel, as the desktop (its "Allow All" items: classrooms only).
        if user.channelId > 0 && connection.canControlTransmit(channel: user.channelId) {
            m.append(.init("Transmit Control") { open(.transmit) })
        }
        // Through the Monitor, Advanced has only moving people (no volumes, no relay).
        if audio || rights.moveUsers { m.append(.init("Advanced") { open(.advanced) }) }
        // Mute All is in the server screen's More menu (the owner's choice).
        return m
    }

    var body: some View {
        let list = flatReversed ? items.reversed() : items
        ForEach(list) { i in Button(i.title, action: i.action) }
    }
}

struct MenuItem: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
    var destructive = false
    init(_ title: String, _ action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// The desktop's Subscriptions submenu: each one checked or not.
struct SubscriptionsDialog: View {
    let connection: ServerConnection
    let user: User
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Subscription.desktopOrder.filter(connection.shows), id: \.self) { sub in
                    Toggle(ServerConnection.subscriptionMenuName(sub), isOn: Binding(
                        get: { user.mySubscriptions.on.contains(sub) },
                        set: { connection.setSubscription(user, sub, $0) }))
                }
            }
            .navigationTitle("Subscriptions: \(user.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension Subscription {
    /// The desktop's Subscriptions menu order.
    static let desktopOrder: [Subscription] = [
        .userMessages, .channelMessages, .broadcastMessages, .voice, .video, .desktop, .desktopAccess, .mediaFile,
        .interceptUserMessages, .interceptChannelMessages, .interceptVoice, .interceptVideo, .interceptDesktop, .interceptMediaFile,
    ]
}

/// The desktop's Transmit Control submenu: allow each kind for this person
/// (in any channel), and for everyone (classroom channels).
struct TransmitDialog: View {
    let connection: ServerConnection
    let user: User
    @Environment(\.dismiss) private var dismiss

    private var channel: Channel? { connection.snapshot?.channels.first { $0.id == user.channelId } }
    private static let kinds: [(TransmitStream, String)] = [
        (.channelMessages, "Channel Text Messages"), (.voice, "Voice Transmission"), (.video, "Video Transmission"),
        (.desktop, "Desktop Transmission"), (.mediaFile, "Media File Transmission"),
    ]

    private func allowed(_ who: Int32, _ s: TransmitStream) -> Bool {
        channel.map { connection.transmitAllowed($0, user: who, s) } ?? true
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.kinds.filter { connection.shows($0.0) }, id: \.1) { k in
                    Toggle("Allow \(k.1)", isOn: Binding(
                        get: { allowed(user.id, k.0) },
                        set: { connection.setTransmit(channel: user.channelId, user: user.id, k.0, $0) }))
                }
                if channel?.classroom == true {
                    ForEach(Self.kinds.filter { connection.shows($0.0) }, id: \.1) { k in
                        Toggle("Allow All \(k.1)", isOn: Binding(
                            get: { allowed(0, k.0) },
                            set: { connection.setTransmit(channel: user.channelId, user: 0, k.0, $0) }))
                    }
                }
            }
            .navigationTitle("Transmit Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The desktop's Advanced submenu.
struct AdvancedDialog: View {
    let connection: ServerConnection
    let user: User
    let moveDialog: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if connection.hasAudio {
                    Button("Increase Voice Volume") { connection.stepVolume(user, media: false, by: 1) }
                    Button("Lower Voice Volume") { connection.stepVolume(user, media: false, by: -1) }
                    Button("Increase Media File Volume") { connection.stepVolume(user, media: true, by: 1) }
                    Button("Lower Media File Volume") { connection.stepVolume(user, media: true, by: -1) }
                }
                if connection.rights.moveUsers {
                    Button(connection.pickedToMove.contains(user.id) ? "Don't Store User for Move" : "Store User for Move") {
                        connection.togglePicked(user)
                    }
                    Button("Move Users Dialog") { dismiss(); moveDialog() }
                }
                if connection.hasAudio {
                    Button(connection.snapshot?.relaying?.userId == user.id && connection.snapshot?.relaying?.stream == .voice
                           ? "Stop Relaying Voice Stream" : "Relay Voice Stream") {
                        let on = connection.snapshot?.relaying?.userId == user.id && connection.snapshot?.relaying?.stream == .voice
                        connection.setRelay(on ? nil : user, .voice)
                    }
                    Button(connection.snapshot?.relaying?.userId == user.id && connection.snapshot?.relaying?.stream == .mediaFile
                           ? "Stop Relaying Media File Stream" : "Relay Media File Stream") {
                        let on = connection.snapshot?.relaying?.userId == user.id && connection.snapshot?.relaying?.stream == .mediaFile
                        connection.setRelay(on ? nil : user, .mediaFile)
                    }
                }
            }
            .foregroundStyle(.primary)
            .navigationTitle("Advanced: \(user.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The desktop's Volume dialog (uservolume.ui): voice and media file
/// volume with their stereo options, and Default.
struct UserVolumeDialog: View {
    let connection: ServerConnection
    let user: User
    @Environment(\.dismiss) private var dismiss

    private var u: User { connection.snapshot?.users.first { $0.id == user.id } ?? user }

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice Volume Settings") {
                    slider("Volume", u.voiceVolume) { connection.setVolume(u, percent: $0) }
                    Toggle("Mute left", isOn: Binding(get: { !u.voiceLeft }, set: { connection.setStereo(u, .voice, left: !$0, right: u.voiceRight) }))
                    Toggle("Mute right", isOn: Binding(get: { !u.voiceRight }, set: { connection.setStereo(u, .voice, left: u.voiceLeft, right: !$0) }))
                }
                Section("Media File Volume Settings") {
                    slider("Volume", u.mediaVolume) { connection.setMediaVolume(u, percent: $0) }
                    Toggle("Mute left", isOn: Binding(get: { !u.mediaLeft }, set: { connection.setStereo(u, .mediaFile, left: !$0, right: u.mediaRight) }))
                    Toggle("Mute right", isOn: Binding(get: { !u.mediaRight }, set: { connection.setStereo(u, .mediaFile, left: u.mediaLeft, right: !$0) }))
                }
                Section {
                    Button("Default") {
                        connection.setVolume(u, percent: 50)
                        connection.setMediaVolume(u, percent: 50)
                        connection.setStereo(u, .voice, left: true, right: true)
                        connection.setStereo(u, .mediaFile, left: true, right: true)
                    }
                }
            }
            .navigationTitle("Volume: \(user.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func slider(_ label: String, _ value: Int32, set: @escaping (Int) -> Void) -> some View {
        NamedSlider(label, int: Binding(get: { Int(value) }, set: { set($0) }), in: 0...100, spoken: "\(value) percent")
    }
}

// MARK: Restore volume settings and subscriptions on login (web logins)

/// What the desktop remembers about a BearWare.dk web-login user between
/// their logins (common.cpp UserCached).
struct CachedUser {
    let subscriptions: Set<Subscription>
    let voiceMuted: Bool, mediaMuted: Bool
    let voiceVolume: Int32, mediaVolume: Int32
    let voiceLeft: Bool, voiceRight: Bool, mediaLeft: Bool, mediaRight: Bool

    init(_ u: User) {
        subscriptions = Set(u.mySubscriptions.on)
        voiceMuted = u.voiceMuted; mediaMuted = u.mediaMuted
        voiceVolume = u.voiceVolume; mediaVolume = u.mediaVolume
        voiceLeft = u.voiceLeft; voiceRight = u.voiceRight; mediaLeft = u.mediaLeft; mediaRight = u.mediaRight
    }

    /// The desktop's userCacheID: web logins only ("…@bearware.dk"), by
    /// username and client; nil when not remembered.
    static func key(_ u: User, restore: Bool) -> String? {
        guard restore, u.username.lowercased().hasSuffix("@bearware.dk") else { return nil }
        return "\(u.username)|\(u.clientName)"
    }
}

extension ServerConnection {
    /// Remembers someone (logging out, or before I disconnect).
    func cacheUser(_ u: User) {
        guard let key = CachedUser.key(u, restore: appModel?.restoreUserSettings ?? true) else { return }
        userCache[key] = CachedUser(u)
    }

    /// Puts back what was remembered about someone logging in.
    func restoreUser(_ u: User) {
        guard let key = CachedUser.key(u, restore: appModel?.restoreUserSettings ?? true), let c = userCache[key] else { return }
        if c.voiceMuted != u.voiceMuted { setMuted(u, c.voiceMuted) }
        if c.mediaMuted != u.mediaMuted { setMediaMuted(u, c.mediaMuted) }
        if c.voiceVolume != u.voiceVolume { setVolume(u, percent: Int(c.voiceVolume)) }
        if c.mediaVolume != u.mediaVolume { setMediaVolume(u, percent: Int(c.mediaVolume)) }
        if (c.voiceLeft, c.voiceRight) != (u.voiceLeft, u.voiceRight) { setStereo(u, .voice, left: c.voiceLeft, right: c.voiceRight) }
        if (c.mediaLeft, c.mediaRight) != (u.mediaLeft, u.mediaRight) { setStereo(u, .mediaFile, left: c.mediaLeft, right: c.mediaRight) }
        let now = Set(u.mySubscriptions.on)
        for sub in now.symmetricDifference(c.subscriptions) { setSubscription(u, sub, c.subscriptions.contains(sub)) }
    }
}

/// The desktop's Stream Media File dialog (streammediafile.ui): the file's
/// properties, "Continuously play media file", the start position.
struct StreamMediaFileDialog: View {
    let connection: ServerConnection
    let plan: ServerConnection.StreamPlan
    @Environment(\.dismiss) private var dismiss
    @AppStorage("streamLoop") private var loop = false
    @State private var start = 0.0
    // The desktop's audio preprocessor (none by default), remembered.
    @AppStorage("streamPreprocessor") private var kind = 0
    @AppStorage("streamTTGain") private var ttGain = 50
    @AppStorage("streamTTMuteLeft") private var ttLeft = false
    @AppStorage("streamTTMuteRight") private var ttRight = false
    @AppStorage("streamSpeexAGC") private var spAGC = true
    @AppStorage("streamSpeexGain") private var spGain = 8000
    @AppStorage("streamSpeexMaxGain") private var spMaxGain = 30
    @AppStorage("streamSpeexInc") private var spInc = 12
    @AppStorage("streamSpeexDec") private var spDec = -40
    @AppStorage("streamSpeexDenoise") private var spDenoise = true
    @AppStorage("streamSpeexAtten") private var spAtten = -30

    private var preprocessor: StreamPreprocessor {
        switch kind {
        case 1: .teamTalk(gain: Int32(ttGain), muteLeft: ttLeft, muteRight: ttRight)
        case 2: .speex(agc: spAGC, gainLevel: Int32(spGain), maxIncDb: Int32(spInc), maxDecDb: Int32(spDec),
                       maxGainDb: Int32(spMaxGain), denoise: spDenoise, maxNoiseSuppressDb: Int32(spAtten))
        default: StreamPreprocessor.none
        }
    }

    private var info: MediaFileInfo { plan.info }

    private func time(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d:%02d.%03d", s / 3600, s / 60 % 60, s % 60, Int(ms) % 1000)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Media File Properties") {
                    LabeledContent("Media file", value: (plan.path as NSString).lastPathComponent)
                    LabeledContent("Audio format", value: info.sampleRate > 0 ? "\(info.sampleRate) Hz, \(info.channels == 1 ? "Mono" : "Stereo")" : "None")
                    LabeledContent("Video format", value: info.videoWidth > 0 ? "\(info.videoWidth)x\(info.videoHeight)" : "None")
                    LabeledContent("Duration", value: time(Double(info.durationMs)))
                    Toggle("Continuously play media file", isOn: $loop)
                }
                Section("Playback Settings") {
                    Picker("Audio preprocessor", selection: $kind) {
                        Text("No Audio Preprocessor").tag(0)
                        Text("TeamTalk Audio Preprocessor").tag(1)
                        Text("Speex DSP Audio Preprocessor").tag(2)
                    }
                    if kind == 1 {
                        NamedSlider("Gain Level", int: $ttGain, in: 0...100, spoken: "\(ttGain) percent")
                        Toggle("Mute left channel", isOn: $ttLeft)
                        Toggle("Mute right channel", isOn: $ttRight)
                    }
                    if kind == 2 {
                        Toggle("Enable AGC", isOn: $spAGC)
                        NumberField("Gain Level", value: $spGain, in: 0...32000)
                        NumberField("Max Gain dB", value: $spMaxGain, in: 0...100)
                        NumberField("Max Gain Increase Per Sec (dB)", value: $spInc, in: 0...100)
                        NumberField("Max Gain Decrease Per Sec (dB)", value: $spDec, in: -100...0)
                        Toggle("Enable Denoising", isOn: $spDenoise)
                        NumberField("Max Attenuation of noise (dB)", value: $spAtten, in: -100...0)
                    }
                    if kind != 0 {
                        Button("Default") {
                            ttGain = 50; ttLeft = false; ttRight = false
                            spAGC = true; spGain = 8000; spMaxGain = 30; spInc = 12; spDec = -40; spDenoise = true; spAtten = -30
                        }
                    }
                    if info.durationMs > 0 {
                        NamedSlider("Start position", value: $start, in: 0...Double(info.durationMs), step: 1000, spoken: time(start))
                    }
                }
            }
            .navigationTitle("Stream Media File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        connection.startStream(plan, offsetMs: UInt32(start), looping: loop, preprocessor: preprocessor)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// This server's own volumes (the desktop runs one copy per server, each
/// with its own): master volume, microphone gain and media files, each
/// following Settings until set here; kept on this iPhone.
struct ServerVolumeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection

    private func level(_ label: String, _ key: WritableKeyPath<SavedServer, Int?>, global: Int32, range: ClosedRange<Int> = 0...100) -> some View {
        let own = connection.server[keyPath: key]
        let value = own ?? Int(global)
        return VStack(alignment: .leading) {
            NamedSlider(label, int: Binding(get: { value }, set: { set(key, $0) }), in: range,
                        spoken: own == nil ? "\(value), as in Settings" : "\(value)")
            if own != nil {
                Button("Use Settings' \(label.lowercased())") { set(key, nil) }
            }
        }
    }

    private func set(_ key: WritableKeyPath<SavedServer, Int?>, _ v: Int?) {
        var s = connection.server
        s[keyPath: key] = v
        model.setVolumes(of: s)
    }

    var body: some View {
        let a = model.audio
        NavigationStack {
            Form {
                Section {
                    level("Master volume", \.outputVolume, global: a.outputVolume)
                    level("Microphone gain", \.micGain, global: a.micGain)
                    level("Media file vs. voice volume", \.mediaVolume, global: a.mediaVolume)
                } footer: {
                    Text("For \(connection.server.title) only, as the desktop client's separate copies each have their own. Until you change one here it follows Settings → Sound system.")
                }
            }
            .navigationTitle("Volume for this server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
