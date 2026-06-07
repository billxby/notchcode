// Watches ~/.claude/projects/ recursively and pings the engine whenever a
// .jsonl file is created or modified.
//
// Why FSEventStream and not Foundation's URL.resourceValues / DispatchSource?
//   - FSEventStream is the *macOS-native* file-system notification API. It
//     coalesces events kernel-side (cheap), supports recursive watching of a
//     whole directory tree, and survives directory mutations.
//   - It's a C API from Core Services. The signature uses a function pointer
//     (`FSEventStreamCallback`) plus a void* `info` — same shape as POSIX
//     callbacks. Swift exposes it raw, so this file looks more "C-ish" than
//     anything else in the project.

import Foundation

@MainActor
final class ProjectsWatcher {
    static let shared = ProjectsWatcher()
    private init() {}

    private var stream: FSEventStreamRef?
    private weak var engine: SessionStateEngine?

    /// Path we're watching. Resolved once at start().
    private var watchPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    func start(engine: SessionStateEngine) {
        guard stream == nil else { return }   // idempotent
        self.engine = engine

        let path = watchPath

        // FSEventStream silently produces no events if the path doesn't exist.
        // We still create the stream — it's harmless — but warn so the user
        // knows the dir needs to exist (i.e., they need to have run Claude Code
        // at least once).
        if !FileManager.default.fileExists(atPath: path) {
            print("[Notchcode] ~/.claude/projects/ not found yet. Run Claude Code once to create it.")
        }

        // The C callback. It can't capture `self` because it must be a plain
        // C function pointer — so we pass `self` through the void* `info`
        // pointer of the FSEventStreamContext, then unwrap it inside.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info = info else { return }
            // takeUnretainedValue is correct because we passUnretained below;
            // ARC does not give the C API a retain — we keep `self` alive via
            // the singleton.
            let watcher = Unmanaged<ProjectsWatcher>.fromOpaque(info).takeUnretainedValue()

            // `paths` is a CFArray of CFString. Bridge to Swift [String].
            let pathArray = unsafeBitCast(paths, to: NSArray.self) as! [String]

            // Hop to main actor for engine writes.
            Task { @MainActor in
                for p in pathArray {
                    watcher.handle(rawPath: p)
                }
            }
        }

        // Context bundles our `self` pointer for the C callback.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // Create the stream. Returns nil on failure.
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),  // only future events
            0.5,  // latency in seconds — kernel coalesces bursts
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents      // per-file events (not just dir)
                | kFSEventStreamCreateFlagNoDefer       // first event delivered without waiting
                | kFSEventStreamCreateFlagUseCFTypes    // deliver paths as CFArray<CFString>, not char**
            )
        )

        guard let stream else {
            print("[Notchcode] FSEventStreamCreate returned nil. File watcher disabled.")
            return
        }

        // Dispatch events to the main queue so we don't have to thread-hop.
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        print("[Notchcode] Watching \(path)")

        // Boot-time catch-up: scan the last week's JSONLs so the weekly token
        // total reflects work done before Notchcode launched. After this the
        // per-file cursor is at EOF; FSEvents take over from there.
        catchUpWeek(rootPath: path)
    }

    /// Walk `~/.claude/projects/<slug>/*.jsonl` once, parsing every file
    /// whose mtime falls within the engine's 7-day usage window. Skips
    /// silently if the dir doesn't exist.
    private func catchUpWeek(rootPath: String) {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: rootPath) else { return }

        let windowStart = Date().addingTimeInterval(-SessionStateEngine.weekSeconds)

        var recentFiles: [(url: URL, project: String)] = []
        for slug in projects {
            let projectDir = (rootPath as NSString).appendingPathComponent(slug)
            guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { continue }
            let project = decodeProjectSlug(slug)
            for name in files where name.hasSuffix(".jsonl") {
                let path = (projectDir as NSString).appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: path)
                let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
                if mtime >= windowStart {
                    recentFiles.append((URL(fileURLWithPath: path), project))
                }
            }
        }
        guard !recentFiles.isEmpty else { return }

        Task.detached(priority: .utility) { [weak engine = self.engine] in
            // Pool events across ALL files, then sort chronologically so the
            // engine's rolling buffer stays front-oldest (pruneExpired pops
            // from the front) and message history reads in order.
            //
            // Cost events older than the 7-day window are dropped here —
            // they'd be pruned on the engine's first read anyway, no point
            // shipping them across the actor hop. (A file touched this week
            // can still open with week-old lines.)
            var allCosts: [JSONLParser.CostEvent] = []
            var allMessages: [JSONLParser.MessageEvent] = []
            for (url, project) in recentFiles {
                let result = await JSONLParser.shared.parseNew(at: url, project: project)
                allCosts.append(contentsOf: result.costs)
                allMessages.append(contentsOf: result.messages)
            }
            allCosts.removeAll { $0.timestamp < windowStart }
            allCosts.sort { $0.timestamp < $1.timestamp }
            allMessages.sort { $0.timestamp < $1.timestamp }

            guard let engine, !allCosts.isEmpty || !allMessages.isEmpty else { return }
            // Immutable copies — capturing the mutable accumulators in the
            // @MainActor closure is an error under Swift 6 strict concurrency.
            let costs = allCosts
            let messages = allMessages
            await MainActor.run {
                for ev in costs {
                    let usd = CostTracker.cost(for: ev.usage, model: ev.model)
                    // Mirror the steady-state path: cache reads are bulk
                    // re-served tokens, billed at 10× less and not what
                    // Anthropic's quota meter charges against.
                    let tokens = ev.usage.inputTokens
                                 + ev.usage.outputTokens
                                 + ev.usage.cacheCreate5mTokens
                                 + ev.usage.cacheCreate1hTokens
                    guard tokens > 0 else { continue }
                    engine.recordUsage(
                        sessionId: ev.sessionId,
                        project: ev.project,
                        tokens: tokens,
                        usd: usd,
                        at: ev.timestamp
                    )
                }
                for msg in messages {
                    engine.recordMessage(
                        sessionId: msg.sessionId,
                        project: msg.project,
                        role: msg.role == .user ? .user : .assistant,
                        text: msg.text,
                        at: msg.timestamp
                    )
                }
            }
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Event handling

    private func handle(rawPath: String) {
        let url = URL(fileURLWithPath: rawPath)
        // Claude Code writes one JSONL per session: ~/.claude/projects/{slug}/{session-id}.jsonl
        guard url.pathExtension == "jsonl" else { return }

        let sessionId = url.deletingPathExtension().lastPathComponent
        let projectSlug = url.deletingLastPathComponent().lastPathComponent
        let project = decodeProjectSlug(projectSlug)

        engine?.sessionFileTouched(sessionId: sessionId, project: project)

        // v0.7: parse new assistant-message lines for cost data. Off-main
        // because JSONL files can be megabytes after a long session and
        // we don't want to stutter the notch animation.
        Task.detached(priority: .utility) { [weak engine = self.engine] in
            let result = await JSONLParser.shared.parseNew(at: url, project: project)
            guard !result.costs.isEmpty || !result.messages.isEmpty, let engine else { return }
            await MainActor.run {
                for ev in result.costs {
                    let usd = CostTracker.cost(for: ev.usage, model: ev.model)
                    // Count only fresh compute: input + output + cache writes.
                    // Cache reads are bulk re-served tokens — billed at 10× less
                    // and not what Anthropic's quota meter charges against.
                    let tokens = ev.usage.inputTokens
                                 + ev.usage.outputTokens
                                 + ev.usage.cacheCreate5mTokens
                                 + ev.usage.cacheCreate1hTokens
                    guard tokens > 0 else { continue }
                    engine.recordUsage(
                        sessionId: ev.sessionId,
                        project: ev.project,
                        tokens: tokens,
                        usd: usd,
                        at: ev.timestamp
                    )
                }
                for msg in result.messages {
                    engine.recordMessage(
                        sessionId: msg.sessionId,
                        project: msg.project,
                        role: msg.role == .user ? .user : .assistant,
                        text: msg.text,
                        at: msg.timestamp
                    )
                }
            }
        }
    }

    /// Claude Code encodes project paths as folder names by replacing `/` with
    /// `-`, e.g. `/Users/you/notchcode` → `-Users-you-notchcode`. We just
    /// take the last segment for display ("notchcode"). Full path decoding can
    /// land in v0.6 when the popover lists projects.
    private func decodeProjectSlug(_ slug: String) -> String {
        slug.split(separator: "-").last.map(String.init) ?? slug
    }
}
