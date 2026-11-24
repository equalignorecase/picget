import Foundation
import CoreGraphics

struct ResizeEdge: OptionSet {
    let rawValue: Int
    static let left   = ResizeEdge(rawValue: 1 << 0)
    static let right  = ResizeEdge(rawValue: 1 << 1)
    static let top    = ResizeEdge(rawValue: 1 << 2)
    static let bottom = ResizeEdge(rawValue: 1 << 3)

    static let topLeft: ResizeEdge = [.top, .left]
    static let topRight: ResizeEdge = [.top, .right]
    static let bottomLeft: ResizeEdge = [.bottom, .left]
    static let bottomRight: ResizeEdge = [.bottom, .right]

    var isCorner: Bool {
        (contains(.left) || contains(.right)) && (contains(.top) || contains(.bottom))
    }
}

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
    var radius = 22.0
    var mode = ContentMode.fill
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

    static func draggedFrame(from anchor: CGRect, delta: CGPoint, edges: ResizeEdge, freeCorner: Bool = false) -> CGRect {
        guard !edges.isEmpty else {
            return anchor.offsetBy(dx: delta.x, dy: delta.y)
        }
        let minimum = 48.0
        var frame = anchor
        if !edges.isCorner || freeCorner {
            if edges.contains(.right) {
                frame.size.width = max(minimum, anchor.width + delta.x)
            } else if edges.contains(.left) {
                frame.size.width = max(minimum, anchor.width - delta.x)
                frame.origin.x = anchor.maxX - frame.width
            }
            if edges.contains(.top) {
                frame.size.height = max(minimum, anchor.height + delta.y)
            } else if edges.contains(.bottom) {
                frame.size.height = max(minimum, anchor.height - delta.y)
                frame.origin.y = anchor.maxY - frame.height
            }
            return frame
        }

        let targetWidth = edges.contains(.right) ? anchor.width + delta.x : anchor.width - delta.x
        let targetHeight = edges.contains(.top) ? anchor.height + delta.y : anchor.height - delta.y
        let scaleX = targetWidth / max(1, anchor.width)
        let scaleY = targetHeight / max(1, anchor.height)
        let minScale = max(minimum / max(1, anchor.width), minimum / max(1, anchor.height))
        let dominantScale = abs(scaleX - 1) >= abs(scaleY - 1) ? scaleX : scaleY
        let scale = max(minScale, dominantScale)

        let width = anchor.width * scale
        let height = anchor.height * scale
        frame.size = CGSize(width: width, height: height)
        if edges.contains(.left) { frame.origin.x = anchor.maxX - width }
        if edges.contains(.bottom) { frame.origin.y = anchor.maxY - height }
        return frame
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
