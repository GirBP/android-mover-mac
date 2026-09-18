import XCTest
import ImageIO
import CoreGraphics
@testable import AndroidMoverCore

/// 4.1: вбудовані мініатюри з перших 64 КБ файла + ADBClient.readHead через mock (`exec-out head`).
final class EmbeddedThumbnailTests: XCTestCase {
    private static let mockADBPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/mock_adb.py").path

    /// Великий JPEG (щоб 64 КБ його точно НЕ вміщали) з вбудованою EXIF-мініатюрою.
    static func makeJPEG(width: Int, height: Int, embedThumbnail: Bool) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Шум замість заливки: JPEG стискає однорідне поле у пару КБ, а нам треба > 64 КБ.
        var rng = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                             blue: .random(in: 0...1, using: &rng), alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImageDestinationEmbedThumbnail: embedThumbnail,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testExtractsEmbeddedThumbnailFromTruncatedHead() throws {
        let jpeg = try Self.makeJPEG(width: 2400, height: 1800, embedThumbnail: true)
        XCTAssertGreaterThan(jpeg.count, EmbeddedThumbnail.headBytes * 2, "фікстура має бути більшою за head")
        let head = jpeg.prefix(EmbeddedThumbnail.headBytes)
        let thumb = try XCTUnwrap(EmbeddedThumbnail.extract(from: head, maxPixelSize: 160))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 160)
        XCTAssertGreaterThan(min(thumb.width, thumb.height), 0)
        let encoded = try XCTUnwrap(EmbeddedThumbnail.jpegData(thumb))
        XCTAssertLessThan(encoded.count, 40_000)
    }

    func testNoEmbeddedThumbnailMeansNilNotFullDecode() throws {
        // Без вбудованої мініатюри з обрізаного файла її взяти нема звідки — і декодувати
        // повне зображення (CreateThumbnailFromImageIfAbsent=false) ми не просимо.
        let jpeg = try Self.makeJPEG(width: 2400, height: 1800, embedThumbnail: false)
        let head = jpeg.prefix(EmbeddedThumbnail.headBytes)
        XCTAssertNil(EmbeddedThumbnail.extract(from: head, maxPixelSize: 160))
    }

    func testGarbageAndEmptyAreNil() {
        XCTAssertNil(EmbeddedThumbnail.extract(from: Data(), maxPixelSize: 160))
        XCTAssertNil(EmbeddedThumbnail.extract(from: Data(repeating: 0x5A, count: 4096), maxPixelSize: 160))
        XCTAssertNil(EmbeddedThumbnail.extract(from: Data("not an image at all".utf8), maxPixelSize: 160))
    }

    func testSupportsOnlyFormatsWithEmbeddedThumbnails() {
        XCTAssertTrue(EmbeddedThumbnail.supports(name: "IMG_0001.JPG"))
        XCTAssertTrue(EmbeddedThumbnail.supports(name: "фото.heic"))
        XCTAssertFalse(EmbeddedThumbnail.supports(name: "screen.png"))
        XCTAssertFalse(EmbeddedThumbnail.supports(name: "clip.mp4"))
        XCTAssertFalse(EmbeddedThumbnail.supports(name: "noext"))
    }

    func testReadHeadReturnsExactPrefixBytesForQuotedPath() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.mockADBPath)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("am-head-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("DCIM/Фото відпустки")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        try payload.write(to: dir.appendingPathComponent("o'clock фото.jpg"))

        let client = ADBClient(adbPath: Self.mockADBPath, extraEnvironment: ["MOCK_PHONE_ROOT": base.path])
        let head = try await client.readHead("/sdcard/DCIM/Фото відпустки/o'clock фото.jpg", bytes: 65_536, on: "MOCK001")
        XCTAssertEqual(head.count, 65_536)
        XCTAssertEqual(head, payload.prefix(65_536))

        let short = try await client.readHead("/sdcard/DCIM/Фото відпустки/o'clock фото.jpg", bytes: 10, on: "MOCK001")
        XCTAssertEqual(short, payload.prefix(10))

        do {
            _ = try await client.readHead("/sdcard/DCIM/нема.jpg", bytes: 10, on: "MOCK001")
            XCTFail("очікували помилку для відсутнього файла")
        } catch {}
    }
}
