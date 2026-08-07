import Testing
import Foundation
@testable import AtticCore

@Suite("SizeText")
struct SizeTextTests {
    /// 1MB 미만을 "0"으로 내보내던 버그. 수백 KB짜리 스크린샷이 목록에 전부
    /// 0으로 떠서, 크기를 못 잰 것인지 빈 파일인지 구별할 수 없었다.
    @Test func neverReportsZeroForRealFiles() {
        #expect(SizeText.compact(600 << 10) == "600KB")
        #expect(SizeText.compact(1 << 10) == "1KB")
        #expect(SizeText.compact(512) == "512B")
        #expect(SizeText.compact(1) == "1B")
        for bytes in [UInt64(1), 999, 1 << 10, 700 << 10, 1 << 20, 1 << 30] {
            #expect(SizeText.compact(bytes) != "0")
        }
    }

    @Test func picksUnitByMagnitude() {
        #expect(SizeText.compact(0) == "0B")            // 정말 빈 것은 0B다
        #expect(SizeText.compact(5 << 20) == "5MB")
        #expect(SizeText.compact(3 << 30) == "3.0GB")
        #expect(SizeText.compact((3 << 30) + (512 << 20)) == "3.5GB")
    }

    @Test func splitMatchesCompactUnits() {
        #expect(SizeText.split(600 << 10) == (value: "600", unit: "KB"))
        #expect(SizeText.split(5 << 20) == (value: "5", unit: "MB"))
        #expect(SizeText.split(3 << 30) == (value: "3.0", unit: "GB"))
        #expect(SizeText.split(512) == (value: "512", unit: "B"))
    }
}
