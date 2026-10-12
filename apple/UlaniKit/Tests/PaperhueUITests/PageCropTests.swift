import CoreGraphics
import Foundation
import Testing
import UlaniKit
@testable import PaperhueUI

/// A page's crop in the view model: kept per page in memory, reset by a new photo, ignored but
/// kept by Fit, and rendered exactly as the encoder renders it.
@MainActor
@Suite struct PageCropTests {
    let keepAwake = FakeKeepAwake()
    let defaults = TestDefaults()

    /// 400x300: the centred crop is 400x240 px and a crop needs 100 px, so there is room to
    /// zoom and move.
    nonisolated static let image = TestImages.gradient(400, 300)
    nonisolated static let size = PhotoSize(width: 400, height: 300)

    /// Zoomed 2x towards the bottom right: another frame than the centred one.
    nonisolated static let crop = CropGeometry(photo: size).zoomed(to: 2, about: CGPoint(x: 0.9, y: 0.9)).crop

    func makeModel(_ service: FakePushService = FakePushService()) -> PushViewModel {
        PushViewModel(service: service, keepAwake: keepAwake, defaults: defaults.defaults,
                      preferredLanguages: ["zh-Hant-TW"])
    }

    /// A model with `image` rendered on page 1.
    func modelWithPhoto(_ service: FakePushService = FakePushService()) async -> PushViewModel {
        let model = makeModel(service)
        model.load(photo(Self.image), into: 1)
        await model.waitForRenders()
        return model
    }

    @Test func theCropIsAFrameOfThisPhoto() {
        #expect(Self.crop != Crop.centred(width: 400, height: 300))
        #expect(throws: Never.self) { try Self.crop.validated(width: 400, height: 300) }
        #expect(TestImages.frame(Self.image, crop: Self.crop) != TestImages.frame(Self.image))
    }

    // MARK: 調整範圍… enabled

    @Test func adjustingNeedsADecodedPhotoInFillAndNoJob() async {
        let fetching = Gate(), release = Gate(), pushing = Gate(), pushed = Gate()
        let service = FakePushService(push: { frames, _ in
            await pushing.open()
            await pushed.wait()
            return frames.mapValues { _ in .ok }
        })
        let model = makeModel(service)
        let page = model.page(1)
        #expect(!model.canAdjustCrop(page) && model.cropGeometry(for: 1) == nil)  // no photo

        model.load(PhotoSource(name: "slow.png") {
            await fetching.open()
            await release.wait()
            return fetched(Self.image)
        }, into: 1)
        await fetching.wait()
        #expect(page.hasPhoto && !model.canAdjustCrop(page))  // not decoded yet
        #expect(page.photoImage == nil && page.photoSize == nil)
        await release.open()
        await model.waitForRenders()
        #expect(model.canAdjustCrop(page))
        #expect(page.photoImage === Self.image && page.photoSize == Self.size)
        #expect(model.cropGeometry(for: 1) == CropGeometry(photo: Self.size))

        model.setFit(.contain)
        #expect(!model.canAdjustCrop(page) && model.cropGeometry(for: 1) == nil)
        model.setFit(.cover)
        #expect(model.canAdjustCrop(page))
        // While a re-render runs, the decoded photo is still there.
        model.setGrain(.soft)
        #expect(page.isRendering && model.canAdjustCrop(page))
        await model.waitForRenders()

        let push = Task { await model.push() }
        await pushing.wait()
        #expect(!model.canAdjustCrop(page) && model.cropGeometry(for: 1) == nil)
        model.setCrop(Self.crop, for: 1)  // refused during a job
        #expect(page.crop == nil && !page.isRendering)
        await pushed.open()
        await push.value
        #expect(model.canAdjustCrop(page))
        #expect(model.cropGeometry(for: 0) == nil && model.cropGeometry(for: 5) == nil)
    }

    @Test func anUnreadablePhotoCannotBeCropped() async {
        let model = makeModel()
        model.load(.data(Data("not an image".utf8), name: "notes.txt"), into: 2)
        await model.waitForRenders()
        #expect(model.page(2).failed && !model.canAdjustCrop(model.page(2)))
        model.setCrop(Self.crop, for: 2)
        #expect(model.page(2).crop == nil)
    }

    // MARK: OK and Reset

    @Test func okRendersThePageWithItsCrop() async {
        let model = await modelWithPhoto()
        let page = model.page(1)
        let centred = page.frame
        #expect(centred == TestImages.frame(Self.image))
        model.setCrop(Self.crop, for: 1)
        #expect(page.crop == Self.crop && page.isRendering && page.frame == nil)
        await model.waitForRenders()
        // Exactly what the encoder gives for that crop.
        #expect(page.frame == TestImages.frame(Self.image, crop: Self.crop))
        #expect(page.frame != centred)
        #expect(page.preview?.width == 800 && model.status(1) == "預覽為裝置實際顯示的 7 色效果")
        #expect(model.cropGeometry(for: 1)?.crop == Self.crop)
        #expect(model.canPush)
        // The same crop again changes nothing.
        let generation = page.generation
        model.setCrop(Self.crop, for: 1)
        #expect(!page.isRendering && page.generation == generation)
    }

    @Test func resetRendersThePageAsWithoutACrop() async {
        let model = await modelWithPhoto()
        model.setCrop(Self.crop, for: 1)
        await model.waitForRenders()
        model.resetCrop(page: 1)
        #expect(model.page(1).crop == nil && model.page(1).isRendering)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(Self.image))
        #expect(model.cropGeometry(for: 1) == CropGeometry(photo: Self.size))

        // The editor's Reset then OK: the centred frame, which it hands over as nil.
        model.setCrop(Self.crop, for: 1)
        await model.waitForRenders()
        let editor = model.cropGeometry(for: 1)!.reset()
        model.setCrop(editor.result, for: 1)
        await model.waitForRenders()
        #expect(editor.result == nil && model.page(1).crop == nil)
        #expect(model.page(1).frame == TestImages.frame(Self.image))
    }

    @Test func aCropMustSuitThePhoto() async {
        let model = await modelWithPhoto()
        let tooSmall = CropGeometry(photo: PhotoSize(width: 4000, height: 3000)).zoomed(to: 8, about: CGPoint(x: 0.5, y: 0.5)).crop
        for bad in [Crop(left: 0, top: 0, width: 0.5, height: 0.5), Crop(left: 0.7, top: 0, width: 0.5, height: 0.4), tooSmall,
                    Crop(left: .nan, top: 0, width: 0.5, height: 0.4)] {
            model.setCrop(bad, for: 1)
            #expect(model.page(1).crop == nil && !model.page(1).isRendering, "\(bad)")
        }
    }

    /// The crop's fractions, its minimum and its zoom limit refer to the photo after the 4K
    /// cap, never to the smaller decoded copy.
    @Test func cropsReferToTheCappedPhotoNotTheDecodedCopy() async {
        let capped = PhotoSize(width: 4000, height: 3000)
        let model = makeModel()
        model.load(photo(Self.image, size: capped), into: 1)
        await model.waitForRenders()
        #expect(model.page(1).photoSize == capped)
        let geometry = model.cropGeometry(for: 1)!
        #expect(geometry.photo == capped && geometry.maximumZoom == 8)
        // 8x: 500x300 photo pixels, 50x30 in the decoded copy (which alone would allow only
        // 2.4x).
        let deep = geometry.zoomed(to: 8, about: CGPoint(x: 0.25, y: 0.75)).crop
        #expect((try? deep.validated(width: 400, height: 300)) == nil)
        model.setCrop(deep, for: 1)
        #expect(model.page(1).crop == deep)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(Self.image, crop: deep))
    }

    @Test func aPhotoFileGivesItsSizeFromTheHeader() async {
        let model = makeModel()
        model.load(.data(TestImages.png(Self.image), name: "a.png"), into: 3)
        await model.waitForRenders()
        #expect(model.page(3).photoSize == Self.size)
        #expect(model.cropGeometry(for: 3)?.photo == Self.size)
    }

    // MARK: kept and reset

    @Test func aNewPhotoOrAClearResetsTheCrop() async {
        let model = await modelWithPhoto()
        model.setCrop(Self.crop, for: 1)
        await model.waitForRenders()
        model.load(photo(TestImages.gradient(300, 400), name: "b.png"), into: 1)
        #expect(model.page(1).crop == nil)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(TestImages.gradient(300, 400)))
        #expect(model.cropGeometry(for: 1) == CropGeometry(photo: PhotoSize(width: 300, height: 400)))

        model.load(photo(Self.image), into: 1)
        await model.waitForRenders()
        model.setCrop(Self.crop, for: 1)
        await model.waitForRenders()
        model.clear(page: 1)
        #expect(model.page(1).crop == nil && !model.canAdjustCrop(model.page(1)))
    }

    @Test func eachPageHasItsOwnCrop() async {
        let model = makeModel()
        for page in [1, 2] {
            model.load(photo(Self.image), into: page)
        }
        await model.waitForRenders()
        model.setCrop(Self.crop, for: 2)
        await model.waitForRenders()
        #expect(model.page(1).crop == nil && model.page(2).crop == Self.crop)
        #expect(model.page(1).frame == TestImages.frame(Self.image))
        #expect(model.page(2).frame == TestImages.frame(Self.image, crop: Self.crop))
    }

    @Test func fitIgnoresTheCropButKeepsIt() async {
        let model = await modelWithPhoto()
        model.setCrop(Self.crop, for: 1)
        await model.waitForRenders()
        model.setFit(.contain)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(Self.image, fit: .contain))
        #expect(model.page(1).crop == Self.crop)
        model.setGrain(.smoothest)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(Self.image, fit: .contain, strength: 0.5))
        model.setFit(.cover)
        await model.waitForRenders()
        #expect(model.page(1).frame == TestImages.frame(Self.image, crop: Self.crop, strength: 0.5))
        #expect(model.cropGeometry(for: 1)?.crop == Self.crop)
    }

    /// Like an option change, a crop supersedes a render still waiting or running, and the
    /// renders that follow keep it.
    @Test func aCropSetWhileRenderingSupersedesTheRender() async {
        let decoding = Concurrency(), release = Gate()
        let model = await modelWithPhoto()
        // Two slow photos hold both render slots, so page 1's next render waits.
        for page in [2, 3] {
            model.load(PhotoSource(name: "p\(page).png") {
                FetchedPhoto(name: nil) {
                    await decoding.enter()
                    await release.wait()
                    return decoded(TestImages.red)
                }
            }, into: page)
        }
        #expect(await eventually { await decoding.current == 2 })
        model.setGrain(.softer)
        let stale = model.page(1).renderTask
        #expect(model.page(1).isRendering)
        model.setCrop(Self.crop, for: 1)
        #expect(model.page(1).renderTask != stale && model.page(1).isRendering)

        await release.open()
        await model.waitForRenders()
        await stale?.value
        #expect(model.page(1).frame == TestImages.frame(Self.image, crop: Self.crop, strength: 0.65))
        #expect(model.page(2).frame == TestImages.frame(TestImages.red, strength: 0.65))
    }

    @Test func theCropReachesThePush() async {
        let service = FakePushService()
        let model = await modelWithPhoto(service)
        model.setCrop(Self.crop, for: 1)
        await model.waitForRenders()
        await model.push()
        #expect(await service.pushed == [[1: TestImages.frame(Self.image, crop: Self.crop)]])
    }
}
