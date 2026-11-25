import Foundation
import NookletCore

func checkStorageAnalysis() throws {
    try withTemporaryDirectory { temporary in
        let root = temporary.appendingPathComponent("scan", isDirectory: true)
        let folder = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let large = folder.appendingPathComponent("large.bin")
        let small = root.appendingPathComponent("small.bin")
        let sparse = root.appendingPathComponent("sparse.bin")
        let outside = temporary.appendingPathComponent("outside.bin")
        try Data(repeating: 0xab, count: 262_144).write(to: large)
        try Data(repeating: 0xcd, count: 4_096).write(to: small)
        try Data(repeating: 0xef, count: 524_288).write(to: outside)
        try Data().write(to: sparse)
        let sparseHandle = try FileHandle(forWritingTo: sparse)
        try sparseHandle.truncate(atOffset: 50_000_000)
        try sparseHandle.close()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let full = try StorageScanner.scan(root)
        try expectEqual(full.items.map { $0.url.lastPathComponent }, ["Nested", "small.bin", "sparse.bin"])
        try expectEqual(full.items.first?.children.map { $0.url.lastPathComponent }, ["large.bin"])
        try expectEqual(full.fileCount, 3)
        try expectEqual(full.itemCount, 3)
        try expectEqual(full.skippedCount, 1)
        try expectEqual(full.items.last?.bytes, 0)
        try expectEqual(full.totalBytes, full.items.reduce(0) { $0 + $1.bytes })
        let limited = try StorageScanner.scan(root, limit: 1)
        try expectEqual(limited.items.map { $0.url.lastPathComponent }, ["Nested"])
        try expectEqual(limited.totalBytes, full.totalBytes)
        try expectError(try StorageScanner.scan(small))
    }
}

func checkStorageItemReplacement() throws {
    try withTemporaryDirectory { temp in
        let root = temp.appendingPathComponent("folder", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("entry.txt")
        try Data("original".utf8).write(to: file)
        let result = try StorageScanner.scan(root)
        guard let folder = result.items.first, let entry = folder.children.first else {
            throw CheckFailure("Expected nested scan entries")
        }
        let inside = try StorageScanner.scan(folder)
        try expectEqual(inside.items.map { $0.url.lastPathComponent }, ["entry.txt"])
        try StorageScanner.validateForTrash(entry, in: result.directory)
        try expectError(try StorageScanner.validateForTrash(folder, in: folder.url))

        try FileManager.default.moveItem(at: file, to: nested.appendingPathComponent("old.txt"))
        try Data("replacement".utf8).write(to: file)
        try expectError(try StorageScanner.validateForTrash(entry, in: result.directory)) { error in
            try expect(error as? StorageScanError == .itemChanged)
        }

        let moved = temp.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: nested, to: moved)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: moved)
        try expectError(try StorageScanner.scan(folder)) { error in
            try expect(error as? StorageScanError == .itemChanged)
        }
        try expectError(try StorageScanner.validateForTrash(inside.items[0], in: result.directory)) { error in
            try expect(error as? StorageScanError == .itemChanged)
        }
    }
}

func checkStorageTreemap() throws {
    let bounds = CGRect(x: 13, y: 24, width: 411, height: 267)
    let weights = [85.0, 72, 47, 30, 15, 3, 0.01]
    let rectangles = StorageTreemap.rectangles(weights: weights, in: bounds)
    try expectEqual(rectangles.count, weights.count)
    let total = weights.reduce(0, +)
    for (index, rect) in rectangles.enumerated() {
        try expect(bounds.insetBy(dx: -0.000001, dy: -0.000001).contains(rect))
        let area = rect.width * rect.height
        try expect(abs(area / (bounds.width * bounds.height) - weights[index] / total) < 0.000001)
        for neighbor in rectangles.prefix(index) {
            let intersection = rect.intersection(neighbor)
            try expect(intersection.isNull || intersection.width * intersection.height < 0.000001)
        }
    }
}
