import Foundation
import Testing
import UlaniKit
@testable import PaperhueUI

@Suite struct SystemLanguageTests {
    /// The window starts in the language macOS picks for the menus: the first preferred
    /// language the app has a localization for.
    @Test(arguments: [
        (["zh-Hant-TW"], Language.chinese),
        (["zh-TW"], .chinese),
        (["zh-Hans-CN"], .chinese),  // zh-Hans.lproj: Chinese menus as well
        (["zh-CN"], .chinese),
        (["zh-Hant-HK", "en-US"], .chinese),
        (["en-US"], .english),
        (["ja-JP"], .english),
        (["en-US", "zh-Hant-TW"], .english),  // the first language the app has decides
        (["en-TW", "zh-Hant-TW"], .english),
        (["ja-JP", "zh-Hant-TW"], .chinese),  // no Japanese: the menus are Chinese, so is the window
        (["fr-FR", "zh-TW"], .chinese),
        ([], .english),
    ])
    func chineseSystemsGetChineseOthersEnglish(preferred: [String], language: Language) {
        #expect(Language.systemDefault(preferredLanguages: preferred) == language)
    }

    /// `Language.localizations` are exactly the app's `.lproj` folders, so `systemDefault`
    /// matches against what macOS matches against for the menus.
    @Test func theLocalizationsAreTheAppsLprojFolders() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/PaperhueUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // UlaniKit
            .deletingLastPathComponent()  // apple
            .appendingPathComponent("Paperhue/Paperhue")
        let folders = try FileManager.default.contentsOfDirectory(atPath: app.path)
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
        #expect(folders.sorted() == Language.localizations.map(\.localization).sorted())
        #expect(Language.allCases.allSatisfy { folders.contains($0.rawValue) })  // what the toggle stores
    }

    @Test func theToggleIsNamedAfterTheOtherLanguage() {
        #expect(Language.chinese.other == .english && Language.english.other == .chinese)
        #expect(Language.chinese.toggleLabel == "English")
        #expect(Language.english.toggleLabel == "中文")
        #expect(Language.allCases.map(\.rawValue) == ["zh-Hant", "en"])
    }
}

/// The language toggle: one tap switches every text the model shows, at any time, and the
/// choice outlives the app.
@MainActor
@Suite struct LanguageToggleTests {
    let keepAwake = FakeKeepAwake()
    let defaults = TestDefaults()

    func makeModel(_ service: FakePushService = FakePushService(), defaults: UserDefaults? = nil,
                   preferred: [String] = ["zh-Hant-TW"]) -> PushViewModel {
        PushViewModel(service: service, keepAwake: keepAwake, defaults: defaults ?? self.defaults.defaults,
                      preferredLanguages: preferred)
    }

    /// The app's own `AppleLanguages` in the test suite: the toggle's choice, or the
    /// per-app language from System Settings.
    var stored: [String]? {
        defaults.reopened().persistentDomain(forName: defaults.name)?["AppleLanguages"] as? [String]
    }

    /// A later launch on a system preferring `system`: the app's own `AppleLanguages`, when
    /// set, replaces the system's list in `Locale.preferredLanguages`.
    func nextLaunch(system: [String]) -> PushViewModel {
        makeModel(defaults: defaults.reopened(), preferred: stored ?? system)
    }

    @Test func startsInTheSystemLanguage() {
        #expect(makeModel(preferred: ["zh-Hant-TW"]).language == .chinese)
        #expect(makeModel(preferred: ["en-GB"]).language == .english)
        let english = makeModel(preferred: ["fr-FR"])
        #expect(english.menuLanguage == .english && !english.menusSwitchAtNextLaunch)
        #expect(english.strings[.appTitle] == "Paperhue")
        #expect(english.summaryText.hasPrefix("Choose 1–4 photos"))
        #expect(english.deviceStatusText == "Device status: not read yet")
    }

    @Test func togglingSwitchesBackAndForth() {
        let model = makeModel()
        #expect(model.language == .chinese && model.strings[.appTitle] == "紙彩")
        model.toggleLanguage()
        #expect(model.language == .english && model.strings[.appTitle] == "Paperhue")
        model.toggleLanguage()
        #expect(model.language == .chinese)
        model.setLanguage(.english)
        model.setLanguage(.english)
        #expect(model.language == .english)
    }

    @Test func theChoiceIsRememberedAcrossLaunches() {
        let first = makeModel(preferred: ["zh-Hant-TW"])
        first.toggleLanguage()
        // A later launch, on the same Chinese system: the stored choice wins, menus included.
        let next = nextLaunch(system: ["zh-Hant-TW"])
        #expect(next.language == .english && next.menuLanguage == .english)
        #expect(next.summaryText.hasPrefix("Choose 1–4 photos"))
        next.toggleLanguage()
        #expect(nextLaunch(system: ["en-US"]).language == .chinese)
    }

    @Test func theSystemMenusFollowFromTheNextLaunch() {
        let model = makeModel()
        // Untouched until the user chooses (the system's list shows through).
        #expect(stored == nil && !model.menusSwitchAtNextLaunch)
        model.toggleLanguage()
        #expect(stored == ["en"])
        // The menus keep the launch language: the window says so, in the new language.
        #expect(model.menuLanguage == .chinese && model.menusSwitchAtNextLaunch)
        #expect(model.strings[.menusNextLaunch]
                == "The menu bar and system dialogs switch to English the next time you open Paperhue.")
        model.toggleLanguage()
        #expect(stored == ["zh-Hant"])
        #expect(!model.menusSwitchAtNextLaunch)  // the menus' language again
        // The one place the choice is kept.
        #expect(defaults.reopened().persistentDomain(forName: defaults.name)?.keys.sorted() == ["AppleLanguages"])
    }

    /// System Settings › Language & Region › Applications sets (or, for "System Language",
    /// removes) the same `AppleLanguages`: at the next launch the window follows it like the
    /// menus, whatever the toggle chose before.
    @Test func thePerAppLanguageFromSystemSettingsWins() {
        makeModel(preferred: ["zh-Hant-TW"]).toggleLanguage()
        #expect(stored == ["en"])
        defaults.defaults.set(["zh-Hant-TW"], forKey: "AppleLanguages")  // 繁體中文
        #expect(nextLaunch(system: ["en-US"]).language == .chinese)
        defaults.defaults.removeObject(forKey: "AppleLanguages")  // System Language
        #expect(nextLaunch(system: ["zh-Hant-TW"]).language == .chinese)
        #expect(nextLaunch(system: ["en-US"]).language == .english)
    }

    /// After a status read, a failed push (its alert still open) and an unreadable photo: one
    /// toggle changes the summary, the device line, every tile, the technical log and the
    /// alert together.
    @Test func togglingSwitchesEveryTextOnScreenAtOnce() async {
        let error = PushError(page: 2, completed: [1: .ok], underlying: .deviceBusy(what: "an image for page 2"))
        let service = FakePushService(push: { _, progress in
            progress(PushEvent(page: 1, phase: .start, index: 0, count: 2, sent: 0, total: 10))
            progress(PushEvent(page: 1, phase: .done, index: 0, count: 2, sent: 10, total: 10))
            progress(PushEvent(page: 2, phase: .start, index: 1, count: 2, sent: 0, total: 10))
            progress(PushEvent(page: 2, phase: .sending, index: 1, count: 2, sent: 4, total: 10))
            throw error
        }, info: {
            CalendarStatus(battery: Battery(level: 4, charging: false), shown: 3)
        })
        let model = makeModel(service)
        for page in [1, 2] {
            model.load(photo(TestImages.red, name: "p\(page).png"), into: page)
        }
        await model.waitForRenders()
        await model.readInfo()
        await model.push()
        model.load(.data(Data("not an image".utf8), name: "notes.txt"), into: 4)
        await model.waitForRenders()
        let detail = error.description
        let crcs = [1, 2].map { (page: $0, frame: model.page($0).frame!) }

        #expect(model.summaryText == "推送失敗，請看錯誤訊息後再試一次。")
        #expect(model.deviceStatusText == "裝置狀態：電量 4/5，目前顯示第 3 頁")
        #expect((1...4).map(model.status) == ["完成", "未完成", "", "無法讀取 notes.txt：不支援的檔案格式"])
        #expect(model.technicalLines == crcs.map { Strings(.chinese).crcLine(page: $0.page, frame: $0.frame) }
                                        + ["推送失敗：\(detail)"])
        #expect(model.alertTitle == "推送失敗")
        #expect(model.alertMessage == "\(FriendlyTests.silent)\n\n\(detail)")
        let alert = model.alert

        model.toggleLanguage()
        #expect(model.summaryText == "Push failed. Read the error message, then try again.")
        #expect(model.deviceStatusText == "Device status: battery 4/5, showing page 3")
        #expect((1...4).map(model.status) == ["Done", "Not finished", "", "Can’t read notes.txt: unsupported file format"])
        #expect(model.technicalLines == crcs.map { Strings(.english).crcLine(page: $0.page, frame: $0.frame) }
                                        + ["Push failed: \(detail)"])
        #expect(model.technicalLines.first?.hasPrefix("Page 1 CRC32 ") == true)
        #expect(model.alert == alert)  // the same alert, still open
        #expect(model.alertTitle == "Push failed")
        #expect(model.alertMessage == "\(FriendlyTests.englishSilent)\n\n\(detail)")
        #expect(model.page(2).percent == 40)  // state is untouched

        model.toggleLanguage()
        #expect(model.alertTitle == "推送失敗" && model.summaryText == "推送失敗，請看錯誤訊息後再試一次。")
        #expect(model.status(2) == "未完成")
    }

    @Test func togglingDuringAPushKeepsItRunning() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(push: { frames, progress in
            progress(PushEvent(page: 1, phase: .sending, index: 0, count: 1, sent: 1, total: 4))
            await started.open()
            await release.wait()
            progress(PushEvent(page: 1, phase: .refreshing, index: 0, count: 1, sent: 4, total: 4))
            return frames.mapValues { _ in .ok }
        })
        let model = makeModel(service)
        model.load(photo(TestImages.red), into: 1)
        model.load(photo(TestImages.blue), into: 2)
        await model.waitForRenders()
        let push = Task { await model.push() }
        await started.wait()
        #expect(await eventually { model.status(1) == "傳送中 25%" })
        #expect(model.summaryText == "連線並推送中…（正在顯示的那一頁會最後傳）")

        model.toggleLanguage()
        #expect(model.isPushing)
        #expect(model.summaryText == "Connecting and pushing… (the page on screen goes last)")
        #expect(model.status(1) == "Sending 25%" && model.status(2) == "Waiting")
        var quitTitle: String?
        #expect(model.confirmQuit(ask: { strings in
            quitTitle = strings[.quitWhilePushingTitle]
            return false
        }) == .terminateCancel)
        #expect(quitTitle == "Still sending")

        await release.open()
        await push.value
        #expect(model.status(1) == "Done (the screen takes about 40 s to refresh)")
        #expect(model.summaryText == "Done: 2 pages updated, 0 pages already the same.")
        #expect(model.deviceStatusText == "Device status: just pushed (press “Read status” to update)")
    }

    @Test func togglingKeepsPreviewsAndRendersRunning() async {
        let release = Gate()
        let model = makeModel()
        model.load(photo(TestImages.red), into: 1)
        await model.waitForRenders()
        let frame = model.page(1).frame, preview = model.page(1).preview
        let generation = model.page(1).generation
        model.load(PhotoSource(name: "slow.png") {
            await release.wait()
            return fetched(TestImages.blue)
        }, into: 2)
        let rendering = model.page(2).renderTask
        #expect(model.status(2) == "產生預覽中…")

        model.toggleLanguage()
        #expect(model.status(1) == "Preview in the device’s 7 colours")
        #expect(model.status(2) == "Making preview…")
        #expect(model.page(1).frame == frame && model.page(1).preview === preview)
        #expect(model.page(1).generation == generation && !model.page(1).isRendering)
        #expect(model.page(2).isRendering && model.page(2).renderTask == rendering)

        await release.open()
        await model.waitForRenders()
        #expect(model.page(2).frame == TestImages.frame(TestImages.blue))
        #expect(model.status(2) == "Preview in the device’s 7 colours")
    }

    @Test func verifyAndStatusReadInEnglish() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(info: {
            await started.open()
            await release.wait()
            throw UlaniError.notFound
        }, probe: { frames in
            frames.keys.reduce(into: [:]) { $0[$1] = $1 == 2 ? .differs : .matches }
        })
        let model = makeModel(service, preferred: ["en-AU"])
        for page in [1, 2] {
            model.load(photo(TestImages.red), into: page)
        }
        await model.waitForRenders()
        await model.push()
        await model.verify()
        #expect(model.status(1) == "Verified: matches" && model.status(2) == "Verified: differs")
        #expect(model.summaryText == "Verified: page 2 differs from the pushed photo.")
        #expect(model.technicalLines.suffix(2) == ["Page 1 Verified: matches", "Page 2 Verified: differs"])

        let read = Task { await model.readInfo() }
        await started.wait()
        #expect(model.deviceStatusText == "Device status: connecting…")
        await release.open()
        await read.value
        #expect(model.deviceStatusText == "Device status: unreachable")
        #expect(model.alertTitle == "Couldn’t read the status")
        #expect(model.alertMessage?.hasPrefix(FriendlyTests.englishNotFound) == true)
        #expect(model.technicalLines.last == "Couldn’t read the status: \(UlaniError.notFound)")
    }
}
