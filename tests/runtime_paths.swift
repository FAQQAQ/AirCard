import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RuntimePathsTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("AirCard paths \(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        func makeFile(_ relativePath: String, executable: Bool = false) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture\n".utf8).write(to: url)
            try files.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            return url
        }

        func expect(_ actual: URL?, _ expected: URL?, _ description: String) throws {
            guard actual?.standardizedFileURL == expected?.standardizedFileURL else {
                throw CheckFailure(description: "\(description): expected \(expected?.path ?? "nil"), got \(actual?.path ?? "nil")")
            }
        }

        // A relocated app must use its own resources, even when another checkout
        // is the working directory. Spaces must remain ordinary path characters.
        let packagedBackend = try makeFile("Moved App/AirCard.app/Contents/Resources/aircard_backend.py")
        let packagedHelper = try makeFile("Moved App/AirCard.app/Contents/Resources/bin/device_helper", executable: true)
        let packagedExecutable = try makeFile("Moved App/AirCard.app/Contents/MacOS/AirCard", executable: true)
        let staleBackend = try makeFile("Stale checkout/aircard_backend.py")
        _ = try makeFile("Stale checkout/build/device_helper", executable: true)
        let packagedRoot = AppRuntimePaths.scriptDirectory(
            resourceURL: packagedBackend.deletingLastPathComponent(),
            executableURL: packagedExecutable,
            currentDirectoryURL: staleBackend.deletingLastPathComponent()
        )
        try expect(packagedRoot, packagedBackend.deletingLastPathComponent(), "packaged resources take precedence")
        try expect(AppRuntimePaths.deviceHelperURL(scriptDirectory: packagedRoot!), packagedHelper, "relocated packaged helper")

        // Finder can launch a standalone build binary with an unrelated CWD.
        let checkoutBackend = try makeFile("Active checkout/aircard_backend.py")
        let checkoutHelper = try makeFile("Active checkout/build/device_helper", executable: true)
        let standalone = try makeFile("Active checkout/build/AirCard_arm64", executable: true)
        let checkout = checkoutBackend.deletingLastPathComponent()
        let standaloneRoot = AppRuntimePaths.scriptDirectory(
            resourceURL: standalone.deletingLastPathComponent(),
            executableURL: standalone,
            currentDirectoryURL: root.appendingPathComponent("Unrelated folder")
        )
        try expect(standaloneRoot, checkout, "standalone executable locates parent checkout")
        try expect(AppRuntimePaths.deviceHelperURL(scriptDirectory: standaloneRoot!), checkoutHelper, "standalone build helper")
        try expect(AppRuntimePaths.scriptDirectory(
            resourceURL: nil, executableURL: standalone,
            currentDirectoryURL: staleBackend.deletingLastPathComponent()
        ), checkout, "stale CWD cannot override executable checkout")

        // A backend alongside the executable has priority over its parent.
        let siblingBackend = try makeFile("Active checkout/build/aircard_backend.py")
        try expect(AppRuntimePaths.scriptDirectory(
            resourceURL: nil, executableURL: standalone,
            currentDirectoryURL: staleBackend.deletingLastPathComponent()
        ), siblingBackend.deletingLastPathComponent(), "executable sibling precedes parent")

        let fallbackBackend = try makeFile("CWD fallback/aircard_backend.py")
        try expect(AppRuntimePaths.scriptDirectory(
            resourceURL: root.appendingPathComponent("No resources"),
            executableURL: nil, currentDirectoryURL: fallbackBackend.deletingLastPathComponent()
        ), fallbackBackend.deletingLastPathComponent(), "CWD is supported as final fallback")
        try expect(AppRuntimePaths.scriptDirectory(
            resourceURL: nil, executableURL: nil,
            currentDirectoryURL: root.appendingPathComponent("Absent checkout")
        ), nil, "missing backend returns nil")

        // Directories named like a script or executable are not usable files.
        let directoryBackend = root.appendingPathComponent("Directory backend/aircard_backend.py")
        try files.createDirectory(at: directoryBackend, withIntermediateDirectories: true)
        try expect(AppRuntimePaths.scriptDirectory(
            resourceURL: directoryBackend.deletingLastPathComponent(),
            executableURL: nil, currentDirectoryURL: root.appendingPathComponent("Absent checkout")
        ), nil, "backend must be a regular file")

        let noHelperBackend = try makeFile("Missing helper/aircard_backend.py")
        try expect(AppRuntimePaths.deviceHelperURL(scriptDirectory: noHelperBackend.deletingLastPathComponent()), nil,
                   "missing local helper cannot borrow from another app")
        let nonexecutable = try makeFile("Helper selection/bin/device_helper")
        let buildHelper = try makeFile("Helper selection/build/device_helper", executable: true)
        let helperRoot = root.appendingPathComponent("Helper selection")
        try expect(AppRuntimePaths.deviceHelperURL(scriptDirectory: helperRoot), buildHelper,
                   "nonexecutable bin candidate is skipped")
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonexecutable.path)
        try expect(AppRuntimePaths.deviceHelperURL(scriptDirectory: helperRoot), nonexecutable,
                   "executable bin candidate takes precedence over build")
        let helperDirectory = root.appendingPathComponent("Directory helper/bin/device_helper")
        try files.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperDirectory.path)
        try expect(AppRuntimePaths.deviceHelperURL(scriptDirectory: root.appendingPathComponent("Directory helper")), nil,
                   "executable directory is not a helper")

        print("Runtime path regression checks passed (13 assertions).")
    }
}
