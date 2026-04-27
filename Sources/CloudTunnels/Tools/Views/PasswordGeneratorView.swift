import AppKit
import SwiftUI

/// Random password generator with copy + share-via-onetimesecret.
/// Wraps `PasswordGenerator` (pure helper) — the view holds no
/// generation logic, just the @State bindings + UI.
struct PasswordGeneratorView: View {
    @State private var options = PasswordGenerator.Options()
    @State private var current: String = ""
    @State private var errorMessage: String?

    @State private var shareTTL: OneTimeSecret.TTL = .oneHour
    @State private var sharing: Bool = false
    @State private var shareURL: URL?
    @State private var shareError: String?

    var body: some View {
        // Wrapped in a ScrollView so the share-result block can't
        // overflow the menu bar popover and overlap the footer menu
        // items. The fixed window width comes from MenuBarView.
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
            HStack {
                Text("PASSWORD")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entropyLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(entropyColor)
            }
            HStack(spacing: 6) {
                Text(current.isEmpty ? "(no charsets selected)" : current)
                    .font(.system(size: 14, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
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
                .help("Generate a new password")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(current, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .disabled(current.isEmpty)
                .help("Copy to clipboard")
            }
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LENGTH")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(options.length)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            Slider(
                value: Binding(
                    get: { Double(options.length) },
                    set: {
                        options.length = Int($0)
                        regenerate()
                    }
                ),
                in: Double(PasswordGenerator.minLength)...Double(PasswordGenerator.maxLength),
                step: 1
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("CHARACTERS")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                charsetToggle("Lowercase a-z", $options.lowercase)
                charsetToggle("Uppercase A-Z", $options.uppercase)
                charsetToggle("Digits 0-9", $options.digits)
                charsetToggle("Symbols !@#%^&*…", $options.symbols)
                charsetToggle("Exclude ambiguous (0/O/l/1/I/|)", $options.excludeAmbiguous)
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
                    sharePassword()
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

    private func charsetToggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; regenerate() }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    private var entropyLabel: String {
        let bits = PasswordGenerator.entropyBits(options)
        return String(format: "≈ %.0f bits", bits)
    }

    private var entropyColor: Color {
        let bits = PasswordGenerator.entropyBits(options)
        if bits >= 100 { return .green }
        if bits >= 60 { return .blue }
        if bits >= 40 { return .orange }
        return .red
    }

    private func regenerate() {
        do {
            current = try PasswordGenerator.generate(options)
            errorMessage = nil
        } catch {
            current = ""
            errorMessage = error.localizedDescription
        }
        // Reset the share URL whenever the password changes — the
        // old URL would point to the old secret and be misleading.
        shareURL = nil
        shareError = nil
    }

    private func sharePassword() {
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
