import AnkiMateLLM
import AnkiMateShared
import AppKit
import Foundation
import UniformTypeIdentifiers

enum AgentAttachmentImportLimits {
    static let maxAttachmentsPerMessage = 8
    static let maxImageBytes: Int64 = 10 * 1024 * 1024
    static let maxTextBytes: Int64 = 256 * 1024
}

enum AgentAttachmentImportError: LocalizedError {
    case tooManyAttachments(Int)
    case unsupportedFile(String)
    case fileTooLarge(String, Int64)
    case unreadableText(String)

    var errorDescription: String? {
        switch self {
        case .tooManyAttachments(let limit):
            return "You can attach up to \(limit) files per message."
        case .unsupportedFile(let name):
            return "\(name) is not a supported attachment. Use images, Markdown, or plain text files."
        case .fileTooLarge(let name, let limit):
            return "\(name) is too large. The limit is \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))."
        case .unreadableText(let name):
            return "\(name) could not be read as UTF-8 text."
        }
    }
}

final class AgentAttachmentFileStore: AgentAttachmentStoring, @unchecked Sendable {
    private let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = AgentAttachmentFileStore.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func importFiles(_ urls: [URL], sessionID: UUID, existingCount: Int) throws -> [AgentAttachment] {
        guard existingCount + urls.count <= AgentAttachmentImportLimits.maxAttachmentsPerMessage else {
            throw AgentAttachmentImportError.tooManyAttachments(AgentAttachmentImportLimits.maxAttachmentsPerMessage)
        }

        var imported: [AgentAttachment] = []
        do {
            for url in urls {
                imported.append(try importFile(url, sessionID: sessionID))
            }
            return imported
        } catch {
            try? delete(imported)
            throw error
        }
    }

    func importPastedImage(
        _ data: Data,
        sessionID: UUID,
        existingCount: Int,
        fileName: String = "pasted-image.png"
    ) throws -> AgentAttachment {
        guard existingCount + 1 <= AgentAttachmentImportLimits.maxAttachmentsPerMessage else {
            throw AgentAttachmentImportError.tooManyAttachments(AgentAttachmentImportLimits.maxAttachmentsPerMessage)
        }
        let byteSize = Int64(data.count)
        try validateSize(byteSize, kind: .image, fileName: fileName)

        let id = UUID()
        let sessionRelativeDirectory = sessionID.uuidString
        let copiedFileName = id.uuidString + ".png"
        let destinationDirectory = rootURL.appendingPathComponent(sessionRelativeDirectory, isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent(copiedFileName)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)

        let imageSize = NSImage(data: data)?.size
        return AgentAttachment(
            id: id,
            kind: .image,
            mimeType: "image/png",
            fileName: fileName,
            relativePath: sessionRelativeDirectory + "/" + copiedFileName,
            byteSize: byteSize,
            width: imageSize.map { Int($0.width) },
            height: imageSize.map { Int($0.height) }
        )
    }

    func data(for attachment: AgentAttachment) throws -> Data {
        try Data(contentsOf: url(for: attachment))
    }

    func delete(_ attachments: [AgentAttachment]) throws {
        for attachment in attachments {
            let fileURL = url(for: attachment)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    func deleteAllAttachments(for sessionID: UUID) throws {
        let directory = rootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func url(for attachment: AgentAttachment) -> URL {
        rootURL.appendingPathComponent(attachment.relativePath, isDirectory: false)
    }

    private func importFile(_ sourceURL: URL, sessionID: UUID) throws -> AgentAttachment {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let fileName = sourceURL.lastPathComponent
        let byteSize = Int64(values.fileSize ?? 0)
        let type = values.contentType ?? UTType(filenameExtension: sourceURL.pathExtension)
        let kind = try attachmentKind(for: sourceURL, type: type)
        try validateSize(byteSize, kind: kind, fileName: fileName)

        let id = UUID()
        let sessionRelativeDirectory = sessionID.uuidString
        let copiedFileName = id.uuidString + "." + sourceURL.pathExtension
        let destinationDirectory = rootURL.appendingPathComponent(sessionRelativeDirectory, isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent(copiedFileName)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let relativePath = sessionRelativeDirectory + "/" + copiedFileName
        let mimeType = mimeType(for: sourceURL, type: type, kind: kind)

        switch kind {
        case .image:
            let imageSize = NSImage(contentsOf: destinationURL)?.size
            return AgentAttachment(
                id: id,
                kind: .image,
                mimeType: mimeType,
                fileName: fileName,
                relativePath: relativePath,
                byteSize: byteSize,
                width: imageSize.map { Int($0.width) },
                height: imageSize.map { Int($0.height) }
            )
        case .textFile:
            let text = try textContent(at: destinationURL, fileName: fileName)
            return AgentAttachment(
                id: id,
                kind: .textFile,
                mimeType: mimeType,
                fileName: fileName,
                relativePath: relativePath,
                byteSize: byteSize,
                extractedTextPreview: Self.preview(from: text),
                characterCount: text.count
            )
        }
    }

    private func attachmentKind(for url: URL, type: UTType?) throws -> AgentAttachment.Kind {
        if type?.conforms(to: .image) == true {
            return .image
        }

        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "txt"].contains(ext) {
            return .textFile
        }

        throw AgentAttachmentImportError.unsupportedFile(url.lastPathComponent)
    }

    private func validateSize(_ byteSize: Int64, kind: AgentAttachment.Kind, fileName: String) throws {
        switch kind {
        case .image:
            guard byteSize <= AgentAttachmentImportLimits.maxImageBytes else {
                throw AgentAttachmentImportError.fileTooLarge(fileName, AgentAttachmentImportLimits.maxImageBytes)
            }
        case .textFile:
            guard byteSize <= AgentAttachmentImportLimits.maxTextBytes else {
                throw AgentAttachmentImportError.fileTooLarge(fileName, AgentAttachmentImportLimits.maxTextBytes)
            }
        }
    }

    private func textContent(at url: URL, fileName: String) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentAttachmentImportError.unreadableText(fileName)
        }
        return text
    }

    private func mimeType(for url: URL, type: UTType?, kind: AgentAttachment.Kind) -> String {
        if let mimeType = type?.preferredMIMEType {
            return mimeType
        }
        switch kind {
        case .image:
            return "image/\(url.pathExtension.lowercased())"
        case .textFile:
            return ["md", "markdown"].contains(url.pathExtension.lowercased()) ? "text/markdown" : "text/plain"
        }
    }

    private static func preview(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 180 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 180)
        return String(trimmed[..<end]) + "..."
    }

    private static func defaultRootURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent(AnkiMateIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("AgentAttachments", isDirectory: true)
    }
}
