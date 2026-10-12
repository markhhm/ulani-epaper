import Foundation
import Testing
@testable import PaperhuePages

/// The bundled fonts must be the Python reference's files, byte for byte: the pages are
/// compared with goldens drawn from them.
@Suite struct FontFilesTests {
    static let reference = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/PaperhuePagesTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UlaniKit
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("python/src/ulani_epaper/fonts")

    @Test(arguments: ["NotoSansCJKtc-Regular-subset.otf", "NotoSansCJKtc-Bold-subset.otf", "OFL.txt"])
    func bundledFontMatchesTheReference(name: String) throws {
        let bundled = try Data(contentsOf: PaperhuePages.fontsDirectory.appendingPathComponent(name))
        let reference = try Data(contentsOf: Self.reference.appendingPathComponent(name))
        #expect(bundled == reference)
    }
}
