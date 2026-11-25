import Foundation

public enum SoftwareUpdate: Equatable, Sendable {
    case noRelease
    case upToDate
    case available(version: String, releasePage: URL)

    public enum CheckError: Error, Equatable, Sendable {
        case invalidVersion
        case invalidResponse
        case rateLimited
        case httpStatus(Int)
    }

    public static func check(currentVersion: String) async throws -> Self {
        let endpoint = URL(string: "https://api.github.com/repos/jinwang-aibai/Nooklet/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nooklet", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.invalidResponse }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            throw CheckError.rateLimited
        }
        return try result(currentVersion: currentVersion, status: http.statusCode, data: data)
    }

    public static func result(currentVersion: String, status: Int, data: Data) throws -> Self {
        guard let current = Version(currentVersion) else { throw CheckError.invalidVersion }
        switch status {
        case 404: return .noRelease
        case 200: break
        default: throw CheckError.httpStatus(status)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw CheckError.invalidResponse
        }
        if release.draft || release.prerelease { return .noRelease }
        guard let latest = Version(release.tagName), !latest.isBeta else { throw CheckError.invalidResponse }
        if current.numbers > latest.numbers || (current.numbers == latest.numbers && !current.isBeta) {
            return .upToDate
        }
        let page = URL(string: "https://github.com/jinwang-aibai/Nooklet/releases/tag/\(release.tagName)")!
        return .available(version: latest.display, releasePage: page)
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
        }
    }

    private struct Version {
        let numbers: (Int, Int, Int)
        let isBeta: Bool

        var display: String { "\(numbers.0).\(numbers.1).\(numbers.2)" }

        init?(_ value: String) {
            let tag = value.hasPrefix("v") ? value.dropFirst() : value[...]
            let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
            guard let base = parts.first, parts.count <= 2 else { return nil }
            let components = base.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 3,
                  let major = Self.number(components[0]), let minor = Self.number(components[1]),
                  let patch = Self.number(components[2]) else { return nil }
            numbers = (major, minor, patch)
            isBeta = parts.count == 2
            if isBeta {
                let beta = parts[1]
                guard beta.hasPrefix("beta."), let revision = Self.number(beta.dropFirst(5)), revision > 0 else {
                    return nil
                }
            }
        }

        private static func number(_ digits: Substring) -> Int? {
            guard !digits.isEmpty,
                  digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  digits.count == 1 || digits.first != "0" else { return nil }
            return Int(digits)
        }
    }
}
