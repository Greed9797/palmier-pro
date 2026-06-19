import Foundation

/// File-backed BYOK key store. NOT the macOS Keychain — deliberately.
///
/// This app is ad-hoc signed and rebuilt on CI with a fresh code signature (new cdhash)
/// every release. The login Keychain binds each item's ACL to the creating binary's code
/// requirement, so after any reinstall the app can no longer read — or even overwrite —
/// keys it saved under the previous signature (`SecItemCopyMatching` → `errSecAuthFailed`).
/// That silently wiped every saved BYOK key on each update, which read as "MiniMax/Gemini
/// stopped working". A signature can't be stabilized on CI (ad-hoc, no Team ID), so storage
/// must not be signature-bound.
///
/// Instead: a single `0600` file in Application Support, readable only by the user, by any
/// build of the app. Values are base64 (obfuscation against shoulder-surfing/log scraping,
/// NOT encryption — without a stable Keychain there is no place to hold an encryption key).
/// The real protection is the file mode plus the per-user directory.
enum KeychainStore {
    private static let lock = NSLock()

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.palmier.pro", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("credentials.json", isDirectory: false)
    }

    private static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

    private static func writeAll(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        let url = fileURL
        try? data.write(to: url, options: [.atomic])
        // .atomic renames a fresh temp file into place → perms reset to umask default; re-pin to 0600.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func save(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all[account] = Data(value.utf8).base64EncodedString()
        writeAll(all)
    }

    static func load(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let b64 = readAll()[account],
              let data = Data(base64Encoded: b64),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func delete(account: String) {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all.removeValue(forKey: account)
        writeAll(all)
    }
}
