import AppKit
import SwiftUI

struct UUIDGeneratorView: View {
    @State private var uuids: [String] = [UUID().uuidString.lowercased()]
    @State private var count: Int = 1
    @State private var uppercase: Bool = false
    @State private var hyphens: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Stepper("Count: \(count)", value: $count, in: 1...50)
                    .controlSize(.small)
                Toggle("Uppercase", isOn: $uppercase).controlSize(.small).toggleStyle(.checkbox)
                Toggle("Hyphens", isOn: $hyphens).controlSize(.small).toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                Button("Generate") { regenerate() }
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(uuids.joined(separator: "\n"), forType: .string)
                }
                .disabled(uuids.isEmpty)
                Spacer()
            }
            .controlSize(.small)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(uuids, id: \.self) { uuid in
                        HStack {
                            Text(formatted(uuid))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(formatted(uuid), forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .onChange(of: count) { _ in regenerate() }
    }

    private func regenerate() {
        uuids = (0..<count).map { _ in UUID().uuidString.lowercased() }
    }

    private func formatted(_ uuid: String) -> String {
        var s = uuid
        if !hyphens { s = s.replacingOccurrences(of: "-", with: "") }
        return uppercase ? s.uppercased() : s
    }
}
