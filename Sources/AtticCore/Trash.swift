import Foundation
import os

private let logger = os.Logger(subsystem: "com.sangjunpark.attic", category: "trash")

public struct TrashContents: Sendable, Equatable {
    public let bytes: UInt64
    public let itemCount: Int

    public init(bytes: UInt64, itemCount: Int) {
        self.bytes = bytes
        self.itemCount = itemCount
    }

    public var isEmpty: Bool { itemCount == 0 }

    /// 비우라고 권할 만한가. 20MB짜리 휴지통을 두고 권하면 잔소리가 된다.
    public var isWorthEmptying: Bool { bytes >= 100 << 20 }

    /// 방금 옮긴 직후에는 양과 무관하게 비우기를 권한다. 그러지 않으면 100MB 미만을
    /// 옮긴 사람은 비우기 버튼을 영영 보지 못한다.
    public func shouldOfferEmptying(justMoved: Bool) -> Bool {
        justMoved ? !isEmpty : isWorthEmptying
    }
}

public struct TrashEmptyOutcome: Sendable, Equatable {
    public let removed: Int
    public let failed: Int

    public init(removed: Int, failed: Int) {
        self.removed = removed
        self.failed = failed
    }
}

/// 휴지통을 들여다보고 비운다.
///
/// 이 앱은 삭제하지 않고 휴지통으로만 옮기므로, 비우지 않으면 디스크 여유가 한
/// 바이트도 늘지 않는다. 그 마지막 한 걸음을 여기서 닫는다.
///
/// 앱이 알아서 지우지는 않는다. 사용자가 크기와 개수를 보고 확인을 한 번 더 거쳐
/// 직접 누를 때만 지운다.
public struct Trash: Sendable {
    let directory: URL

    public init(directory: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) {
        self.directory = directory
    }

    /// 휴지통에 무엇이 얼마나 들었나. nil은 읽을 수 없다는 뜻이고 0바이트와 구별해야
    /// 한다. 전체 디스크 접근이 없으면 `~/.Trash`는 열리지 않는다.
    public func inspect(timeout: TimeInterval = 30) async -> TrashContents? {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: directory.path) else { return nil }
        let visible = names.filter { $0 != ".DS_Store" }
        guard !visible.isEmpty else { return TrashContents(bytes: 0, itemCount: 0) }
        let bytes = await DirectorySize.measure(directory.path, lowPriority: true,
                                               timeout: timeout) ?? 0
        return TrashContents(bytes: bytes, itemCount: visible.count)
    }

    /// 휴지통의 항목을 영구 삭제한다. 되돌릴 수 없으므로 호출부는 반드시 사용자
    /// 확인을 받은 뒤에 불러야 한다.
    ///
    /// 잠기거나 사용 중인 항목이 있어도 나머지는 지우고, 실패 개수를 그대로 돌려준다.
    public func empty() async -> TrashEmptyOutcome {
        // 경로를 잘못 받아 홈 디렉터리를 지우는 사고를 구조로 막는다. 조용히
        // 무시하지 않고 로그를 남긴다.
        guard directory.lastPathComponent == ".Trash" else {
            logger.error("Refusing to empty non-trash directory: \(self.directory.path, privacy: .public)")
            return TrashEmptyOutcome(removed: 0, failed: 0)
        }
        let dir = directory
        return await Task.detached {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
                return TrashEmptyOutcome(removed: 0, failed: 0)
            }
            var removed = 0
            var failed = 0
            for name in names where name != ".DS_Store" {
                do {
                    try fm.removeItem(at: dir.appending(path: name))
                    removed += 1
                } catch {
                    failed += 1
                    logger.error("Failed to remove trash item: \(error, privacy: .public)")
                }
            }
            return TrashEmptyOutcome(removed: removed, failed: failed)
        }.value
    }

    /// Finder에서 휴지통을 연다. 권한이 없어 크기를 못 읽을 때의 대안이자, 비우기
    /// 전에 내용을 직접 보고 싶은 사람을 위한 길이다.
    public var openURL: URL { directory }
}
