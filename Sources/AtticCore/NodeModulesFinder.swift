import Foundation

/// node_modules를 찾는다. 자식 프로세스로 훑으면 보호 폴더 접근 허용이 앱에
/// 기록되지 않아 스캔할 때마다 프롬프트가 다시 뜨므로 앱 안에서 훑는다.
public enum NodeModulesFinder {
    /// 결과와 함께 온전히 훑었는지를 돌려준다. 일부만 훑은 목록을 완전한 결과로
    /// 올리면 "비울 게 없어요"가 거짓이 된다.
    public struct Result: Sendable {
        public let paths: [String]
        public let complete: Bool
    }

    /// `lowPriority`·`timeout`은 무시한다. 앱 안에서 훑으면 끊을 프로세스가 없고
    /// 우선순위는 호출하는 Task가 정한다. 호출부를 흔들지 않으려고 인자만 남겼다.
    public static func find(under root: String, maxDepth: Int,
                            lowPriority: Bool = false,
                            timeout: TimeInterval = 120) -> Result {
        var paths: [String] = []
        // maxDepth는 그 단계까지 내려가 그 안을 살핀다는 뜻이라 node_modules 자신은
        // 한 단계 더 깊을 수 있다.
        let complete = DirectoryWalk.walk(
            root: root, maxDepth: maxDepth + 1,
            onDirectory: { path in
                guard (path as NSString).lastPathComponent == "node_modules" else { return false }
                paths.append(path)
                return true     // 찾았으면 그 아래는 보지 않는다
            })
        return Result(paths: paths, complete: complete)
    }

}
