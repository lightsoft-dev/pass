import MarkdownUI
import SwiftUI

/// Full Markdown rendering for Pa and readable worker conversations.
struct AgentMarkdownView: View {
    let source: String
    var fontSize: CGFloat = 13
    var projectRoot: String? = nil

    private var projectURL: URL? {
        projectRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Markdown(source, baseURL: projectURL, imageBaseURL: projectURL)
                .markdownTheme(.basic)
                .markdownImageProvider(AgentImageProvider())
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

            ForEach(Array(AgentMessageMedia.bareLocalImages(in: source, relativeTo: projectURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(4)), id: \.path) { url in
                AgentLocalImageView(url: url)
            }
            ForEach(Array(AgentMessageMedia.bareWebImages(in: source).prefix(3)),
                    id: \.absoluteString) { url in
                AgentRemoteImageView(url: url)
            }
            ForEach(Array(AgentMessageMedia.webLinks(in: source).prefix(3)),
                    id: \.absoluteString) { url in
                AgentWebLinkCard(url: url)
            }
        }
    }
}
