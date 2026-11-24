import AppKit
import ImageIO

actor ImageDecoder {
    private struct Key: Hashable {
        let asset: UUID
        let pixels: Int
        let index: Int
        let animated: Bool
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        var access: UInt64
    }

    private var cache: [Key: Entry] = [:]
    private var access: UInt64 = 0
    private var budget = 24 * 1024 * 1024

    func reduceCache(_ reduced: Bool) {
        budget = (reduced ? 8 : 24) * 1024 * 1024
        evict(animated: false)
        evict(animated: true)
    }

    func clear() { cache.removeAll() }

    private func evict(animated: Bool) {
        let group = cache.filter { $0.key.animated == animated }.sorted { $0.value.access < $1.value.access }
        var cost = group.reduce(0) { $0 + $1.value.cost }
        for (key, entry) in group where cost > budget {
            cache.removeValue(forKey: key)
            cost -= entry.cost
        }
    }

    func decode(asset: Asset, directory: URL, pixels: Int, index: Int) throws -> CGImage {
        try Task.checkCancellation()
        let key = Key(asset: asset.id, pixels: pixels, index: index, animated: asset.animated)
        access &+= 1
        if var entry = cache[key] {
            entry.access = access
            cache[key] = entry
            return entry.image
        }
        let image = try autoreleasepool {
            let url = directory.appendingPathComponent(asset.filename)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let result = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw PicgetError.invalidImage }
            return result
        }
        try Task.checkCancellation()
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        if !overflow, cost <= budget {
            cache[key] = Entry(image: image, cost: cost, access: access)
            if asset.animated {
                let recent = cache.filter { $0.key.asset == asset.id && $0.key.animated }
                    .sorted { $0.value.access > $1.value.access }
                for entry in recent.dropFirst(3) { cache.removeValue(forKey: entry.key) }
            }
            evict(animated: asset.animated)
        }
        return image
    }
}

@MainActor
final class DesktopWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(canvas: WidgetCanvas) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = Self.levelForEditing(false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Keep the widget in place during Show Desktop.
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        contentView = canvas
    }

    static func levelForEditing(_ editing: Bool) -> NSWindow.Level {
        if editing { return .normal }
        return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    }

    func orderForEditing(_ editing: Bool) {
        let target = Self.levelForEditing(editing)
        guard level != target || !isVisible else { return }
        level = target
        if editing { orderFrontRegardless() }
        else { orderBack(nil) }
    }
}

@MainActor
final class WidgetCanvas: NSView {
    private let picture = CALayer()
    private var imageSize = CGSize.zero

    func present(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        imageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        layoutPicture()
        CATransaction.commit()
    }
    var settings: Widget
    var editing = false
    var geometryChanged: ((CGRect) -> Void)?
    var dropped: ((URL) -> Void)?

    private struct ResizeHandle: OptionSet {
        let rawValue: Int
        static let left   = ResizeHandle(rawValue: 1 << 0)
        static let right  = ResizeHandle(rawValue: 1 << 1)
        static let top    = ResizeHandle(rawValue: 1 << 2)
        static let bottom = ResizeHandle(rawValue: 1 << 3)

        static let topLeft: ResizeHandle = [.top, .left]
        static let topRight: ResizeHandle = [.top, .right]
        static let bottomLeft: ResizeHandle = [.bottom, .left]
        static let bottomRight: ResizeHandle = [.bottom, .right]
    }

    private var anchor: (location: CGPoint, frame: CGRect, handle: ResizeHandle)?

    private static let nwseCursor: NSCursor = {
        let sel = Selector(("_windowResizeNorthWestSouthEastCursor"))
        if NSCursor.responds(to: sel),
           let cursor = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .arrow
    }()

    private static let neswCursor: NSCursor = {
        let sel = Selector(("_windowResizeNorthEastSouthWestCursor"))
        if NSCursor.responds(to: sel),
           let cursor = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .arrow
    }()

    init(settings: Widget) {
        self.settings = settings
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        picture.contentsGravity = .resize
        layer?.addSublayer(picture)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        layoutPicture()
        window?.invalidateCursorRects(for: self)
    }

    private func handle(at point: CGPoint) -> ResizeHandle {
        let margin: CGFloat = 14
        let onLeft = point.x <= margin
        let onRight = point.x >= bounds.maxX - margin
        let onBottom = point.y <= margin
        let onTop = point.y >= bounds.maxY - margin

        var result = ResizeHandle()
        if onLeft { result.insert(.left) }
        if onRight { result.insert(.right) }
        if onBottom { result.insert(.bottom) }
        if onTop { result.insert(.top) }
        return result
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard editing || !settings.locked else { return }

        let margin: CGFloat = 14
        let w = bounds.width
        let h = bounds.height
        guard w > margin * 2, h > margin * 2 else { return }

        // Corners
        addCursorRect(CGRect(x: 0, y: 0, width: margin, height: margin), cursor: Self.neswCursor) // Bottom-left
        addCursorRect(CGRect(x: w - margin, y: 0, width: margin, height: margin), cursor: Self.nwseCursor) // Bottom-right
        addCursorRect(CGRect(x: 0, y: h - margin, width: margin, height: margin), cursor: Self.nwseCursor) // Top-left
        addCursorRect(CGRect(x: w - margin, y: h - margin, width: margin, height: margin), cursor: Self.neswCursor) // Top-right

        // Edges
        addCursorRect(CGRect(x: margin, y: 0, width: w - margin * 2, height: margin), cursor: .resizeUpDown) // Bottom
        addCursorRect(CGRect(x: margin, y: h - margin, width: w - margin * 2, height: margin), cursor: .resizeUpDown) // Top
        addCursorRect(CGRect(x: 0, y: margin, width: margin, height: h - margin * 2), cursor: .resizeLeftRight) // Left
        addCursorRect(CGRect(x: w - margin, y: margin, width: margin, height: h - margin * 2), cursor: .resizeLeftRight) // Right
    }

    func layoutPicture() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer?.cornerRadius = settings.effectiveRadius(in: bounds.size)
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        if settings.mode == .stretch {
            picture.frame = bounds
            return
        }
        let horizontal = bounds.width / imageSize.width
        let vertical = bounds.height / imageSize.height
        let scale = settings.mode == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
        let zoom = settings.mode == .crop ? settings.zoom : 1
        let width = imageSize.width * scale * zoom
        let height = imageSize.height * scale * zoom
        let x = settings.mode == .crop ? settings.cropX : 0
        let y = settings.mode == .crop ? settings.cropY : 0
        picture.frame = CGRect(x: (bounds.width - width) * (1 + x) / 2,
                               y: (bounds.height - height) * (1 + y) / 2, width: width, height: height)
    }

    var isDragging: Bool { anchor != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { editing }

    override func mouseDown(with event: NSEvent) {
        guard editing || !settings.locked, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let matchedHandle = handle(at: point)
        anchor = (NSEvent.mouseLocation, window.frame, matchedHandle)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor, let window else { return }
        let delta = NSEvent.mouseLocation - anchor.location
        var frame = anchor.frame

        if !anchor.handle.isEmpty {
            let initialAspectRatio = anchor.frame.width / max(1, anchor.frame.height)

            // Horizontal resize
            if anchor.handle.contains(.right) {
                frame.size.width = max(48, anchor.frame.width + delta.x)
            } else if anchor.handle.contains(.left) {
                let newWidth = max(48, anchor.frame.width - delta.x)
                frame.origin.x = anchor.frame.maxX - newWidth
                frame.size.width = newWidth
            }

            // Vertical resize
            if anchor.handle.contains(.bottom) {
                let newHeight = max(48, anchor.frame.height - delta.y)
                frame.origin.y = anchor.frame.maxY - newHeight
                frame.size.height = newHeight
            } else if anchor.handle.contains(.top) {
                frame.size.height = max(48, anchor.frame.height + delta.y)
            }

            // Aspect lock constraint
            if settings.aspectLocked {
                if anchor.handle.contains(.left) || anchor.handle.contains(.right) {
                    let targetHeight = max(48, frame.size.width / initialAspectRatio)
                    if anchor.handle.contains(.bottom) {
                        frame.origin.y = anchor.frame.maxY - targetHeight
                    }
                    frame.size.height = targetHeight
                } else if anchor.handle.contains(.top) || anchor.handle.contains(.bottom) {
                    let targetWidth = max(48, frame.size.height * initialAspectRatio)
                    frame.size.width = targetWidth
                }
            }
        } else {
            frame.origin.x += delta.x
            frame.origin.y += delta.y
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil, let window else { return }
        anchor = nil
        geometryChanged?(window.frame)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true])?.first as? URL else { return false }
        dropped?(url)
        return true
    }
}

private extension CGPoint {
    static func - (left: CGPoint, right: CGPoint) -> CGPoint {
        CGPoint(x: left.x - right.x, y: left.y - right.y)
    }
}

@MainActor
enum Displays {
    static func id(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max {
            let first = $0.frame.intersection(frame)
            let second = $1.frame.intersection(frame)
            return first.width * first.height < second.width * second.height
        }.flatMap { $0.frame.intersects(frame) ? $0 : nil } ?? NSScreen.main
    }

    static func position(_ widget: Widget) -> CGRect {
        let preferred = widget.display.flatMap { value in NSScreen.screens.first { id($0) == value } }
        guard let screen = preferred ?? (widget.display == nil ? self.screen(for: widget.frame) : NSScreen.main) else {
            return widget.frame
        }
        let bounds = screen.visibleFrame
        var frame = widget.frame
        if preferred != nil, let relative = widget.relativeOrigin {
            frame.origin = CGPoint(x: bounds.minX + relative.x * bounds.width,
                                   y: bounds.minY + relative.y * bounds.height)
        }
        frame.size.width = min(frame.width, bounds.width)
        frame.size.height = min(frame.height, bounds.height)
        frame.origin.x = min(bounds.maxX - frame.width, max(bounds.minX, frame.minX))
        frame.origin.y = min(bounds.maxY - frame.height, max(bounds.minY, frame.minY))
        return frame
    }
}
