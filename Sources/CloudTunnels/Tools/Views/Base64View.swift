import AppKit
import SwiftUI

struct Base64View: View {
    @State private var plain: String = ""
    @State private var encoded: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PLAIN").font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
            ScrollView {
                TextEditor(text: $plain)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 80)
            }
            .frame(maxHeight: 100)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

            HStack(spacing: 6) {
                Button("Encode ↓") {
                    encoded = Data(plain.utf8).base64EncodedString()
                }
                Button("Decode ↑") {
                    if let data = Data(base64Encoded: encoded), let s = String(data: data, encoding: .utf8) {
                        plain = s
                    } else {
                        plain = "(invalid base64)"
                    }
                }
                Spacer()
                Button("Copy plain") {
                    copy(plain)
                }
                .disabled(plain.isEmpty)
                Button("Copy base64") {
                    copy(encoded)
                }
                .disabled(encoded.isEmpty)
            }
            .controlSize(.small)

            Text("BASE64").font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
            ScrollView {
                TextEditor(text: $encoded)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 80)
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .padding(12)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
