import Foundation

// A log path is evidence of what Wallet mentioned, not proof that AFC can read
// that path or that any particular artwork file exists there.
struct CardScanMatch: Codable, Equatable {
    enum Kind: String, Codable {
        case absoluteCardPath = "absolute_card_path"
        case partialCardPath = "partial_card_path"
        case bareIdentifier = "unverified_identifier"
    }

    let cardID: String
    let kind: Kind
    let path: String?
    let containerPath: String?

    var hasAbsolutePath: Bool { kind == .absoluteCardPath }
}

enum CardScanEvidence {
    private static let absolutePath = try! NSRegularExpression(pattern:
        #"(?:/private)?/var/mobile/Library/Passes/Cards/([-A-Za-z0-9_+=]{20,44})\.(pkpass|cache|pkcache)(?=$|/|[\s\"'<>),;])(/[^\s\"'<>),;]*)?"#)
    private static let partialPath = try! NSRegularExpression(pattern:
        #"/(?:Passes/)?Cards/([-A-Za-z0-9_+=]{20,44})\.(pkpass|cache|pkcache)(?=$|/|[\s\"'<>),;])(/[^\s\"'<>),;]*)?"#)
    private static let basenamePath = try! NSRegularExpression(pattern:
        #"/([-A-Za-z0-9_+=]{20,44})\.(pkpass|cache|pkcache)(?=$|/|[\s\"'<>),;])(/[^\s\"'<>),;]*)?"#)
    private static let bareIdentifier = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])"#)
    private static let dummyIDs: Set<String> = [
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=", "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME="
    ]

    static func matches(in line: String) -> [CardScanMatch] {
        // The scanner is not a general-purpose device log recorder.
        guard line.utf8.count <= 65_536 else { return [] }
        let lower = line.lowercased()
        // Real PassKitUI card discovery can contain only "Dashboard loading"
        // and a bare identifier, with none of the artwork keywords below.
        // Accept that specific context without treating all Passbook heartbeat
        // messages as card evidence. Bare identifiers remain unverified.
        let isWalletDashboardLoading = lower.contains("dashboard loading") &&
            (lower.contains("passbook") || lower.contains("passkitui"))
        guard ["passd", "passbook", "passkit", "stockholm", "nanopassd", "wallet", "/cards/"]
            .contains(where: lower.contains),
              ["card", "pkpass", "uniqueid", "identifier", "face", "cache", "image", "artwork", "asset", "texture", "snapshot"]
            .contains(where: lower.contains) || isWalletDashboardLoading else { return [] }

        var found: [CardScanMatch] = []
        var seen = Set<String>()
        let range = NSRange(line.startIndex..., in: line)
        for (regex, kind) in [(absolutePath, CardScanMatch.Kind.absoluteCardPath),
                              (partialPath, .partialCardPath), (basenamePath, .partialCardPath),
                              (bareIdentifier, .bareIdentifier)] {
            for match in regex.matches(in: line, range: range) {
                guard let idRange = Range(match.range(at: 1), in: line) else { continue }
                let cardID = String(line[idRange])
                guard !dummyIDs.contains(cardID), !(cardID.count == 36 && cardID.contains("-")),
                      seen.insert(cardID).inserted else { continue }
                var path: String?
                var containerPath: String?
                if kind != .bareIdentifier, let fullRange = Range(match.range, in: line) {
                    path = String(line[fullRange])
                    let suffixLength = match.range(at: 3).location == NSNotFound ? 0 : match.range(at: 3).length
                    let containerRange = NSRange(location: match.range.location, length: match.range.length - suffixLength)
                    if let container = Range(containerRange, in: line) { containerPath = String(line[container]) }
                }
                found.append(CardScanMatch(cardID: cardID, kind: kind, path: path, containerPath: containerPath))
            }
        }
        return found
    }
}

// The scanner owns one writer on its background task. A scan records at most
// 500 matching lines / 1 MiB, with private filesystem permissions. Full device
// logs, unrelated lines, and repeated identical evidence are never stored.
final class CardScanEvidenceWriter: @unchecked Sendable {
    private struct Entry: Codable {
        let schemaVersion: Int
        let timestamp: String
        let deviceID: String?
        let source: String
        let sourceTruncated: Bool
        let matches: [CardScanMatch]
    }

    let fileURL: URL
    private let handle: FileHandle
    private let maxBytes: Int
    private let maxEntries: Int
    private let deviceID: String?
    private var bytesWritten = 0
    private var entriesWritten = 0
    private var seen = Set<String>()
    private(set) var isFull = false

    init(directory: URL, deviceID: String? = nil, maxBytes: Int = 1_048_576, maxEntries: Int = 500) throws {
        self.maxBytes = max(0, maxBytes)
        self.maxEntries = max(0, maxEntries)
        self.deviceID = deviceID
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("scan-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: fileURL)
    }

    deinit { try? handle.close() }

    @discardableResult
    func append(line: String, matches: [CardScanMatch]) throws -> Bool {
        guard !isFull, !matches.isEmpty else { return false }
        let source = String(line.prefix(4096))
        guard !seen.contains(source) else { return false }
        let entry = Entry(schemaVersion: 1, timestamp: ISO8601DateFormatter().string(from: Date()), deviceID: deviceID, source: source,
                          sourceTruncated: line.count > 4096, matches: matches)
        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        guard entriesWritten < maxEntries, bytesWritten + data.count <= maxBytes else {
            isFull = true
            return false
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        seen.insert(source)
        bytesWritten += data.count
        entriesWritten += 1
        return true
    }
}
