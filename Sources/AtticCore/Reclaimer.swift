import Foundation

/// The outcome of a `Reclaimer.moveToTrash` run.
public struct ReclaimResult: Sendable {
    public let movedBytes: UInt64
    public let movedCount: Int
    public let refused: [(path: String, reason: ReclaimRefusal)]
    public let failed: [(path: String, message: String)]
    /// Where each successfully-trashed item ended up, as reported by
    /// `FileManager.trashItem`'s `resultingItemURL`. Useful for tests (and
    /// any future "undo" affordance) that need to clean up or locate what
    /// was moved.
    public let trashedURLs: [String]
    /// 옮기려 했으나 **경로가 이미 없던** 항목. 문구로 판별하면 번역된 언어에서
    /// 매칭이 깨지므로 구조로 돌려준다 — 호출부는 이 목록을 보고 목록에서 뺀다.
    public var alreadyGone: [String] = []
    /// 이동한 모든 항목의 크기를 실행 직전에 다시 쟀는지. false면 스캔 당시
    /// 값이 섞여 있다는 뜻이므로 화면·성과 장부가 "약"으로 다뤄야 한다.
    public let remeasured: Bool

    public init(
        movedBytes: UInt64,
        movedCount: Int,
        refused: [(path: String, reason: ReclaimRefusal)],
        failed: [(path: String, message: String)],
        trashedURLs: [String] = [],
        remeasured: Bool = true,
        alreadyGone: [String] = []
    ) {
        self.movedBytes = movedBytes
        self.movedCount = movedCount
        self.refused = refused
        self.failed = failed
        self.trashedURLs = trashedURLs
        self.remeasured = remeasured
        self.alreadyGone = alreadyGone
    }
}

/// Moves reclaimable items to the Trash. Never deletes: the only filesystem
/// mutation this type performs is `FileManager.trashItem`. Every item is
/// re-validated through `ReclaimGuard` immediately before being trashed,
/// re-reading its symlink status and modification time at that moment —
/// this defends against anything that changed between scan time and now,
/// and against a caller passing in a tampered or hand-built item.
public struct Reclaimer: Sendable {
    public init() {}

    public func moveToTrash(
        _ items: [ReclaimItem],
        guard guardian: ReclaimGuard,
        staleThresholdDays: Int
    ) async -> ReclaimResult {
        var movedBytes: UInt64 = 0
        var movedCount = 0
        var refused: [(path: String, reason: ReclaimRefusal)] = []
        var failed: [(path: String, message: String)] = []
        var trashedURLs: [String] = []
        var allRemeasured = true
        var alreadyGone: [String] = []

        for item in items {
            let fm = FileManager.default

            // 폴더만 받던 시절의 검사가 남아 있었다. 그 뒤로 스크린샷·다운로드
            // 파일·큰 파일처럼 **파일 하나**인 항목이 생겼는데, 그것들이 전부
            // "경로가 이미 없어요"로 처리되어 목록에서 조용히 사라졌다.
            // attributesOfItem은 심볼릭 링크를 따라가지 않으므로, 끊어진 링크도
            // "없다"가 아니라 링크로 보고 아래 가드가 거부한다.
            guard let attributes = try? fm.attributesOfItem(atPath: item.path) else {
                failed.append((item.path, L("경로가 이미 없어요")))
                alreadyGone.append(item.path)
                continue
            }

            let isSymlink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            let resolvedPath = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path

            let lockfilePresent: Bool
            let ageDays: Int
            if item.kind == .nodeModules {
                let projectDir = (item.path as NSString).deletingLastPathComponent
                lockfilePresent = hasLockfile(inDirectory: projectDir)
                // Fail closed: an unreadable mtime must not be treated as
                // "maximally stale" — treat it as freshly modified instead,
                // so the guard's staleness rule refuses it.
                ageDays = ageInDays(ofPath: projectDir) ?? 0
            } else {
                lockfilePresent = false
                // **여기가 0이면 스캔이 올린 것을 실행이 거부한다.** 나이를 보는
                // 종류(다운로드·스크린샷·보관본)가 전부 "최근에 썼다"로 막혔다.
                // 못 재면 0으로 둔다 — 모르는 것은 손대지 않는 편이 맞다.
                ageDays = FileAge.days(ofItemAt: item.path) ?? 0
            }

            if let refusal = guardian.check(
                path: item.path, kind: item.kind, lockfilePresent: lockfilePresent,
                ageDays: ageDays, isSymlink: isSymlink, resolvedPath: resolvedPath,
                staleThresholdDays: staleThresholdDays
            ) {
                refused.append((item.path, refusal))
                continue
            }

            // 스캔 값은 며칠 전 것일 수 있다 — 그 숫자로 "N GB 비웠어요"라고
            // 말하면 그 사이 사용자가 직접 비운 경우 거짓이 된다. 옮기기 직전에
            // 다시 잰다. 측정에 실패하면 스캔 값을 쓰되 그 사실을 기록한다.
            let measured = await DirectorySize.measure(item.path)
            if measured == nil { allRemeasured = false }

            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resultingURL)
                if let trashedPath = resultingURL?.path {
                    trashedURLs.append(trashedPath)
                }
                movedBytes += measured ?? item.bytes
                movedCount += 1
            } catch {
                failed.append((item.path, error.localizedDescription))
            }
        }

        return ReclaimResult(movedBytes: movedBytes, movedCount: movedCount,
                              refused: refused, failed: failed, trashedURLs: trashedURLs,
                              remeasured: allRemeasured, alreadyGone: alreadyGone)
    }

    private func hasLockfile(inDirectory dir: String) -> Bool {
        let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml"]
        let fm = FileManager.default
        return lockfiles.contains { fm.fileExists(atPath: "\(dir)/\($0)") }
    }

    private func ageInDays(ofPath path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }
        let seconds = Date().timeIntervalSince(mtime)
        return max(0, Int(seconds / 86_400))
    }
}
