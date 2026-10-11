// Drives TeamTalk NG's monitor code (compiled for Mac Catalyst) against a
// live ngmon. Line protocol on stdin/stdout with tests/app_check.py.
import Foundation

func say(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String) -> Never { say("FAIL \(s)"); exit(1) }
func readCommand() -> [String] { (readLine() ?? "").split(separator: " ", maxSplits: 1).map(String.init) }

@MainActor
final class Run {
    var events: [MonitorStoredEvent] = []
    var catchUps: [Int64: Bool] = [:]
    var connection: MonitorConnection?

    func main() async {
        let base = URL(string: CommandLine.arguments[1])!
        guard MonitorService.baseURL.absoluteString == "https://ttmonitor.mad-gamer.com" else { fail("service address") }
        let reg: MonitorRegistration
        do { reg = try await MonitorAPI.register(baseURL: base, deviceName: "Harness") } catch { fail("register: \(error)") }
        let account = MonitorAccount(ref: "harness-ref", name: reg.name, baseURL: base, token: reg.token, pushKey: reg.pushKey, deviceID: reg.deviceId)
        let api = MonitorAPI(account: account)
        say("ok registered as install \(reg.deviceId)")
        do {
            // What Monitor This Server sends for a saved server.
            let saved = Server()
            saved.name = "Test"
            saved.ipaddr = "127.0.0.1"
            saved.tcpport = 20333
            saved.nickname = "NG"
            saved.username = "monitor"
            saved.password = "monitor"
            let input = MonitorCenter.input(for: saved)
            guard input.nickname == "NG (Monitor)", input.channel.isEmpty, input.password == "monitor" else { fail("input \(input)") }
            // No nickname on the saved server: the Settings nickname, as a live connection uses.
            let unnamed = Server()
            UserDefaults.standard.set("Matt", forKey: PREF_GENERAL_NICKNAME)
            guard MonitorCenter.input(for: unnamed).nickname == "Matt (Monitor)" else { fail("settings nickname not used") }
            UserDefaults.standard.removeObject(forKey: PREF_GENERAL_NICKNAME)
            guard MonitorCenter.input(for: unnamed).nickname == "Monitor" else { fail("no nickname at all") }
            say("ok nicknames: saved server's, else Settings', else Monitor")
            guard input.statusMode == MonitorGender.neutral else { fail("gender in Settings not used: \(input.statusMode)") }
            try await api.addServer(input)
            say("ok server added from a saved server")
            let added = try await api.servers().first { $0.host == input.host && $0.username == "monitor" }
            guard let added, try await api.serverConfig(added.id).statusMode == MonitorGender.neutral else { fail("monitor's gender not kept") }
            say("ok monitor has the gender in Settings")
            try await api.registerPush(deviceToken: String(repeating: "cd", count: 32), sandbox: true)
            var prefs = try await api.prefs()
            guard prefs == MonitorPrefs() else { fail("default prefs differ: \(prefs)") }
            prefs.channelMessages = "all"
            try await api.setPrefs(prefs)
            guard try await api.prefs().channelMessages == "all" else { fail("prefs not saved") }
            say("ok prefs round trip")
            // Wait for the monitor to be logged in.
            var servers: [MonitorServerSummary] = []
            for _ in 0..<50 {
                servers = try await api.servers()
                if servers.first?.status == .loggedIn { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let s = servers.first, s.status == .loggedIn else { fail("monitor not logged in: \(servers)") }
            say("ok servers decoded: \(s.displayName) \(s.status.text)")
            let cfg = try await api.serverConfig(s.id)
            guard s.username == "monitor", s.nickname == "NG (Monitor)" else { fail("summary \(s)") }
            say("ok server config: username=\(cfg.username)")
            try await api.pause(server: s.id, minutes: 5)
            for _ in 0..<50 where try await api.servers().first?.status != .paused { try await Task.sleep(nanoseconds: 100_000_000) }
            guard let p = try await api.servers().first, p.status == .paused else { fail("not paused") }
            say("ok paused: \(p.status.text)")
            try await api.resume(server: s.id)
            for _ in 0..<100 where try await api.servers().first?.status != .loggedIn { try await Task.sleep(nanoseconds: 100_000_000) }
            guard try await api.servers().first?.status == .loggedIn else { fail("not resumed") }
            say("ok resumed")
        } catch { fail("api: \(error)") }

        let conn = MonitorConnection(account: account)
        NotificationCenter.default.addObserver(forName: .monitorEvent, object: conn, queue: nil) { n in
            guard let e = n.userInfo?["event"] as? MonitorStoredEvent else { return }
            let catchUp = n.userInfo?["catchUp"] as? Bool ?? false
            Task { @MainActor in
                self.events.append(e)
                self.catchUps[e.seq, default: false] = catchUp
                say("event \(e.seq) \(MonitorEventText.describe(e.event))")
            }
        }
        conn.start()
        connection = conn
        let model: MonitorServerModel
        do { model = try await conn.model(for: 1) } catch { fail("model: \(error)") }
        let me = model.me.userId
        say("ok monitor user \(me)")
        say("ok model: channels=\(model.channels.map(\.path)) me=\(model.me.userId)")
        for _ in 0..<50 where !conn.online { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard conn.online else { fail("websocket not ready: \(conn.lastError ?? "")") }
        say("READY")

        while true {
            let cmd = readCommand()
            switch cmd.first {
            case "wait":
                // wait <text>: until an event describing <text> arrives.
                let want = cmd.count > 1 ? cmd[1] : ""
                var found = false
                for _ in 0..<100 {
                    if events.contains(where: { MonitorEventText.describe($0.event).contains(want) }) { found = true; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard found else { fail("no event with \(want)") }
                say("ok got \(want)")
            case "model":
                let users = model.users.map { "\($0.displayName)@\(model.channel($0.channelId)?.path ?? "-")" }
                say("ok model users=\(users) me_channel=\(model.channel(model.me.channelId)?.path ?? "-")")
            case "relogin":
                // The monitor logs out and back in; the app's copy must
                // fill again (the bug where people and channels vanished).
                var reloaded = false
                let observer = NotificationCenter.default.addObserver(forName: .monitorServerReloaded, object: conn, queue: nil) { _ in
                    Task { @MainActor in reloaded = true }
                }
                do {
                    try await api.pause(server: 1, minutes: 5)
                    for _ in 0..<50 where conn.models[1]?.summary.status != .paused { try await Task.sleep(nanoseconds: 100_000_000) }
                    guard conn.models[1]?.users.isEmpty == true else { fail("paused copy still has people") }
                    try await api.resume(server: 1)
                    for _ in 0..<150 where !reloaded { try await Task.sleep(nanoseconds: 100_000_000) }
                } catch { fail("relogin: \(error)") }
                NotificationCenter.default.removeObserver(observer)
                guard reloaded, let m = conn.models[1] else { fail("not reloaded after logging back in") }
                say("ok reloaded after relogin: channels=\(m.channels.map(\.path)) users=\(m.users.map(\.displayName)) me=\(m.me.userId)")
            case "reply":
                // To Alice's user ID, within her conversation, as the app does.
                do {
                    guard let conv = try await api.conversations(server: 1).first(where: { $0.active }) else { fail("no active conversation") }
                    try await api.sendPrivateMessage(server: 1, userID: conv.userId, conversationID: conv.id, text: cmd[1])
                    let convs = try await api.conversations(server: 1)
                    let (_, msgs, _) = try await api.messages(server: 1, conversation: conv.id)
                    try await api.markRead(server: 1, conversation: conv.id)
                    say("ok replied; conversations=\(convs.map { "\($0.userId):\($0.unread):\($0.active)" }) messages=\(msgs.map { "\($0.outgoing ? ">" : "<")\($0.text)" })")
                } catch { fail("reply: \(error)") }
            case "join":
                do {
                    try await api.act(server: 1, "join", ["channel_id": Int(cmd[1])!])
                    try await api.sendChannelMessage(server: 1, channelID: nil, text: "hello from the app")
                    say("ok joined and spoke")
                } catch { fail("join: \(error)") }
            case "refused":
                do {
                    try await api.act(server: 1, "move", ["user_id": 9999, "channel_id": 1])
                    fail("move should fail")
                } catch { say("ok refusal: \(error.localizedDescription)") }
            case "open":
                // open <payload json>: what the notification extension does.
                let obj = try! JSONSerialization.jsonObject(with: cmd[1].data(using: .utf8)!) as! [String: Any]
                guard let ttng = obj["ttng"] as? [String: Any], let sealed = ttng["sealed"] as? String,
                      let data = MonitorPush.open(sealed: sealed, keyBase64: account.pushKey),
                      let content = try? JSONDecoder().decode(MonitorPushContent.self, from: data) else { fail("could not open push") }
                guard ttng["ref"] as? String == "harness-ref" else { fail("push ref") }
                say("ok opened push: \(content.title) | \(content.body) | user=\(content.data["user_id"]?.int ?? -1) server=\(content.data["server_id"]?.int ?? -1)")
            case "away":
                // The app goes to the background: its live link closes.
                connection?.stop()
                say("ok away")
            case "back":
                // Back to the foreground: missed events come once, as catch-up.
                connection?.start()
                let want = cmd.count > 1 ? cmd[1] : ""
                var matches: [MonitorStoredEvent] = []
                for _ in 0..<100 {
                    matches = events.filter { MonitorEventText.describe($0.event).contains(want) }
                    if !matches.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                matches = events.filter { MonitorEventText.describe($0.event).contains(want) }
                guard matches.count == 1 else { fail("missed event delivered \(matches.count) times") }
                guard catchUps[matches[0].seq] == true else { fail("missed event not marked as catch-up") }
                say("ok caught up once, quietly")
            case "merge":
                // A second sign-up (a new iPhone before iCloud Keychain caught
                // up) monitors a server, then is merged into this one.
                do {
                    let other = try await MonitorAPI.register(baseURL: base, deviceName: "New iPhone")
                    let otherAPI = MonitorAPI(account: MonitorAccount(ref: "other", name: "", baseURL: base, token: other.token, pushKey: other.pushKey, deviceID: other.deviceId))
                    let saved = Server()
                    saved.name = "Late"
                    saved.ipaddr = "127.0.0.1"
                    saved.tcpport = 20333
                    saved.username = "alice"
                    saved.password = "alice"
                    try await otherAPI.addServer(MonitorCenter.input(for: saved))
                    try await api.merge(otherToken: other.token)
                    let names = try await api.servers().map(\.name)
                    guard names.contains("Late") else { fail("merged server missing: \(names)") }
                    do {
                        _ = try await otherAPI.servers()
                        fail("other sign-up still works")
                    } catch MonitorError.notPaired {}
                    say("ok merged: \(names)")
                } catch { fail("merge: \(error)") }
            case "unpair":
                do {
                    try await api.unpair()
                    _ = try await api.servers()
                    fail("still paired")
                } catch MonitorError.notPaired {
                    say("ok stopped monitoring everything")
                } catch { fail("unpair: \(error)") }
            default:
                conn.stop()
                say("DONE")
                exit(0)
            }
        }
    }
}

@main
struct Main {
    static func main() {
        Task { @MainActor in await Run().main() }
        dispatchMain()
    }
}
