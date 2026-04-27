import AppKit
import SwiftUI

/// Standalone "share an arbitrary secret via onetimesecret.com" tool.
/// Useful when the user has a secret from elsewhere (a config file,
/// an API key from a console, a credential from a password manager)
/// that they need to hand off to someone over a chat channel they
/// don't fully trust.
struct OneTimeSecretView: View {
    @State private var secret: String = ""
    @State private var ttl: OneTimeSecret.TTL = .oneHour
    @State private var sharing: Bool = false
    @State private var shareURL: URL?
    @State private var shareError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                input
                controls
                Divider().opacity(0.4)
                shareButton
                result
            }
            .padding(14)
        }
    }

    // MARK: - Sections

    private var input: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SECRET")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            TextEditor(text: $secret)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            Text("Anything pasted here is sent to onetimesecret.com over HTTPS. The recipient can view it exactly once before the link self-destructs.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack {
            Text("Expires after")
                .font(.system(size: 11))
            Picker("", selection: $ttl) {
                ForEach(OneTimeSecret.TTL.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            Spacer()
        }
    }

    private var shareButton: some View {
        Button {
            createShareLink()
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
        .disabled(secret.isEmpty || sharing)
    }

    @ViewBuilder
    private var result: some View {
        if let url = shareURL {
            VStack(alignment: .leading, spacing: 6) {
                Text("SHARE LINK")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
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
                    .help("Copy share URL")
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open in browser")
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.10))
                )
                Text("This link can be viewed once. After that it self-destructs and the secret is gone forever.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        if let err = shareError {
            Text(err)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func createShareLink() {
        guard !secret.isEmpty else { return }
        sharing = true
        shareError = nil
        shareURL = nil
        let secretCopy = secret
        let ttlCopy = ttl
        Task {
            do {
                let url = try await OneTimeSecret.share(secretCopy, ttl: ttlCopy)
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
