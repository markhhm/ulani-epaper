import CoreGraphics
import Foundation
import ImageIO
import Testing
import PaperhueAgenda
import UniformTypeIdentifiers
import UlaniKit
@testable import PaperhuePages

/// The card model, the store and the .paperhue-card file (shared/CARDS.md). Ports
/// python/tests/test_cards.py (the store sits in a folder the app chooses, so the config-folder
/// cases become "the folder it is given"); the messages and the files are the Python
/// reference's (Differential/card-expectations.json, exported.paperhue-card). Each test gets its
/// own instance and with it a fresh folder, removed afterwards.
@Suite final class CardTests: Sendable {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paperhue-cards-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func store(_ name: String = "cfg") -> CardStore { CardStore(folder: folder.appendingPathComponent(name)) }

    // MARK: The card and its JSON

    /// cards.json as the reference writes the four fixtures, byte for byte, both ways.
    @Test func theCardsFileIsTheReferencesBothWays() throws {
        let fixtures = try CardRepo.names.map(CardRepo.fixture)
        let expected = try CardExpectations.load().file
        let mac = store("mac"), windows = store("windows")
        try mac.save(fixtures)
        #expect(try String(contentsOf: mac.url, encoding: .utf8) == expected)
        try FileManager.default.createDirectory(at: windows.folder, withIntermediateDirectories: true)
        try expected.write(to: windows.url, atomically: true, encoding: .utf8)
        #expect(try windows.load() == fixtures)
    }

    @Test(arguments: CardRepo.names)
    func aFixtureRoundTrips(name: String) throws {
        let card = try CardRepo.fixture(name)
        #expect(try Card.parse(Data(card.json.utf8)) == card)
    }

    @Test func missingFieldsTakeTheirDefaults() throws {
        let card = try Card.parse(Data(card(background: "{}").utf8))
        #expect(card == Card(id: "a1b2c3d4", background: CardBackground(color: .white),
                             texts: [CardText("x", box: .init(x: 0, y: 0, width: 1, height: 1), size: 48, color: .black,
                                              outline: false, outlineColor: .white, align: .center)]))
        #expect(card.json.contains(#""box": [\#n    0.0,"#))  // numbers are floats, as Python writes them
    }

    /// The JSON's rules, each refused with the reference's message (cards.parse's ValueError, in
    /// Python's order: the first rule broken is the one reported).
    @Test func badCardsAreRefusedWithTheReferencesMessages() {
        let nine = "[" + (0..<9).map { #"{"text": "\#($0)", "box": [0, 0, 1, 1]}"# }.joined(separator: ", ") + "]"
        let inks = "black, white, green, blue, red, yellow, orange"
        let cases: [(String, String)] = [
            (card(texts: nine), "每張牌卡最多 8 個文字框（目前 9 個）"),
            (card(text: "\"\(String(repeating: "字", count: 81))\""), "每個文字框最多 80 字（目前 81 字）"),
            (card(text: #""  ""#), "文字框是空的"),
            (card(extra: #", "color": "purple""#), "文字顏色必須是 \(inks) 之一，收到 'purple'"),
            (card(extra: #", "outline_color": "grey""#), "外框顏色必須是 \(inks) 之一，收到 'grey'"),
            (card(extra: #", "align": "justify""#), "對齊必須是 left, center, right 之一，收到 'justify'"),
            (card(extra: #", "size": 5"#), "字級必須是 12 到 240 的整數，收到 5"),
            (card(extra: #", "size": 48.0"#), "字級必須是 12 到 240 的整數，收到 48.0"),
            (card(extra: #", "size": true"#), "字級必須是 12 到 240 的整數，收到 True"),
            (card(box: "[0.5, 0.2, 0.8, 0.3]"), "文字框必須在畫面內（0 到 1 的比例），收到 (0.5, 0.2, 0.8, 0.3)"),
            (card(box: "[0, 0, 1]"), "文字框的位置要有 4 個數字，收到 (0, 0, 1)"),
            (card(box: "[0, 0, true, 1]"), "文字框的位置要有 4 個數字，收到 (0, 0, True, 1)"),
            (card(background: #"{"color": "pink"}"#), "背景顏色必須是 \(inks) 之一，收到 'pink'"),
            (card(background: #"{"image": "../x.jpg"}"#), "背景圖必須是單純的檔名（jpg 或 png），收到 '../x.jpg'"),
            (card(background: #"{"image": "x.jpg", "crop": [0, 0, 2, 1]}"#),
             "裁切範圍必須在畫面內（0 到 1 的比例），收到 (0.0, 0.0, 2.0, 1.0)"),
            (card(background: #"{"image": "x.jpg", "crop": [0, 0, "a", 1]}"#), "裁切範圍要有 4 個數字，收到 (0, 0, 'a', 1)"),
            (card(extra: #", "outline": 1"#), "outline 必須是 true 或 false"),
            (card(text: "5"), "文字必須是字串"),
            (card(version: "2"), "unknown version 2"),
            (card(id: #""A1B2C3D4""#), "card ids are 8 hex characters, got 'A1B2C3D4'"),
            (card(id: "12345678"), "card ids are 8 hex characters, got 12345678"),
            (card(extra: #", "color": null"#), "文字顏色必須是 \(inks) 之一，收到 None"),
            (card(text: #""""#, extra: #", "color": "purple""#), "文字框是空的"),
            (card(background: #"{"color": "pink"}"#, texts: nine), "背景顏色必須是 \(inks) 之一，收到 'pink'"),
            (card(background: #"{"image": "a\u0301.jpg"}"#), "背景圖必須是單純的檔名（jpg 或 png），收到 'a\u{301}.jpg'"),
            (card(background: #"{"image": "x.jpg\n"}"#), #"背景圖必須是單純的檔名（jpg 或 png），收到 'x.jpg\n'"#),
        ]
        for (json, message) in cases {
            #expect(cardError { _ = try Card.parse(Data(json.utf8)) }?.description == message, "\(json)")
        }
        for json in ["[]", "{", #"{"version": 1}"#, card(background: "[]"), card(texts: "5"), card(box: "5"),
                     card(background: #"{"image": "x.jpg", "crop": 5}"#),
                     #"{"version": 1, "background": {}, "texts": []}"#] {
            guard case .notACard = cardError({ _ = try Card.parse(Data(json.utf8)) }) else {
                Issue.record("\(json) is not refused as not a card")
                continue
            }
        }
    }

    /// The rules a card built in the app can break (its colours and alignment cannot be wrong).
    @Test func aCardMadeInTheAppIsChecked() throws {
        let cases: [(Card, CardError)] = [
            (Card(texts: (0..<9).map { box("\($0)") }), .tooManyTexts(count: 9)),
            (Card(texts: [box(String(repeating: "字", count: 81))]), .textTooLong(count: 81)),
            (Card(texts: [box("  ")]), .emptyText),
            (Card(texts: [box(size: 5)]), .badSize("5")),
            (Card(texts: [box(size: 241)]), .badSize("241")),
            (Card(texts: [CardText("x", box: .init(x: 0.5, y: 0.2, width: 0.8, height: 0.3))]),
             .boxOutside("(0.5, 0.2, 0.8, 0.3)")),
            (Card(texts: [CardText("x", box: .init(x: 0, y: 0, width: .infinity, height: 1))]),
             .boxNotNumbers("(0.0, 0.0, inf, 1.0)")),
            (Card(texts: [CardText("x", box: .init(x: 0, y: 0, width: 0, height: 1))]), .boxOutside("(0.0, 0.0, 0.0, 1.0)")),
            (Card(background: CardBackground(image: "../x.jpg")), .badImageName("'../x.jpg'")),
            (Card(background: CardBackground(image: "x.gif")), .badImageName("'x.gif'")),
            (Card(background: CardBackground(image: "x.jpg", crop: Crop(left: 0.5, top: 0, width: 0.6, height: 1))),
             .cropOutside("(0.5, 0.0, 0.6, 1.0)")),
        ]
        for (card, error) in cases {
            #expect(cardError { _ = try card.checked() } == error)
        }
        #expect(try Card(texts: [box("  A\r\nB  ")]).checked().texts[0].text == "A\nB")
        let edge = { (w: Double) in Card(texts: [CardText("x", box: .init(x: 0.5, y: 0, width: w, height: 1))]) }
        #expect(try edge(0.5 + 1e-10).checked().texts.count == 1)  // rounding slack, as Python's
        #expect(cardError { _ = try edge(0.5 + 1e-8).checked() } == .boxOutside("(0.5, 0.0, 0.50000001, 1.0)"))
        let crop = Crop(left: 0.25, top: 0.25, width: 0.5, height: 0.5)
        #expect(try Card(background: CardBackground(crop: crop)).checked().background.crop == crop)  // a photo comes with add()
    }

    @Test func messagesComeInBothLanguages() {
        #expect(CardError.textTooLong(count: 81).message(inChinese: false)
                == "A text box can have at most 80 characters (this one has 81)")
        #expect(CardError.unknownColour(.outline, "'grey'").message(inChinese: false)
                == "The outline colour must be one of black, white, green, blue, red, yellow, orange, not 'grey'")
        let file = CardError.notACardFile(.entryTooBig("card.json"))
        #expect(file.message(inChinese: true) == "這不是有效的牌卡檔：card.json 太大")
        #expect(file.message(inChinese: false) == "This is not a valid card file: card.json is too big")
        #expect(CardError.noSuchCard("a1b2c3d4").errorDescription == "沒有這張牌卡：a1b2c3d4")
        #expect(CardError.unknownVersion("2").description == "unknown version 2")
    }

    // MARK: The store (test_cards.py)

    @Test func noFileMeansNoCards() throws {
        #expect(try store().load() == [])
    }

    @Test func roundTripAndFileShape() throws {
        let store = store()
        let card = try store.add(Card(texts: [box("開會中\n15:00 回來", size: 60, color: .white, outline: true, outlineColor: .black,
                                                  align: .left), box("Hi", color: .red)]))
        #expect(try store.load() == [card])
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        let saved = try #require((raw["cards"] as? [[String: Any]])?.first)
        #expect(raw["version"] as? Int == 1 && saved["id"] as? String == card.id && Card.isID(card.id))
        #expect(saved["background"] as? NSDictionary == ["color": "white"])
        #expect((saved["texts"] as? [NSDictionary])?.first == [
            "text": "開會中\n15:00 回來", "box": [0.1, 0.2, 0.8, 0.3], "size": 60, "color": "white", "outline": true,
            "outline_color": "black", "align": "left",
        ] as NSDictionary)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.folder.path) == ["cards.json"])  // no temporary files
    }

    @Test func invalidCardsAreRefusedAndNothingIsWritten() throws {
        let store = store()
        for bad in [Card(texts: (0..<9).map { box("\($0)") }), Card(texts: [box(String(repeating: "字", count: 81))]),
                    Card(texts: [box("  ")]), Card(texts: [box(size: 5)]),
                    Card(texts: [CardText("x", box: .init(x: 0.5, y: 0.2, width: 0.8, height: 0.3))]),
                    Card(background: CardBackground(image: "../x.jpg"))] {
            #expect(cardError { try store.add(bad) } != nil)
        }
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func textIsStoredNormalised() throws {
        #expect(try store().add(Card(texts: [box("  A\r\nB  ")])).texts[0].text == "A\nB")
    }

    @Test func idsAreNewAndUnique() throws {
        let tokens = Tokens(["00000001", "00000001", "00000002"])
        let store = CardStore(folder: folder, token: { tokens.next() })
        let a = try store.add(Card(id: "ffffffff", texts: [box("a")]))  // the id it has is ignored
        let b = try store.add(Card(texts: [box("b")]))
        #expect(try a.id == "00000001" && b.id == "00000002" && store.load() == [b, a])  // newest first
    }

    @Test func aPhotoIsCopiedInCappedAt4K() throws {
        let store = store()
        let crop = Crop(left: 0, top: 0, width: 5.0 / 6, height: 1)
        let card = try store.add(Card(background: CardBackground(crop: crop), texts: [box()]), photo: photo(5000, 2500))
        #expect(card.background == CardBackground(image: "\(card.id).jpg", crop: crop))
        #expect(try storedSize(store, card) == PhotoSize(width: 3840, height: 1920))  // capped like every photo
    }

    @Test func aCropMustSuitTheStoredPhoto() throws {
        let store = store()
        let crop = Crop(left: 0, top: 0, width: 0.5, height: 1)
        guard case .crop = cardError({ try store.add(Card(background: CardBackground(crop: crop)), photo: photo()) }) else {
            Issue.record("a crop of the wrong shape was taken")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func aBackgroundImageComesWithItsPhoto() throws {
        #expect(cardError { try self.store().add(Card(background: CardBackground(image: "x.jpg"))) } == .photoRequired)
    }

    @Test func updateChangesACardAndSwapsItsPhoto() throws {
        let store = store()
        let card = try store.add(Card(texts: [box("舊")]), photo: photo())
        let file = store.folder.appendingPathComponent("backgrounds/\(card.id).jpg")
        let changed = try store.update(Card(id: card.id, background: card.background, texts: [box("新")]))
        #expect(try store.get(card.id).texts[0].text == "新" && changed.background == card.background)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let other = try store.update(changed, photo: photo(1200, 720))  // a new photo, same file
        #expect(try other.background == card.background && storedSize(store, other) == PhotoSize(width: 1200, height: 720))
        let plain = try store.update(Card(id: card.id, background: CardBackground(color: .yellow), texts: changed.texts))
        #expect(plain.background == CardBackground(color: .yellow))
        #expect(!FileManager.default.fileExists(atPath: file.path))  // nothing refers to it any more
        #expect(cardError { try store.update(Card(id: "00000000", texts: [self.box()])) } == .noSuchCard("00000000"))
        #expect(cardError { try store.update(Card(id: card.id, background: CardBackground(image: "x.jpg"))) } == .photoRequired)
    }

    @Test func removeDeletesTheCardAndItsBackground() throws {
        let store = store()
        let a = try store.add(Card(texts: [box("a")]), photo: photo())
        let b = try store.add(Card(texts: [box("b")]))
        #expect(try store.remove(a.id) == a)
        #expect(try store.load() == [b])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.backgrounds.folder.path).isEmpty)
        #expect(cardError { try store.remove(a.id) } == .noSuchCard(a.id))
    }

    /// Not in cards.py: the app's 複製 (export and import in one step, without re-encoding the photo).
    @Test func duplicateCopiesTheCardAndItsPhoto() throws {
        let store = store()
        let card = try store.add(Card(background: CardBackground(crop: Crop(left: 0.5, top: 0, width: 0.5, height: 0.5)),
                                      texts: [box("牌")]), photo: photo())
        let copy = try store.duplicate(card.id)
        #expect(copy.id != card.id && copy.texts == card.texts && copy.background == CardBackground(
            image: "\(copy.id).jpg", crop: card.background.crop))
        #expect(try store.load() == [copy, card])
        let url = { (c: Card) in store.backgrounds.url(PageBackground(image: c.background.image!)) }
        #expect(try Data(contentsOf: url(copy)) == Data(contentsOf: url(card)))
        try store.remove(copy.id)
        #expect(FileManager.default.fileExists(atPath: url(card).path))
        let plain = try store.add(Card(texts: [box()]))
        #expect(try store.duplicate(plain.id).background == plain.background)
        #expect(cardError { try store.duplicate("00000000") } == .noSuchCard("00000000"))
    }

    @Test func aBrokenFileIsReportedAndNeverOverwritten() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try "{not json".write(to: store.url, atomically: true, encoding: .utf8)
        guard case .unreadableFile(let path, _) = cardError({ try store.add(Card(texts: [self.box()])) }) else {
            Issue.record("a broken file was not reported")
            return
        }
        #expect(path.hasSuffix("cards.json"))
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{not json")
        try #"{"version": 1, "cards": [{"version": 1, "id": "a1b2c3d4", "background": {"color": "pink"}, "texts": []}]}"#
            .write(to: store.url, atomically: true, encoding: .utf8)
        guard case .invalidFile = cardError({ _ = try store.load() }) else {
            Issue.record("an invalid card was not reported")
            return
        }
    }

    // MARK: Photos

    @Test func theBackgroundIsTheCropOfThePhotoDithered() throws {
        let store = store()
        let card = try store.add(Card(background: CardBackground(crop: Crop(left: 0.6, top: 0, width: 0.4, height: 0.4))),
                                 photo: photo())  // red left half, blue right half
        let frame = try #require(try store.background(of: card, strength: 1, colours: .classic))
        #expect(Set(frame.indices()) == [PanelColour.blue.index])  // only the right half's top, not the red
        #expect(try store.photo(of: card)?.size == PhotoSize(width: 1000, height: 600))
        #expect(try store.background(of: Card(), strength: 1, colours: .natural) == nil)
    }

    @Test func aMissingBackgroundFileIsReported() throws {
        let store = store()
        let card = try store.add(Card(), photo: photo())
        store.backgrounds.remove(PageBackground(image: card.background.image!))
        guard case .unreadablePhoto(let reason) = cardError({ _ = try store.background(of: card, strength: 1, colours: .natural) }) else {
            Issue.record("a missing photo was not reported")
            return
        }
        #expect(reason.contains(card.background.image!))
        #expect(cardError { _ = try store.exportCard(card.id) } == .missingPhoto(path: store.backgrounds.url(
            PageBackground(image: card.background.image!)).path))
    }

    // MARK: The .paperhue-card file

    @Test func exportAndImportRoundTripBetweenTwoFolders() throws {
        let a = store("a"), b = store("b")
        let card = try a.add(Card(background: CardBackground(crop: Crop(left: 0.5, top: 0, width: 0.5, height: 0.5)),
                                  texts: [box("牌", outline: true, outlineColor: .black)]), photo: photo())
        let file = try a.exportCard(card.id)
        let zip = try CardZip(file)
        let json = try zip.read("card.json", limit: CardStore.maxJSONBytes)
        var exported = card
        exported.background.image = "background.jpg"
        #expect(String(decoding: json, as: UTF8.self) == exported.json)
        #expect(try zip.read("background.jpg", limit: CardStore.maxImageBytes)
                == Data(contentsOf: a.backgrounds.url(PageBackground(image: card.background.image!))))
        let copy = try b.importCard(file)
        #expect(copy.id != card.id && copy.texts == card.texts && copy.background.crop == card.background.crop)
        #expect(try b.load() == [copy] && a.load() == [card])  // the original is untouched
        #expect(try storedSize(b, copy) == PhotoSize(width: 1000, height: 600))
        let again = try b.importCard(file)  // importing twice makes two cards
        #expect(try ![card.id, copy.id].contains(again.id) && b.load().count == 2)
        let plain = try a.add(Card(texts: [box()]))
        #expect(try b.importCard(a.exportCard(plain.id)).background == plain.background)
    }

    /// A file the Python reference exported (Differential/exported.paperhue-card, card.json
    /// deflated): it imports, and exported again its card.json is the reference's but for the id.
    @Test func aCardFileFromThePythonReferenceImports() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Differential/exported.paperhue-card")
        let file = try Data(contentsOf: url)
        let store = store()
        let card = try store.importCard(file)
        let crop = Crop(left: 0.25, top: 0.25, width: 0.5, height: 0.5)
        #expect(card.background == CardBackground(image: "\(card.id).jpg", crop: crop))
        #expect(card.texts == [CardText("我選擇繼續裝忙", box: .init(x: 0.04, y: 0.72, width: 0.92, height: 0.24), size: 52,
                                        color: .white, outline: true, outlineColor: .black)])
        #expect(try storedSize(store, card) == PhotoSize(width: 400, height: 240))
        let theirs = String(decoding: try CardZip(file).read("card.json", limit: CardStore.maxJSONBytes), as: UTF8.self)
        let ours = String(decoding: try CardZip(store.exportCard(card.id)).read("card.json", limit: CardStore.maxJSONBytes),
                          as: UTF8.self)
        let id = try #require(theirs.firstMatch(of: /"id": "([0-9a-f]{8})"/)?.output.1)
        #expect(ours == theirs.replacingOccurrences(of: String(id), with: card.id))
    }

    @Test func aCardFileMadeElsewhereImports() throws {
        let file = try CardZip.write([("card.json", Data(cardFileJSON(image: "background.jpg", crop: "[0, 0, 1, 1]").utf8), true),
                                      ("background.jpg", jpeg(), false)])
        let card = try store().importCard(file)
        #expect(card.background.image == "\(card.id).jpg")
    }

    /// Each is refused as `notACardFile`, and nothing is saved.
    @Test func badCardFilesAreRefusedAndImportNothing() throws {
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("not a zip", Data("not a zip".utf8)),
            ("a damaged download", try damaged(deflate: true) { data, _, _ in
                data.replaceSubrange(39..<59, with: [UInt8](repeating: 255, count: 20))  // not a deflate block
            }),
            ("an unknown compression", try damaged { data, i, central in data[i + (central ? 10 : 8)] = 99 }),
            ("encrypted", try damaged { data, i, central in data[i + (central ? 8 : 6)] |= 1 }),
            ("nested beyond what JSON reads", try zipped(["card.json": String(repeating: "[", count: 30_000)
                                                          + String(repeating: "]", count: 30_000)])),
            ("no card.json", try zipped(["other.txt": "x"])),
            ("not JSON", try zipped(["card.json": "{"])),
            ("the image is not in the zip", try zipped(["card.json": cardFileJSON(image: "background.jpg")])),
            ("a path", try zipped(["card.json": cardFileJSON(image: "../evil.jpg"), "../evil.jpg": "x"])),
            ("not an image", try zipped(["card.json": cardFileJSON(image: "background.jpg"), "background.jpg": "not an image"])),
            ("too big", try zipped(["card.json": String(repeating: "x", count: 70_000)])),
            // An untrusted image goes to no decoder but JPEG's and PNG's, whatever its name says.
            ("a TIFF named background.jpg", try CardZip.write([
                ("card.json", Data(cardFileJSON(image: "background.jpg").utf8), true),
                ("background.jpg", try tiff(), false)])),
            ("a crop that does not suit the photo", try CardZip.write([
                ("card.json", Data(cardFileJSON(image: "background.jpg", crop: "[0, 0, 0.5, 1]").utf8), true),
                ("background.jpg", jpeg(), false)])),
        ]
        let store = store()
        for (name, file) in cases {
            guard case .notACardFile = cardError({ try store.importCard(file) }) else {
                Issue.record("\(name): not refused as a card file")
                continue
            }
        }
        #expect(!FileManager.default.fileExists(atPath: store.folder.path))
    }

    // MARK: -

    private func box(_ text: String = "暫離", size: Int = 48, color: PanelColour = .black, outline: Bool = false,
                     outlineColor: PanelColour = .white, align: CardText.Align = .center) -> CardText {
        CardText(text, box: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.3), size: size, color: color, outline: outline,
                 outlineColor: outlineColor, align: align)
    }

    /// A card's JSON with one text box, any part replaced.
    private func card(version: String = "1", id: String = #""a1b2c3d4""#, background: String = #"{"color": "white"}"#,
                      text: String = #""x""#, box: String = "[0, 0, 1, 1]", extra: String = "", texts: String? = nil) -> String {
        let texts = texts ?? #"[{"text": \#(text), "box": \#(box)\#(extra)}]"#
        return #"{"version": \#(version), "id": \#(id), "background": \#(background), "texts": \#(texts)}"#
    }

    /// test_cards.py's card_json: one text box on red, or on the photo `image`.
    private func cardFileJSON(image: String? = nil, crop: String = "null") -> String {
        card(background: image.map { #"{"image": "\#($0)", "crop": \#(crop)}"# } ?? #"{"color": "red"}"#)
    }

    private func zipped(_ entries: [String: String]) throws -> Data {
        try CardZip.write(entries.map { ($0.key, Data($0.value.utf8), false) })
    }

    /// A zip whose card.json only fails when read: `patch(&data, i, central)` runs on its local
    /// and its central header (test_cards.py's `damaged`).
    private func damaged(deflate: Bool = false, _ patch: (inout Data, Int, Bool) -> Void) throws -> Data {
        var data = try CardZip.write([("card.json", Data(String(repeating: cardFileJSON(), count: 40).utf8), deflate)])
        patch(&data, data.firstRange(of: Data([0x50, 0x4B, 3, 4]))!.lowerBound, false)
        patch(&data, data.firstRange(of: Data([0x50, 0x4B, 1, 2]))!.lowerBound, true)
        return data
    }

    /// A `width` x `height` photo, red on the left half and blue on the right, decoded as the app does.
    private func photo(_ width: Int = 1000, _ height: Int = 600) throws -> DecodedPhoto {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try FrameEncoder.loadPhoto(data: encoded(try #require(context.makeImage()), .png))
    }

    /// An 80 x 48 blue JPEG.
    private func jpeg() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 80, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 48))
        return try encoded(try #require(context.makeImage()), .jpeg)
    }

    private func tiff() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 80, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return try encoded(try #require(context.makeImage()), .tiff)
    }

    private func encoded(_ image: CGImage, _ type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func storedSize(_ store: CardStore, _ card: Card) throws -> PhotoSize? {
        try store.photo(of: card)?.size
    }
}

/// The CardError `body` throws, or nil.
private func cardError(_ body: () throws -> Void) -> CardError? {
    do {
        try body()
        return nil
    } catch {
        return error as? CardError
    }
}

/// Hands out the given id candidates, then random ones (Python tests patch secrets.token_hex).
private final class Tokens: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]

    init(_ queue: [String]) { self.queue = queue }

    func next() -> String {
        lock.withLock { queue.isEmpty ? NoteStore.randomToken() : queue.removeFirst() }
    }
}
