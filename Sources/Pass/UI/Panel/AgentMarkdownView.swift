import MarkdownUI
import SwiftUI

/// Full Markdown rendering for Pa and readable worker conversations.
struct AgentMarkdownView: View {
    let source: String
    var fontSize: CGFloat = 13

    var body: some View {
        Markdown(source)
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontFamily(.custom("Pretendard"))
                FontSize(fontSize)
            }
            .markdownTextStyle(\.code) {
                FontFamily(.system(.monospaced))
                FontSize(.em(0.92))
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamily(.system(.monospaced))
                            FontSize(11)
                        }
                        .padding(10)
                }
                .background(Color.primary.opacity(0.055),
                            in: RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: .zero, bottom: .em(0.7))
            }
            .textSelection(.enabled)
    }
}
