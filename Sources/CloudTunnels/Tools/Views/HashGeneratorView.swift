import AppKit
import CryptoKit
import SwiftUI

struct HashGeneratorView: View {
    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INPUT").font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
            ScrollView {
                TextEditor(text: $input)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 80)
            }
            .frame(maxHeight: 100)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 6) {
                HashRow(label: "MD5", value: md5)
                HashRow(label: "SHA-1", value: sha1)
                HashRow(label: "SHA-256", value: sha256)
                HashRow(label: "SHA-512", value: sha512)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var data: Data { Data(input.utf8) }
    private var md5: String { Insecure.MD5.hash(data: data).hex }
    private var sha1: String { Insecure.SHA1.hash(data: data).hex }
    private var sha256: String { SHA256.hash(data: data).hex }
    private var sha512: String { SHA512.hash(data: data).hex }
}

private struct HashRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
        }
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
