import Foundation

/// 항목이 얼마나 오래 그대로인지 재는 단 하나의 자리. 스캔과 실행 직전 재검증이
/// 나이를 각자 재면 답이 어긋나 사용자가 고른 것을 가드가 거부하게 된다.
public enum FileAge {
    /// 파일 하나의 나이(일). 만든 날과 고친 날 중 늦은 쪽을 쓴다. 최근에 손댄
    /// 것을 오래된 것으로 오판하면 안 된다.
    public static func daysOfFile(_ path: String, now: Date = Date()) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let dates = [attrs[.modificationDate] as? Date,
                     attrs[.creationDate] as? Date].compactMap { $0 }
        guard let latest = dates.max() else { return nil }
        return max(0, Int(now.timeIntervalSince(latest) / 86_400))
    }

    /// 폴더의 나이(일)는 안에 든 것 중 가장 최근 파일의 나이다. 최근에 쓴 파일이
    /// 하나라도 있으면 그 폴더는 최근으로 본다. 빈 폴더나 끝까지 훑지 못한 폴더는
    /// nil이다. 모르는 것을 오래됐다고 말하지 않는다.
    public static func daysOfFolder(_ path: String, now: Date = Date(),
                                    maxDepth: Int = 6) -> Int? {
        var newest: Date?
        var count = 0
        let complete = DirectoryWalk.walk(root: path, maxDepth: maxDepth, onFile: { _, _, at in
            count += 1
            if newest == nil || at > newest! { newest = at }
        })
        guard complete, count > 0, let newest else { return nil }
        return max(0, Int(now.timeIntervalSince(newest) / 86_400))
    }

    /// 파일이든 폴더든 알아서 잰다. 못 재면 nil이고, 호출부는 그것을 "오래됐다"로
    /// 바꾸지 않아야 한다.
    public static func days(ofItemAt path: String, now: Date = Date()) -> Int? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue
            ? daysOfFolder(path, now: now)
            : daysOfFile(path, now: now)
    }
}
