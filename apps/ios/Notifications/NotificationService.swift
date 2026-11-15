import CryptoKit
import Foundation
import UserNotifications

/// Opens the Monitor's sealed notifications: the service sends Apple only a
/// placeholder and the real title and text sealed (ChaCha20-Poly1305:
/// base64 of a 12-byte nonce, the ciphertext and the tag) with this
/// install's key, which the app keeps in the shared App Group.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        defer { contentHandler(content) }
        guard let ttng = request.content.userInfo["ttng"] as? [String: Any] else { return }
        var fields = ttng["content"] as? [String: Any]
        if fields == nil, let sealed = ttng["sealed"] as? String, let opened = Self.open(sealed) {
            fields = (try? JSONSerialization.jsonObject(with: opened)) as? [String: Any]
        }
        guard let f = fields else { return }
        if let t = f["title"] as? String, !t.isEmpty { content.title = t }
        if let t = f["subtitle"] as? String { content.subtitle = t }
        if let t = f["body"] as? String { content.body = t }
        if let t = f["thread"] as? String, !t.isEmpty { content.threadIdentifier = t }
        if let t = f["category"] as? String, !t.isEmpty { content.categoryIdentifier = t }
        if let d = f["data"] as? [String: Any] {
            var info = content.userInfo
            info["data"] = d
            content.userInfo = info
        }
    }

    private static func open(_ sealed: String) -> Data? {
        let group = Bundle.main.object(forInfoDictionaryKey: "TTNGAppGroup") as? String ?? ""
        guard let keyText = UserDefaults(suiteName: group)?.string(forKey: "pushKey"),
              let key = Data(base64Encoded: keyText), key.count == 32,
              let combined = Data(base64Encoded: sealed),
              let box = try? ChaChaPoly.SealedBox(combined: combined)
        else { return nil }
        return try? ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }
}
