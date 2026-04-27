import Foundation
import TunnelCore
import os

struct AWSProfileState: Equatable, Identifiable {
    let name: String
    let isValid: Bool
    let accountId: String?
    let arn: String?

    var id: String { name }
}

@MainActor
final class AWSAuthManager: ObservableObject {
    /// All profile names discovered via `aws configure list-profiles`.
    /// Used by the Add Tunnel form picker.
    @Published private(set) var allProfileNames: [String] = []
    /// State (signed-in / account-id) for profiles that are actually
    /// referenced by a tunnel. We don't probe sts get-caller-identity for
    /// profiles nobody uses — that would be 30+ slow STS calls per refresh.
    @Published private(set) var profileStates: [String: AWSProfileState] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var pluginAvailable = true

    /// Profiles whose validity should be probed on refresh. The MenuBarRoot
    /// keeps this set in sync with the tunnel list.
    private var trackedProfiles: Set<String> = []

    private var monitorTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "aws-auth")

    /// Convenience: ordered list of state objects for profiles currently in
    /// use (alphabetical by name). For UI display.
    var trackedProfileStates: [AWSProfileState] {
        trackedProfiles
            .sorted()
            .map { name in
                profileStates[name] ?? AWSProfileState(name: name, isValid: false, accountId: nil, arn: nil)
            }
    }

    var isAnyValid: Bool { profileStates.values.contains { $0.isValid } }

    func setTrackedProfiles(_ names: Set<String>) {
        guard names != trackedProfiles else { return }
        trackedProfiles = names
        // Drop state for profiles that are no longer tracked
        profileStates = profileStates.filter { names.contains($0.key) }
        Task { await refresh() }
    }

    func start(intervalMinutes: Int) {
        stop()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let seconds = max(60, intervalMinutes * 60)
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Check session-manager-plugin presence once per refresh
        pluginAvailable = (try? AWSLocator.checkSessionManagerPlugin()) != nil

        // Always cheap: list all profile names
        guard let aws = try? AWSLocator.findAWS() else {
            allProfileNames = []
            profileStates = [:]
            return
        }
        if let result = await Self.runAWS(aws, ["configure", "list-profiles"], timeout: 10),
           result.exit == 0 {
            allProfileNames = Self.parseProfileList(result.stdout)
        }

        // Only probe sts get-caller-identity for tracked profiles
        guard !trackedProfiles.isEmpty else {
            profileStates = [:]
            lastRefresh = Date()
            return
        }

        let probed = await Self.probe(profiles: Array(trackedProfiles), aws: aws)
        var byName: [String: AWSProfileState] = [:]
        for state in probed { byName[state.name] = state }
        profileStates = byName
        lastRefresh = Date()
        log.info("aws profiles probed: tracked=\(self.trackedProfiles.count, privacy: .public) all=\(self.allProfileNames.count, privacy: .public) plugin=\(self.pluginAvailable, privacy: .public)")
    }

    /// Runs `aws sso login --profile=X`. Opens a browser for the user.
    func ssoLogin(profile: String) async -> Bool {
        guard let aws = try? AWSLocator.findAWS() else { return false }
        let proc = Process()
        proc.executableURL = aws
        proc.arguments = ["sso", "login", "--profile", profile]
        do { try proc.run() } catch {
            log.error("sso login launch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                proc.waitUntilExit()
                cont.resume(returning: proc.terminationStatus == 0)
            }
        }
        await refresh()
        return ok
    }

    // MARK: - Probing

    private static func probe(profiles names: [String], aws: URL) async -> [AWSProfileState] {
        guard !names.isEmpty else { return [] }
        return await withTaskGroup(of: AWSProfileState.self, returning: [AWSProfileState].self) { group in
            for name in names {
                group.addTask {
                    let result = await runAWS(aws, [
                        "sts", "get-caller-identity",
                        "--profile", name,
                        "--output", "json",
                    ], timeout: 12)
                    guard let result, result.exit == 0 else {
                        return AWSProfileState(name: name, isValid: false, accountId: nil, arn: nil)
                    }
                    let identity = parseCallerIdentity(result.stdout)
                    return AWSProfileState(
                        name: name,
                        isValid: true,
                        accountId: identity.accountId,
                        arn: identity.arn
                    )
                }
            }
            var out: [AWSProfileState] = []
            for await state in group { out.append(state) }
            return out.sorted { $0.name < $1.name }
        }
    }

    nonisolated static func parseProfileList(_ output: String) -> [String] {
        output
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private struct CallerIdentity: Decodable {
        let Account: String?
        let Arn: String?
    }

    nonisolated static func parseCallerIdentity(_ json: String) -> (accountId: String?, arn: String?) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CallerIdentity.self, from: data) else {
            return (nil, nil)
        }
        return (decoded.Account, decoded.Arn)
    }

    static func runAWS(_ aws: URL, _ args: [String], timeout: TimeInterval = 15) async -> (stdout: String, exit: Int32)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(stdout: String, exit: Int32)?, Never>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = aws
                proc.arguments = args
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = Pipe()
                do { try proc.run() } catch {
                    cont.resume(returning: nil); return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                if proc.isRunning {
                    proc.terminate()
                    cont.resume(returning: nil); return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let s = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: (s, proc.terminationStatus))
            }
        }
    }
}
