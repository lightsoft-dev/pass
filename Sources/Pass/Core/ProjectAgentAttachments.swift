import Foundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

enum ProjectAgentAttachments {
    static let maximumFiles = 8
    private static let maximumFileBytes = 25_000_000
    private static let maximumImageBytes = 12_000_000
    private static let marker = "\n\n<pass-attached-files>\n"

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        guard name.count > 37, UUID(uuidString: String(name.prefix(36))) != nil,
              name[name.index(name.startIndex, offsetBy: 36)] == "-" else { return name }
        return String(name.dropFirst(37))
    }

    static func copyFiles(_ urls: [URL], for projectRoot: String,
                          baseDirectory: URL? = nil) throws -> [URL] {
        guard urls.count <= maximumFiles else {
            throw AttachmentError.tooManyFiles
        }
        let support = baseDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Pass/Pa", isDirectory: true)
            .appendingPathComponent(ProjectAgentIdentity.sessionName(for: projectRoot), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied: [URL] = []
        do {
            for source in urls {
                guard source.isFileURL else { throw AttachmentError.notAFile }
                let didAccess = source.startAccessingSecurityScopedResource()
                defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
                guard (try source.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw AttachmentError.notAFile
                }
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maximumFileBytes else { throw AttachmentError.fileTooLarge }
                let destination = directory.appendingPathComponent(
                    UUID().uuidString + "-" + source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                copied.append(destination)
            }
            return copied
        } catch {
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    static func prompt(_ text: String, files: [URL]) -> String {
        let body = text.isEmpty ? "첨부 파일을 확인해 주세요." : text
        guard !files.isEmpty,
              let data = try? JSONEncoder().encode(files.map(\.path)),
              let paths = String(data: data, encoding: .utf8) else { return body }
        return body + marker + paths + "\n</pass-attached-files>"
    }

    static func displayContent(_ prompt: String) -> (text: String, files: [URL]) {
        guard let range = prompt.range(of: marker, options: .backwards),
              let end = prompt.range(of: "\n</pass-attached-files>", range: range.upperBound..<prompt.endIndex),
              let data = String(prompt[range.upperBound..<end.lowerBound]).data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return (prompt, [])
        }
        return (String(prompt[..<range.lowerBound]), paths.map { URL(fileURLWithPath: $0) })
    }

    static func imagePayloads(for files: [URL]) throws -> [[String: Any]] {
        var payloads: [[String: Any]] = []
        for url in files where isImage(url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                  ] as CFDictionary),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw AttachmentError.imageUnreadable }
            guard data.count <= maximumImageBytes else { throw AttachmentError.imageTooLarge }
            payloads.append(["type": "image", "data": data.base64EncodedString(),
                             "mimeType": "image/png"])
        }
        return payloads
    }

    enum AttachmentError: LocalizedError {
        case tooManyFiles, notAFile, fileTooLarge, imageUnreadable, imageTooLarge

        var errorDescription: String? {
            switch self {
            case .tooManyFiles: return "파일은 한 번에 8개까지 첨부할 수 있습니다."
            case .notAFile: return "선택한 항목은 파일이 아닙니다."
            case .fileTooLarge: return "25MB를 넘는 파일은 첨부할 수 없습니다."
            case .imageUnreadable: return "이미지를 읽을 수 없습니다."
            case .imageTooLarge: return "이미지 미리보기가 너무 큽니다. 더 작은 이미지를 선택해 주세요."
            }
        }
    }
}
