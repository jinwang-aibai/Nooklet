import Foundation
import NookletCore

func checkFinderTools() throws {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let file = home.appendingPathComponent("工作区/hello ' world.txt")
    let external = URL(fileURLWithPath: "/Volumes/External/notes.md")
    let urls = [file, external]
    try expectEqual(FinderAction.copyName.clipboardText(for: urls, relativeTo: home), "hello ' world.txt\nnotes.md")
    try expectEqual(FinderAction.copyAbsolutePath.clipboardText(for: urls, relativeTo: home), "\(file.path)\n\(external.path)")
    try expectEqual(
        FinderAction.copyRelativePath.clipboardText(for: urls, relativeTo: home),
        "工作区/hello ' world.txt\n../../Volumes/External/notes.md"
    )
    try expectEqual(FinderAction.copyRelativePath.clipboardText(for: [home], relativeTo: home), ".")
    try expectEqual(
        FinderAction.copyEscapedPath.clipboardText(for: urls, relativeTo: home),
        "'/Users/example/工作区/hello '\\'' world.txt' '/Volumes/External/notes.md'"
    )
    try expectEqual(
        FinderAction.copyFileURL.clipboardText(for: urls, relativeTo: home),
        "file:///Users/example/%E5%B7%A5%E4%BD%9C%E5%8C%BA/hello%20'%20world.txt\nfile:///Volumes/External/notes.md"
    )

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let folder = try FinderNewFile.createFolder(in: directory)
    let secondFolder = try FinderNewFile.createFolder(in: directory)
    try expectEqual(folder.lastPathComponent, "未命名文件夹")
    try expectEqual(secondFolder.lastPathComponent, "未命名文件夹 2")

    let original = try FinderNewFile.json.create(in: directory)
    try Data("keep".utf8).write(to: original)
    let newFile = try FinderNewFile.json.create(in: directory)
    try expectEqual(newFile.lastPathComponent, "未命名文件 2.json")
    let originalText = try String(contentsOf: original, encoding: .utf8)
    try expectEqual(originalText, "keep")
    let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: newFile)) as? [String: String]
    try expectEqual(decoded, [:])
}
