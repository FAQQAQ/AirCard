import Foundation

// Resolve the backend and its helper from the same installation, whether the
// program is launched from its app bundle or directly from a checkout's build/.
enum AppRuntimePaths {
    static func scriptDirectory(
        resourceURL: URL?,
        executableURL: URL?,
        currentDirectoryURL: URL
    ) -> URL? {
        var candidates: [URL] = []
        if let resourceURL { candidates.append(resourceURL) }
        if let executableDirectory = executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory)
            candidates.append(executableDirectory.deletingLastPathComponent())
        }
        candidates.append(currentDirectoryURL)
        return candidates.first {
            isRegularFile($0.appendingPathComponent("aircard_backend.py"))
        }?.standardizedFileURL
    }

    static func deviceHelperURL(scriptDirectory: URL) -> URL? {
        for relativePath in ["bin/device_helper", "build/device_helper"] {
            let candidate = scriptDirectory.appendingPathComponent(relativePath)
            if isRegularFile(candidate) &&
                FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
