import Foundation
import Security

/// Stores the server config (including the auth token) in the keychain.
enum Keychain {
    private static let service = "io.backl.navisync"
    private static let account = "server"

    static func saveConfig(_ config: ServerConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        deleteConfig()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadConfig() -> ServerConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    static func deleteConfig() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// JSON files in Application Support, used to cache the library for offline browsing.
enum DiskStore {
    static let baseDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaviSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func directory(_ name: String) -> URL {
        let url = baseDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var libraryDirectory: URL { directory("Library") }

    static func save<T: Encodable>(_ value: T, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: libraryDirectory.appendingPathComponent(safeName(name) + ".json"), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: libraryDirectory.appendingPathComponent(safeName(name) + ".json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func clearLibrary() {
        try? FileManager.default.removeItem(at: libraryDirectory)
    }

    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }
}
