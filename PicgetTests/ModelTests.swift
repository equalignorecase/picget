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
}
