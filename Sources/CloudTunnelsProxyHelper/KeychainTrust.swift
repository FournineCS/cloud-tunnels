import Foundation

/// Installs (and removes) the local CA in /Library/Keychains/System.keychain
/// as a trusted root. The helper runs as root, so this needs no sudo prompt
/// — but it does need the canonical `/usr/bin/security` CLI, which is part
/// of every macOS install since forever.
///
/// We deliberately shell out instead of using `SecTrustSettingsSetTrustSettings`
/// because the Security.framework APIs for system-wide trust settings need
/// finicky CFDictionary construction and historically have edge-case bugs.
/// Shell-out is one fork+exec on first install and never again.
public struct KeychainTrust: Sendable {
    public static let systemKeychainPath = "/Library/Keychains/System.keychain"
    public static let securityToolPath = "/usr/bin/security"

    public init() {}

    // MARK: - Public API

    /// Installs `ca.pem` as a trusted root in the System keychain. No-op if
    /// a cert with the given common name is already present and trusted.
    /// Idempotent.
    public func installRootIfNeeded(
        pemPath: URL,
        commonName: String
    ) throws {
        if isInstalled(commonName: commonName) { return }
        try add(pemPath: pemPath)
    }

    /// Removes any cert with the given common name from the System keychain.
    /// Used by `uninstall()` and the Reset action. Errors are swallowed —
    /// best-effort cleanup, never fails the surrounding teardown.
    public func removeRoot(commonName: String) {
        guard isInstalled(commonName: commonName) else { return }
        // `delete-certificate` removes the first match. Loop until none
        // remain so reinstall-loops can't pile up duplicates.
        for _ in 0..<8 {
            let result = run(
                Self.securityToolPath,
                ["delete-certificate", "-c", commonName, Self.systemKeychainPath]
            )
            if result.exitCode != 0 { break }
            if !isInstalled(commonName: commonName) { break }
        }
    }

    public func isInstalled(commonName: String) -> Bool {
        let result = run(
            Self.securityToolPath,
            [
                "find-certificate",
                "-c", commonName,
                Self.systemKeychainPath,
            ]
        )
        return result.exitCode == 0
    }

    // MARK: - Internals

    private func add(pemPath: URL) throws {
        // -d  add to the default (admin / system) domain
        // -r trustRoot  treat as a self-signed root
        // -k <keychain>  target the System keychain
        let result = run(
            Self.securityToolPath,
            [
                "add-trusted-cert",
                "-d",
                "-r", "trustRoot",
                "-k", Self.systemKeychainPath,
                pemPath.path,
            ]
        )
        if result.exitCode != 0 {
            throw NSError(
                domain: "com.fourninecloud.cloud-tunnels.proxy-helper",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to add CA to System keychain (exit \(result.exitCode)): \(result.stderr)"
                ]
            )
        }
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ path: String, _ args: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: String(describing: error))
        }
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
