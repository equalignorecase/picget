import Foundation
import CoreGraphics

enum ContentMode: String, Codable, CaseIterable { case fit, fill, crop, stretch }
enum PlaybackMode: String, Codable, CaseIterable { case original, capped, visible, paused, firstFrame }
enum PowerMode: String, CaseIterable { case off, on, system }

struct Widget: Codable, Identifiable {
    var id = UUID()
    var asset: UUID
    var name: String
    var frame = CGRect(x: 80, y: 80, width: 260, height: 200)
    var display: String?
    var relativeOrigin: CGPoint?
    var opacity = 1.0
    var radius = 0.0
    var mode = ContentMode.fit
    var zoom = 1.0
    var cropX = 0.0
    var cropY = 0.0
    var locked = false
    var clickThrough = false
    var aspectLocked = false
    var visible = true
    var playback = PlaybackMode.original
    var fps = 20.0
    var created = Date()
    var modified = Date()
    var remote: URL?

    static func resized(_ size: CGSize, to value: Double, alongWidth: Bool, locked: Bool, limit: CGSize) -> CGSize {
        guard value.isFinite, size.width > 0, size.height > 0 else { return size }
        let current = alongWidth ? size.width : size.height
        if locked {
            let maximum = min(limit.width / size.width, limit.height / size.height)
            let minimum = min(maximum, max(48 / size.width, 48 / size.height))
            let scale = min(maximum, max(minimum, value / current))
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
        var result = size
        if alongWidth { result.width = min(limit.width, max(48, value)) }
        else { result.height = min(limit.height, max(48, value)) }
        return result
    }

    static func maximumRadius(in size: CGSize) -> Double {
        max(0, min(size.width, size.height) / 2)
    }

    func effectiveRadius(in size: CGSize) -> Double {
        min(radius, Self.maximumRadius(in: size))
    }

    mutating func validate() {
        if ![frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite) {
            frame = CGRect(x: 80, y: 80, width: 260, height: 200)
        }
        frame.size.width = min(8192, max(48, frame.width))
        frame.size.height = min(8192, max(48, frame.height))
        opacity = min(1, max(0, opacity))
        radius = radius.isFinite ? min(4096, max(0, radius)) : 0
        zoom = min(4, max(1, zoom))
        cropX = min(1, max(-1, cropX))
        cropY = min(1, max(-1, cropY))
        fps = min(60, max(1, fps))
    }
}

struct Asset: Codable, Sendable {
    let id: UUID
    let format: String
    let hash: String
    let width: Int
    let height: Int
    let ends: [Double]
    let loops: Int

    var animated: Bool { ends.count > 1 }
    var filename: String { "\(id.uuidString).\(["png", "jpg", "gif"].contains(format) ? format : "invalid")" }
}

struct Configuration: Codable {
    var version = 1
    var widgets: [Widget] = []
    var assets: [UUID: Asset] = [:]
}

enum PicgetError: LocalizedError {
    case invalidURL, invalidImage, tooLarge, response, busy, configuration
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTPS image URL without embedded credentials."
        case .invalidImage: "This file is damaged or uses an unsupported image format."
        case .tooLarge: "This image exceeds Picget’s size or frame limits."
        case .response: "The server did not return a complete image."
        case .busy: "An import is already in progress."
        case .configuration: "Widget settings could not be read."
        }
    }
}

enum Playback {
    static func frame(at elapsed: Double, ends: [Double], loops: Int) -> Int? {
        guard let duration = ends.last, duration > 0 else { return nil }
        if loops > 0, elapsed >= duration * Double(loops) { return nil }
        let position = elapsed.truncatingRemainder(dividingBy: duration)
        return ends.firstIndex { $0 > position } ?? 0
    }
}
