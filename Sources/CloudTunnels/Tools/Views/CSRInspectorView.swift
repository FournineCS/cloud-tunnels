import AppKit
import SwiftUI

/// CSR Inspector — paste a PEM Certificate Signing Request and see
/// its subject, requested SANs, and public key. Parallel to the
/// TLS Certificate Inspector but for the request side of the
/// issuing flow.
struct CSRInspectorView: View {
    @State private var pem: String = ""
    @State private var inspected: CSRInspector.Inspected?
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
                Text("PEM CSR")
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
            Text("Paste a `-----BEGIN CERTIFICATE REQUEST-----` block. Useful for sanity-checking a CSR before submitting it to a CA.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var output: some View {
        if let i = inspected {
            VStack(alignment: .leading, spacing: 8) {
                FieldRow(label: "Subject CN", value: i.subjectCN ?? "(none)")
                FieldRow(label: "Subject", value: i.subjectFull, monospace: true)
                FieldRow(label: "Public Key", value: i.publicKeyAlgorithm)
                if !i.sanDNS.isEmpty {
                    FieldRow(label: "Requested SAN (DNS)", value: i.sanDNS.joined(separator: ", "), monospace: true)
                }
                if !i.sanIP.isEmpty {
                    FieldRow(label: "Requested SAN (IP)", value: i.sanIP.joined(separator: ", "), monospace: true)
                }
                FieldRow(label: "SHA-256", value: i.sha256Fingerprint, monospace: true)
            }
        } else if let err = errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Paste a PEM CSR above to inspect it")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Actions

    private func inspect() {
        guard !pem.isEmpty else {
            inspected = nil
            errorMessage = nil
            return
        }
        do {
            inspected = try CSRInspector.inspect(pem: pem)
            errorMessage = nil
        } catch {
            inspected = nil
            errorMessage = error.localizedDescription
        }
    }
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
