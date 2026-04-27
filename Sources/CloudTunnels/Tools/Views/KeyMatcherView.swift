import AppKit
import SwiftUI

/// Certificate / Key Matcher — paste a cert PEM and a private key
/// PEM, verify they belong to the same keypair. Real use case:
/// during cert rotation, when importing from another system, or
/// when triaging "does this key actually unlock this cert"
/// questions during an incident.
struct KeyMatcherView: View {
    @State private var certPEM: String = ""
    @State private var keyPEM: String = ""
    @State private var result: KeyMatcher.MatchResult?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                certInput
                keyInput
                Divider().opacity(0.4)
                actions
                resultSection
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var certInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CERTIFICATE PEM")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            TextEditor(text: $certPEM)
                .font(.system(size: 10, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
    }

    private var keyInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PRIVATE KEY PEM")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            TextEditor(text: $keyPEM)
                .font(.system(size: 10, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Text("Supports PKCS#8 (`PRIVATE KEY`), SEC1 EC (`EC PRIVATE KEY`), and PKCS#1 RSA (`RSA PRIVATE KEY`).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                runCheck()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                    Text("Check match")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(certPEM.isEmpty || keyPEM.isEmpty)

            Button("Clear") {
                certPEM = ""
                keyPEM = ""
                result = nil
                errorMessage = nil
            }
            .disabled(certPEM.isEmpty && keyPEM.isEmpty)

            Spacer()
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let r = result {
            switch r {
            case .match(let algorithm):
                banner(
                    symbol: "checkmark.seal.fill",
                    color: .green,
                    title: "Match",
                    body: "Certificate and private key belong to the same \(algorithm) keypair."
                )
            case .mismatch(let certKey, let privateKey):
                banner(
                    symbol: "xmark.octagon.fill",
                    color: .red,
                    title: "Mismatch",
                    body: "Certificate uses \(certKey); private key is \(privateKey). These do not belong to the same keypair."
                )
            }
        } else if let err = errorMessage {
            Text(err)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func banner(symbol: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(body)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.10))
        )
    }

    // MARK: - Actions

    private func runCheck() {
        do {
            result = try KeyMatcher.check(certPEM: certPEM, keyPEM: keyPEM)
            errorMessage = nil
        } catch {
            result = nil
            errorMessage = error.localizedDescription
        }
    }
}
