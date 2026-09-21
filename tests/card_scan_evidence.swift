import Foundation

@main
struct ScanEvidenceTests {
    static func check(_ condition: @autoclosure () throws -> Bool) rethrows {
        let value = try condition()
        precondition(value)
    }

    static func main() throws {
        let card = "abcdefghijklmnopqrstuvwxyza="
        let full = "/var/mobile/Library/Passes/Cards/\(card).pkcache/FrontFace"
        let line = "passd[100] image cache read failed: \"\(full)\""
        let matches = CardScanEvidence.matches(in: line)
        precondition(matches.count == 1)
        precondition(matches[0].cardID == card)
        precondition(matches[0].hasAbsolutePath)
        precondition(matches[0].path == full)
        precondition(matches[0].containerPath == "/var/mobile/Library/Passes/Cards/\(card).pkcache")

        let privateMatch = CardScanEvidence.matches(in: "Wallet face /private\(full)")
        precondition(privateMatch[0].hasAbsolutePath)
        precondition(privateMatch[0].path == "/private\(full)")

        let partial = CardScanEvidence.matches(in: "passd cache /Passes/Cards/\(card).cache/Preview")
        precondition(partial.count == 1 && partial[0].kind == .partialCardPath)
        precondition(!partial[0].hasAbsolutePath)
        let basename = CardScanEvidence.matches(in: "passd image file at /unknown/\(card).pkpass/texture.png")
        precondition(basename.count == 1 && basename[0].kind == .partialCardPath)
        precondition(!basename[0].hasAbsolutePath)
        let weak = CardScanEvidence.matches(in: "passd card identifier \(card)")
        precondition(weak.count == 1 && weak[0].kind == .bareIdentifier)
        precondition(weak[0].path == nil && !weak[0].hasAbsolutePath)

        // Anonymized forms of the real device lines that the previous context
        // filter dropped before the identifier regex was ever reached.
        let dashboardPrefix = "Sep 21 21:32:38 TestPhone Passbook(PassKitUI)[1234] <Notice>: Dashboard loading (0x12345678): "
        let dashboardLines = [
            dashboardPrefix + "for \(card), pass feature unknown",
            dashboardPrefix + "\(card) - m:NO, sm:YES, em:NO, b:NO, p:NO, sp:YES, f:YES, crpp:YES, ti:NO, as:NO, rg:NO, fk:YES, a:NO u:YES ui:YES pc:YES rpp:NO aai:NO bc:YES t:NO, tg:YES, tsc:NO",
            "\0" + dashboardPrefix + "\(card) - m:YES, sm:YES, em:YES, b:YES, p:YES, sp:YES, f:YES, crpp:YES, ti:YES, as:YES, rg:YES, fk:YES, a:YES u:YES ui:YES pc:YES rpp:YES aai:YES bc:YES t:YES, tg:YES, tsc:YES"
        ]
        for dashboardLine in dashboardLines {
            let detected = CardScanEvidence.matches(in: dashboardLine)
            precondition(detected.count == 1 && detected[0].cardID == card)
            precondition(detected[0].kind == .bareIdentifier && !detected[0].hasAbsolutePath)
            precondition(detected[0].path == nil && detected[0].containerPath == nil)
        }
        let otherIdentifier = String(repeating: "z", count: 27) + "="
        let multipleCandidates = CardScanEvidence.matches(in: dashboardPrefix + "\(card), related \(otherIdentifier)")
        precondition(multipleCandidates.count == 2)
        precondition(multipleCandidates.allSatisfy { $0.kind == .bareIdentifier && $0.path == nil && !$0.hasAbsolutePath })
        precondition(CardScanEvidence.matches(in: dashboardPrefix + "no entries yet").isEmpty)
        precondition(CardScanEvidence.matches(in: "Weather[1234] Dashboard loading: \(card)").isEmpty)
        precondition(CardScanEvidence.matches(in: "Passbook(PassKitUI)[1234] heartbeat alive \(card)").isEmpty)
        precondition(CardScanEvidence.matches(in: "Passbook(PassKitUI)[1234] Dashboard heartbeat alive \(card)").isEmpty)
        precondition(CardScanEvidence.matches(in: "unrelated photo identifier \(card)").isEmpty)
        precondition(CardScanEvidence.matches(in: "passd heartbeat alive \(card)").isEmpty)
        precondition(CardScanEvidence.matches(in: "passd card M6nDwZrkYbFlsodLgCbvyFZQ1cc=").isEmpty)
        precondition(!CardScanEvidence.matches(in: "passd \(full.replacingOccurrences(of: ".pkcache/FrontFace", with: ".pkcacheFake"))")
            .contains(where: \.hasAbsolutePath))
        precondition(CardScanEvidence.matches(in: "passd card \(String(repeating: "x", count: 66_000)) \(card)").isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scan-evidence-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let dashboardWriter = try CardScanEvidenceWriter(directory: directory, deviceID: "TEST-DEVICE")
        for dashboardLine in dashboardLines {
            try check(dashboardWriter.append(line: dashboardLine, matches: CardScanEvidence.matches(in: dashboardLine)))
        }
        let dashboardData = try Data(contentsOf: dashboardWriter.fileURL)
        let dashboardRecords = String(decoding: dashboardData, as: UTF8.self).split(separator: "\n")
        precondition(dashboardRecords.count == dashboardLines.count)
        let dashboardRecord = try JSONSerialization.jsonObject(with: Data(dashboardRecords[0].utf8)) as! [String: Any]
        precondition(dashboardRecord["source"] as? String == dashboardLines[0])
        let dashboardRecordedMatches = dashboardRecord["matches"] as! [[String: Any]]
        precondition(dashboardRecordedMatches[0]["kind"] as? String == "unverified_identifier")
        precondition(dashboardRecordedMatches[0]["path"] == nil)
        let writer = try CardScanEvidenceWriter(directory: directory, deviceID: "TEST-DEVICE", maxEntries: 2)
        try check(writer.append(line: line, matches: matches))
        try check(!writer.append(line: line, matches: matches))
        try check(!writer.append(line: "unrelated", matches: []))
        try check(writer.append(line: "passd card \(card) \(String(repeating: "x", count: 5000))", matches: weak))
        try check(!writer.append(line: "another line", matches: weak))
        precondition(writer.isFull)
        let data = try Data(contentsOf: writer.fileURL)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        precondition(lines.count == 2)
        let record = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        precondition(record["source"] as? String == line)
        precondition(record["deviceID"] as? String == "TEST-DEVICE")
        precondition(record["schemaVersion"] as? Int == 1)
        let truncated = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
        precondition(truncated["sourceTruncated"] as? Bool == true)
        precondition((truncated["source"] as! String).count == 4096)
        let permissions = try FileManager.default.attributesOfItem(atPath: writer.fileURL.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let dirPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        precondition(dirPermissions.intValue == 0o700)
        let tiny = try CardScanEvidenceWriter(directory: directory, maxBytes: 10)
        try check(!tiny.append(line: line, matches: matches))
        precondition(tiny.isFull)
        try check(Data(contentsOf: tiny.fileURL).isEmpty)

        // Optional private capture replay. Only read the supplied JSON; never
        // embed device/card identifiers in committed fixtures or test output.
        if CommandLine.arguments.count > 1 {
            precondition(CommandLine.arguments.count == 2, "Expected one optional capture JSON path")
            let captureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let capture = try JSONSerialization.jsonObject(with: captureData) as! [String: Any]
            let capturedLines = capture["asset_clues"] as! [String]
            precondition(!capturedLines.isEmpty, "Capture contains no asset_clues lines")
            for capturedLine in capturedLines {
                let capturedMatches = CardScanEvidence.matches(in: capturedLine)
                precondition(!capturedMatches.isEmpty, "A captured Dashboard line was not detected")
                precondition(capturedMatches.allSatisfy {
                    $0.kind == .bareIdentifier && !$0.hasAbsolutePath && $0.path == nil && $0.containerPath == nil
                }, "Captured Dashboard identifiers must remain unverified")
            }
            print("Dashboard capture replay passed: \(capturedLines.count)/\(capturedLines.count) lines")
        }
        print("Scan evidence regression checks passed")
    }
}
