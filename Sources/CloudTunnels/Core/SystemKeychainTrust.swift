import Foundation
import Security
import os

/// Adds and removes the CloudTunnels local CA in the **user** trust domain
/// from the GUI process. We deliberately use the user domain (not .admin /
/// system) because:
///
/// 1. Setting trust settings in the system domain requires `SecTrustSettings
///    SetTrustSettings` to display a SecurityAgent dialog — which fails with
///    `errSecInteractionNotAllowed` from any process not in the right auth
///    context (launchd daemons, osascript with administrator privileges, etc.).
///    On macOS Tahoe even mkcert's pattern is unreliable.
/// 2. The user domain only needs the user's own permission, which the GUI
///    process already has — no dialogs at all in the common case.
/// 3. Both Safari and Chrome (≥90, on the macOS keychain trust store) consult
///    the user trust domain in addition to the system one. Firefox uses NSS
///    and ignores both — that caveat is independent of system-vs-user.
///
/// Implementation is pure Security framework — no shelling out to /usr/bin/security,
/// no AppleScript, no Process. Imports the cert via `SecItemAdd`, then sets
/// trust via `SecTrustSettingsSetTrustSettings(cert, .user, nil)` where `nil`
/// means "trust for every use case" (matches `kSecTrustSettingsResultTrustRoot`
/// for self-signed roots, which is what our CA is).
public enum SystemKeychainTrust {

    public enum Error: Swift.Error, LocalizedError {
        case caFileMissing(String)
        case pemParseFailed
        case keychainAddFailed(OSStatus, String)
        case trustSettingsFailed(OSStatus, String)
        case userCancelled

        public var errorDescription: String? {
            switch self {
            case .caFileMissing(let path):
                return "CA file not found at \(path) — the helper may not have generated it yet."
            case .pemParseFailed:
                return "Could not parse the local CA certificate."
            case .keychainAddFailed(let status, let detail):
                return "Could not add CA to login keychain (OSStatus \(status)): \(detail)"
            case .trustSettingsFailed(let status, let detail):
                return "Could not mark CA as trusted (OSStatus \(status)): \(detail)"
            case .userCancelled:
                return "Trust install cancelled by user"
            }
        }
    }

    public static let commonName = "CloudTunnels Local CA"
    public static let caCertPath = "/Library/Application Support/CloudTunnels/proxy/ca/ca.pem"

    private static let log = Logger(
        subsystem: "com.fourninecloud.cloud-tunnels",
        category: "SystemKeychainTrust"
    )

    // MARK: - Public API

    /// Returns true only if the CA is present in the user trust store **and**
    /// has trust settings applied. A bare cert with no trust settings is the
    /// orphan state we want to detect and recover from.
    public static func isInstalled() -> Bool {
        guard let cert = findCertificate(named: commonName) else { return false }
        var settings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(cert, .user, &settings)
        // errSecSuccess + non-nil settings = trust is active
        // errSecItemNotFound = cert exists but no trust = orphan
        return status == errSecSuccess && settings != nil
    }

    /// Idempotent installer. No-op if the CA is already trusted in the user
    /// domain. Otherwise loads ca.pem from disk, imports the cert, and sets
    /// it as a trusted root for all uses.
    public static func installIfNeeded(pemPath: String = caCertPath) throws {
        if isInstalled() {
            log.debug("CA already trusted in user domain — nothing to do")
            return
        }

        // 1. Read PEM from disk (the helper writes it world-readable as 0644)
        let pemURL = URL(fileURLWithPath: pemPath)
        guard FileManager.default.fileExists(atPath: pemPath) else {
            throw Error.caFileMissing(pemPath)
        }
        let pemString = try String(contentsOf: pemURL, encoding: .utf8)

        // 2. Strip PEM armor and base64-decode to DER
        let derData = try parsePEM(pemString)

        // 3. Build a SecCertificate
        guard let cert = SecCertificateCreateWithData(nil, derData as CFData) else {
            throw Error.pemParseFailed
        }

        // 4. Make sure the cert is in *some* keychain so trust settings can
        //    reference it. Add to the user's login keychain. If it's already
        //    there from a previous broken attempt that's fine — duplicate is
        //    a soft error we ignore.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: commonName,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            throw Error.keychainAddFailed(addStatus, secErrorMessage(addStatus))
        }

        // 5. Apply trust settings in the user domain. Passing nil for
        //    settings means "trust for all uses" — equivalent to the
        //    "Always Trust" toggle in Keychain Access.
        let trustStatus = SecTrustSettingsSetTrustSettings(cert, .user, nil)
        if trustStatus != errSecSuccess {
            throw Error.trustSettingsFailed(trustStatus, secErrorMessage(trustStatus))
        }

        log.info("CA installed and trusted in user domain")
    }

    /// Removes both the trust setting and the cert itself from the user
    /// keychain. Used by the Reset / Uninstall path.
    public static func removeIfPresent() throws {
        guard let cert = findCertificate(named: commonName) else { return }

        // Remove user-domain trust first. Passing nil for settings deletes
        // any existing trust settings for this cert in the user domain.
        let trustStatus = SecTrustSettingsRemoveTrustSettings(cert, .user)
        if trustStatus != errSecSuccess && trustStatus != errSecItemNotFound {
            log.error("Failed to remove trust settings (\(trustStatus, privacy: .public))")
        }

        // Then delete the cert from the keychain.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: commonName,
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            log.error("Failed to delete CA from keychain (\(deleteStatus, privacy: .public))")
        }

        log.info("CA removed from user keychain")
    }

    // MARK: - Internals

    private static func findCertificate(named label: String) -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        return (item as! SecCertificate)
    }

    private static func parsePEM(_ pem: String) throws -> Data {
        let lines = pem.split(separator: "\n").filter { line in
            !line.contains("BEGIN CERTIFICATE") && !line.contains("END CERTIFICATE")
        }
        let base64 = lines.joined()
        guard let der = Data(base64Encoded: base64) else {
            throw Error.pemParseFailed
        }
        return der
    }

    private static func secErrorMessage(_ status: OSStatus) -> String {
        guard let cfStr = SecCopyErrorMessageString(status, nil) else {
            return "OSStatus \(status)"
        }
        return cfStr as String
    }
}
