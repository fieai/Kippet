import Foundation

struct ShelfReleaseVersion: Comparable, Sendable {
    private let numbers: [String]
    private let prerelease: [String]

    init?(_ string: String) {
        let pattern = #/(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?/#
        guard let (_, major, minor, patch, suffix) = string.wholeMatch(of: pattern)?.output else { return nil }
        numbers = [String(major), String(minor), String(patch)]
        prerelease = suffix?.split(separator: ".").map(String.init) ?? []
        guard !prerelease.contains(where: {
            $0.count > 1 && $0.first == "0" && $0.allSatisfy(\.isNumber)
        }) else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right {
            return numericLess(left, right)
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftIsNumber = left.allSatisfy(\.isNumber)
            let rightIsNumber = right.allSatisfy(\.isNumber)
            if leftIsNumber != rightIsNumber { return leftIsNumber }
            return leftIsNumber ? numericLess(left, right) : left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numericLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.count == rhs.count ? lhs < rhs : lhs.count < rhs.count
    }
}

struct ShelfRelease: Decodable, Equatable, Sendable {
    let version: ShelfReleaseVersion
    let versionLabel: String
    let downloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case url = "html_url"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try values.decode(String.self, forKey: .tag)
        versionLabel = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let version = ShelfReleaseVersion(versionLabel) else {
            throw DecodingError.dataCorruptedError(forKey: .tag, in: values, debugDescription: "Invalid version tag")
        }
        self.version = version

        let url = try values.decode(URL.self, forKey: .url)
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: values, debugDescription: "Invalid release URL")
        }
        downloadURL = url
    }
}

enum ShelfUpdateSchedule {
    static func isDue(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        enabled && (lastCheck.map { now.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true)
    }
}
