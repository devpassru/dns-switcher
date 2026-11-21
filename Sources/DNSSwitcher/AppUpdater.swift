import Foundation
import AppKit

public struct AppUpdateInfo: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let releaseURL: URL
    public let downloadURL: URL
}

public enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateInfo)
    case downloading
    case installing
    case failed(String)
}

@MainActor
public final class AppUpdater: ObservableObject {
    public static let shared = AppUpdater()

    public static let repoOwner = "devpassru"
    public static let repoName = "dns-switcher"
    private static let latestReleaseAPI = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"

    @Published public private(set) var state: AppUpdateState = .idle

    private init() {}

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.7.9"
    }

    public var availableUpdate: AppUpdateInfo? {
        if case .available(let info) = state {
            return info
        }
        return nil
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    public func dismissError() {
        if case .failed = state {
            state = .idle
        }
    }

    /// Compares two semantic version strings (e.g. "v1.7.8" vs "1.7.7").
    public nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let parse: (String) -> [Int] = { raw in
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("v") || s.hasPrefix("V") {
                s.removeFirst()
            }
            if let dashIdx = s.firstIndex(of: "-") {
                s = String(s[..<dashIdx])
            }
            return s.split(separator: ".").map { Int($0) ?? 0 }
        }

        let a = parse(candidate)
        let b = parse(current)
        let maxCount = max(a.count, b.count)
        guard maxCount > 0 else { return false }

        for i in 0..<maxCount {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv {
                return av > bv
            }
        }
        return false
    }

    public func checkForUpdates(silent: Bool = false) async {
        guard !isBusy else { return }
        if !silent {
            state = .checking
        }

        guard let url = URL(string: Self.latestReleaseAPI) else {
            if !silent { state = .failed("Некорректный URL обновлений") }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DNSSwitcher/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if !silent { state = .failed("GitHub API вернул ошибку") }
                return
            }

            let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if Self.isVersion(decoded.tagName, newerThan: currentVersion),
               let zipAsset = decoded.assets.first(where: { $0.name == "DNSSwitcher-macOS.zip" }) ?? decoded.assets.first(where: { $0.name.hasSuffix(".zip") }),
               let downloadURL = URL(string: zipAsset.browserDownloadUrl),
               let releaseURL = URL(string: decoded.htmlUrl) {
                let cleanVersion = decoded.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                state = .available(AppUpdateInfo(
                    version: cleanVersion,
                    tagName: decoded.tagName,
                    releaseURL: releaseURL,
                    downloadURL: downloadURL
                ))
            } else if !silent {
                state = .upToDate
            }
        } catch {
            if !silent {
                state = .failed("Не удалось проверить обновления")
            }
        }
    }

    public func installAvailableUpdate() async {
        guard case .available(let info) = state else { return }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            NSWorkspace.shared.open(info.releaseURL)
            state = .failed("Автообновление доступно только для .app")
            return
        }

        state = .downloading
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnsswitcher-update-\(UUID().uuidString)", isDirectory: true)
        var handoffToShell = false
        defer {
            if !handoffToShell {
                try? FileManager.default.removeItem(at: workDir)
            }
        }

        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let (downloadedTmp, response) = try await URLSession.shared.download(from: info.downloadURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                state = .failed("Ошибка загрузки архива")
                return
            }

            let zipURL = workDir.appendingPathComponent("DNSSwitcher-macOS.zip")
            try FileManager.default.moveItem(at: downloadedTmp, to: zipURL)

            state = .installing
            let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            let unzipped = await Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-x", "-k", zipURL.path, extractDir.path]
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    return proc.terminationStatus == 0
                } catch {
                    return false
                }
            }.value

            let newAppURL = extractDir.appendingPathComponent("DNSSwitcher.app", isDirectory: true)
            guard unzipped, FileManager.default.fileExists(atPath: newAppURL.path) else {
                state = .failed("Ошибка распаковки обновления")
                return
            }

            let targetParent = bundleURL.deletingLastPathComponent().path
            let needsAdmin = !FileManager.default.isWritableFile(atPath: targetParent) ||
                             !FileManager.default.isWritableFile(atPath: bundleURL.path)

            let script = makeAtomicReplaceAndRelaunchScript(
                newAppPath: newAppURL.path,
                targetAppPath: bundleURL.path,
                workDirPath: workDir.path,
                runAsUserUID: needsAdmin ? getuid() : nil
            )

            if needsAdmin {
                let bgCmd = "/bin/sh -c \(shellEscape(script)) >/dev/null 2>&1 &"
                let appleScript = "do shell script \(appleScriptStringLiteral(bgCmd)) with administrator privileges"
                let adminOk = await Task.detached(priority: .userInitiated) {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    proc.arguments = ["-e", appleScript]
                    do {
                        try proc.run()
                        proc.waitUntilExit()
                        return proc.terminationStatus == 0
                    } catch {
                        return false
                    }
                }.value

                guard adminOk else {
                    state = .available(info)
                    return
                }
            } else {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/sh")
                proc.arguments = ["-c", script]
                try proc.run()
            }

            handoffToShell = true
            NSApplication.shared.terminate(nil)
        } catch {
            state = .failed("Не удалось установить обновление")
        }
    }

    private func makeAtomicReplaceAndRelaunchScript(
        newAppPath: String,
        targetAppPath: String,
        workDirPath: String,
        runAsUserUID: uid_t?
    ) -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let escNew = shellEscape(newAppPath)
        let escTarget = shellEscape(targetAppPath)
        let escBackup = shellEscape("\(targetAppPath).backup-\(UUID().uuidString)")
        let escWork = shellEscape(workDirPath)

        let openCmd: String
        if let uid = runAsUserUID {
            openCmd = "/bin/launchctl asuser \(uid) /usr/bin/open -n \(escTarget)"
        } else {
            openCmd = "/usr/bin/open -n \(escTarget)"
        }

        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        if [ -e \(escTarget) ]; then
            mv \(escTarget) \(escBackup) || { rm -rf \(escWork); exit 1; }
        fi
        if mv \(escNew) \(escTarget); then
            rm -rf \(escBackup)
        else
            if [ -e \(escBackup) ]; then
                mv \(escBackup) \(escTarget)
            fi
            rm -rf \(escWork)
            exit 1
        fi
        xattr -cr \(escTarget) 2>/dev/null || true
        rm -rf \(escWork)
        \(openCmd)
        """
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
