import AppKit
import SwiftUI

struct TimestampConverterView: View {
    @State private var epochString: String = String(Int(Date().timeIntervalSince1970))
    @State private var iso: String = ""
    @State private var local: String = ""

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Now") { setFromDate(Date()) }
                .controlSize(.small)

            field(label: "UNIX EPOCH (seconds)", text: $epochString) { text in
                if let n = Int(text) {
                    setFromDate(Date(timeIntervalSince1970: TimeInterval(n)), updatingEpoch: false)
                }
            }
            field(label: "ISO 8601", text: $iso) { text in
                if let date = Self.isoFormatter.date(from: text) {
                    setFromDate(date, updatingISO: false)
                }
            }
            field(label: "LOCAL", text: $local) { text in
                if let date = Self.localFormatter.date(from: text) {
                    setFromDate(date, updatingLocal: false)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .onAppear { setFromDate(Date()) }
    }

    @ViewBuilder
    private func field(label: String, text: Binding<String>, onCommit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.wrappedValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            TextField("", text: text, onCommit: { onCommit(text.wrappedValue) })
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
        }
    }

    private func setFromDate(_ date: Date, updatingEpoch: Bool = true, updatingISO: Bool = true, updatingLocal: Bool = true) {
        if updatingEpoch { epochString = String(Int(date.timeIntervalSince1970)) }
        if updatingISO { iso = Self.isoFormatter.string(from: date) }
        if updatingLocal { local = Self.localFormatter.string(from: date) }
    }
}
