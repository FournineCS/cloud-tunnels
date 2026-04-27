import AppKit
import SwiftUI

/// K8s Secret Encoder/Decoder — small utility specialized for
/// the k8s Secret YAML format. Encodes plaintext to a
/// ready-to-paste Secret snippet; decodes a Secret YAML's
/// `data:` block back to (key, value) pairs.
struct K8sSecretCoderView: View {

    enum Mode: String, CaseIterable, Identifiable {
        case encode = "Encode"
        case decode = "Decode"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .encode

    // Encode state
    @State private var secretName: String = "my-secret"
    @State private var secretKey: String = "password"
    @State private var plaintext: String = ""
    @State private var encoded: String = ""

    // Decode state
    @State private var pastedYAML: String = ""
    @State private var decoded: [K8sSecretCoder.DecodedEntry]?
    @State private var decodeError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modePicker
                Divider().opacity(0.4)
                if mode == .encode {
                    encodeSection
                } else {
                    decodeSection
                }
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(Mode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Encode

    private var encodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SECRET NAME")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                TextField("my-secret", text: $secretName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: secretName) { _ in runEncode() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("DATA KEY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                TextField("password", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: secretKey) { _ in runEncode() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PLAINTEXT VALUE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                TextEditor(text: $plaintext)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .onChange(of: plaintext) { _ in runEncode() }
            }
            if !encoded.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SECRET YAML")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(encoded, forType: .string)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy YAML")
                            }
                        }
                        .controlSize(.small)
                        Button {
                            // Copy just the base64 for users who
                            // want to paste it into an existing
                            // secret's data: block rather than
                            // replacing the whole thing.
                            let base64 = Data(plaintext.utf8).base64EncodedString()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(base64, forType: .string)
                        } label: {
                            Text("Copy base64")
                        }
                        .controlSize(.small)
                    }
                    Text(encoded)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
            }
        }
        .onAppear { runEncode() }
    }

    // MARK: Decode

    private var decodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PASTE SECRET YAML")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            pastedYAML = s
                            runDecode()
                        }
                    }
                    .controlSize(.small)
                }
                TextEditor(text: $pastedYAML)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .onChange(of: pastedYAML) { _ in runDecode() }
                Text("Paste the output of `kubectl get secret <name> -o yaml`. stringData entries are ignored (they're not base64-encoded).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let entries = decoded {
                if entries.isEmpty {
                    Text("`data:` block is empty.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DECODED VALUES")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                        ForEach(entries) { entry in
                            decodedRow(entry)
                        }
                    }
                }
            } else if let err = decodeError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func decodedRow(_ entry: K8sSecretCoder.DecodedEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.key)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.value ?? entry.rawBase64, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy decoded value")
            }
            if let value = entry.value {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.05))
                    )
            } else {
                Text("(non-UTF8 data, \(entry.rawBase64.count) base64 chars)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func runEncode() {
        encoded = K8sSecretCoder.encodeAsSecretYAML(
            value: plaintext,
            name: secretName,
            key: secretKey
        )
    }

    private func runDecode() {
        guard !pastedYAML.isEmpty else {
            decoded = nil
            decodeError = nil
            return
        }
        if let result = K8sSecretCoder.decodeSecretYAML(pastedYAML) {
            decoded = result
            decodeError = nil
        } else {
            decoded = nil
            decodeError = "No `data:` block found. Paste a Secret YAML with a `data:` section."
        }
    }
}
