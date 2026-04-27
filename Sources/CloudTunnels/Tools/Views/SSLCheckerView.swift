import AppKit
import SwiftUI

/// SSL Checker — connect to `host[:port]`, capture the server cert,
/// and show the parsed fields using the same CertInspector summary
/// the Certificate Inspector tool renders. Useful for verifying what
/// a prod endpoint is actually serving without dropping to
/// `openssl s_client -connect host:443 </dev/null`.
struct SSLCheckerView: View {
    @State private var input: String = ""
    @State private var checking: Bool = false
    @State private var result: SSLChecker.CheckResult?
    @State private var errorMessage: String?
    @State private var detailsExpanded: Bool = false
    @State private var chainExpanded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inputRow
                Divider().opacity(0.4)
                resultSection
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOST[:PORT]")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("example.com  or  example.com:8443", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { runCheck() }
                Button {
                    runCheck()
                } label: {
                    HStack(spacing: 4) {
                        if checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "network.badge.shield.half.filled")
                        }
                        Text(checking ? "Checking…" : "Check")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.isEmpty || checking)
            }
            Text("Opens a TLS handshake to the host, captures the leaf certificate, and cancels before any HTTP request is sent.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let r = result {
            VStack(alignment: .leading, spacing: 8) {
                expiryBanner(r.leaf)
                pemActionRow(r.leaf)
                FieldRow(label: "Host", value: "\(r.hostname):\(r.port)", monospace: true)
                FieldRow(label: "Chain", value: "\(r.chainLength) certificate\(r.chainLength == 1 ? "" : "s")")
                FieldRow(label: "Subject CN", value: r.leaf.subjectCN ?? "(none)")
                FieldRow(label: "Issuer CN", value: r.leaf.issuerCN ?? "(none)")
                FieldRow(label: "Not Before", value: Self.dateFormatter.string(from: r.leaf.notValidBefore))
                FieldRow(label: "Not After", value: Self.dateFormatter.string(from: r.leaf.notValidAfter))
                FieldRow(label: "Public Key", value: r.leaf.publicKeyAlgorithm)
                FieldRow(label: "Serial", value: r.leaf.serialNumberHex, monospace: true)
                if !r.leaf.sanDNS.isEmpty {
                    FieldRow(label: "SAN (DNS)", value: r.leaf.sanDNS.joined(separator: ", "), monospace: true)
                }
                if !r.leaf.sanIP.isEmpty {
                    FieldRow(label: "SAN (IP)", value: r.leaf.sanIP.joined(separator: ", "), monospace: true)
                }
                FieldRow(label: "SHA-256", value: r.leaf.sha256Fingerprint, monospace: true)

                fullDetailsDisclosure(r.leaf)

                if r.chain.count > 1 {
                    fullChainDisclosure(r.chain)
                }
            }
        } else if let err = errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Enter a hostname to check its SSL certificate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// Row of buttons to copy / save the leaf cert's PEM. Sits
    /// right below the expiry banner so users don't have to scroll
    /// to find the "I just want the cert" action.
    @ViewBuilder
    private func pemActionRow(_ leaf: CertInspector.Inspected) -> some View {
        if let pem = leaf.pem {
            HStack(spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pem, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy PEM")
                    }
                }
                .controlSize(.small)
                Button {
                    savePEM(pem, suggestedName: suggestedFilename(leaf))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("Save PEM…")
                    }
                }
                .controlSize(.small)
                Spacer()
            }
        }
    }

    /// Expandable block with every detail the CertInspector
    /// extracted — KeyUsage, ExtendedKeyUsage, BasicConstraints,
    /// the raw PEM, and the full Subject/Issuer DNs (not just CN).
    @ViewBuilder
    private func fullDetailsDisclosure(_ leaf: CertInspector.Inspected) -> some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                FieldRow(label: "Subject", value: leaf.subjectFull, monospace: true)
                FieldRow(label: "Issuer", value: leaf.issuerFull, monospace: true)
                FieldRow(label: "Signature", value: leaf.signatureAlgorithm)
                if let bc = leaf.basicConstraints {
                    FieldRow(label: "Basic Constraints", value: bc)
                }
                if !leaf.keyUsages.isEmpty {
                    FieldRow(label: "Key Usage", value: leaf.keyUsages.joined(separator: ", "))
                }
                if !leaf.extendedKeyUsages.isEmpty {
                    FieldRow(label: "Extended Key Usage", value: leaf.extendedKeyUsages.joined(separator: ", "))
                }
                if let pem = leaf.pem {
                    pemBlock(pem)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Full certificate details")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
    }

    /// Expandable block listing every intermediate/root cert the
    /// server sent. Each entry gets its own Copy PEM / Save PEM
    /// buttons so users can grab a specific intermediate without
    /// having to diff the bundle.
    @ViewBuilder
    private func fullChainDisclosure(_ chain: [CertInspector.Inspected]) -> some View {
        DisclosureGroup(isExpanded: $chainExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(chain.enumerated()), id: \.offset) { idx, cert in
                    chainEntry(index: idx, cert: cert, total: chain.count)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Full chain (\(chain.count))")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
    }

    private func chainEntry(
        index: Int,
        cert: CertInspector.Inspected,
        total: Int
    ) -> some View {
        let role: String
        if index == 0 {
            role = "Leaf"
        } else if index == total - 1 {
            role = "Root"
        } else {
            role = "Intermediate \(index)"
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("[\(index)] \(role)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(cert.subjectCN ?? cert.subjectFull)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let pem = cert.pem {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pem, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy PEM")
                    Button {
                        savePEM(pem, suggestedName: suggestedFilename(cert))
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Save PEM…")
                }
            }
            Text("Issuer: \(cert.issuerCN ?? cert.issuerFull)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Expires \(Self.dateFormatter.string(from: cert.notValidAfter))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func pemBlock(_ pem: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PEM")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(pem)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }

    private func expiryBanner(_ i: CertInspector.Inspected) -> some View {
        let symbol: String
        let color: Color
        let message: String
        if i.isExpired {
            symbol = "xmark.octagon.fill"
            color = .red
            message = "Expired \(abs(i.daysUntilExpiry)) days ago"
        } else if i.daysUntilExpiry <= 30 {
            symbol = "exclamationmark.triangle.fill"
            color = .orange
            message = "Expires in \(i.daysUntilExpiry) days"
        } else {
            symbol = "checkmark.seal.fill"
            color = .green
            message = "Valid for \(i.daysUntilExpiry) more days"
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.10))
        )
    }

    // MARK: - Actions

    private func runCheck() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let (host, port) = Self.parseHostPort(raw)
        checking = true
        result = nil
        errorMessage = nil
        Task {
            do {
                let r = try await SSLChecker.check(hostname: host, port: port)
                await MainActor.run {
                    self.result = r
                    self.checking = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.checking = false
                }
            }
        }
    }

    /// Write the given PEM to disk via NSSavePanel. Runs on the
    /// main thread because NSSavePanel is main-thread only.
    private func savePEM(_ pem: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Certificate PEM"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? pem.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Build a sane default filename like `example.com.pem` from
    /// the cert's CN, falling back to "certificate.pem".
    private func suggestedFilename(_ cert: CertInspector.Inspected) -> String {
        let base = cert.subjectCN?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "*", with: "wildcard")
            .replacingOccurrences(of: "/", with: "_")
            ?? ""
        let clean = base.isEmpty ? "certificate" : base
        return "\(clean).pem"
    }

    /// Split "host:port" or plain "host" into (host, port).
    /// Default port is 443. Exposed for testing via internal access.
    static func parseHostPort(_ raw: String) -> (host: String, port: Int) {
        // Strip an accidental https:// prefix. URLs pasted from
        // browsers often carry it; users shouldn't have to clean up.
        var s = raw
        if s.hasPrefix("https://") { s = String(s.dropFirst("https://".count)) }
        if s.hasPrefix("http://") { s = String(s.dropFirst("http://".count)) }
        // Drop any path suffix.
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        // IPv6 literal: [::1]:8443
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let afterClose = s.index(after: close)
            if afterClose < s.endIndex, s[afterClose] == ":" {
                let portStr = s[s.index(after: afterClose)...]
                return (host, Int(portStr) ?? 443)
            }
            return (host, 443)
        }
        // Normal host[:port]
        if let colon = s.firstIndex(of: ":") {
            let host = String(s[..<colon])
            let portStr = s[s.index(after: colon)...]
            return (host, Int(portStr) ?? 443)
        }
        return (s, 443)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct FieldRow: View {
    let label: String
    let value: String
    var monospace: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy")
            }
            Text(value)
                .font(.system(size: monospace ? 10 : 11, design: monospace ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.04))
                )
        }
    }
}
