// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SaaSIdentityPlatform",
    targets: [
        // CoreKit：纯 Swift 层（模型 / API client / 业务逻辑）。
        // 铁律：本 target 禁止 import SwiftUI / UIKit —— 必须保持任何 Swift 工具链可编译，
        // 远程门禁 swift build/test 直接锁它。
        .target(name: "CoreKit"),
        .testTarget(name: "CoreKitTests", dependencies: ["CoreKit"]),
    ]
)
