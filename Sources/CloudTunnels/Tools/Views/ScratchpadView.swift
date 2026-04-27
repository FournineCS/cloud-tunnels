import SwiftUI

struct ScratchpadView: View {
    @AppStorage("cloudtunnel.scratchpad") private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

            HStack {
                Text("\(text.count) chars · \(lineCount) lines · \(wordCount) words")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { text = "" }
                    .controlSize(.small)
                    .disabled(text.isEmpty)
            }
        }
        .padding(12)
    }

    private var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private var lineCount: Int {
        text.isEmpty ? 0 : text.split(whereSeparator: { $0.isNewline }).count
    }
}
