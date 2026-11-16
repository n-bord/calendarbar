import Foundation
import Security
import CalendarCore

/// Old versions could store a Telemost token. Only explicit account removal touches it now.
enum TelemostVault {
    static func remove(for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CalendarBarIdentity.identifier + ".telemost", kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CalendarError.message("Не удалось удалить прежний доступ Телемоста (\(status)).")
        }
    }
}
