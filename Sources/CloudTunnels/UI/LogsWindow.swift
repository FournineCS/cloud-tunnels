import AppKit
import Foundation
import SwiftUI

/// Live-tailing logs viewer for debugging tunnel failures, proxy
/// helper issues, and auth problems. Wraps `/usr/bin/log stream`
/// with a predicate scoped to our subsystems and parses its NDJSON
/// output into a ring buffer that the SwiftUI view observes.
///
/// Why shell out to `log stream` instead of using `OSLogStore`:
/// `OSLogStore` requires entitlements the sandboxed GUI app can't
/// carry (com.apple.private.logging.log-archive or similar) and
/// doesn't support live follow mode from user-space processes.
/// `log stream` is the Apple-sanctioned CLI path, ships in every
/// macOS, and has no entitlement requirement.
@MainActor
final class LogStreamer: ObservableObject {

    /// One parsed log line as it appears in the UI.
    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let subsystem: String
        let category: String
        let message: String

        enum Level: String {
            case debug = "Debug"
            case info = "Info"
            case `default` = "Default"
            case error = "Error"
            case fault = "Fault"

            var isError: Bool { self == .error || self == .fault }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case tunnels = "Tunnels"
        case proxy = "Proxy"
        case errors = "Errors only"
        var id: Self { self }
    }

    /// Ring buffer cap. ~2000 lines is several minutes of busy logs
    /// and fits comfortably in a List without janking the scroll.
    private static let maxLines = 2000

    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var isRunning = false
    @Published var filter: Filter = .all
    @Published private(set) var lastError: String?

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var accumulator = Data()

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        lastError = nil
        accumulator.removeAll(keepingCapacity: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--predicate",
            #"subsystem BEGINSWITH "com.fourninecloud.cloud-tunnels""#,
            "--style", "ndjson",
            "--level", "debug",
        ]

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            guard let self else { return }
            Task { @MainActor in
                self.ingest(chunk)
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                if terminated.terminationStatus != 0 {
                    self.lastError = "log stream exited with status \(terminated.terminationStatus)"
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.stdoutPipe = out
            self.stderrPipe = err
            self.isRunning = true
        } catch {
            lastError = "Failed to start log stream: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let proc = process else { return }
        proc.terminate()
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
    }

    // MARK: - Filtering

    var filteredLines: [LogLine] {
        switch filter {
        case .all: return lines
        case .errors: return lines.filter { $0.level.isError }
        case .tunnels:
            return lines.filter {
                let c = $0.category.lowercased()
                return c == "tunnel" || c == "manager" || c.contains("launcher")
            }
        case .proxy:
            return lines.filter { $0.subsystem.contains("proxy-helper") || $0.category.lowercased().contains("caddy") || $0.category.lowercased().contains("proxy") }
        }
    }

    /// Build a plain-text dump of the currently-visible log lines for
    /// copy-to-clipboard. Preserves order and includes timestamps.
    func plainTextDump() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return filteredLines.map { line in
            "\(fmt.string(from: line.timestamp)) [\(line.level.rawValue)] \(line.category): \(line.message)"
        }.joined(separator: "\n")
    }

    // MARK: - NDJSON ingestion

    /// Parses a buffer of bytes from `log stream` as newline-delimited
    /// JSON. Incomplete trailing lines are kept in `accumulator` for
    /// the next chunk.
    private func ingest(_ chunk: Data) {
        accumulator.append(chunk)
        while let newlineIdx = accumulator.firstIndex(of: 0x0a) {
            let lineData = accumulator.subdata(in: accumulator.startIndex..<newlineIdx)
            accumulator.removeSubrange(accumulator.startIndex...newlineIdx)
            if let line = parseLine(lineData) {
                append(line)
            }
        }
    }

    private func parseLine(_ data: Data) -> LogLine? {
        guard !data.isEmpty, data.first != 0x5B /* '[' array wrapper at stream start */ else { return nil }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let message = (obj["eventMessage"] as? String) ?? ""
            let subsystem = (obj["subsystem"] as? String) ?? ""
            let category = (obj["category"] as? String) ?? ""
            let typeRaw = (obj["messageType"] as? String) ?? "Default"
            let timestampString = (obj["timestamp"] as? String) ?? ""
            let timestamp = Self.parseTimestamp(timestampString) ?? Date()
            let level = LogLine.Level(rawValue: typeRaw) ?? .default
            // Skip the noisy system categories that leak in from the
            // framework layer — we only want our own logs.
            guard subsystem.hasPrefix("com.fourninecloud.cloud-tunnels") else { return nil }
            return LogLine(
                timestamp: timestamp,
                level: level,
                subsystem: subsystem,
                category: category,
                message: message
            )
        } catch {
            return nil
        }
    }

    private static let timestampFormatters: [DateFormatter] = {
        let f1 = DateFormatter()
        f1.locale = Locale(identifier: "en_US_POSIX")
        f1.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
        let f2 = DateFormatter()
        f2.locale = Locale(identifier: "en_US_POSIX")
        f2.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZZZZZ"
        return [f1, f2]
    }()

    private static func parseTimestamp(_ string: String) -> Date? {
        for f in timestampFormatters {
            if let d = f.date(from: string) { return d }
        }
        return nil
    }

    private func append(_ line: LogLine) {
        lines.append(line)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}

// MARK: - SwiftUI view

struct LogsWindowContent: View {
    @StateObject private var streamer = LogStreamer()
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            logList
            Divider().opacity(0.4)
            statusBar
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { streamer.start() }
        .onDisappear { streamer.stop() }
    }

    // MARK: - Sections

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $streamer.filter) {
                ForEach(LogStreamer.Filter.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            Button {
                streamer.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear the current log buffer (doesn't affect the system log)")

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(streamer.plainTextDump(), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy visible log lines to clipboard")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(streamer.filteredLines) { line in
                        LogRow(line: line)
                            .id(line.id)
                    }
                    // Sentinel used to auto-scroll to the tail
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: streamer.filteredLines.count) { _ in
                if autoScroll {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("tail", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(streamer.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(streamer.isRunning ? "Streaming" : "Stopped")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(streamer.filteredLines.count) / \(streamer.lines.count) lines")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            if let err = streamer.lastError {
                Text("·").foregroundStyle(.secondary)
                Text(err).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

// MARK: - Row

private struct LogRow: View {
    let line: LogStreamer.LogLine

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: line.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(levelSymbol)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 14, alignment: .leading)
            Text(line.category)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
                .truncationMode(.tail)
            Text(line.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.level.isError ? .red : .primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private var levelSymbol: String {
        switch line.level {
        case .debug: return "·"
        case .info: return "i"
        case .default: return "—"
        case .error: return "✗"
        case .fault: return "‼"
        }
    }

    private var levelColor: Color {
        switch line.level {
        case .debug: return .secondary
        case .info: return .secondary
        case .default: return .secondary
        case .error: return .red
        case .fault: return .red
        }
    }
}
