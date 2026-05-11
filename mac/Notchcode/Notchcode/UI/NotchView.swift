// The SwiftUI view that lives INSIDE the notch panel.
//
// v0.3: surfaces the richer status enum (working tool name, waiting, done,
// error) coming from hook events. Visuals stay minimal — color tuning and
// animations land in v0.4.
//
// Reactive plumbing: because SessionStateEngine is @Observable, every
// property read inside `body` auto-subscribes. Like Riverpod's `ref.watch`
// but implicit — no wrapper, no .obs, just a plain property access.

import SwiftUI

struct NotchView: View {
    let size: CGSize
    let engine: SessionStateEngine

    var body: some View {
        ZStack {
            NotchShape()
                .fill(.black)

            Text(statusLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 12)
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
    }

    // MARK: - Derived label

    private var statusLabel: String {
        let count = engine.activeSessions.count
        switch engine.aggregateStatus {
        case .idle:
            return "idle"
        case .working(let tool?):
            // "Edit" / "Read" / "Bash" — Claude Code's tool names are already
            // short and PascalCase. If multiple sessions, prefix the count.
            return count > 1 ? "\(count) · \(tool)" : tool
        case .working(nil):
            return count > 1 ? "\(count) working" : "working"
        case .waiting:
            return count > 1 ? "\(count) waiting" : "waiting on you"
        case .done:
            return "done"
        case .error(let msg):
            return msg
        }
    }
}

#Preview {
    NotchView(size: CGSize(width: 260, height: 72), engine: SessionStateEngine.shared)
        .padding(40)
        .background(.gray)
}
