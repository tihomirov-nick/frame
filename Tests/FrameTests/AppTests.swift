import AppKit
import XCTest
@testable import Frame

/// The family's menu bar standard. Nothing here touches the menu bar: the menu is built, never shown.
@MainActor
final class AppTests: XCTestCase {
    func testTheIconIsATemplateImage22PointsHigh() {
        for badge in [false, true] {
            let image = MenuBarIcon.image(badge: badge)
            XCTAssertEqual(image.size.height, 22)
            XCTAssertEqual(image.size, MenuBarIcon.canvas)
            XCTAssertTrue(image.isTemplate)
        }
    }

    func testTheMenuEndsWithTheFamilyItems() {
        let items = StatusItem.menu().items
        let tail = Array(items.suffix(5))
        XCTAssertEqual(tail.map(\.isSeparatorItem), [false, false, false, true, false])
        XCTAssertEqual(tail[0].action, #selector(AppDelegate.showSettings(_:)))
        XCTAssertEqual(tail[0].keyEquivalent, ",")
        XCTAssertEqual(tail[1].action, #selector(AppDelegate.checkForUpdates(_:)))
        XCTAssertEqual(tail[2].action, #selector(AppDelegate.showAbout(_:)))
        XCTAssertEqual(tail[4].action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(tail[4].keyEquivalent, "q")
        // The app's own actions come first, a separator after them.
        let actions = AppActions.menuItems().count
        XCTAssertEqual(items.count, actions + (actions > 0 ? 1 : 0) + 5)
    }

    func testThePointerIsMeasuredFromTheTopLeftOfTheCapturedArea() {
        // The area: 800 × 600 points at 100, 50 from the top left of the main screen, 1000 points high.
        let area = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertEqual(CursorTracker.normalized(CGPoint(x: 500, y: 650), in: area, mainScreenTop: 1000), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(CursorTracker.normalized(CGPoint(x: 100, y: 950), in: area, mainScreenTop: 1000), CGPoint(x: 0, y: 0))
        XCTAssertEqual(CursorTracker.normalized(CGPoint(x: 900, y: 350), in: area, mainScreenTop: 1000), CGPoint(x: 1, y: 1))
    }

    func testTheRecordingMenuOffersEachKindOfRecording() {
        let titles = AppActions.menuItems().map(\.title)
        XCTAssertEqual(titles.count, 4)
        XCTAssertFalse(AppActions.isBusy)
    }
}
