import XCTest
@testable import Picget

final class ModelTests: XCTestCase {
    func testCornerRadiusRecoversAfterResizing() throws {
        var widget = Widget(asset: UUID(), name: "Picture")
        widget.radius = 150
        widget.frame.size = CGSize(width: 120, height: 80)
        widget.validate()

        XCTAssertEqual(widget.effectiveRadius(in: widget.frame.size), 40)
        let saved = try JSONEncoder().encode(widget)
        let restored = try JSONDecoder().decode(Widget.self, from: saved)
        XCTAssertEqual(restored.effectiveRadius(in: CGSize(width: 400, height: 300)), 150)
    }

    func testConfigurationRoundTrip() throws {
        let widget = Widget(asset: UUID(), name: "Picture")
        let configuration = Configuration(widgets: [widget])
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.widgets.first?.id, widget.id)
        XCTAssertEqual(decoded.widgets.first?.asset, widget.asset)
    }

    func testRemoteURLRequiresHTTPS() throws {
        XCTAssertThrowsError(try Assets.remoteURL("http://example.com/image.png"))
        XCTAssertThrowsError(try Assets.remoteURL("https://name:secret@example.com/image.png"))
        XCTAssertEqual(try Assets.remoteURL("https://example.com/image.png").host, "example.com")
    }

    func testPlaybackCapsPresentationWithoutChangingSourceTiming() {
        XCTAssertEqual(Playback.frame(at: 0.35, ends: [0.1, 0.3, 0.5], loops: 0), 2)
        XCTAssertEqual(Playback.frame(at: 0.55, ends: [0.1, 0.3, 0.5], loops: 0), 0)
        XCTAssertNil(Playback.frame(at: 0.55, ends: [0.1, 0.3, 0.5], loops: 1))
    }

    func testDraggedFrameSideEdgesAndProportionalCorners() {
        let anchor = CGRect(x: 100, y: 100, width: 200, height: 100)

        let leftExpanded = Widget.draggedFrame(from: anchor, delta: CGPoint(x: -40, y: 20), edges: .left)
        XCTAssertEqual(leftExpanded, CGRect(x: 60, y: 100, width: 240, height: 100))

        let rightExpanded = Widget.draggedFrame(from: anchor, delta: CGPoint(x: 50, y: -30), edges: .right)
        XCTAssertEqual(rightExpanded, CGRect(x: 100, y: 100, width: 250, height: 100))

        let topExpanded = Widget.draggedFrame(from: anchor, delta: CGPoint(x: 20, y: 30), edges: .top)
        XCTAssertEqual(topExpanded, CGRect(x: 100, y: 100, width: 200, height: 130))

        let bottomClamped = Widget.draggedFrame(from: anchor, delta: CGPoint(x: 0, y: 90), edges: .bottom)
        XCTAssertEqual(bottomClamped, CGRect(x: 100, y: 152, width: 200, height: 48))

        let bottomRightProportional = Widget.draggedFrame(from: anchor, delta: CGPoint(x: 100, y: -20), edges: .bottomRight)
        XCTAssertEqual(bottomRightProportional, CGRect(x: 100, y: 50, width: 300, height: 150))

        let bottomRightFree = Widget.draggedFrame(from: anchor, delta: CGPoint(x: 100, y: -20), edges: .bottomRight, freeCorner: true)
        XCTAssertEqual(bottomRightFree, CGRect(x: 100, y: 80, width: 300, height: 120))
    }

    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewerVersion("v0.1.1", than: "0.1.0"))
        XCTAssertTrue(Updater.isNewerVersion("v0.2", than: "0.1.9"))
        XCTAssertTrue(Updater.isNewerVersion("1.0.0", than: "0.9.9"))
        XCTAssertFalse(Updater.isNewerVersion("v0.1.0", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewerVersion("0.1", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewerVersion("0.0.9", than: "0.1.0"))
    }
}
