import AppKit
import SwiftUI

/// Cryptographic-secret generator for HMAC keys, JWT signing
/// secrets, TOTP shared secrets, etc. Pure logic lives in
/// `SecretGenerator`; the view is a thin shell + share-via-OTS.
struct SecretGeneratorView: View {
    @State private var byteLength: SecretGenerator.ByteLength = .thirtyTwo
    @State private var format: SecretGenerator.Format = .hex
    @State private var current: String = ""

    @State private var shareTTL: OneTimeSecret.TTL = .oneHour
    @State private var sharing: Bool = false
    @State private var shareURL: URL?
    @State private var shareError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                output
                Divider().opacity(0.4)
                controls
                Divider().opacity(0.4)
                shareSection
            }
            .padding(14)
        }
        .onAppear { regenerate() }
    }

    // MARK: - Sections

    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SECRET")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(current)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
                Button {
                    regenerate()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Generate a new secret")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(current, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Copy to clipboard")
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BYTE LENGTH")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Picker("", selection: $byteLength) {
                    ForEach(SecretGenerator.ByteLength.allCases) { len in
                        Text(len.displayName).tag(len)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: byteLength) { _ in regenerate() }
                Text(byteLength.hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FORMAT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Picker("", selection: $format) {
                    ForEach(SecretGenerator.Format.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: format) { _ in regenerate() }
                Text(format.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shareSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Expires after")
                        .font(.system(size: 11))
                    Picker("", selection: $shareTTL) {
                        ForEach(OneTimeSecret.TTL.allCases) { ttl in
                            Text(ttl.displayName).tag(ttl)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Button {
                    shareSecret()
                } label: {
                    HStack(spacing: 6) {
                        if sharing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "link.badge.plus")
                        }
                        Text(sharing ? "Creating link…" : "Create one-time share link")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(current.isEmpty || sharing)

                if let url = shareURL {
                    HStack(spacing: 6) {
                        Text(url.absoluteString)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.green.opacity(0.10))
                    )
                }
                if let err = shareError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Share via onetimesecret.com", systemImage: "link.badge.plus")
                .font(.system(size: 11, weight: .semibold))
        }
    }

    // MARK: - Helpers

    private func regenerate() {
        current = SecretGenerator.generate(byteLength: byteLength, format: format)
        shareURL = nil
        shareError = nil
    }

    private func shareSecret() {
        guard !current.isEmpty else { return }
        sharing = true
        shareError = nil
        shareURL = nil
        let secret = current
        let ttl = shareTTL
        Task {
            do {
                let url = try await OneTimeSecret.share(secret, ttl: ttl)
                await MainActor.run {
                    self.shareURL = url
                    self.sharing = false
                }
            } catch {
                await MainActor.run {
                    self.shareError = error.localizedDescription
                    self.sharing = false
                }
            }
        }
    }
}
