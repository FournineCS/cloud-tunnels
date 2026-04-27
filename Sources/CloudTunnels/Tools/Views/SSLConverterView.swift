import AppKit
import SwiftUI

/// SSL Converter — convert a single cert/key between PEM and DER
/// encodings. PEM ↔ DER only; PKCS#12 (.p12) is intentionally out
/// of scope because it needs password-based encryption and is
/// better served by `openssl pkcs12 ...`.
struct SSLConverterView: View {
    @State private var mode: SSLConverter.Mode = .pemToDer
    @State private var pemLabel: SSLConverter.PEMLabel = .certificate
    @State private var input: String = ""
    @State private var output: String = ""
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                modeRow
                inputSection
                actions
                outputSection
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MODE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Picker("", selection: $mode) {
                ForEach(SSLConverter.Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _ in
                output = ""
                errorMessage = nil
            }

            if mode == .derToPem {
                Text("OUTPUT PEM LABEL")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Picker("", selection: $pemLabel) {
                    ForEach(SSLConverter.PEMLabel.allCases) { label in
                        Text(label.rawValue).tag(label)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mode == .pemToDer ? "PEM INPUT" : "DER INPUT (HEX OR BASE64)")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            TextEditor(text: $input)
                .font(.system(size: 10, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Text(mode == .pemToDer
                 ? "Paste a `-----BEGIN X-----` block. Any label (CERTIFICATE, PRIVATE KEY, etc.) is accepted."
                 : "Paste DER bytes as hex pairs (`30 82 ...` or `30:82:...`) or as base64.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                convert()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Convert")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(input.isEmpty)

            Button("Clear") {
                input = ""
                output = ""
                errorMessage = nil
            }
            .disabled(input.isEmpty && output.isEmpty)

            Spacer()

            if !output.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy output")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if let err = errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if !output.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("OUTPUT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(output)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 80, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
            }
        }
    }

    // MARK: - Actions

    private func convert() {
        errorMessage = nil
        output = ""
        do {
            switch mode {
            case .pemToDer:
                let der = try SSLConverter.pemToDer(input)
                // Present as hex for easy paste into openssl -in -inform DER
                output = SSLConverter.formatDerAsHex(der)
            case .derToPem:
                let der = try SSLConverter.parseDerInput(input)
                output = SSLConverter.derToPem(der, label: pemLabel)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
