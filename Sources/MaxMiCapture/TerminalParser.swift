import Foundation
import MaxMiCore

/// Dedicated parser for terminal emulators (Warp, Apple Terminal, iTerm2).
///
/// Unlike document/chat apps, a terminal exposes its ENTIRE scrollback as a single
/// AXTextArea blob — no per-command structure, no message rows. So extraction is just
/// "grab the biggest text area", and the interesting decisions are (a) how to derive a
/// stable thread key from a volatile window title, and (b) how to keep an actively-used
/// terminal from creating a near-identical version on every capture tick (content-hash
/// dedup in commitCapture only catches EXACTLY-equal content; a terminal changes by one
/// line constantly).
///
/// The blob IS re-segmented into `{command, output, isRunning}` pairs here by prompt-line
/// detection (`promptPatterns`), which is a heuristic on rendered text: a scrollback whose
/// prompt matches neither shape stays one commandless segment. Phase D replaces this with an
/// anchored parser that reads the emulator's own command boundaries.
public struct TerminalParser: SourceParser {
    static let contentCap = 8000
    public init() {}

    /// Prompt shapes, tried in order. The FIRST one that any line matches becomes the splitter
    /// for the whole scrollback. Each pattern spans the WHOLE prompt through its marker, so the
    /// text after the match is the command alone — never the prompt's cwd.
    static let promptPatterns = [
        "^\\S+@\\S+(?:\\s\\S+)*\\s[%$❯]\\s",   // user@host <path> % command
        "^[~/]\\S*(?:\\s\\S+)*\\s[%$❯]\\s",    // ~/path ❯ command
    ]

    public func parseStructured(window: AXNode, app: AppInfo) throws -> CapturedContent? {
        guard let blob = largestTextArea(in: window), !blob.isEmpty else { return nil }
        return structured(fromScrollback: blob, app: app)
    }

    public func parse(window: AXNode, app: AppInfo) throws -> ParsedCapture? {
        // One AX walk per capture: `parse` reads the blob itself (the thread key needs the raw
        // prompt lines) and shares the segmentation with `parseStructured`.
        guard let blob = largestTextArea(in: window), !blob.isEmpty else { return nil }
        let session = structured(fromScrollback: blob, app: app)
        return ParsedCapture(
            sourceApp: app.name,                 // "Warp", "Terminal", "iTerm2"
            sourceKey: terminalKey(app: app, content: blob),
            sourceTitle: app.windowTitle,
            content: ContentRenderer.render(session, style: .full),
            contentKind: .terminal,
            parserVersion: 2,
            accumulationPolicy: .appendItems,
            offscreenPolicy: .visibleOnly(maxCharacters: 64_000),
            structured: session
        )
    }

    /// The typed session for one scrollback blob.
    func structured(fromScrollback blob: String, app: AppInfo) -> CapturedContent {
        let session = TerminalSession(
            cwd: sessionCwd(fromTitle: app.windowTitle),
            segments: Self.segments(fromScrollback: blob)
        )
        // Newest-anchored hard cap on the STRUCTURED value: the rendered text is derived from it,
        // so capping the string afterwards would just be undone by the renderer.
        return CaptureAccumulator.bound(.terminal(session), to: Self.contentCap)
    }

    /// Split the scrollback on prompt lines. Failure to recognise any prompt yields one segment
    /// with `command: nil` — a full-screen TUI has no command structure to find.
    static func segments(fromScrollback blob: String) -> [TerminalSegment] {
        let lines = blob.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let pattern = promptPatterns.first(where: { candidate in
            lines.contains { $0.range(of: candidate, options: .regularExpression) != nil }
        }) else {
            return [TerminalSegment(command: nil, output: blob, isRunning: false)]
        }

        var segments: [TerminalSegment] = []
        var pendingCommand: String?
        var pendingOutput: [String] = []

        func flush(isRunning: Bool) {
            let output = joinedOutput(pendingOutput)
            guard pendingCommand != nil || !output.isEmpty else { return }
            segments.append(TerminalSegment(command: pendingCommand, output: output, isRunning: isRunning))
        }

        for line in lines {
            if let range = line.range(of: pattern, options: .regularExpression) {
                // A new prompt means whatever came before it has finished.
                flush(isRunning: false)
                pendingOutput = []
                let command = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                pendingCommand = command.isEmpty ? nil : command
            } else {
                pendingOutput.append(line)
            }
        }
        // A BARE trailing prompt (no command, no output after it) means the previous command
        // finished, and it is already flushed with `isRunning: false`. Anything left over — a
        // command awaiting output, or output still arriving — is still running.
        if pendingCommand != nil || !joinedOutput(pendingOutput).isEmpty {
            flush(isRunning: true)
        }
        return segments.isEmpty
            ? [TerminalSegment(command: nil, output: blob, isRunning: false)]
            : segments
    }

    /// Join output lines and drop trailing blank lines, so a segment's bytes are deterministic.
    static func joinedOutput(_ lines: [String]) -> String {
        var lines = lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The session's cwd: the window title when it LOOKS like a path (`~`/`/` prefix), else nil.
    /// Deliberately narrower than `terminalKey`'s cwd sniffing — a title like "✳ Review audit"
    /// or a path buried in command output is not a working directory. Phase D's anchored parser
    /// reads the real absolute cwd instead.
    func sessionCwd(fromTitle title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespaces),
              title.hasPrefix("~") || title.hasPrefix("/") else { return nil }
        return workingDirectory(fromTitle: title)
    }

    /// Terminal scrollback lives in one big AXTextArea. Return the LONGEST text-area value
    /// (Warp = one; some emulators expose a couple — take the richest).
    func largestTextArea(in root: AXNode) -> String? {
        var best: String?
        func walk(_ n: AXNode) {
            if n.role == "AXTextArea", let v = n.value, !v.isEmpty {
                if best == nil || v.count > best!.count { best = v }
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return best
    }

    /// Option B: group terminal activity by working directory / project, so recall is
    /// "what was I doing in the MaxMi repo?" rather than one giant blob or a thread per command.
    /// Strategy: sniff the deepest cwd-looking path from the scrollback (most recent prompt),
    /// fall back to the window title, fall back to the app name. Heuristic by nature — a
    /// terminal has no structured "current directory" attribute, so we read it from the text.
    func terminalKey(app: AppInfo, content: String) -> String {
        let appSlug = slug(app.name)
        if let dir = workingDirectory(fromContent: content) ?? workingDirectory(fromTitle: app.windowTitle) {
            return "terminal:\(appSlug)/\(dir)"
        }
        // No sniffable cwd (e.g. a full-screen TUI like Claude Code). Separate by the stable window
        // id so distinct windows get distinct threads instead of merging into one "terminal:warp"
        // bucket. We deliberately DON'T key on the window title — TUI titles are volatile (spinners)
        // and would spawn a new thread on every capture. Bare app name only if no window id resolved.
        if let wid = app.windowID {
            return "terminal:\(appSlug)/win-\(wid)"
        }
        return "terminal:\(appSlug)"
    }

    /// Find the LAST (most recent) home-or-absolute path in the scrollback and return its
    /// final component — the project/dir you're currently in. Prompts render cwd as "~/foo/bar"
    /// or "/Users/x/foo/bar"; we take "bar". Returns nil if no prompt cwd is present.
    /// Anchors to the PROMPT (path immediately followed by %/$/❯/#), not any path token in
    /// the buffer — so file arguments (inspect2.mjs) and paths in output (MaxMi.app)) are
    /// rejected; only the shell's current directory is used.
    func workingDirectory(fromContent content: String) -> String? {
        for line in content.split(separator: "\n").reversed() {
            if let dir = promptCwd(in: String(line)) { return dir }
        }
        return nil
    }

    /// Warp/iTerm often put the cwd in the title (e.g. "MaxMi — -zsh" or "~/code/MaxMi").
    /// Titles have no prompt terminator, so match a bare path here.
    func workingDirectory(fromTitle title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return lastPathComponent(in: title, requirePrompt: false)
    }

    /// A path that is immediately followed (after optional spaces) by a shell prompt
    /// terminator — i.e. the cwd of a prompt line, not a path buried in output.
    private func promptCwd(in s: String) -> String? {
        lastPathComponent(in: s, requirePrompt: true)
    }

    /// Extract the final component of a ~/... or /Users/... path, slugged.
    /// requirePrompt: the path must be followed by a prompt char (%, $, ❯, #, >) — used for
    /// scrollback lines. false for titles (no prompt present).
    private func lastPathComponent(in s: String, requirePrompt: Bool) -> String? {
        let pathBody = "(~|/Users/[^/ ]+)(/[^ \t\n:%$#>❯]+)*"
        let pattern = requirePrompt ? "\(pathBody)\\s*[%$#>❯]" : pathBody
        guard let range = s.range(of: pattern, options: .regularExpression) else { return nil }
        var path = String(s[range])
        // Strip the trailing prompt char (and any spaces before it) we matched for anchoring.
        if requirePrompt { path = path.trimmingCharacters(in: CharacterSet(charactersIn: " \t%$#>❯")) }
        guard let last = path.split(separator: "/").last, !last.isEmpty else { return nil }
        let component = String(last)
        // Reject file-looking tokens (a real cwd rarely ends in a known file extension).
        if let dot = component.lastIndex(of: "."), dot != component.startIndex {
            let ext = component[component.index(after: dot)...]
            if ext.count <= 5 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return nil }
        }
        return slug(component)
    }

    private func slug(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }
}
