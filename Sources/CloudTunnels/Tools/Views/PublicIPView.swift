import AppKit
import SwiftUI

struct PublicIPView: View {
    @State private var info: PublicIPInfo?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView()
                    .controlSize(.small)
            } else if let info {
                Text(info.ip)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                if let asn = info.asn { metaRow("ASN", asn) }
                if let org = info.org { metaRow("ORG", org) }
                if let country = info.country { metaRow("COUNTRY", country) }
            } else if let error {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Click Refresh to fetch your public IP")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("Refresh") { Task { await refresh() } }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info?.ip ?? "", forType: .string)
                }
                .disabled(info == nil)
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .task { await refresh() }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).textSelection(.enabled)
        }
    }

    private func refresh() async {
        loading = true
        error = nil
        do {
            info = try await PublicIP.fetch()
        } catch {
            self.error = error.localizedDescription
            self.info = nil
        }
        loading = false
    }
}
