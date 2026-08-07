import SwiftUI
import ServiceManagement
import UserNotifications
import AtticCore

struct SettingsView: View {
    @Environment(\.appearsActive) private var appearsActive
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var protectedPathsText =
        (UserDefaults.standard.stringArray(forKey: "protectedPaths") ?? [])
            .joined(separator: "\n")
    @State private var projectRootsText =
        (UserDefaults.standard.stringArray(forKey: "projectRoots") ?? [])
            .joined(separator: "\n")
    @State private var spaceScanSound =
        (UserDefaults.standard.object(forKey: "spaceScanSound") as? Bool) ?? true
    @State private var diskAlertEnabled =
        (UserDefaults.standard.object(forKey: "diskAlertEnabled") as? Bool) ?? true
    @State private var diskAlertThresholdGB =
        (UserDefaults.standard.object(forKey: "diskAlertThresholdGB") as? Int) ?? 20
    @State private var notifStatus: UNAuthorizationStatus?
    @State private var sentTest = false
    @State private var loginItemNote: String?
    @State private var testFailed = false
    @State private var language = AppLanguage.current
    @State private var staleDays =
        (UserDefaults.standard.object(forKey: "staleDays") as? Int) ?? 90
    @State private var largeFileMB = UserSettings.largeFileMB
    @State private var includeUserFiles =
        (UserDefaults.standard.object(forKey: "includeUserFiles") as? Bool) ?? true
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted

    var body: some View {
        Form {
            Section {
            Picker(L("언어"), selection: Binding(
                get: { language },
                set: { picked in
                    language = picked
                    AppLanguage.apply(picked)
                    // 모델의 값이 바뀌면 팝오버·설정 창이 새 로케일로 다시 그려진다.
                    DiagnosticsModel.shared.setLanguage(picked)
                })) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Toggle("로그인 시 실행", isOn: Binding(
                get: { launchAtLogin },
                set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        loginItemNote = nil
                    } catch {
                        loginItemNote = L("등록하지 못했어요 — %@", error.localizedDescription)
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    // 시스템이 승인을 요구하면 토글이 말없이 튕긴다 — 이유를 말해준다.
                    if SMAppService.mainApp.status == .requiresApproval {
                        loginItemNote = L("시스템 설정 → 로그인 항목에서 승인이 필요해요")
                    }
                }))
            if let loginItemNote {
                HStack(spacing: 8) {
                    Text(loginItemNote)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if SMAppService.mainApp.status == .requiresApproval {
                        Button(L("로그인 항목 열기")) { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
            }
            }
            Section("알림") {
            Toggle("스캔이 끝나면 소리로 알리기", isOn: Binding(
                get: { spaceScanSound },
                set: { on in
                    spaceScanSound = on
                    UserDefaults.standard.set(on, forKey: "spaceScanSound")
                }))
            Toggle("디스크 여유가 부족하면 알려주기", isOn: Binding(
                get: { diskAlertEnabled },
                set: { on in
                    diskAlertEnabled = on
                    UserDefaults.standard.set(on, forKey: "diskAlertEnabled")
                }))
            if diskAlertEnabled {
                Picker(L("알려줄 기준"), selection: Binding(
                    get: { diskAlertThresholdGB },
                    set: { value in
                        diskAlertThresholdGB = value
                        UserDefaults.standard.set(value, forKey: "diskAlertThresholdGB")
                    })) {
                    ForEach([10, 20, 30, 50, 100], id: \.self) { gb in
                        Text(L("여유 %lldGB 미만", gb)).tag(gb)
                    }
                }
            }
                HStack(spacing: 8) {
                    Text(notifStatusText)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if notifStatus == .denied {
                        Button("시스템 설정 열기") { openNotificationSettings() }
                            .controlSize(.small)
                    } else {
                        Button(testLabel) {
                            sentTest = true
                            testFailed = false
                            Task {
                                let notifier = DiagnosticsModel.shared.notifier
                                await notifier.notify(title: L("알림 테스트"),
                                                      body: L("이 배너가 보이면 정상이에요"))
                                // 권한이 거부돼 폴백으로 갔으면 "보냈어요"는 거짓이다.
                                testFailed = notifier.fallbackActive
                                try? await Task.sleep(for: .seconds(2))
                                sentTest = false
                                await refreshNotifStatus()
                            }
                        }
                        .controlSize(.small)
                        .disabled(sentTest)
                    }
                }
            }

            Section("무엇을 찾을지") {
                // 폴더마다 묻는 프롬프트를 없애는 유일한 방법이다 — 이미 허용돼
                // 있으면 이 안내를 보여줄 이유가 없다.
                if !hasFullDiskAccess {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("폴더마다 접근을 묻고 있어요")
                            .font(.system(size: 11, weight: .semibold))
                        Text("내 파일을 찾으려면 다운로드·데스크탑·문서 폴더를 봐야 하고, macOS는 폴더마다 따로 물어봐요. 휴지통에 얼마가 들었는지도 이 권한이 있어야 보여줄 수 있어요. 한 번 허용하면 다시 묻지 않아요.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(L("한 번만 허용하기")) {
                                NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                            }
                            .controlSize(.small)
                            Button(L("다시 확인")) {
                                hasFullDiskAccess = FullDiskAccess.isGranted
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Toggle("내 파일도 찾기", isOn: Binding(
                    get: { includeUserFiles },
                    set: { on in
                        includeUserFiles = on
                        UserDefaults.standard.set(on, forKey: "includeUserFiles")
                    }))
                Text("받아두고 잊은 설치 파일, 오래된 스크린샷, 큰 파일을 함께 찾아요 · 캐시와 달리 지우면 되돌릴 수 없어서 자동으로 선택되지는 않아요")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Picker(L("오래된 기준"), selection: Binding(
                    get: { staleDays },
                    set: { value in
                        staleDays = value
                        UserDefaults.standard.set(value, forKey: "staleDays")
                    })) {
                    Text("1개월 넘게 안 씀").tag(30)
                    Text("3개월 넘게 안 씀").tag(90)
                    Text("6개월 넘게 안 씀").tag(180)
                    Text("1년 넘게 안 씀").tag(365)
                }
                if includeUserFiles {
                    Picker(L("큰 파일 기준"), selection: Binding(
                        get: { largeFileMB },
                        set: { value in
                            largeFileMB = value
                            UserDefaults.standard.set(value, forKey: "largeFileMB")
                        })) {
                        // 1GB부터 시작하면 흔한 동영상·발표자료(300~800MB)가 전부
                        // 안 보인다. 예전에는 이 목록의 최소값이 1GB여서 코드
                        // 기본값(300MB)을 화면에서 고를 수조차 없었다.
                        Text("200MB 넘는 것").tag(200)
                        Text("500MB 넘는 것").tag(500)
                        ForEach([1, 2, 5, 10], id: \.self) { gb in
                            Text(L("%lldGB 넘는 것", gb)).tag(gb * 1024)
                        }
                    }
                }
            }

            Section("node_modules를 찾을 폴더 (줄바꿈 구분)") {
                TextEditor(text: $projectRootsText)
                    .frame(height: 60)
                    .onChange(of: projectRootsText) { _, text in
                        UserDefaults.standard.set(
                            text.split(separator: "\n").map(String.init)
                                .filter { !$0.isEmpty },
                            forKey: "projectRoots")
                    }
                Text(L("비워 두면 홈의 %@ 폴더를 찾아봐요 · 개발자가 아니면 비워 두세요",
                       DiagnosticsModel.defaultProjectRootNames.joined(separator: "·")))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Section("손대지 말 폴더 (줄바꿈 구분)") {
                TextEditor(text: $protectedPathsText)
                    .frame(height: 80)
                    .onChange(of: protectedPathsText) { _, text in
                        UserDefaults.standard.set(
                            text.split(separator: "\n").map(String.init)
                                .filter { !$0.isEmpty },
                            forKey: "protectedPaths")
                    }
                Text("여기 적은 폴더는 찾기와 정리에서 모두 빼요 · ~ 사용 가능")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(width: 430)
        // 사용자가 시스템 설정에서 껐을 수 있다 — 로컬 저장 금지, 매번 status를 읽는다
        .onChange(of: appearsActive) { _, active in
            if active {
                launchAtLogin = SMAppService.mainApp.status == .enabled
                // 사용자가 시스템 설정에서 방금 허용했을 수 있다 — 창이 다시
                // 활성될 때 확인한다.
                hasFullDiskAccess = FullDiskAccess.isGranted
                Task { await refreshNotifStatus() }
            }
        }
        .task { await refreshNotifStatus() }
    }

    private var testLabel: String {
        if testFailed { return L("보내지 못했어요") }
        return sentTest ? L("보냈어요") : L("테스트 알림 보내기")
    }

    private var notifStatusText: String {
        switch notifStatus {
        case .authorized: L("배너로 알려드려요")
        case .denied: L("꺼져 있어요 — 그동안은 소리와 메뉴바 아이콘으로 알려드려요")
        case nil: ""
        default: L("첫 알림 때 허용을 물어봐요")
        }
    }

    private func refreshNotifStatus() async {
        notifStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// 시스템 설정 → 알림 → 이 앱 페이지로 바로 연다(딥링크 실측 확인 2026-08-05).
    /// 번들 ID는 하드코딩하지 않는다 — ID를 바꾸면 조용히 엉뚱한 페이지가 열린다.
    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.sangjunpark.attic"
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }
}
