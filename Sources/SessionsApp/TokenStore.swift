import Foundation
import Security
import SessionsCore
import SessionsTelegram

/// Токен бота — в файле ~/Library/Application Support/Sessions/telegram-token (0600).
/// Не в связке ключей: ad-hoc подпись меняется с каждой сборкой, и система
/// спрашивала бы доступ после каждого обновления.
enum TokenStore {

    private static let file = TokenFile(url: Bridge.supportDir.appendingPathComponent("telegram-token"))

    static func token() -> String? {
        migrateFromKeychain()
        return file.token()
    }

    /// nil — удалить. false — файл записать не удалось.
    @discardableResult
    static func setToken(_ t: String?) -> Bool {
        migrateFromKeychain()
        return file.save(t)
    }

    // MARK: - Перенос из связки ключей (ранние dev-сборки)

    private static let migratedKey = "telegramTokenMigrated"

    private static let keychainItem: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.local.afksessions.telegram",
        kSecAttrAccount as String: "bot-token",
    ]

    /// Один раз: забрать токен из связки ключей в файл и удалить запись.
    /// Флаг ставим сразу — чтобы не спрашивать доступ к связке на каждом запуске.
    private static func migrateFromKeychain() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)

        var q = keychainItem
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let old = String(data: data, encoding: .utf8) else { return }
        // Файл уже есть — он новее; иначе переносим. Запись в связке удаляем, только если токен сохранён.
        if file.token() != nil || file.save(old) {
            SecItemDelete(keychainItem as CFDictionary)
        }
    }
}
