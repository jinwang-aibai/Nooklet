import Foundation
import NookletCore

func checkRunningAppGroups() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    func bundle(_ path: String) throws -> RunningAppBundle {
        guard let result = RunningAppBundle(url: root.appendingPathComponent(path, isDirectory: true)) else {
            throw CheckFailure("Expected app bundle for \(path)")
        }
        return result
    }

    let chat = try bundle("WeChat.app")
    let weApp = try bundle("WeChat.app/Contents/MacOS/WeChatAppEx.app")
    let renderer = try bundle("WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/Helpers/Renderer.app")
    let work = try bundle("企业微信.app")
    let assistant = try bundle("企业微信.app/Contents/MacOS/Assistant.app")
    let workCopy = try bundle("企业微信 Copy.app")
    try expect(chat.isOwner)
    try expectFalse(weApp.isOwner)
    try expectEqual(weApp.ownerURL.path, chat.url.path)
    try expectEqual(renderer.ownerURL.path, chat.url.path)
    try expectEqual(assistant.ownerURL.path, work.url.path)
    try expectEqual(renderer.groupID(ownerIdentifier: nil), chat.groupID(ownerIdentifier: ""))
    try expect(work.groupID(ownerIdentifier: nil) != chat.groupID(ownerIdentifier: nil))
    try expectEqual(workCopy.groupID(ownerIdentifier: "com.tencent.WeWorkMac"),
                    assistant.groupID(ownerIdentifier: "com.tencent.WeWorkMac"))
    try expect(work.groupID(ownerIdentifier: "com.tencent.WeWorkMac") != chat.groupID(ownerIdentifier: "com.tencent.xinWeChat"))

    let standalone = try bundle("Backups.app/Standalone.app")
    try expect(standalone.isOwner)
    try expectNil(RunningAppBundle(url: URL(fileURLWithPath: "/usr/bin/zsh")))
}
