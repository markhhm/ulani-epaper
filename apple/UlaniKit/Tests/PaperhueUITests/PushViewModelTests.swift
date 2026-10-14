import CoreGraphics
import Foundation
import Testing
import UlaniKit
@testable import PaperhueUI

// Mirrors python/tests/test_gui.py, plus the app's keep-awake parts.

@MainActor
@Suite struct PushViewModelTests {
    let keepAwake = FakeKeepAwake()
    let defaults = TestDefaults()

    /// A model in Chinese, as on a zh-TW system with no stored choice (see LanguageTests).
    func makeModel(_ service: FakePushService = FakePushService()) -> PushViewModel {
        PushViewModel(service: service, keepAwake: keepAwake, defaults: defaults.defaults,
                      preferredLanguages: ["zh-Hant-TW"])
    }

    /// A model with photos on `pages`, previews rendered.
    func modelWithPhotos(_ pages: [Int], service: FakePushService = FakePushService()) async -> PushViewModel {
        let model = makeModel(service)
        for page in pages {
            model.load(photo(page % 2 == 0 ? TestImages.blue : TestImages.red, name: "p\(page).png"), into: page)
        }
        await model.waitForRenders()
        return model
    }

    // MARK: photos and previews

    @Test func startsWithFourEmptyPages() {
        let model = makeModel()
        #expect(model.pages.map(\.page) == [1, 2, 3, 4])
        #expect(model.pages.allSatisfy { $0.frame == nil && $0.preview == nil && $0.status == .blank && !$0.isRendering })
        #expect(model.fit == .cover && model.grain == .standard && model.colours == .natural)
        #expect(model.summary == .idle && model.summaryText == Strings(.chinese)[.summaryIdle])
        #expect(model.deviceStatusText == "裝置狀態：尚未讀取")
        #expect(!model.canPush && model.canEdit)
    }

    @Test func choosingPhotosBuildsPreviewsAndEnablesPush() async {
        let model = makeModel()
        model.load(photo(TestImages.red, name: "a.png"), into: 2)
        let page = model.page(2)
        #expect(page.isRendering && model.statusText(of: page) == "產生預覽中…" && page.name == "a.png")
        #expect(!model.canPush)  // still rendering
        await model.waitForRenders()
        #expect(page.frame == TestImages.frame(TestImages.red))
        #expect(page.preview?.width == 800 && page.preview?.height == 480)
        #expect(!page.isRendering && model.statusText(of: page) == "預覽為裝置實際顯示的 7 色效果")
        #expect(model.canPush)
        #expect(Set(model.frames().keys) == [2])
    }

    @Test func renderingRunsOffTheMainThread() async {
        let model = makeModel()
        let source = PhotoSource(name: "a.png") {
            #expect(!onMainThread())
            return FetchedPhoto(name: nil) {
                #expect(!onMainThread())
                return decoded(TestImages.red)
            }
        }
        model.load(source, into: 1)
        await model.waitForRenders()
        #expect(model.page(1).frame != nil)
    }

    @Test func aSlowDownloadDoesNotHoldUpOtherPages() async {
        let started = [Gate(), Gate()], release = Gate()
        let model = makeModel()
        for page in [1, 2] {
            model.load(PhotoSource(name: "icloud\(page).heic") {
                await started[page - 1].open()
                await release.wait()  // still downloading
                return fetched(TestImages.red)
            }, into: page)
        }
        await started[0].wait()
        await started[1].wait()
        model.load(photo(TestImages.blue, name: "local.png"), into: 3)
        #expect(await eventually { !model.page(3).isRendering })
        #expect(model.page(3).frame == TestImages.frame(TestImages.blue))
        #expect(model.page(1).isRendering && model.page(2).isRendering)

        await release.open()
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(TestImages.red))
        #expect(model.page(2).frame == TestImages.frame(TestImages.red))
    }

    @Test func atMostTwoPhotosDecodeAtATime() async {
        let decoding = Concurrency(), release = Gate()
        let model = makeModel()
        for page in 1...3 {
            model.load(PhotoSource(name: "p\(page).png") {
                FetchedPhoto(name: nil) {
                    await decoding.enter()
                    await release.wait()
                    await decoding.leave()
                    return decoded(TestImages.red)
                }
            }, into: page)
        }
        #expect(await eventually { await decoding.current == 2 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await decoding.current == 2)  // the third one waits for a slot

        await release.open()
        await model.waitForRenders()
        #expect(await decoding.peak == 2)
        #expect(model.pages.prefix(3).allSatisfy { $0.frame == TestImages.frame(TestImages.red) })
    }

    @Test func photosFromDataAndFilesAreDecoded() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("blue.png")
        try TestImages.png(TestImages.blue).write(to: file)

        let model = makeModel()
        model.load(.data(TestImages.png(TestImages.red), name: "red.png"), into: 1)
        model.load(.file(file), into: 3)
        #expect(model.page(3).name == "blue.png")
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(TestImages.red))
        #expect(model.page(3).frame == TestImages.frame(TestImages.blue))
        #expect(model.page(1).name == "red.png" && model.page(3).name == "blue.png")
    }

    @Test func aNewerPhotoWinsOverAnOlderOneStillLoading() async {
        let started = Gate(), gate = Gate()
        let model = makeModel()
        model.load(PhotoSource(name: "slow.png") {
            await started.open()
            await gate.wait()
            return fetched(TestImages.red)
        }, into: 1)
        let stale = model.page(1).renderTask
        await started.wait()  // the old photo is loading now
        model.load(photo(TestImages.blue, name: "fast.png"), into: 1)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(TestImages.blue))

        await gate.open()
        await stale?.value
        #expect(model.page(1).frame == TestImages.frame(TestImages.blue))
        #expect(model.page(1).name == "fast.png")
        #expect(model.status(1) == "預覽為裝置實際顯示的 7 色效果")
    }

    @Test func changingAnOptionWhileLoadingDropsTheStaleRender() async {
        let started = Gate(), gate = Gate()
        let calls = Counter()
        let image = TestImages.gradient(160, 100)
        let model = makeModel()
        model.load(PhotoSource(name: "a.png") {
            if await calls.next() == 1 {  // only the first render is slow
                await started.open()
                await gate.wait()
            }
            return fetched(image)
        }, into: 1)
        let stale = model.page(1).renderTask
        await started.wait()
        model.setGrain(.smoothest)
        await model.waitForRenders()
        let smoothest = TestImages.frame(image, strength: 0.5)
        #expect(smoothest != TestImages.frame(image, strength: 1.0))  // what the stale render makes
        #expect(model.page(1).frame == smoothest)

        await gate.open()
        await stale?.value
        #expect(model.page(1).frame == smoothest)
        #expect(!model.page(1).isRendering)
    }

    @Test func everyGrainLevelReachesTheEncoder() async {
        let image = TestImages.gradient(160, 100)
        let model = makeModel()
        model.load(photo(image), into: 1)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(image, strength: 1.0))
        var crcs: Set<UInt32> = []
        for (grain, strength) in [(Grain.soft, 0.8), (.softer, 0.65), (.smoothest, 0.5), (.standard, 1.0)] {
            model.setGrain(grain)
            #expect(model.grain == grain && model.page(1).isRendering)
            await model.waitForRenders()
            #expect(model.page(1).frame == TestImages.frame(image, strength: strength), "\(grain)")
            if let frame = model.page(1).frame { crcs.insert(frame.crc32) }
        }
        #expect(crcs.count == 4)  // each level gives its own frame
    }

    @Test func changingOptionsRecomputesPreviews() async {
        let tall = TestImages.gradient(100, 400)
        let model = makeModel()
        model.load(photo(tall, name: "tall.png"), into: 1)
        await model.waitForRenders()
        let covered = model.page(1).frame
        model.setFit(.contain)
        #expect(model.fit == .contain && model.page(1).isRendering && model.page(1).frame == nil)
        await model.waitForRenders()
        let contained = model.page(1).frame
        #expect(contained != nil && contained != covered)
        #expect(contained?.bytes.prefix(10) == Data(repeating: 0x11, count: 10))  // white margin on the left
        model.setGrain(.smoothest)
        await model.waitForRenders()
        let smoothest = TestImages.frame(tall, fit: .contain, strength: 0.5)
        #expect(model.page(1).frame == smoothest)
        #expect(smoothest != contained)
        #expect(model.grain == .smoothest)
    }

    /// 經典 keeps the grain; changing to 自然 starts again from 標準. Both are kept and redraw the photos.
    @Test func naturalStartsFromStandardGrainAndClassicKeepsIt() async {
        let image = TestImages.gradient(160, 100)
        let model = makeModel()
        model.load(photo(image), into: 1)
        await model.waitForRenders()
        model.setGrain(.softer)
        await model.waitForRenders()
        model.setColours(.classic)
        #expect(model.colours == .classic && model.grain == .softer && model.page(1).isRendering)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(image, strength: 0.65, colours: .classic))
        #expect(makeModel().colours == .classic && makeModel().grain == .softer)

        model.setGrain(.smoothest)
        model.setColours(.natural)
        #expect(model.colours == .natural && model.grain == .standard && model.page(1).isRendering)
        #expect(model.settings.grain == 1 && makeModel().colours == .natural && makeModel().grain == .standard)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(image, colours: .natural))

        model.setGrain(.soft)
        model.setColours(.natural)  // already 自然: nothing changes
        #expect(model.grain == .soft && model.settings.grain == 0.8)
    }

    @Test func decodedPhotosAreReusedWhenOptionsChange() async {
        let fetches = Counter(), decodes = Counter()
        let model = makeModel()
        model.load(PhotoSource(name: "a.png") {
            _ = await fetches.next()
            return FetchedPhoto(name: nil) {
                _ = await decodes.next()
                return decoded(TestImages.red)
            }
        }, into: 1)
        await model.waitForRenders()
        model.setFit(.contain)
        await model.waitForRenders()
        #expect(await fetches.value == 1)
        #expect(await decodes.value == 1)
        #expect(model.page(1).frame == TestImages.frame(TestImages.red, fit: .contain))
    }

    @Test func unreadableFileIsReportedBrieflyOnTheTile() async throws {
        let directory = try temporaryDirectory()
            .appendingPathComponent(String(repeating: "a-very-long-folder-name-", count: 6), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let bad = directory.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: bad)

        let model = makeModel()
        model.load(.file(bad), into: 1)
        await model.waitForRenders()
        let page = model.page(1)
        #expect(model.statusText(of: page) == "無法讀取 notes.txt：不支援的檔案格式")
        #expect(!model.statusText(of: page).contains(directory.path))
        #expect(page.failed && !page.hasPhoto && page.frame == nil && page.name == nil)
        #expect(!model.canPush)
    }

    @Test func clearEmptiesThePageAndDropsItsRender() async {
        let started = Gate(), gate = Gate()
        let model = await modelWithPhotos([1])
        model.load(PhotoSource(name: "slow.png") {
            await started.open()
            await gate.wait()
            return fetched(TestImages.blue)
        }, into: 2)
        let stale = model.page(2).renderTask
        await started.wait()
        model.clear(page: 2)
        model.clear(page: 1)
        for page in [model.page(1), model.page(2)] {
            #expect(page.frame == nil && page.preview == nil && page.name == nil && !page.hasPhoto)
            #expect(page.status == .blank && page.percent == 0 && !page.isRendering)
        }
        await gate.open()
        await stale?.value
        #expect(model.page(2).frame == nil)
        #expect(!model.canPush)
    }

    // MARK: push

    @Test func pushSendsFramesAndShowsProgress() async {
        let service = FakePushService()
        let model = await modelWithPhotos([1, 4], service: service)
        #expect(model.canPush)
        await model.push()

        let pushed = await service.pushed
        #expect(pushed.count == 1)
        #expect(pushed.first == model.frames())
        #expect(Set(pushed.first.map { Array($0.keys) } ?? []) == [1, 4])
        #expect(model.status(1) == "完成" && model.page(1).percent == 100)
        #expect(model.status(4) == "完成" && model.page(4).percent == 100)
        #expect(model.status(2).isEmpty && model.page(2).percent == 0)
        #expect(model.summaryText == "完成：2 頁已更新，0 頁原本就相同。")
        #expect(model.deviceStatusText == "裝置狀態：剛完成推送（按「讀取狀態」可更新）")
        #expect(model.alert == nil)
        #expect(model.job == nil && model.canPush)
    }

    @Test func updatingAPageSendsOnlyThatPage() async {
        let service = FakePushService()
        let model = await modelWithPhotos([1, 4], service: service)
        #expect(!model.canPush(page: model.page(2)))  // no photo
        await model.push(page: 2)
        #expect(await service.pushed.isEmpty)

        await model.push(page: 4)
        #expect(await service.pushed == [[4: model.page(4).frame!]])
        #expect(model.status(4) == "完成" && model.page(4).percent == 100)
        #expect(model.status(1) == "預覽為裝置實際顯示的 7 色效果" && model.page(1).percent == 0)  // untouched
        #expect(model.summaryText == "完成：1 頁已更新，0 頁原本就相同。")
        #expect(model.job == nil && model.canPush(page: model.page(1)))
    }

    @Test func pushSummaryCountsUnchangedPages() async {
        let service = FakePushService(push: { frames, progress in
            progress(PushEvent(page: 1, phase: .unchanged, index: 0, count: 2, sent: 10, total: 10))
            progress(PushEvent(page: 3, phase: .done, index: 1, count: 2, sent: 10, total: 10))
            progress(PushEvent(page: 3, phase: .refreshing, index: 1, count: 2, sent: 10, total: 10))
            return [1: .unchanged, 3: .ok]
        })
        let model = await modelWithPhotos([1, 3], service: service)
        await model.push()
        #expect(model.summaryText == "完成：1 頁已更新，1 頁原本就相同。")
        #expect(model.status(1) == "已是這張照片，略過")
        #expect(model.status(3) == "完成（畫面約需 40 秒刷新）")
    }

    @Test func progressIsShownInOrderBeforeTheResult() async {
        let service = FakePushService(push: { frames, progress in
            for sent in stride(from: 0, through: 1000, by: 10) {
                progress(PushEvent(page: 2, phase: .sending, index: 0, count: 1, sent: sent, total: 1000))
            }
            progress(PushEvent(page: 2, phase: .done, index: 0, count: 1, sent: 1000, total: 1000))
            return [2: .ok]
        })
        let model = await modelWithPhotos([2], service: service)
        await model.push()
        #expect(model.status(2) == "完成" && model.page(2).percent == 100)
    }

    @Test func pagesWaitWhileThePushConnects() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(push: { frames, _ in
            await started.open()
            await release.wait()
            return frames.mapValues { _ in .ok }
        })
        let model = await modelWithPhotos([1, 3], service: service)
        let push = Task { await model.push() }
        await started.wait()
        #expect(model.status(1) == "等待中" && model.status(3) == "等待中")
        #expect(model.status(2).isEmpty)
        #expect(model.summaryText == "連線並推送中…（正在顯示的那一頁會最後傳）")
        #expect(model.isPushing)
        await release.open()
        await push.value
        #expect(!model.isPushing)
    }

    @Test func optionsPhotosAndButtonsAreLockedDuringAPush() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(push: { frames, _ in
            await started.open()
            await release.wait()
            return frames.mapValues { _ in .ok }
        })
        let model = await modelWithPhotos([1], service: service)
        let frame = model.page(1).frame
        let push = Task { await model.push() }
        await started.wait()

        #expect(model.job == .push && model.isBusy)
        #expect(!model.canPush && !model.canEdit)
        model.setFit(.contain)
        model.setGrain(.smoothest)
        model.setColours(.classic)
        model.load(photo(TestImages.blue), into: 2)
        model.clear(page: 1)
        await model.readInfo()  // refused: one job at a time
        await model.push()      // refused too
        #expect(model.fit == .cover && model.grain == .standard && model.colours == .natural)
        #expect(model.page(1).frame == frame && model.page(2).frame == nil && !model.page(2).isRendering)
        #expect(await service.infoCalls == 0)
        #expect(await service.pushed.count == 1)

        await release.open()
        await push.value
        #expect(model.job == nil && model.canEdit && model.canPush)
        model.setFit(.contain)
        #expect(model.fit == .contain)
        await model.waitForRenders()
    }

    @Test func screenStaysAwakeWhileAJobRuns() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(push: { frames, _ in
            await started.open()
            await release.wait()
            throw UlaniError.linkLost("gone")
        })
        let model = await modelWithPhotos([1], service: service)
        #expect(!keepAwake.isActive)
        let push = Task { await model.push() }
        await started.wait()
        #expect(keepAwake.isActive)
        await release.open()
        await push.value
        #expect(keepAwake.begun == 1 && keepAwake.ended == 1)  // ended after an error, too

        await model.readInfo()
        #expect(keepAwake.begun == 2 && keepAwake.ended == 2)
    }

    @Test func pushFailureShowsAFriendlyError() async {
        let service = FakePushService(push: { _, _ in
            throw UlaniError.connectFailed(attempts: 4, last: "no e-paper device found (is Bluetooth on and the device nearby?)")
        })
        let model = await modelWithPhotos([3], service: service)
        await model.push()
        #expect(model.alertTitle == "推送失敗")
        #expect(model.alertMessage?.contains("找不到裝置") == true)
        #expect(model.summaryText == "推送失敗，請看錯誤訊息後再試一次。")
        #expect(model.status(3) == "未完成")
        #expect(model.canPush)  // can retry
    }

    @Test func failedPushMarksEveryUnfinishedPage() async {
        let service = FakePushService(push: { _, progress in
            progress(PushEvent(page: 1, phase: .start, index: 0, count: 3, sent: 0, total: 10))
            progress(PushEvent(page: 1, phase: .done, index: 0, count: 3, sent: 10, total: 10))
            progress(PushEvent(page: 2, phase: .start, index: 1, count: 3, sent: 0, total: 10))
            progress(PushEvent(page: 2, phase: .sending, index: 1, count: 3, sent: 4, total: 10))
            // waits for the header of the next page, then gives up
            throw PushError(page: 2, completed: [1: .ok], underlying: .deviceBusy(what: "an image for page 2"))
        })
        let model = await modelWithPhotos([1, 2, 4], service: service)
        await model.push()
        #expect(model.status(1) == "完成" && model.page(1).percent == 100)
        #expect(model.status(2) == "未完成" && model.page(2).percent == 40)  // keeps its progress
        #expect(model.status(4) == "未完成" && model.page(4).percent == 0)
        #expect(model.status(3).isEmpty)
        #expect(model.alertMessage?.contains("沒有回應") == true)
    }

    // MARK: status

    @Test func readInfoShowsBatteryAndPage() async {
        let service = FakePushService(info: {
            CalendarStatus(battery: Battery(level: 4, charging: false), shown: 3)
        })
        let model = makeModel(service)
        await model.readInfo()
        #expect(model.deviceStatusText == "裝置狀態：電量 4/5，目前顯示第 3 頁")
        #expect(model.job == nil)
    }

    @Test func showOnDeviceSaysWhatTheDeviceShows() async {
        let service = FakePushService()  // the device shows page 1
        let model = makeModel(service)
        await model.display(page: 1)
        #expect(model.deviceStatusText == "裝置已經在顯示第 1 頁。")
        await model.display(page: 2)
        #expect(model.deviceStatusText == "已切換到第 2 頁，裝置畫面重畫約需 40 秒。")
        #expect(await service.displayed == [1, 2])
        #expect(model.job == nil && model.alert == nil)

        let failing = makeModel(FakePushService(display: { _ in throw UlaniError.notFound }))
        await failing.display(page: 2)
        #expect(failing.alertTitle == "無法在裝置上顯示這一頁")
        #expect(failing.alertMessage?.contains("找不到裝置") == true)
    }

    @Test func readInfoShowsConnectingThenUnreachable() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(info: {
            await started.open()
            await release.wait()
            throw UlaniError.notFound
        })
        let model = makeModel(service)
        let read = Task { await model.readInfo() }
        await started.wait()
        #expect(model.deviceStatusText == "裝置狀態：連線中…")
        #expect(model.job == .info && !model.canEdit)
        await release.open()
        await read.value
        #expect(model.deviceStatusText == "裝置狀態：連不上")
        #expect(model.alertTitle == "讀取狀態失敗")
        #expect(model.alertMessage?.contains("找不到裝置") == true)
    }

    @Test func deviceLineDoesNotStayUnreachableAfterAPush() async {
        let service = FakePushService(info: { throw UlaniError.notFound })
        let model = await modelWithPhotos([1], service: service)
        await model.readInfo()
        #expect(model.deviceStatusText == "裝置狀態：連不上")
        model.alert = nil
        await model.push()
        #expect(model.deviceStatusText.contains("剛完成推送"))
    }

    // MARK: quitting

    @Test func quittingDuringAPushAsksFirst() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(push: { frames, _ in
            await started.open()
            await release.wait()
            return frames.mapValues { _ in .ok }
        })
        let model = await modelWithPhotos([1], service: service)
        var asked = 0
        #expect(model.confirmQuit(ask: { _ in asked += 1; return false }) == .terminateNow)
        #expect(asked == 0)  // nothing to interrupt

        let push = Task { await model.push() }
        await started.wait()
        #expect(model.confirmQuit(ask: { _ in asked += 1; return false }) == .terminateCancel)
        #expect(model.confirmQuit(ask: { _ in asked += 1; return true }) == .terminateNow)
        #expect(asked == 2)
        await release.open()
        await push.value
    }

    /// Closing the macOS app's only window quits it, so the window is already gone when
    /// 「仍在傳送」 shows: keeping the push must bring it back (Python keeps the window open).
    @Test func keepingAPushReopensTheWindow() async {
        let started = Gate(), release = Gate()
        let service = FakePushService(push: { frames, _ in
            await started.open()
            await release.wait()
            return frames.mapValues { _ in .ok }
        })
        let model = await modelWithPhotos([1], service: service)
        var reopened = 0
        #expect(model.confirmQuit(ask: { _ in false }, keepSending: { reopened += 1 }) == .terminateNow)
        #expect(reopened == 0)  // nothing to keep

        let push = Task { await model.push() }
        await started.wait()
        #expect(model.confirmQuit(ask: { _ in true }, keepSending: { reopened += 1 }) == .terminateNow)
        #expect(reopened == 0)  // quitting anyway
        #expect(model.confirmQuit(ask: { _ in false }, keepSending: { reopened += 1 }) == .terminateCancel)
        #expect(reopened == 1)
        #expect(model.isPushing)
        await release.open()
        await push.value
    }
}

extension PushViewModel {
    /// The text under `page`'s progress bar.
    func status(_ page: Int) -> String { statusText(of: self.page(page)) }
}
