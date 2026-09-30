import SwiftUI

// T-1 基建期占位壳：让 SaaSIdentity scheme 可编可跑，远门 L2 xcodebuild 段
// 连带 CoreKit/SaasSharedGenerated 全量编译。真 UI（Config/Login/Account 三
// View + SessionStore 接线）在 T-2/T-3 随 REQ-2026-001 red-first 生长。
@main
struct SaaSIdentityApp: App {
    var body: some Scene {
        WindowGroup {
            Text("身份平台")
        }
    }
}
