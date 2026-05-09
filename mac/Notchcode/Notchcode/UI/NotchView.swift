// The SwiftUI view that lives INSIDE the notch panel.
//
// v0.2: reads from `SessionStateEngine` to display aggregate state. Because
// the engine is `@Observable`, every property read inside `body` is auto-
// tracked — when `engine.aggregateStatus` changes, SwiftUI rebuilds this view.
// Equivalent to Riverpod's `ref.watch(...)` in Flutter, except the dependency
// is implicit (just by reading the property).

import SwiftUI

struct NotchView: View {
    let size: CGSize

    /// The engine reference. With @Observable, plain `let` is enough — no
    /// @ObservedObject wrapper needed. SwiftUI tracks reads of its properties.
    let engine: SessionStateEngine

    var body: some View {
        ZStack {
            // Shape color reacts to status. v0.4 will animate this transition.
            NotchShape()
                .fill(shapeColor)

            // Status label. We read engine.activeSessions / aggregateStatus
            // here → SwiftUI auto-subscribes → label updates as state changes.
            Text(statusLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()   // session counts don't jitter as digits change
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
    }

    // MARK: - Derived UI

    private var shapeColor: Color {
        switch engine.aggregateStatus {
        case .idle:    return .black
        case .working: return .black   // v0.4 will switch to a blue tint + spinner
        }
    }

    private var statusLabel: String {
        let count = engine.activeSessions.count
        switch engine.aggregateStatus {
        case .idle:
            return "idle"
        case .working:
            return count == 1 ? "working" : "\(count) working"
        }
    }
}

#Preview {
    NotchView(size: CGSize(width: 260, height: 72), engine: SessionStateEngine.shared)
        .padding(40)
        .background(.gray)
}
