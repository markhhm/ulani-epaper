import Testing
@testable import PaperhueAgenda

@Suite struct ScaffoldTests {
    @Test func moduleBuilds() {
        _ = PaperhueAgenda.self
    }
}
