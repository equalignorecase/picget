import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Picget

final class ImportTests: XCTestCase {
    func testStaticImportsAndDownsamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let source = try XCTUnwrap(context.makeImage())
        let repository = Assets(root: root)
        let decoder = ImageDecoder()
        for (type, suffix) in [(UTType.png, "png"), (.jpeg, "jpg")] {
            let input = root.appendingPathComponent("photo.\(suffix)")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, source, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let asset = try await repository.importFile(input, existing: [])
            XCTAssertEqual(asset.format, suffix)
            XCTAssertFalse(asset.animated)
            let image = try await decoder.decode(asset: asset, directory: repository.directory, pixels: 64, index: 0)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 32)
            if type == .png { XCTAssertNotEqual(image.alphaInfo, .none) }
        }
    }

    func testTransparentGIFWithRestorePreviousAndRestoreBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("misleading.png")
        let encoded = "R0lGODlhEAAIAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFCgAAACwAAAAAEAAIAAAIIgADCAwAoKDBgwUHEkTIUCHDhgMfInQo0SDFigAuVtQoMSAAIfkEDRQAAAAsAAAAAAgACACBAAAAAP8AAAAAAAAACBsAAQgEEKBggIEEDSI0eHAgw4UKHUYU+FBiwYAAIfkECR4AAAAsBAAAAAgACACBAAAAAAD/AAAAAAAACBsAAQgEEKBggIEEDSI0eHAgw4UKHUYU+FBiwYAAIfkEBSgAAAAsAAAAABAACACBAAAA//8AAAAAAAAACCMAAQgcSFBggIMBCioEgDDhQoINH0JEKHFgxIoMKWK8WLFhQAA7"
        try XCTUnwrap(Data(base64Encoded: encoded)).write(to: source)
        let repository = Assets(root: root)
        let asset = try await repository.importFile(source, existing: [])
        let duplicate = try await repository.importFile(source, existing: [asset])
        XCTAssertEqual(duplicate.id, asset.id)
        XCTAssertEqual(asset.format, "gif")
        XCTAssertEqual(asset.ends.count, 4)
        XCTAssertEqual(try XCTUnwrap(asset.ends.last), 1, accuracy: 0.001)
        try FileManager.default.removeItem(at: source)
        let directory = repository.directory
        let decoder = ImageDecoder()
        let expected: [[UInt8]] = [[255, 0, 0, 0], [255, 255, 0, 0], [255, 0, 255, 0], [255, 0, 0, 255]]
        for index in [0, 2, 1, 3] {
            let image = try await decoder.decode(asset: asset, directory: directory, pixels: 16, index: index)
            XCTAssertEqual(image.width, 16)
            XCTAssertEqual(image.height, 8)
            let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8,
                bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 8))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual([1, 5, 9, 13].map { pixels[4 * 64 + $0 * 4 + 3] }, expected[index], "Frame \(index)")
        }
    }
}
