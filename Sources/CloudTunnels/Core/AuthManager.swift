import Foundation
import TunnelCore
import os

struct AccountState: Equatable, Identifiable {
    let email: String
    let isActive: Bool   // the gcloud-currently-active account
    let isValid: Bool    // `gcloud auth print-access-token --account=<email>` succeeds
    var id: String { email }
}

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var accounts: [AccountState] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    var onChange: (([AccountState]) -> Void)?

    private var monitorTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.fourninecloud.cloud-tunnels", category: "auth")

    var isAnySignedIn: Bool { accounts.contains { $0.isValid } }
    var activeAccount: AccountState? { accounts.first { $0.isActive } }

    func isValid(email: String) -> Bool {
        accounts.first { $0.email == email }?.isValid ?? false
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
        let next = await Self.probe()
        if next != accounts {
            accounts = next
            onChange?(next)
            log.info("accounts refreshed: count=\(next.count, privacy: .public)")
        }
        lastRefresh = Date()
    }

    /// Runs `gcloud auth login`. The user picks which account to add in the
    /// browser. On success, the chosen account becomes the gcloud-active one
    /// but all previously-added accounts remain available.
    func login() async -> Bool {
        guard let gcloud = try? GCloudLocator.find() else { return false }
        let proc = Process()
        proc.executableURL = gcloud
        proc.arguments = ["auth", "login"]
        do { try proc.run() } catch {
            log.error("login launch failed: \(error.localizedDescription, privacy: .public)")
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

    /// Runs `gcloud auth revoke EMAIL --quiet`.
    func revoke(email: String) async -> Bool {
        guard let gcloud = try? GCloudLocator.find() else { return false }
        let (_, exit) = await Self.runGCloud(gcloud, ["auth", "revoke", email, "--quiet"], timeout: 30) ?? ("", 1)
        await refresh()
        return exit == 0
    }

    /// Sets the gcloud active account (affects commands without `--account=`).
    func setActive(email: String) async -> Bool {
        guard let gcloud = try? GCloudLocator.find() else { return false }
        let (_, exit) = await Self.runGCloud(gcloud, ["config", "set", "account", email], timeout: 10) ?? ("", 1)
        await refresh()
        return exit == 0
    }

    // MARK: - Probing

    private static func probe() async -> [AccountState] {
        guard let gcloud = try? GCloudLocator.find() else { return [] }

        // List all accounts with credentials
        guard let (stdout, exit) = await runGCloud(gcloud, [
            "auth", "list", "--format=json"
        ]), exit == 0 else { return [] }

        let listed = parseAuthList(stdout)
        guard !listed.isEmpty else { return [] }

        // For each account, check if its token is valid (in parallel)
        return await withTaskGroup(of: AccountState.self, returning: [AccountState].self) { group in
            for entry in listed {
                group.addTask {
                    let (_, vexit) = await runGCloud(gcloud, [
                        "auth", "print-access-token", "--account=\(entry.email)"
                    ]) ?? ("", 1)
                    return AccountState(
                        email: entry.email,
                        isActive: entry.isActive,
                        isValid: vexit == 0
                    )
                }
            }
            var out: [AccountState] = []
            for await state in group { out.append(state) }
            return out.sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.email < rhs.email
            }
        }
    }

    private struct RawAuthEntry: Decodable {
        let account: String
        let status: String?
    }

    nonisolated static func parseAuthList(_ json: String) -> [(email: String, isActive: Bool)] {
        guard let data = json.data(using: .utf8) else { return [] }
        guard let entries = try? JSONDecoder().decode([RawAuthEntry].self, from: data) else { return [] }
        return entries
            .filter { !$0.account.isEmpty }
            .map { ($0.account, ($0.status ?? "").uppercased() == "ACTIVE") }
    }

    static func runGCloud(_ gcloud: URL, _ args: [String], timeout: TimeInterval = 15) async -> (stdout: String, exit: Int32)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(stdout: String, exit: Int32)?, Never>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = gcloud
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
