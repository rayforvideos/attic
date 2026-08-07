import Darwin
import Foundation

/// `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`를 적용/해제한 결과.
/// 실측(docs/research/making-it-faster.md): 대상 CPU 2.6배↓(E 코어 고정),
/// 디스크 읽기 3.5배↓. 비권한으로 동작하며 같은 uid의 임의 프로세스(자식이 아니어도,
/// GUI 앱이어도)에 걸 수 있다. 타 uid 대상은 커널이 EPERM으로 거부한다.
public enum PriorityChange: Sendable, Equatable {
    /// 뒤로 밀림 — `PRIO_DARWIN_BG` 적용 성공.
    case backgrounded
    /// 되돌려짐 — `prio = 0`으로 해제 성공. (`PRIO_DARWIN_NONBG`는 공개 SDK에 없다.
    /// man 페이지가 명시하듯 해제는 리터럴 0이 정식 경로다.)
    case restored
    /// 대상 uid가 우리와 다르다 — 커널이 애초에 EPERM으로 막는 대상. 신호도 못 보내는
    /// 프로세스에 정책을 걸려는 시도조차 하지 않는다.
    case refusedOtherUid
    /// 자기 자신, 유효하지 않은 pid, 또는 보호 목록에 속한 시스템 프로세스.
    case refusedProtected
    /// 판정은 통과했으나 syscall 자체가 실패했다.
    case failed(errno: Int32)
}

/// 프로세스를 Darwin 백그라운드 정책으로 밀어 넣거나 되돌리는 얇은 래퍼.
/// 판정 로직(누구를 건드려도 되는가)과 syscall 실행을 한 곳에 묶어, 안전 경계가
/// 호출부마다 따로 재구현되며 어긋나는 일을 막는다.
public struct ProcessPriority: Sendable {
    /// 시스템이 이미 낮은 QoS로 돌리는 인덱서까지 포함해 손대면 안 되는 프로세스 이름.
    /// 근거: 경쟁 제품 App Tamer 3.0 베타가 tccd/launchd/secinitd를 스로틀해 앱 실행이
    /// 막히는 사고를 벤더가 인정했다. 시스템 서비스를 느리게 만들면 그것을 기다리는
    /// 모든 것이 함께 멈춘다. mds/mdworker 계열(Spotlight)은 시스템 서비스는 아니지만
    /// Apple이 이미 낮은 우선순위로 스케줄링하고 있어 더 밀면 색인이 영원히 끝나지 않고
    /// 오히려 계속 CPU를 붙잡는 역효과가 난다 — 그래서 함께 거부 목록에 넣는다.
    /// Apple 제공 바이너리가 사는 곳. 여기 있는 것은 uid가 같아도 밀지 않는다.
    public static let systemBinaryPrefixes: [String] = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/",
        "/Library/Apple/",
    ]

    /// `/System/` 안이지만 **사용자가 직접 쓰는 평범한 앱**이 사는 곳. 활성 상태
    /// 보기·메모·캘린더 같은 것들이다 — 이들을 느리게 만드는 것은 서드파티 앱을
    /// 느리게 만드는 것과 다르지 않고, 종료는 이미 허용하는데 속도 조절만 막으면
    /// 앞뒤가 맞지 않는다. 시스템 서비스(`/System/Library/`)는 그대로 거부한다.
    public static let userFacingSystemAppPrefixes: [String] = [
        "/System/Applications/", "/System/Library/CoreServices/Applications/",
    ]

    public static let protectedNames: Set<String> = [
        "launchd", "WindowServer", "loginwindow", "tccd", "secinitd",
        "mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport",
    ]

    private let ownUid: uid_t
    private let ownPid: pid_t

    public init(ownUid: uid_t, ownPid: pid_t) {
        self.ownUid = ownUid
        self.ownPid = ownPid
    }

    /// 뒤로 밀기. 같은 uid이고 보호 대상이 아닐 때만 syscall을 시도한다.
    /// 이 프로세스에 정책을 걸 수 있는지 — **UI의 버튼 표시 조건과 모델의 거부
    /// 조건이 같은 근거를 쓰게 하기 위한 공용 판정이다.** 둘이 어긋나면 눌러도
    /// 항상 거절되는 버튼(또는 되는데 없는 버튼)이 생긴다(실측으로 확인).
    public func canAdjust(pid: pid_t, uid: uid_t, execPath: String) -> Bool {
        refusal(pid: pid, uid: uid, execPath: execPath) == nil
    }

    public func background(pid: pid_t, uid: uid_t, execPath: String) -> PriorityChange {
        if let refusal = refusal(pid: pid, uid: uid, execPath: execPath) { return refusal }
        return apply(pid: pid, prio: PRIO_DARWIN_BG, success: .backgrounded)
    }

    /// 되돌리기. 배경 밀기와 같은 안전 경계를 적용한다 — 이미 안전하다고 확인된
    /// pid만 되돌릴 것이므로 실질적 제약은 아니지만, 경계를 한 곳에 두기 위함이다.
    public func restore(pid: pid_t, uid: uid_t, execPath: String) -> PriorityChange {
        if let refusal = refusal(pid: pid, uid: uid, execPath: execPath) { return refusal }
        return apply(pid: pid, prio: 0, success: .restored)
    }

    /// 현재 뒤로 밀려 있는지 조회한다.
    ///
    /// 주의: 실측(docs/research/making-it-faster.md §"현재 상태를 조회할 수 없다")에 따르면
    /// `getpriority(PRIO_DARWIN_PROCESS, <타 pid>)`는 BG를 걸어둔 뒤에도 계속 0을 반환하는
    /// 사례가 관찰됐다 — 자기 자신(pid==0/자기 pid)에 대해서만 신뢰할 수 있었다. 이 함수는
    /// syscall 결과를 있는 그대로 보고하되, errno가 설정된 순수 실패(대상 없음 등)만 nil로
    /// 구분한다. **타 프로세스에 대한 반환값을 앱의 유일한 진실 소스로 쓰지 말 것** —
    /// 뒤로 민 목록은 앱이 자체적으로 기록해 관리해야 한다.
    public func isBackgrounded(pid: pid_t) -> Bool? {
        errno = 0
        let result = getpriority(PRIO_DARWIN_PROCESS, id_t(pid))
        if result == -1 && errno != 0 { return nil }
        return (result & PRIO_DARWIN_BG) != 0
    }

    // MARK: - 내부

    private func refusal(pid: pid_t, uid: uid_t, execPath: String) -> PriorityChange? {
        guard uid == ownUid else { return .refusedOtherUid }
        guard pid > 0, pid != ownPid else { return .refusedProtected }
        // Apple이 제공한 시스템 바이너리는 우리가 뒤로 밀 대상이 아니다.
        //
        // 이유는 Spotlight 인덱서를 막아둔 것과 같다: 느리게 만들면 일이 더 오래
        // 걸려 CPU를 오히려 길게 먹고, 무엇이 그것을 기다리는지 우리가 알 수 없다.
        // App Tamer 3.0 베타가 tccd·launchd·secinitd를 스로틀해 앱 실행이 막힌
        // 사고를 벤더가 인정한 전례가 있다. 실측에서 duetexpertd(/usr/libexec)가
        // 75%를 먹는 걸 봤지만, 그것도 같은 판단으로 손대지 않는다.
        //
        // 우리가 미는 대상은 내 개발 프로세스와 내가 띄운 앱이다.
        let isUserFacingApp = Self.userFacingSystemAppPrefixes.contains {
            execPath.hasPrefix($0)
        }
        for prefix in Self.systemBinaryPrefixes
        where execPath.hasPrefix(prefix) && !isUserFacingApp {
            return .refusedProtected
        }
        let name = (execPath as NSString).lastPathComponent
        if Self.protectedNames.contains(name) { return .refusedProtected }
        return nil
    }

    private func apply(pid: pid_t, prio: Int32, success: PriorityChange) -> PriorityChange {
        errno = 0
        let ret = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), prio)
        if ret == -1 { return .failed(errno: errno) }
        return success
    }

    /// 우리가 방금 띄운 자식 프로세스를 Darwin 백그라운드로 내린다.
    ///
    /// `background(pid:uid:execPath:)`의 안전 가드(Apple 바이너리 거부, 보호된
    /// 이름 거부)는 "남의 프로세스"를 뒤로 미는 것을 막기 위한 경계다. 여기서
    /// 대상은 우리 프로세스가 `Process.run()`으로 방금 만든 자식(`/usr/bin/du`
    /// 등)이라 그 경계가 적용될 이유가 없다 — 우리가 만들었고, 우리가 끝을
    /// 기다리는 프로세스다. 스캔이 사용자 작업과 P 코어를 다투지 않게 하려면
    /// 이 경로가 필요하다.
    public static func backgroundOwnChild(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        errno = 0
        let ret = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
        return ret == 0
    }
}
