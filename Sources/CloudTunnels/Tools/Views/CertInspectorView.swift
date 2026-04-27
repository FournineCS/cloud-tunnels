import AppKit
import SwiftUI

/// Decodes a PEM-encoded X.509 certificate and shows the parsed
/// fields in a flat read-only inspector. Pure logic lives in
/// `CertInspector`. Useful for debugging the Caddy + LocalCA proxy
/// (paste a leaf cert from
/// /Library/Application Support/CloudTunnels/proxy/leaves/<host>.pem
/// and verify the SANs match the expected hostname).
struct CertInspectorView: View {
    @State private var pem: String = ""
    @State private var inspected: CertInspector.Inspected?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                input
                Divider().opacity(0.4)
                output
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PEM CERTIFICATE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        pem = s
                        inspect()
                    }
                }
                .controlSize(.small)
                Button("Clear") {
                    pem = ""
                    inspected = nil
                    errorMessage = nil
                }
                .controlSize(.small)
                .disabled(pem.isEmpty)
            }
            TextEditor(text: $pem)
                .font(.system(size: 10, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .onChange(of: pem) { _ in inspect() }
            Text("Paste a `-----BEGIN CERTIFICATE-----` block. The first cert in the input is decoded; subsequent chain entries are ignored.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var output: some View {
        if let i = inspected {
            VStack(alignment: .leading, spacing: 8) {
                expiryBanner(i)
                FieldRow(label: "Subject CN", value: i.subjectCN ?? "(none)")
                FieldRow(label: "Subject", value: i.subjectFull, monospace: true)
                FieldRow(label: "Issuer CN", value: i.issuerCN ?? "(none)")
                FieldRow(label: "Issuer", value: i.issuerFull, monospace: true)
                FieldRow(label: "Not Before", value: Self.dateFormatter.string(from: i.notValidBefore))
                FieldRow(label: "Not After", value: Self.dateFormatter.string(from: i.notValidAfter))
                FieldRow(label: "Serial", value: i.serialNumberHex, monospace: true)
                FieldRow(label: "Public Key", value: i.publicKeyAlgorithm)
                FieldRow(label: "Signature Alg", value: i.signatureAlgorithm)
                if !i.sanDNS.isEmpty {
                    FieldRow(label: "SAN (DNS)", value: i.sanDNS.joined(separator: ", "), monospace: true)
                }
                if !i.sanIP.isEmpty {
                    FieldRow(label: "SAN (IP)", value: i.sanIP.joined(separator: ", "), monospace: true)
                }
                FieldRow(
                    label: "SHA-256",
                    value: i.sha256Fingerprint,
                    monospace: true
                )
            }
        } else if let err = errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "lock.doc")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Paste a PEM certificate above to inspect it")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
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

    private func inspect() {
        guard !pem.isEmpty else {
            inspected = nil
            errorMessage = nil
            return
        }
        do {
            inspected = try CertInspector.inspect(pem: pem)
            errorMessage = nil
        } catch {
            inspected = nil
            errorMessage = error.localizedDescription
        }
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
