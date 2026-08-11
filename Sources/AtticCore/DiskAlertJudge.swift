import Foundation

/// 디스크 여유 부족 알림의 판정자. 규칙은 스팸 방지를 위한 것이다. 여유가 임계치
/// 아래에 머무는 동안 계속 알리면 사용자가 알림을 꺼버린다.
///
/// 알리는 경우: 여유 < 임계치이고,
///  (a) 이 사건의 첫 하강이거나
///  (b) 지난 알림 후 임계치+히스테리시스(5GB)를 넘겨 확실히 회복했다가 다시 떨어졌거나
///  (c) 지난 알림에서 24시간이 지났을 때(계속 방치된 부족을 하루 한 번 상기).
public struct DiskAlertJudge: Sendable {
    private let thresholdBytes: UInt64
    private let hysteresisBytes: UInt64
    private let remindInterval: TimeInterval
    /// 마지막 알림 시각. 영속되어야 한다. 메모리에만 두면 앱을 켜거나 임계치를
    /// 옮길 때마다 첫 판정에서 알림이 나가 24시간 규칙이 무효가 된다.
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
        // 시계가 되돌아가면 간격이 음수가 되어 역행량만큼 더 침묵하므로, 음수는
        // 간격 초과로 본다.
        let elapsed = now.timeIntervalSince(lastAlertAt)
        if recoveredSinceLastAlert || elapsed < 0 || elapsed >= remindInterval {
            self.lastAlertAt = now
            recoveredSinceLastAlert = false
            return true
        }
        return false
    }
}
