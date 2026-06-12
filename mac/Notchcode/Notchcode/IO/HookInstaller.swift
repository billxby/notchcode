// Detects whether Notchcode's hook entries are wired into a coding agent's
// config file, and runs the bundled installer/uninstaller scripts on demand.
//
// Per-agent: Claude Code (~/.claude/settings.json) and Codex (~/.codex/hooks.json)
// are tracked and installed INDEPENDENTLY — installing or removing one never
// touches the other. Both files share the same {hooks:{Event:[…]}} shape and
// the same loopback marker "127.0.0.1:9876", so one detector handles both.
//
// State is @Observable so the UI can show two independent install rows that
// react when the user clicks Install and a file flips.

import Foundation
import Observation

@Observable
@MainActor
final class HookInstaller {
    static let shared = HookInstaller()

    /// Per-agent install state, refreshed by `refresh()`. UI reads via
    /// `isInstalled(_:)`. NotchcodeApp warms it at launch; the script runners
    /// refresh after they finish.
    private(set) var installed: [Agent: Bool] = [:]

    /// Per-agent last error from a script run, surfaced briefly in the UI.
    private(set) var lastError: [Agent: String] = [:]

    /// Agents with a script currently running, so the UI can disable buttons.
    private(set) var working: Set<Agent> = []

    private init() {}

    // MARK: - Detection

    func isInstalled(_ agent: Agent) -> Bool { installed[agent] ?? false }
    func lastError(_ agent: Agent) -> String? { lastError[agent] }
    func isWorking(_ agent: Agent) -> Bool { working.contains(agent) }

    /// Re-reads every agent's config file and flips `installed`. Cheap enough
    /// to call on demand (the files are tiny).
    func refresh() {
        for agent in Agent.allCases {
            installed[agent] = Self.detectInstalled(agent)
        }
    }

    /// Loopback marker — must match install-hooks.sh exactly. Any change to the
    /// port requires updating both. Single source of truth is the script; this
    /// is the Swift-side mirror.
    static let marker = "127.0.0.1:9876"

    private static func detectInstalled(_ agent: Agent) -> Bool {
        guard let data = try? Data(contentsOf: agent.hookConfigFile),
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

    /// Runs the bundled `install-hooks.sh <agent>`. Refreshes state on exit.
    func runInstaller(_ agent: Agent) {
        runScript(named: "install-hooks", agent: agent)
    }

    func runUninstaller(_ agent: Agent) {
        runScript(named: "uninstall-hooks", agent: agent)
    }

    private func runScript(named scriptName: String, agent: Agent) {
        guard let scriptURL = Bundle.main.url(forResource: scriptName, withExtension: "sh") else {
            lastError[agent] = "\(scriptName).sh not bundled with this build."
            return
        }
        working.insert(agent)
        lastError[agent] = nil

        Task.detached(priority: .userInitiated) { [scriptURL, agent] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptURL.path, agent.rawValue]
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
                HookInstaller.shared.working.remove(agent)
                HookInstaller.shared.lastError[agent] = errorMessage
                HookInstaller.shared.refresh()
            }
        }
    }

    // MARK: - One-line install command (for users without the .app)

    /// The public curl one-liner — serves the canonical script straight from
    /// the repo. Pass the agent as the script argument.
    static func oneLineInstallCommand(_ agent: Agent) -> String {
        "curl -fsSL https://raw.githubusercontent.com/billxby/notchcode/main/mac/Notchcode/Notchcode/Resources/install-hooks.sh | bash -s -- \(agent.rawValue)"
    }
}
