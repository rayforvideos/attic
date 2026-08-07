import Foundation
import os

/// 디렉터리를 **앱 안에서 직접** 훑는다.
///
/// 왜 `/usr/bin/find`를 자식 프로세스로 띄우지 않는가: macOS는 보호 폴더
/// (데스크탑·문서·다운로드) 접근을 **누가 요청했는지**로 판정한다. 앱이 find를
/// 띄워 그 자식이 폴더를 읽으면 허용을 눌러도 우리 앱에 기록이 남지 않고,
/// 스캔할 때마다 같은 프롬프트가 다시 뜬다(사용자 신고로 확인).
///
/// 같은 일을 앱 안에서 하면 접근이 앱에 귀속되어 **한 번 허용하면 그걸로 끝난다.**
/// find가 빨랐던 이유는 별도 프로세스라서가 아니라 가지치기(prune)였고, 그건
/// 여기서도 그대로 한다.
public enum DirectoryWalk {
    /// 훑기의 공통 규칙. 이름이 같아도 종류마다 찾는 것이 달라 콜백으로 나눈다.
    ///
    /// - `maxDepth`: 루트 직속이 1. 깊게 들어가면 사진 라이브러리 같은 곳까지
    ///   파고들어 느려진다.
    /// - `pruneNames`: 이 이름의 디렉터리는 들어가지 않는다(Library 등).
    /// - `onDirectory`: true를 돌려주면 그 디렉터리 **안으로 들어가지 않는다**.
    ///   node_modules처럼 "찾았으면 그 아래는 볼 필요 없는" 경우에 쓴다.
    /// - `onFile`: 파일마다 크기·시각과 함께 불린다.
    ///
    /// 볼륨 경계를 넘지 않는다(`find -x`와 같다) — 외장 디스크나 네트워크
    /// 마운트로 넘어가면 스캔이 끝나지 않는다.
    /// 반환값은 **온전히 훑었는지**. 읽지 못한 폴더가 하나라도 있으면 false다 —
    /// 그것을 성공으로 받으면 "비울 게 없어요"가 거짓이 될 수 있다.
    @discardableResult
    static func walk(root: String,
                     maxDepth: Int,
                     pruneNames: Set<String> = [],
                     onDirectory: (String) -> Bool = { _ in false },
                     onFile: (String, UInt64, Date) -> Void = { _, _, _ in }) -> Bool {
        // errorHandler는 열거 중 다른 스레드에서 불릴 수 있어 잠금으로 감싼다.
        let unreadable = OSAllocatedUnfairLock(initialState: false)
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey, .volumeIdentifierKey,
        ]
        // 숨김 항목과 패키지 내부(.app·.photoslibrary)는 건너뛴다 — 사용자가
        // "파일"로 여기지 않는 것을 목록에 올리면 안 된다.
        guard let enumerator = fm.enumerator(
            at: rootURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            // 읽을 수 없는 폴더 하나가 훑기 전체를 멈추게 하지 않는다.
            errorHandler: { _, _ in
                unreadable.withLock { $0 = true }
                return true     // 폴더 하나를 못 읽어도 나머지는 훑는다
            }) else { return false }

        let rootVolume = try? rootURL.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier

        // 열거는 루트의 심볼릭 링크를 풀어서 돌려준다(`/var` → `/private/var`).
        // 그대로 넘기면 홈 아래에 있는 경로가 홈 밖으로 보여 가드가 전부 거부한다
        // (테스트 4개가 이걸로 깨졌다) — 호출자가 준 표기로 되돌려 준다.
        //
        // resolvingSymlinksInPath()로는 알 수 없다: 그 API는 호환성 때문에
        // `/private` 접두사를 **다시 떼어내서** 원래 경로와 같은 값을 준다(실측).
        // canonicalPath는 실제 경로를 그대로 준다.
        let resolvedRoot = (try? rootURL.resourceValues(forKeys: [.canonicalPathKey])
            .canonicalPath) ?? root      // 루트에서 한 번만 읽는다
        let trimmedRoot = root.hasSuffix("/") && root.count > 1
            ? String(root.dropLast()) : root
        func asGiven(_ path: String) -> String {
            guard resolvedRoot != trimmedRoot, path.hasPrefix(resolvedRoot) else { return path }
            return trimmedRoot + path.dropFirst(resolvedRoot.count)
        }

        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                enumerator.skipDescendants()
                continue
            }
            if values.isSymbolicLink == true {
                continue    // 심볼릭 링크는 따라가지 않는다(순환·중복 계산 방지)
            }
            if values.isDirectory == true {
                let name = url.lastPathComponent
                if pruneNames.contains(name) || enumerator.level >= maxDepth {
                    enumerator.skipDescendants()
                }
                if let rootVolume, let volume = values.volumeIdentifier,
                   !volume.isEqual(rootVolume) {
                    enumerator.skipDescendants()
                    continue
                }
                if onDirectory(asGiven(url.path)) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let size = values.fileSize else { continue }
            // 만든 날과 고친 날 중 늦은 쪽 — 최근에 손댄 것을 오래된 것으로
            // 오판하지 않기 위함이다.
            let dates = [values.contentModificationDate, values.creationDate]
                .compactMap { $0 }
            guard let latest = dates.max() else { continue }
            onFile(asGiven(url.path), UInt64(size), latest)
        }
        return !unreadable.withLock { $0 }
    }
}
