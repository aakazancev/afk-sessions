import XCTest
@testable import SessionsTelegram

final class MediaTests: XCTestCase {
    func testFitsPhoto() {
        XCTAssertTrue(MediaPlan.fitsPhoto(ImageInfo(bytes: 500_000, width: 1280, height: 800)))
        // Длинный fullPage: 1280×30000 — сумма > 10000 и соотношение > 20.
        XCTAssertFalse(MediaPlan.fitsPhoto(ImageInfo(bytes: 3_000_000, width: 1280, height: 30000)))
        // Соотношение ровно 20 — можно; больше — нельзя.
        XCTAssertTrue(MediaPlan.fitsPhoto(ImageInfo(bytes: 1, width: 400, height: 8000)))
        XCTAssertFalse(MediaPlan.fitsPhoto(ImageInfo(bytes: 1, width: 400, height: 8001)))
        // Сумма сторон > 10000 при нормальном соотношении.
        XCTAssertFalse(MediaPlan.fitsPhoto(ImageInfo(bytes: 1, width: 5001, height: 5000)))
        // > 10 МБ.
        XCTAssertFalse(MediaPlan.fitsPhoto(ImageInfo(bytes: 10 * 1024 * 1024 + 1, width: 1280, height: 800)))
        // Размеры не прочитались — не фото.
        XCTAssertFalse(MediaPlan.fitsPhoto(ImageInfo(bytes: 100, width: 0, height: 0)))
    }

    func testFitsDocument() {
        XCTAssertTrue(MediaPlan.fitsDocument(bytes: 50 * 1024 * 1024))
        XCTAssertFalse(MediaPlan.fitsDocument(bytes: 50 * 1024 * 1024 + 1))
    }
}
