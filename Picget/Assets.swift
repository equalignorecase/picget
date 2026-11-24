import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

actor Assets {
    static let localLimit = 100 * 1024 * 1024
    static let remoteLimit = 25 * 1024 * 1024
    let directory: URL
    let staging: URL

    init(root: URL) {
        directory = root.appendingPathComponent("Assets", isDirectory: true)
        staging = root.appendingPathComponent("Temporary", isDirectory: true)
    }

    nonisolated static func remoteURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw PicgetError.invalidURL }
        return url
    }

    func importFile(_ url: URL, existing: [Asset]) throws -> Asset {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try store(existing: existing) { output in
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            var count = 0
            while let block = try input.read(upToCount: 128 * 1024), !block.isEmpty {
                try Task.checkCancellation()
                count += block.count
                guard count <= Self.localLimit else { throw PicgetError.tooLarge }
                try output.write(contentsOf: block)
            }
        }
    }

    func importRemote(_ url: URL, existing: [Asset],
                      progress: @Sendable (Double) async -> Void) async throws -> Asset {
        try prepare()
        let temp = staging.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = try createFile(temp)
        defer { try? output.close() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url else { throw PicgetError.response }
        _ = try Self.remoteURL(finalURL.absoluteString)
        let expected = response.expectedContentLength
        guard expected <= Self.remoteLimit else { throw PicgetError.tooLarge }
        var count = 0
        var block = Data()
        block.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            count += 1
            guard count <= Self.remoteLimit else { throw PicgetError.tooLarge }
            block.append(byte)
            if block.count == 64 * 1024 {
                try Task.checkCancellation()
                try output.write(contentsOf: block)
                block.removeAll(keepingCapacity: true)
                if expected > 0 { await progress(min(1, Double(count) / Double(expected))) }
            }
        }
        try Task.checkCancellation()
        guard expected <= 0 || count == expected else { throw PicgetError.response }
        try output.write(contentsOf: block)
        try output.close()
        return try commit(temp, existing: existing)
    }

    private func prepare() throws {
        for folder in [directory, staging] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    private func createFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }

    private func store(existing: [Asset], write: (FileHandle) throws -> Void) throws -> Asset {
        try prepare()
        let temp = staging.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = try createFile(temp)
        defer { try? output.close() }
        try write(output)
        try output.close()
        return try commit(temp, existing: existing)
    }

    private func commit(_ url: URL, existing: [Asset]) throws -> Asset {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while let block = try input.read(upToCount: 128 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            digest.update(data: block)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        if let match = existing.first(where: {
            $0.hash == hash && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
        }) { return match }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PicgetError.invalidImage }
        let format: String
        switch type as String {
        case UTType.png.identifier: format = "png"
        case UTType.jpeg.identifier: format = "jpg"
        case UTType.gif.identifier: format = "gif"
        default: throw PicgetError.invalidImage
        }
        let count = CGImageSourceGetCount(source)
        guard width <= 16384, height <= 16384,
              width <= (format == "gif" ? 4_000_000 : 64_000_000) / height,
              (1...2000).contains(count) else { throw PicgetError.tooLarge }
        var ends: [Double] = []
        var duration = 0.0
        for index in 0..<count {
            try Task.checkCancellation()
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                throw PicgetError.invalidImage
            }
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += delay.isFinite && delay >= 0.02 ? min(60, delay) : 0.1
            ends.append(duration)
        }
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = container?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let repeatCount = gif?[kCGImagePropertyGIFLoopCount] as? Int
        let loops = repeatCount.map { $0 == 0 ? 0 : min(65535, max(0, $0)) + 1 } ?? 1
        let asset = Asset(id: UUID(), format: format, hash: hash, width: width, height: height,
                          ends: ends, loops: loops)
        try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent(asset.filename))
        return asset
    }
}

private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, (try? Assets.remoteURL(url.absoluteString)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
