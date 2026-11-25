import Foundation
import NookletCore

func checkSoftwareUpdate() throws {
    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease])
    }

    let stable = try release("v1.0.0")
    let firstRelease = SoftwareUpdate.available(
        version: "1.0.0", releasePage: URL(string: "https://github.com/jinwang-aibai/Nooklet/releases/tag/v1.0.0")!
    )
    try expectEqual(SoftwareUpdate.result(currentVersion: "0.3.2-beta.25", status: 200, data: stable), firstRelease)
    try expectEqual(SoftwareUpdate.result(currentVersion: "1.0.0-beta.2", status: 200, data: stable), firstRelease)
    try expectEqual(SoftwareUpdate.result(currentVersion: "1.0.0", status: 200, data: stable), .upToDate)
    try expectEqual(SoftwareUpdate.result(currentVersion: "1.9.0", status: 200, data: try release("1.10.0")),
                    .available(version: "1.10.0",
                               releasePage: URL(string: "https://github.com/jinwang-aibai/Nooklet/releases/tag/1.10.0")!))
    try expectEqual(SoftwareUpdate.result(currentVersion: "1.0.1-beta.1", status: 200, data: stable), .upToDate)
    try expectEqual(SoftwareUpdate.result(currentVersion: "1.0.0", status: 404, data: Data()), .noRelease)
    try expectEqual(SoftwareUpdate.result(currentVersion: "1.0.0", status: 200,
                                          data: try release("v2.0.0-beta.1", prerelease: true)), .noRelease)
    try expectEqual(SoftwareUpdate.result(currentVersion: "1.0.0", status: 200,
                                          data: try release("v2.0.0", draft: true)), .noRelease)
    try expectError(SoftwareUpdate.result(currentVersion: "1.0.0", status: 200, data: Data()))
    try expectError(SoftwareUpdate.result(currentVersion: "1.0.0", status: 200, data: try release("v2.0.0/path")))
    try expectError(SoftwareUpdate.result(currentVersion: "1.0.0", status: 200, data: try release("v02.0.0")))
    try expectError(SoftwareUpdate.result(currentVersion: "1.0.0", status: 503, data: Data())) {
        try expectEqual($0 as? SoftwareUpdate.CheckError, .httpStatus(503))
    }
}
