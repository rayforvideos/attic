import Foundation

/// 디스크 여유 부족 알림의 판정자. 규칙의 존재 이유는 **스팸 방지**다 —
/// 여유가 임계치 아래에 머무는 동안 30초마다 알리면 알림을 끄게 만든다.
///
/// 알리는 경우: 여유 < 임계치이고,
///  (a) 이 사건의 첫 하강이거나
///  (b) 지난 알림 후 임계치+히스테리시스(5GB)를 넘겨 확실히 회복했다가 다시 떨어졌거나
///  (c) 지난 알림에서 24시간이 지났을 때(계속 방치된 부족을 하루 한 번 상기).
public struct DiskAlertJudge: Sendable {
    private let thresholdBytes: UInt64
    private let hysteresisBytes: UInt64
    private let remindInterval: TimeInterval
    /// 마지막 알림 시각. **영속되어야 한다** — 메모리에만 두면 앱을 켤 때마다,
    /// 임계치를 한 칸 움직일 때마다 첫 판정에서 즉시 알림이 나가 24시간 규칙이
    /// 무효가 된다(감사에서 확인).
    public private(set) var lastAlertAt: Date?
    public private(set) var recoveredSinceLastAlert = false

    public init(thresholdBytes: UInt64,
                hysteresisBytes: UInt64 = 5 << 30,
                remindInterval: TimeInterval = 24 * 3600,
                lastAlertAt: Date? = nil,
                recoveredSinceLastAlert: Bool = false) {
        self.thresholdBytes = thresholdBytes
        self.hysteresisBytes = hysteresisBytes
        self.remindInterval = remindInterval
        self.lastAlertAt = lastAlertAt
        self.recoveredSinceLastAlert = recoveredSinceLastAlert
    }

    public mutating func shouldAlert(freeBytes: UInt64, at now: Date) -> Bool {
        if freeBytes >= thresholdBytes {
            if freeBytes >= thresholdBytes + hysteresisBytes {
                recoveredSinceLastAlert = true
            }
            return false
        }

        guard let lastAlertAt else {
            self.lastAlertAt = now
            return true
        }
        // 시계가 되돌아가면 간격이 음수가 되어 "역행량 + 24시간" 동안 침묵한다 —
        // 음수는 간격 초과로 본다.
        let elapsed = now.timeIntervalSince(lastAlertAt)
        if recoveredSinceLastAlert || elapsed < 0 || elapsed >= remindInterval {
            self.lastAlertAt = now
            recoveredSinceLastAlert = false
            return true
        }
        return false
    }
}
