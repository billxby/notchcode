// Detects whether Notchcode's hook entries are wired into Claude Code's
// ~/.claude/settings.json, and runs the bundled installer/uninstaller
// scripts on demand.
//
// The check is the same shape as install-hooks.sh's match logic: look for
// the loopback marker "127.0.0.1:9876" inside any hook command. We don't
// parse the full Claude Code hook schema — the marker is the contract.
//
// Flutter analogy: a small repository-style helper that wraps a tiny shell
// out + a JSON read. State (`isInstalled`) is @Observable so the UI can
// react when the user clicks Install and the file flips.

import Foundation
import Observation

@Observable
@MainActor
final class HookInstaller {
    static let shared = HookInstaller()

    /// Cached result of the last `refresh()` call. UI reads this; NotchcodeApp
    /// warms it at launch and `runInstaller()` / `runUninstaller()` refresh
    /// it after they finish.
    private(set) var isInstalled: Bool = false

    /// Last error message from a script run, surfaced briefly in the UI.
    /// Cleared on the next successful run.
    private(set) var lastError: String? = nil

    /// True only while a script is running, so the UI can disable buttons.
    private(set) var isWorking: Bool = false

    private init() {}

    // MARK: - Detection

    /// Re-reads `~/.claude/settings.json` and flips `isInstalled`.
    /// Cheap enough to call on demand (the file is tiny).
    func refresh() {
        isInstalled = Self.detectInstalled()
    }

    /// Loopback marker — must match install-hooks.sh exactly. Any rename of
    /// the port requires updating both. Kept as a single source of truth in
    /// the script; this copy is a Swift-side mirror.
    static let marker = "127.0.0.1:9876"

    private static func detectInstalled() -> Bool {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else { return false }

        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let hookList = group["hooks"] as? [[String: Any]] else { continue }
                for hook in hookList {
                    if let cmd = hook["command"] as? String, cmd.contains(marker) {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Run scripts

    /// Runs the bundled `install-hooks.sh`. Refreshes `isInstalled` on exit.
    /// Errors surface in `lastError`.
    func runInstaller() {
        runScript(named: "install-hooks")
    }

    func runUninstaller() {
        runScript(named: "uninstall-hooks")
    }

    private func runScript(named scriptName: String) {
        guard let scriptURL = Bundle.main.url(forResource: scriptName, withExtension: "sh") else {
            lastError = "\(scriptName).sh not bundled with this build."
            return
        }
        isWorking = true
        lastError = nil

        Task.detached(priority: .userInitiated) { [scriptURL] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptURL.path]
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            // nil errorMessage = success.
            let errorMessage: String?
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    errorMessage = nil
                } else {
                    let raw = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "exit \(task.terminationStatus)"
                    errorMessage = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            await MainActor.run {
                HookInstaller.shared.isWorking = false
                HookInstaller.shared.lastError = errorMessage
                HookInstaller.shared.refresh()
            }
        }
    }

    // MARK: - One-line install command (for users without the .app)

    /// The public curl one-liner — serves the canonical script straight from
    /// the repo, so there's a single source of truth with the bundled copy
    /// the in-app "Install hooks…" button runs. Matching uninstaller lives at
    /// the same path: .../Resources/uninstall-hooks.sh.
    static let oneLineInstallCommand =
        "curl -fsSL https://raw.githubusercontent.com/billxby/notchcode/main/mac/Notchcode/Notchcode/Resources/install-hooks.sh | bash"
}
