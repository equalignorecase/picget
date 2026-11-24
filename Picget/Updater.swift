import AppKit
import Foundation

@MainActor
final class Updater: ObservableObject {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/equalignorecase/picget/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/equalignorecase/picget/releases")!

    struct Release: Decodable, Equatable, Identifiable {
        struct Asset: Decodable, Equatable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]

        var id: String { tagName }

        var zipAsset: Asset? {
            let zips = assets.filter {
                $0.name.lowercased().hasSuffix(".zip") &&
                $0.browserDownloadURL.scheme?.lowercased() == "https"
            }
            return zips.first(where: { $0.name.localizedCaseInsensitiveContains("picget") }) ?? zips.first
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body
            case htmlURL = "html_url"
            case draft, prerelease, assets
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case noReleases
        case available(Release)
        case downloading(Double?)
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published var state = State.idle
    @Published var presentedRelease: Release?
    var onUpdateAvailable: (() -> Void)?

    private var task: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    nonisolated static func parseVersion(_ raw: String) -> [Int] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        if let separator = cleaned.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            cleaned = String(cleaned[..<separator])
        }
        return cleaned.split(separator: ".").map { Int($0) ?? 0 }
    }

    nonisolated static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        let lhs = parseVersion(remote)
        let rhs = parseVersion(current)
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    func check(manual: Bool) {
        guard !state.isBusy else { return }
        task?.cancel()
        state = .checking
        task = Task {
            do {
                var request = URLRequest(url: Self.latestReleaseURL)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Picget/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw UpdateError.network
                }
                if http.statusCode == 404 {
                    state = manual ? .noReleases : .idle
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    throw UpdateError.network
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                if release.draft == true {
                    state = manual ? .noReleases : .idle
                    return
                }
                if Self.isNewerVersion(release.tagName, than: Self.currentVersion) {
                    state = .available(release)
                    presentedRelease = release
                    onUpdateAvailable?()
                } else {
                    state = manual ? .upToDate(Self.currentVersion) : .idle
                }
            } catch is CancellationError {
                state = .idle
            } catch {
                state = manual ? .failed((error as? UpdateError)?.message ?? "Could not check GitHub for updates.") : .idle
            }
        }
    }

    func install(_ release: Release) {
        guard !state.isBusy else { return }
        guard let asset = release.zipAsset else {
            NSWorkspace.shared.open(release.htmlURL)
            presentedRelease = nil
            state = .idle
            return
        }
        task?.cancel()
        state = .downloading(nil)
        task = Task {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("Picget-update-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let zipURL = staging.appendingPathComponent("update.zip")
                let extractURL = staging.appendingPathComponent("extracted", isDirectory: true)
                try FileManager.default.createDirectory(at: extractURL, withIntermediateDirectories: true)

                var request = URLRequest(url: asset.browserDownloadURL)
                request.timeoutInterval = 60
                request.setValue("Picget/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw UpdateError.downloadFailed
                }
                let expected = http.expectedContentLength
                FileManager.default.createFile(atPath: zipURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: zipURL)
                defer { try? handle.close() }

                var buffer = Data()
                var received: Int64 = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    if buffer.count >= 64 * 1024 {
                        try handle.write(contentsOf: buffer)
                        received += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        if expected > 0 {
                            state = .downloading(min(1, Double(received) / Double(expected)))
                        }
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                }

                state = .installing
                let newApp = try await Task.detached(priority: .userInitiated) {
                    try Self.extractBundle(from: zipURL, into: extractURL)
                }.value

                let destination = try Self.installDestination()
                try Self.scheduleReplaceAndRelaunch(from: newApp, to: destination, cleanup: staging)
                NSApplication.shared.terminate(nil)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: staging)
                state = .available(release)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                state = .failed((error as? UpdateError)?.message ?? "Update failed. Try downloading from GitHub.")
            }
        }
    }

    func dismissReleasePrompt() {
        if case .downloading = state { task?.cancel() }
        presentedRelease = nil
        if case .available = state { state = .idle }
    }

    nonisolated private static func extractBundle(from zipURL: URL, into extractURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, extractURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.installFailed }

        let direct = extractURL.appendingPathComponent("Picget.app")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let children = try FileManager.default.contentsOfDirectory(
            at: extractURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if let topApp = children.first(where: { $0.pathExtension == "app" }) { return topApp }
        for child in children {
            let nested = child.appendingPathComponent("Picget.app")
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
        }
        throw UpdateError.installFailed
    }

    nonisolated private static func installDestination() throws -> URL {
        let current = Bundle.main.bundleURL
        let fm = FileManager.default
        if current.pathExtension == "app",
           fm.isWritableFile(atPath: current.deletingLastPathComponent().path) {
            return current
        }
        let applications = URL(fileURLWithPath: "/Applications/Picget.app")
        if fm.isWritableFile(atPath: "/Applications") {
            return applications
        }
        throw UpdateError.permissionDenied
    }

    nonisolated private static func scheduleReplaceAndRelaunch(from source: URL, to target: URL, cleanup: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3" && /usr/bin/ditto "$2" "$3" && /usr/bin/open "$3"
        rm -rf "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "picget-updater", "\(pid)", source.path, target.path, cleanup.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    enum UpdateError: Error {
        case network
        case downloadFailed
        case installFailed
        case permissionDenied

        var message: String {
            switch self {
            case .network: return "Could not check GitHub for updates."
            case .downloadFailed: return "Could not download the update from GitHub."
            case .installFailed: return "Could not install the downloaded update."
            case .permissionDenied: return "Picget does not have permission to replace the app bundle."
            }
        }
    }
}
