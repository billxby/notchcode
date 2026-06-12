// SwiftUI presentation for `Agent`. Kept out of the Foundation-only Agent.swift
// so the engine/IO layers stay free of SwiftUI.

import SwiftUI

extension Agent {
    /// Per-agent accent. Claude keeps its established orange; Codex gets a
    /// distinct teal-green so the two read apart at a glance in a mixed list.
    var accent: Color {
        switch self {
        case .claude: return Color(red: 1.00, green: 0.616, blue: 0.239)  // #ff9d3d
        case .codex:  return Color(red: 0.063, green: 0.639, blue: 0.498)  // #10a37f
        }
    }

    /// Short uppercase chip text shown on a session row to identify the agent.
    var badgeText: String {
        switch self {
        case .claude: return "CLAUDE"
        case .codex:  return "CODEX"
        }
    }
}

/// Small colored capsule identifying which agent a session belongs to.
struct AgentBadge: View {
    let agent: Agent
    var body: some View {
        Text(agent.badgeText)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(agent.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(agent.accent.opacity(0.16)))
    }
}
