import XCTest

final class MarkPocketUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testLinkAndVerifyICloudFolder() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(2)
        attachScreenshot(name: "01_initial_state")

        let alreadyLinked = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "MarkPocket、フォルダ別に見る")
        ).firstMatch.waitForExistence(timeout: 2)

        if !alreadyLinked {
            unlinkLocalStorageIfPresent(in: app)
            openFolderPicker(in: app)
            sleep(3)
            attachScreenshot(name: "02_picker_opened")

            navigateAndTapICloudDrive(in: app)
            sleep(3)
            attachScreenshot(name: "03_icloud_drive")

            if let markPocketItem = findPickerFolderNamed("MarkPocket", in: app) {
                print("PICKER_ACTION: tapping MarkPocket at \(markPocketItem.frame)")
                markPocketItem.tap()
                sleep(2)
                attachScreenshot(name: "04_selected_markpocket")

                if tapOpenUntilPickerDismisses(in: app) {
                    sleep(4)
                    attachScreenshot(name: "05a_synced_4s")
                    sleep(10)
                    attachScreenshot(name: "05b_synced_14s")
                } else {
                    print("PICKER_STATUS: OPEN_DID_NOT_DISMISS")
                    return
                }
            } else {
                print("PICKER_STATUS: MARKPOCKET_NOT_FOUND_IN_ICLOUD_DRIVE")
                return
            }
        } else {
            print("HOME_STATUS: MARKPOCKET_ALREADY_LINKED")
        }

        verifySyncedReaderAndFolders(in: app)
    }

    @MainActor
    private func unlinkLocalStorageIfPresent(in app: XCUIApplication) {
        let storageText = app.staticTexts["File Provider Storage"].firstMatch
        guard storageText.waitForExistence(timeout: 1.5) else {
            return
        }

        storageText.swipeLeft()
        let swipeDelete = app.buttons["連携解除"].firstMatch
        if swipeDelete.waitForExistence(timeout: 2) {
            swipeDelete.tap()
            sleep(1)
            return
        }

        storageText.press(forDuration: 1.0)
        let menuDelete = app.buttons["連携を解除"].firstMatch
        if menuDelete.waitForExistence(timeout: 2) {
            menuDelete.tap()
            sleep(1)
        }
    }

    @MainActor
    private func openFolderPicker(in app: XCUIApplication) {
        let emptyLinkButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "iCloud フォルダを連携")
        ).firstMatch
        if emptyLinkButton.waitForExistence(timeout: 2) {
            emptyLinkButton.tap()
            return
        }

        let addBtn = app.navigationBars.buttons["追加"].firstMatch
        if addBtn.waitForExistence(timeout: 2) {
            addBtn.tap()
            sleep(1)
            let linkMenuItem = app.buttons["フォルダを連携"].firstMatch
            if linkMenuItem.waitForExistence(timeout: 2) {
                linkMenuItem.tap()
            }
        }
    }

    @MainActor
    private func navigateAndTapICloudDrive(in app: XCUIApplication) {
        if let iCloud = findExactLocationElement("iCloud Drive", in: app) {
            print("PICKER_NAV: iCloud Drive visible, tapping")
            iCloud.tap()
            return
        }

        let navButtonLabels = ["戻る", "サイドバーを表示", "サイドバー", "ブラウズ", "場所", "ロケーション", "Back", "Browse", "Show Sidebar"]
        for step in 0..<4 {
            var tapped = false
            for label in navButtonLabels {
                let query = app.buttons.matching(NSPredicate(format: "label == %@ OR label CONTAINS %@", label, label))
                if query.count > 0 {
                    let btn = query.firstMatch
                    if btn.exists && btn.isEnabled && btn.isHittable {
                        print("PICKER_NAV: tapping '\(btn.label)' step \(step)")
                        btn.tap()
                        tapped = true
                        sleep(2)
                        break
                    }
                }
            }
            if !tapped {
                break
            }
            attachScreenshot(name: "02b_nav_step_\(step)")
            if let iCloud = findExactLocationElement("iCloud Drive", in: app) {
                print("PICKER_NAV: found iCloud Drive at step \(step), tapping")
                iCloud.tap()
                return
            }
        }
        print("PICKER_STATUS: ICLOUD_DRIVE_NOT_REACHED")
    }

    @MainActor
    private func findExactLocationElement(_ name: String, in app: XCUIApplication) -> XCUIElement? {
        let sidebarCell = app.cells["DOC.sidebar.item.\(name)"].firstMatch
        if sidebarCell.exists && sidebarCell.isHittable {
            return sidebarCell
        }

        let cell = app.cells.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", name, "\(name),", "\(name)、")
        ).firstMatch
        if cell.exists && cell.isHittable {
            return cell
        }

        let button = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, "\(name)、")
        ).firstMatch
        if button.exists && button.isHittable {
            return button
        }

        let text = app.staticTexts[name].firstMatch
        if text.exists && text.isHittable {
            return text
        }

        return nil
    }

    @MainActor
    private func findPickerFolderNamed(_ name: String, in app: XCUIApplication) -> XCUIElement? {
        for swipeIdx in 0..<3 {
            let cellQuery = app.cells.matching(
                NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", name, "\(name),", "\(name)、")
            )
            let cellCount = cellQuery.count
            for idx in 0..<min(cellCount, 5) {
                let candidate = cellQuery.element(boundBy: idx)
                if candidate.exists && candidate.frame.minY > 120 && candidate.isHittable {
                    return candidate
                }
            }

            let textQuery = app.staticTexts.matching(NSPredicate(format: "label == %@", name))
            let textCount = textQuery.count
            for idx in 0..<min(textCount, 5) {
                let candidate = textQuery.element(boundBy: idx)
                if candidate.exists && candidate.frame.minY > 180 && candidate.isHittable {
                    return candidate
                }
            }

            if swipeIdx < 2 {
                app.swipeUp()
                sleep(1)
            }
        }
        return nil
    }

    @MainActor
    private func tapOpenUntilPickerDismisses(in app: XCUIApplication) -> Bool {
        for attempt in 0..<5 {
            if let openButton = findEnabledOpenButton(in: app) {
                print("PICKER_NAV: tapping 開く attempt \(attempt)")
                openButton.tap()
                sleep(2)
            }
            if !app.buttons["キャンセル"].firstMatch.exists && !app.buttons["開く"].firstMatch.exists {
                print("PICKER_NAV: picker dismissed cleanly at attempt \(attempt)")
                return true
            }
            sleep(2)
        }
        return !app.buttons["キャンセル"].firstMatch.exists
    }

    @MainActor
    private func findEnabledOpenButton(in app: XCUIApplication) -> XCUIElement? {
        for label in ["開く", "Open", "完了", "Done"] {
            let btn = app.buttons[label].firstMatch
            if btn.exists && btn.isEnabled && btn.isHittable {
                return btn
            }
        }
        return nil
    }

    @MainActor
    private func verifySyncedReaderAndFolders(in app: XCUIApplication) {
        let firstCloudDoc = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND NOT (label CONTAINS %@)", ".md", "main/", "Markdown_CheatSheet.md")
        ).firstMatch
        if firstCloudDoc.waitForExistence(timeout: 6) {
            print("[READER_FIRST] tapping: \(firstCloudDoc.label)")
            firstCloudDoc.tap()
            sleep(3)
            attachScreenshot(name: "06_reader_first")
            print("[READER_FIRST] sampleTextsCount: \(app.staticTexts.count)")
            navigateBack(in: app)
            sleep(1)
        }

        let onDemandDoc = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "iCloud からタップして読み込み")
        ).firstMatch
        if onDemandDoc.waitForExistence(timeout: 3) {
            print("[READER_ONDEMAND] tapping: \(onDemandDoc.label)")
            onDemandDoc.tap()
            sleep(8)
            attachScreenshot(name: "07_reader_ondemand")
            print("[READER_ONDEMAND] sampleTextsCount: \(app.staticTexts.count)")
            navigateBack(in: app)
            sleep(1)
        }

        let folderRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "MarkPocket、フォルダ別に見る")
        ).firstMatch
        if folderRow.waitForExistence(timeout: 3) {
            folderRow.tap()
            sleep(2)
            attachScreenshot(name: "08_folder_root")

            let mainRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "main")).firstMatch
            if mainRow.waitForExistence(timeout: 3) {
                mainRow.tap()
                sleep(2)
                attachScreenshot(name: "09_folder_main")
                print("[FOLDER_MAIN] visibleTexts: \(app.staticTexts.count)")
            }
        }
    }

    @MainActor
    private func navigateBack(in app: XCUIApplication) {
        let backBtn = app.navigationBars.buttons.element(boundBy: 0)
        if backBtn.exists && backBtn.isHittable {
            backBtn.tap()
        }
    }

    @MainActor
    private func attachScreenshot(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
