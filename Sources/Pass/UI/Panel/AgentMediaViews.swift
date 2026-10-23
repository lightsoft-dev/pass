import AppKit
import ImageIO
import LinkPresentation
import MarkdownUI
import SwiftUI

/// MarkdownUI's default provider loads network images only. Worker screenshots are local files.
struct AgentImageProvider: ImageProvider {
    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url, url.isFileURL {
            AgentLocalImageView(url: url)
        } else if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            AgentRemoteImageView(url: url)
        } else {
            Label("이미지를 열 수 없습니다", systemImage: "photo")
                .font(PassFont.ui(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

struct AgentLocalImageView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                Button { NSWorkspace.shared.open(url) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        AgentImagePreview(image: image)
                        Text(url.lastPathComponent)
                            .font(PassFont.ui(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("이미지 열기")
            } else if loaded {
                Label("이미지를 찾을 수 없습니다: \(url.lastPathComponent)", systemImage: "photo")
                    .font(PassFont.ui(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small).frame(height: 80)
            }
        }
        .task(id: url) {
            image = Self.thumbnail(for: url)
            loaded = true
        }
    }

    private static func thumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail,
                       size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}

struct AgentRemoteImageView: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                Button { NSWorkspace.shared.open(url) } label: {
                    image.resizable()
                        .scaledToFit()
                        .frame(maxWidth: 560, maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("웹 이미지 열기")
            case .failure:
                Link("이미지 열기", destination: url)
                    .font(PassFont.ui(size: 11))
            case .empty:
                ProgressView().controlSize(.small).frame(height: 80)
            @unknown default:
                EmptyView()
            }
        }
    }
}

struct AgentImageDataView: View {
    let data: Data

    var body: some View {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 1200
           ] as CFDictionary) {
            let image = NSImage(cgImage: thumbnail,
                                size: NSSize(width: thumbnail.width, height: thumbnail.height))
            AgentImagePreview(image: image)
                .accessibilityLabel("에이전트가 보낸 이미지")
        }
    }
}

struct AgentConversationContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AgentImagePreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 560, maxHeight: 380)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AgentWebLinkCard: View {
    let url: URL
    @State private var title: String?
    @State private var thumbnail: NSImage?

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "link")
                        .font(PassFont.ui(size: 17))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title ?? url.host ?? url.absoluteString)
                        .font(PassFont.ui(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(url.host ?? url.absoluteString)
                        .font(PassFont.ui(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(PassFont.ui(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(9)
            .frame(maxWidth: 540, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("웹 링크 열기: \(title ?? url.absoluteString)")
        .task(id: url) {
            let provider = LPMetadataProvider()
            provider.timeout = 6
            guard let metadata = try? await provider.startFetchingMetadata(for: url),
                  !Task.isCancelled else { return }
            title = metadata.title
            let imageProvider = metadata.imageProvider ?? metadata.iconProvider
            if let imageProvider, imageProvider.canLoadObject(ofClass: NSImage.self) {
                imageProvider.loadObject(ofClass: NSImage.self) { image, _ in
                    DispatchQueue.main.async { thumbnail = image as? NSImage }
                }
            }
        }
    }
}
