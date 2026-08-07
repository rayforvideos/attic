import Testing
@testable import AtticCore

@Test func processSampleIsValueTypeWithIdentity() {
    let s = ProcessSample.fixture(pid: 42, startSec: 100)
    #expect(s.identity == ProcIdentity(pid: 42, startSec: 100, startUsec: 0))
}

@Test func fixtureDefaultsAreSafe() {
    let s = ProcessSample.fixture()
    #expect(s.pid > 0)          // kill(0)/kill(-1) 사고 방지 규약
    #expect(s.argv.isEmpty == false)
}
