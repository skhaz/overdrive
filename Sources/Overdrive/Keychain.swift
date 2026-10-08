import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "org.delduca.Overdrive.lastfm"

    static func read(_ account: String) -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }

        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ account: String, _ value: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        SecItemDelete(query as CFDictionary)

        guard !value.isEmpty else { return }

        // An ad-hoc signature changes with each release, so open the item to all apps to prevent a password prompt after each update.
        var access: SecAccess?
        SecAccessCreate(service as CFString, [] as CFArray, &access)

        for acl in SecAccessCopyMatchingACLList(access!, kSecACLAuthorizationDecrypt) as! [SecACL] {
            SecACLSetContents(acl, nil, service as CFString, [])
        }

        SecItemAdd(query.merging([kSecValueData: Data(value.utf8), kSecAttrAccess: access!]) { $1 } as CFDictionary, nil)
    }
}
