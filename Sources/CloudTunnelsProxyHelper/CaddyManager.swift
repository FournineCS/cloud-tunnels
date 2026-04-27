import Foundation
import os
import ProxyHelperShared

/// Supervises the Caddy reverse-proxy child process. Owns the on-disk
/// JSON config, the `Process` handle, and the admin API client. The
/// helper's XPC layer talks only to this — it never touches Caddy
/// directly.
///
/// Lifecycle:
///   1. Helper starts → `start(routes:)` writes initial config and
///      spawns `caddy run --config <path> --adapter json`.
///   2. `addRoute` / `removeRoute` from XPC → `reload(routes:)` writes
///      a new config to the same path and POSTs `/load` to Caddy's
///      admin API on `127.0.0.1:2019`. Caddy hot-reloads in-place
///      with no listener downtime.
///   3. Helper stop → `stop()` SIGTERMs the child and waits for exit.
///
/// Why we shell out instead of using a Swift HTTP server: see the
/// commit history for the in-process NIO+AsyncHTTPClient implementation
/// that lived here previously and broke on browser SSO POST flows due
/// to upstream request/response correlation bugs we couldn't pin down.
/// Caddy is a battle-tested HTTP/1.1 + HTTP/2 reverse proxy that
/// handles every edge case (pipelining, keep-alive, sticky sessions,
/// chunked encoding, WebSocket upgrade) without us reimplementing them.
public actor CaddyManager {

    public enum CaddyError: LocalizedError {
        case binaryNotFound([String])
        case spawnFailed(String)
        case adminAPIUnreachable(String)
        case configEncodeFailed(String)
        case reloadFailed(Int, String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound(let searched):
                return "Caddy binary not found. Searched: \(searched.joined(separator: ", "))"
            case .spawnFailed(let msg):
                return "Failed to spawn caddy: \(msg)"
            case .adminAPIUnreachable(let msg):
                return "Caddy admin API unreachable: \(msg)"
            case .configEncodeFailed(let msg):
                return "Failed to encode caddy config: \(msg)"
            case .reloadFailed(let code, let body):
                return "Caddy /load returned HTTP \(code): \(body)"
            }
        }
    }

    /// Path search order for the Caddy binary. The helper runs as root
    /// from inside `/Applications/CloudTunnels.app`, so `Bundle.main`
    /// resolves to the .app and our bundled copy is the first hit. If
    /// the user has Homebrew Caddy installed and the .app wasn't built
    /// with `make download-caddy`, we fall through to the system copy.
    public static func defaultBinarySearchPaths() -> [String] {
        var paths: [String] = []
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/caddy").path
        paths.append(bundled)
        paths.append("/opt/homebrew/bin/caddy")
        paths.append("/usr/local/bin/caddy")
        paths.append("/usr/bin/caddy")
        return paths
    }

    private let log = Logger(
        subsystem: "com.fourninecloud.cloud-tunnels.proxy-helper",
        category: "CaddyManager"
    )

    /// Supervisor backoff schedule (seconds). Picked to recover from
    /// transient port binding races and Caddy's own admin-API warm-up
    /// without spamming restarts if Caddy is fundamentally broken.
    /// After `maxRestartAttempts` consecutive failures we give up and
    /// log a fault — the user has to fix whatever is wrong and click
    /// Start on a tunnel to kick a fresh `start(routes:)` call.
    private static let restartBackoffSeconds: [UInt64] = [1, 2, 5, 10, 30]
    public static let maxRestartAttempts = 5

    private let configPath: URL
    private let leavesDirectory: URL
    private let binarySearchPaths: [String]

    private var process: Process?
    private var stderrPipe: Pipe?
    private(set) public var bootTime: Date?

    /// Last known routes, captured on every start/reload so the
    /// supervisor can restart Caddy without XPC help when the child
    /// dies unexpectedly.
    private var lastRoutes: [ProxyRoute] = []

    /// Set to true when `stop()` runs so the termination handler
    /// knows the exit was intentional and doesn't trigger a restart.
    private var isStopping = false

    /// Consecutive auto-restart attempts since the last successful
    /// start. Reset to 0 whenever Caddy stays up past the warm-up
    /// window. Prevents an infinite restart loop when Caddy is
    /// crashing on every boot (e.g., misconfigured port binding).
    private(set) public var restartAttempts: Int = 0

    public init(
        configPath: URL,
        leavesDirectory: URL,
        binarySearchPaths: [String] = CaddyManager.defaultBinarySearchPaths()
    ) {
        self.configPath = configPath
        self.leavesDirectory = leavesDirectory
        self.binarySearchPaths = binarySearchPaths
    }

    // MARK: - Public API

    public var currentPID: Int32? {
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    public var isRunning: Bool {
        process?.isRunning == true
    }

    /// Start Caddy with the given routes. Idempotent — if Caddy is
    /// already running, this hot-reloads the config instead. On a
    /// successful start, resets the auto-restart counter.
    public func start(routes: [ProxyRoute]) async throws {
        self.lastRoutes = routes
        self.isStopping = false

        if isRunning {
            try await reload(routes: routes)
            return
        }

        try writeConfig(routes: routes)

        let binary = try locateBinary()
        log.info("Spawning caddy at \(binary, privacy: .public) with config \(self.configPath.path, privacy: .public)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // NO `--adapter json`. JSON is Caddy's native config format;
        // adapters exist only to CONVERT other formats (Caddyfile,
        // nginx) into JSON. Passing --adapter json makes Caddy fail
        // with "unrecognized config adapter: json" and exit 1.
        proc.arguments = [
            "run",
            "--config", configPath.path,
        ]
        let stderr = Pipe()
        let stdout = Pipe()
        proc.standardError = stderr
        proc.standardOutput = stdout

        // Drain stderr and stdout line-by-line into our logger so we
        // can see Caddy's startup errors, reload messages, and
        // request logs in `log show` alongside the helper's own
        // output. Without this, the pipe fills up and Caddy blocks.
        Self.drainPipe(stderr, label: "caddy/stderr", log: log)
        Self.drainPipe(stdout, label: "caddy/stdout", log: log)

        // Capture a weak reference into the termination handler so
        // unexpected exits can trigger the supervisor restart path.
        // The handler fires on a background queue, so we hop back
        // onto the actor to mutate state safely.
        proc.terminationHandler = { [weak self, log] terminated in
            log.error("caddy process exited status=\(terminated.terminationStatus, privacy: .public) reason=\(String(describing: terminated.terminationReason), privacy: .public)")
            guard let self else { return }
            Task { await self.handleChildExit(status: terminated.terminationStatus) }
        }

        do {
            try proc.run()
        } catch {
            throw CaddyError.spawnFailed(error.localizedDescription)
        }

        self.process = proc
        self.stderrPipe = stderr
        self.bootTime = Date()
        log.info("caddy started pid=\(proc.processIdentifier, privacy: .public)")

        // Wait for the admin API to become reachable. Caddy starts
        // listening on its admin port within a few hundred ms after
        // spawn; we poll for up to 5 s before giving up.
        try await waitForAdminAPI()

        // Successful start — reset the supervisor's failure counter
        // so an unrelated future crash gets a fresh budget.
        self.restartAttempts = 0
    }

    /// Termination handler — distinguishes between intentional stop
    /// (isStopping == true) and unexpected crashes. Unexpected crashes
    /// trigger an exponential-backoff restart using the last-known
    /// routes, up to maxRestartAttempts. Runs on the actor because it
    /// touches state.
    private func handleChildExit(status: Int32) async {
        self.process = nil
        self.stderrPipe = nil
        self.bootTime = nil

        if isStopping {
            log.info("caddy exit was expected (stopping); no restart")
            isStopping = false
            return
        }

        // Unexpected exit. Attempt a restart if we haven't blown
        // through the attempt budget.
        guard restartAttempts < Self.maxRestartAttempts else {
            log.fault("caddy crashed \(self.restartAttempts, privacy: .public) times in a row; giving up. User must restart a tunnel to retry.")
            restartAttempts = 0
            return
        }

        let attempt = restartAttempts
        restartAttempts += 1
        let delaySec = Self.restartBackoffSeconds[min(attempt, Self.restartBackoffSeconds.count - 1)]
        log.error("caddy crashed (attempt \(attempt + 1, privacy: .public)/\(Self.maxRestartAttempts, privacy: .public)); restarting in \(delaySec, privacy: .public)s")

        try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)

        // Routes might have been cleared by a removeRoute in the
        // meantime. Don't restart if there's nothing to serve.
        guard !lastRoutes.isEmpty else {
            log.info("caddy supervisor: no routes remaining, not restarting")
            return
        }

        do {
            try await start(routes: lastRoutes)
            log.info("caddy supervisor: restart succeeded")
        } catch {
            log.error("caddy supervisor: restart failed: \(error.localizedDescription, privacy: .public)")
            // handleChildExit will fire again from the next termination;
            // the loop continues until we hit maxRestartAttempts.
        }
    }

    /// Reload Caddy's config in place. Writes a new JSON config to the
    /// same path and tells Caddy to re-read it via the admin API. This
    /// is graceful — existing connections are not dropped, the listener
    /// stays up the whole time.
    public func reload(routes: [ProxyRoute]) async throws {
        try writeConfig(routes: routes)
        guard isRunning else {
            // Caddy isn't running yet. Cold-start it instead of trying
            // to hit a non-existent admin API.
            try await start(routes: routes)
            return
        }
        try await postReload()
        log.info("caddy reloaded with \(routes.count, privacy: .public) route(s)")
    }

    /// Stop Caddy gracefully. SIGTERMs the child process and waits for
    /// it to exit. Marks `isStopping` so the termination handler knows
    /// the exit was intentional and skips the auto-restart path.
    /// Safe to call multiple times.
    public func stop() async {
        self.isStopping = true
        self.lastRoutes = []
        self.restartAttempts = 0

        guard let proc = process, proc.isRunning else {
            self.process = nil
            self.bootTime = nil
            return
        }
        log.info("Stopping caddy pid=\(proc.processIdentifier, privacy: .public)")
        proc.terminate()
        // Block until exit. terminationHandler will fire concurrently.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                cont.resume()
            }
        }
        self.process = nil
        self.stderrPipe = nil
        self.bootTime = nil
    }

    // MARK: - Internals

    private func locateBinary() throws -> String {
        let fm = FileManager.default
        for path in binarySearchPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        throw CaddyError.binaryNotFound(binarySearchPaths)
    }

    /// Attach a line-buffered reader to a pipe and forward every line
    /// to the unified log with the given label. Runs on a background
    /// DispatchQueue because FileHandle.readabilityHandler fires on
    /// whatever queue Foundation chooses, which is fine for logging
    /// but shouldn't touch our actor state.
    private static func drainPipe(_ pipe: Pipe, label: String, log: Logger) {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
                    log.info("[\(label, privacy: .public)] \(tail, privacy: .public)")
                }
                return
            }
            buffer.append(chunk)
            while let newlineIdx = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: 0..<newlineIdx)
                buffer.removeSubrange(0...newlineIdx)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    log.info("[\(label, privacy: .public)] \(line, privacy: .public)")
                }
            }
        }
    }

    private func writeConfig(routes: [ProxyRoute]) throws {
        let data: Data
        do {
            data = try CaddyfileBuilder.build(
                routes: routes,
                leavesDirectory: leavesDirectory
            )
        } catch {
            throw CaddyError.configEncodeFailed(error.localizedDescription)
        }
        // Ensure parent dir exists.
        try FileManager.default.createDirectory(
            at: configPath.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
        try data.write(to: configPath, options: .atomic)
    }

    private func waitForAdminAPI() async throws {
        let deadline = Date().addingTimeInterval(5)
        var lastError: String = "no attempts made"
        while Date() < deadline {
            do {
                _ = try await getAdminConfig()
                return
            } catch {
                lastError = error.localizedDescription
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
        throw CaddyError.adminAPIUnreachable(lastError)
    }

    private func getAdminConfig() async throws -> Data {
        let url = URL(string: "http://\(CaddyfileBuilder.adminListen)/config/")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CaddyError.adminAPIUnreachable("non-200 from /config/")
        }
        return data
    }

    private func postReload() async throws {
        let url = URL(string: "http://\(CaddyfileBuilder.adminListen)/load")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try Data(contentsOf: configPath)
        let (data, response) = try await URLSession.shared.upload(for: request, from: request.httpBody ?? Data())
        guard let http = response as? HTTPURLResponse else {
            throw CaddyError.reloadFailed(0, "no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw CaddyError.reloadFailed(http.statusCode, body)
        }
    }
}
