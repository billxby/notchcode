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
//
// Flutter analogy: `Directory.watch()` returns a Stream<FileSystemEvent> that
// abstracts platform differences. macOS uses FSEvents under the hood. We're
// dropping below that abstraction so we can recurse and tune coalescing.

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
    }

    /// Claude Code encodes project paths as folder names by replacing `/` with
    /// `-`, e.g. `/Users/you/notchcode` → `-Users-billxu-notchcode`. We just
    /// take the last segment for display ("notchcode"). Full path decoding can
    /// land in v0.6 when the popover lists projects.
    private func decodeProjectSlug(_ slug: String) -> String {
        slug.split(separator: "-").last.map(String.init) ?? slug
    }
}
