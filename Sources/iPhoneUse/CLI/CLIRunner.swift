import Foundation

/// Handles CLI subcommands (`task`, `photo_*`, `file_*`, `app_list`, `open_app`, `device_info`,
/// `device_logs`, `assistivetouch`) without starting AppKit when invoked from the command line.
enum CLIRunner {
    static let supportedCommands: Set<String> = [
        "task",
        "setup_status", "setup-status",
        "list", "list_devices", "devices", "status",
        "acquire", "wait", "release",
        "screentext",
        "tap_text", "tap-text", "tap_icon", "tap-icon",
        "scroll", "scroll_until", "scroll-until", "scroll_collect", "scroll-collect",
        "exec", "run",
        "photo_list", "photo_pull", "photo_delete", "photo_push", "photo", "photos",
        "file_list", "file_pull", "file_push", "file_remove", "file", "files",
        "app_list", "open_app", "app", "apps",
        "device_info", "info",
        "device_logs", "logs",
        "assistivetouch", "assistive-touch",
    ]

    static func shouldRunCLI(arguments: [String]) -> Bool {
        guard let first = arguments.dropFirst().first?.lowercased() else {
            return false
        }
        return supportedCommands.contains(first)
    }

    static func runAndExit(arguments: [String] = CommandLine.arguments) -> Never {
        let result = execute(arguments: Array(arguments.dropFirst()))
        if !result.stdout.isEmpty {
            FileHandle.standardOutput.write(Data((result.stdout + "\n").utf8))
        }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data((result.stderr + "\n").utf8))
        }
        exit(result.exitCode)
    }

    /// Parses and executes a CLI command (where `args` excludes the binary name `iphone-use`),
    /// returning `(exitCode, stdout, stderr)`.
    static func execute(
        arguments args: [String],
        runtimeHooks: GhosthandRuntimeHooks? = nil
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        if let head = args.first?.lowercased(), head == "exec" || head == "run" {
            return executePythonHarness(arguments: Array(args.dropFirst()))
        }
        do {
            let request = try buildRequest(from: args)
            let response = ControlAPI.handle(request, runtimeHooks: runtimeHooks)
            let bodyText = String(data: response.body, encoding: .utf8) ?? "{}"
            if (200..<300).contains(response.status) {
                return (0, bodyText, "")
            } else {
                return (1, bodyText, bodyText)
            }
        } catch let ghostError as GhosthandError {
            let data =
                (try? JSONSerialization.data(withJSONObject: ghostError.json(), options: [.sortedKeys]))
                ?? Data()
            let text = String(data: data, encoding: .utf8) ?? ghostError.message
            return (1, text, text)
        } catch {
            let payload: [String: Any] = ["ok": false, "error": "\(error)"]
            let data =
                (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "\(error)"
            return (1, text, text)
        }
    }

    static func buildRequest(from args: [String]) throws -> HTTPRequest {
        guard let head = args.first?.lowercased() else {
            throw GhosthandError.invalidArgument("Missing CLI subcommand")
        }

        var index = 1
        var command = head
        if ["photo", "photos", "file", "files", "app", "apps"].contains(head),
            index < args.count,
            !args[index].hasPrefix("-")
        {
            let sub = args[index].lowercased()
            index += 1
            switch (head, sub) {
            case ("photo", "list"), ("photos", "list"), ("photo", "ls"), ("photos", "ls"):
                command = "photo_list"
            case ("photo", "pull"), ("photos", "pull"), ("photo", "get"), ("photos", "get"):
                command = "photo_pull"
            case ("photo", "delete"), ("photos", "delete"), ("photo", "rm"), ("photos", "rm"):
                command = "photo_delete"
            case ("photo", "push"), ("photos", "push"), ("photo", "import"), ("photos", "import"):
                command = "photo_push"
            case ("file", "list"), ("files", "list"), ("file", "ls"), ("files", "ls"):
                command = "file_list"
            case ("file", "pull"), ("files", "pull"), ("file", "get"), ("files", "get"):
                command = "file_pull"
            case ("file", "push"), ("files", "push"), ("file", "put"), ("files", "put"):
                command = "file_push"
            case ("file", "remove"), ("files", "remove"), ("file", "rm"), ("files", "rm"):
                command = "file_remove"
            case ("app", "list"), ("apps", "list"), ("app", "ls"), ("apps", "ls"):
                command = "app_list"
            case ("app", "open"), ("apps", "open"), ("app", "launch"), ("apps", "launch"):
                command = "open_app"
            default:
                throw GhosthandError.invalidArgument("Unknown subcommand: \(head) \(sub)")
            }
        }

        var body: [String: Any] = [:]
        var positionals: [String] = []

        func nextValue(for flag: String) throws -> String {
            guard index < args.count else {
                throw GhosthandError.invalidArgument("Missing value for \(flag)")
            }
            let val = args[index]
            index += 1
            return val
        }

        while index < args.count {
            let token = args[index]
            index += 1
            switch token {
            case "-d", "--device":
                body["device"] = try nextValue(for: token)
            case "-l", "--lease":
                body["lease"] = try nextValue(for: token)
            case "-p", "--prompt":
                body["prompt"] = try nextValue(for: token)
            case "-r", "--resume", "--task", "--task-id":
                body["resume"] = try nextValue(for: token)
            case "--thinking-level", "--thinking":
                body["thinking_level"] = try nextValue(for: token)
            case "--max-steps":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--max-steps must be an integer")
                }
                body["max_steps"] = val
            case "--approve", "--confirm-safety":
                body["approve"] = true
            case "--no-approve":
                body["approve"] = false
            case "--path":
                body["path"] = try nextValue(for: token)
            case "--source", "--file":
                body["source"] = try nextValue(for: token)
            case "-o", "--output", "--destination":
                body["output"] = try nextValue(for: token)
            case "--filename", "--name":
                body["filename"] = try nextValue(for: token)
            case "--data", "--base64":
                body["data"] = try nextValue(for: token)
            case "--content", "--text":
                body["content"] = try nextValue(for: token)
            case "-b", "--bundle-id", "--bundle":
                body["bundle_id"] = try nextValue(for: token)
            case "--limit":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--limit must be an integer")
                }
                body["limit"] = val
            case "--seconds":
                let raw = try nextValue(for: token)
                guard let val = Double(raw) else {
                    throw GhosthandError.invalidArgument("--seconds must be a number")
                }
                body["seconds"] = val
            case "--lines", "--max-lines":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--lines must be an integer")
                }
                body["lines"] = val
            case "--contains", "--filter", "--process":
                body["contains"] = try nextValue(for: token)
            case "--enabled":
                let raw = try nextValue(for: token)
                guard let flag = PostActionOptions.parseBoolFlag(raw) else {
                    throw GhosthandError.invalidArgument("--enabled must be true/false/on/off")
                }
                body["enabled"] = flag
            case "--on", "--enable":
                body["enabled"] = true
            case "--off", "--disable":
                body["enabled"] = false
            case "-R", "--recursive":
                body["recursive"] = true
            case "--app":
                body["app"] = try nextValue(for: token)
            case "--wait-text":
                body["wait_text"] = try nextValue(for: token)
            case "--timeout-ms":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--timeout-ms must be an integer")
                }
                body["timeout_ms"] = val
            case "--screentext":
                body["screentext"] = true
            case "--settle":
                body["settle"] = true
            case "--reason":
                body["reason"] = try nextValue(for: token)
            case "--label":
                body["label"] = try nextValue(for: token)
            case "--force":
                body["force"] = true
            case "--exact":
                body["exact"] = true
            case "--index":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--index must be an integer")
                }
                body["index"] = val
            case "--offset-x":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--offset-x must be an integer")
                }
                body["offset_x"] = val
            case "--offset-y":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--offset-y must be an integer")
                }
                body["offset_y"] = val
            case "--icon":
                body["icon"] = true
            case "--direction", "--dir":
                body["direction"] = try nextValue(for: token)
            case "--ticks":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--ticks must be an integer")
                }
                body["ticks"] = val
            case "--until-text", "--until":
                body["until_text"] = try nextValue(for: token)
            case "--collect":
                body["collect"] = true
            case "--max-scrolls":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--max-scrolls must be an integer")
                }
                body["max_scrolls"] = val
            case "--end-after":
                let raw = try nextValue(for: token)
                guard let val = Int(raw) else {
                    throw GhosthandError.invalidArgument("--end-after must be an integer")
                }
                body["end_after"] = val
            case "--min-confidence":
                let raw = try nextValue(for: token)
                guard let val = Double(raw) else {
                    throw GhosthandError.invalidArgument("--min-confidence must be a number")
                }
                body["min_confidence"] = val
            case "--content-only":
                body["content_only"] = true
            default:
                if token.hasPrefix("-") {
                    throw GhosthandError.invalidArgument("Unknown flag: \(token)")
                }
                positionals.append(token)
            }
        }

        switch command {
        case "setup_status", "setup-status":
            var query: [String: String] = [:]
            if let dev = (body["device"] as? String) ?? positionals.first {
                query["device"] = dev
            }
            return HTTPRequest(method: "GET", path: "/setup_status", query: query, body: [:])

        case "list", "list_devices", "devices":
            return HTTPRequest(method: "GET", path: "/devices", query: [:], body: [:])

        case "status":
            return HTTPRequest(method: "GET", path: "/status", query: [:], body: [:])

        case "acquire":
            if body["reason"] == nil, !positionals.isEmpty {
                body["reason"] = positionals.joined(separator: " ")
            }
            return HTTPRequest(method: "POST", path: "/leases/acquire", query: [:], body: body)

        case "wait":
            if body["reason"] == nil, !positionals.isEmpty {
                body["reason"] = positionals.joined(separator: " ")
            }
            return HTTPRequest(method: "POST", path: "/leases/wait", query: [:], body: body)

        case "release":
            if body["lease"] == nil, let first = positionals.first {
                body["lease"] = first
            }
            return HTTPRequest(method: "POST", path: "/leases/release", query: [:], body: body)

        case "screentext":
            if body["device"] == nil, let first = positionals.first {
                body["device"] = first
            }
            return HTTPRequest(method: "POST", path: "/screentext", query: [:], body: body)

        case "tap_text", "tap-text":
            if body["text"] == nil, let tx = body["content"] as? String {
                body["text"] = tx
            } else if body["text"] == nil, !positionals.isEmpty {
                body["text"] = positionals.joined(separator: " ")
            }
            return HTTPRequest(method: "POST", path: "/tap_text", query: [:], body: body)

        case "tap_icon", "tap-icon":
            if body["text"] == nil, let tx = body["content"] as? String {
                body["text"] = tx
            } else if body["text"] == nil, !positionals.isEmpty {
                body["text"] = positionals.joined(separator: " ")
            }
            body["icon"] = true
            return HTTPRequest(method: "POST", path: "/tap_icon", query: [:], body: body)

        case "scroll":
            if body["direction"] == nil, let first = positionals.first {
                body["direction"] = first
            }
            if body["direction"] == nil {
                body["direction"] = "down"
            }
            return HTTPRequest(method: "POST", path: "/scroll", query: [:], body: body)

        case "scroll_until", "scroll-until":
            if body["until_text"] == nil, let tx = body["content"] as? String {
                body["until_text"] = tx
            } else if body["until_text"] == nil, !positionals.isEmpty {
                body["until_text"] = positionals.joined(separator: " ")
            }
            if body["direction"] == nil {
                body["direction"] = "down"
            }
            return HTTPRequest(method: "POST", path: "/scroll_until", query: [:], body: body)

        case "scroll_collect", "scroll-collect":
            if body["direction"] == nil, let first = positionals.first {
                body["direction"] = first
            }
            if body["direction"] == nil {
                body["direction"] = "down"
            }
            body["collect"] = true
            return HTTPRequest(method: "POST", path: "/scroll_collect", query: [:], body: body)

        case "task":
            if body["prompt"] == nil && !positionals.isEmpty {
                body["prompt"] = positionals.joined(separator: " ")
            }
            return HTTPRequest(method: "POST", path: "/task", query: [:], body: body)

        case "photo_list", "photos":
            return HTTPRequest(method: "POST", path: "/photos/list", query: [:], body: body)

        case "photo_pull":
            if body["path"] == nil, let first = positionals.first {
                body["path"] = first
                if body["output"] == nil, positionals.count >= 2 {
                    body["output"] = positionals[1]
                }
            }
            return HTTPRequest(method: "POST", path: "/photos/pull", query: [:], body: body)

        case "photo_delete":
            if body["path"] == nil, let first = positionals.first {
                body["path"] = first
            }
            return HTTPRequest(method: "POST", path: "/photos/delete", query: [:], body: body)

        case "photo_push":
            if body["path"] == nil && body["source"] == nil, let first = positionals.first {
                body["path"] = first
            }
            return HTTPRequest(method: "POST", path: "/photos/push", query: [:], body: body)

        case "file_list", "files":
            if body["path"] == nil, let first = positionals.first {
                body["path"] = first
            }
            return HTTPRequest(method: "POST", path: "/files/list", query: [:], body: body)

        case "file_pull":
            if body["path"] == nil, let first = positionals.first {
                body["path"] = first
                if body["output"] == nil, positionals.count >= 2 {
                    body["output"] = positionals[1]
                }
            }
            return HTTPRequest(method: "POST", path: "/files/pull", query: [:], body: body)

        case "file_push":
            if positionals.count >= 2 {
                if body["source"] == nil { body["source"] = positionals[0] }
                if body["path"] == nil { body["path"] = positionals[1] }
            } else if let first = positionals.first, body["path"] == nil {
                body["path"] = first
            }
            return HTTPRequest(method: "POST", path: "/files/push", query: [:], body: body)

        case "file_remove":
            if body["path"] == nil, let first = positionals.first {
                body["path"] = first
            }
            return HTTPRequest(method: "POST", path: "/files/remove", query: [:], body: body)

        case "app_list", "apps":
            return HTTPRequest(method: "POST", path: "/apps/list", query: [:], body: body)

        case "open_app":
            if body["app"] == nil, let first = positionals.first {
                body["app"] = first
            }
            return HTTPRequest(method: "POST", path: "/open_app", query: [:], body: body)

        case "device_info", "info":
            return HTTPRequest(method: "POST", path: "/device_info", query: [:], body: body)

        case "device_logs", "logs":
            return HTTPRequest(method: "POST", path: "/device_logs", query: [:], body: body)

        case "assistivetouch", "assistive-touch":
            if body["enabled"] == nil, let first = positionals.first {
                switch first.lowercased() {
                case "on", "true", "1", "enable", "enabled":
                    body["enabled"] = true
                case "off", "false", "0", "disable", "disabled":
                    body["enabled"] = false
                case "status", "get":
                    break
                default:
                    throw GhosthandError.invalidArgument(
                        "assistivetouch argument must be on, off, or status (got \"\(first)\")"
                    )
                }
            }
            return HTTPRequest(method: "POST", path: "/assistivetouch", query: [:], body: body)

        default:
            throw GhosthandError.invalidArgument("Unsupported CLI command: \(command)")
        }
    }

    private static func executePythonHarness(
        arguments args: [String]
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/codex/skills/iphone-use/scripts/phone_exec.py",
            "\(cwd)/.agents/skills/iphone-use/scripts/phone_exec.py",
            "\(NSHomeDirectory())/Projects/iphone-use/codex/skills/iphone-use/scripts/phone_exec.py",
            "\(NSHomeDirectory())/.gemini/config/skills/iphone-use/scripts/phone_exec.py",
        ]
        guard let scriptPath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            let msg = "{\"error\":\"phone_exec.py not found\",\"ok\":false}"
            return (1, msg, msg)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptPath] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.standardInput
        do {
            try proc.run()
            proc.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
            return (proc.terminationStatus, outStr, errStr)
        } catch {
            let msg = "{\"error\":\"\(error)\",\"ok\":false}"
            return (1, msg, msg)
        }
    }
}
