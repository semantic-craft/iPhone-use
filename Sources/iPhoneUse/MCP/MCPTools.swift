import Foundation

/// Public tool descriptions and input schemas, kept separate from execution.
/// Descriptions are localized per language; names, keys, and constraints stay
/// byte-identical so every client keeps working regardless of language.
enum MCPToolCatalog {
    static func device(for table: StringsMCP) -> [String: Any] {
        ["type": "string", "description": table.deviceParam]
    }

    static func tools(for language: AppLanguage) -> [[String: Any]] {
        let table = StringsMCP(language: language)
        let device = device(for: table)
        let normalized: [String: Any] = ["type": "boolean", "description": table.normalizedParam]
        let includeImage: [String: Any] = ["type": "boolean", "default": true, "description": table.includeImage]
        let maxEdge: [String: Any] = ["type": "integer", "minimum": 1, "default": MCPServer.longEdge]
        let waitTextProp: [String: Any] = ["type": "string", "minLength": 1]
        let timeoutMsProp: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 60000, "default": 5000]
        let screentextFlagProp: [String: Any] = ["type": "boolean", "default": false]
        let minConfidenceProp: [String: Any] = ["type": "number", "minimum": 0, "maximum": 1]
        let contentOnlyProp: [String: Any] = ["type": "boolean", "default": false]
        let offsetProp: [String: Any] = ["type": "integer"]
        let iconFlagProp: [String: Any] = ["type": "boolean", "default": false]
        let pointObjectSchema: [String: Any] = [
            "type": "object",
            "properties": ["x": number(table.xPixels), "y": number(table.yPixels)],
            "required": ["x", "y"],
        ]
        return [
            tool("list_devices", table.toolListDevices, [:], readOnly: true),
            tool(
                "screenshot",
                table.toolScreenshot,
                [
                    "device": device,
                    "include_image": includeImage,
                    "native": ["type": "boolean", "default": false],
                    "screentext": screentextFlagProp,
                ],
                readOnly: true),
            tool(
                "ocr_screen",
                table.toolOCRScreen,
                [
                    "device": device, "maxEdge": maxEdge,
                    "min_confidence": minConfidenceProp, "content_only": contentOnlyProp,
                ],
                readOnly: true),
            tool(
                "screentext",
                table.toolScreentext,
                [
                    "device": device, "maxEdge": maxEdge,
                    "min_confidence": minConfidenceProp, "content_only": contentOnlyProp,
                ],
                readOnly: true),
            tool(
                "tap_text", table.toolTapText,
                [
                    "text": ["type": "string", "minLength": 1], "exact": ["type": "boolean", "default": false],
                    "index": ["type": "integer", "minimum": 0, "default": 0],
                    "hold": ["type": "number", "minimum": 0, "maximum": 60, "default": 0.08],
                    "offset_x": offsetProp, "offset_y": offsetProp, "icon": iconFlagProp,
                    "maxEdge": maxEdge, "device": device, "include_image": includeImage,
                ], required: ["text"]),
            tool(
                "move_pointer",
                table.toolMovePointer,
                ["x": number(table.xPixels), "y": number(table.yPixels), "normalized": normalized, "device": device],
                required: ["x", "y"]),
            tool(
                "adjust_pointer",
                table.toolAdjustPointer,
                [
                    "dx": ["type": "integer", "minimum": -32, "maximum": 32],
                    "dy": ["type": "integer", "minimum": -32, "maximum": 32], "device": device,
                ], required: ["dx", "dy"]),
            tool(
                "click_pointer",
                table.toolClickPointer,
                ["device": device]),
            tool(
                "tap", table.toolTap,
                ["x": number(table.xPixels), "y": number(table.yPixels), "normalized": normalized, "device": device],
                required: ["x", "y"]),
            tool(
                "double_tap", table.toolDoubleTap,
                [
                    "x": number(table.xPixels), "y": number(table.yPixels),
                    "text": ["type": "string", "minLength": 1],
                    "index": ["type": "integer", "minimum": 0],
                    "exact": ["type": "boolean", "default": false],
                    "offset_x": offsetProp, "offset_y": offsetProp, "icon": iconFlagProp,
                    "normalized": normalized,
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool(
                "triple_tap", table.toolTripleTap,
                [
                    "x": number(table.xPixels), "y": number(table.yPixels),
                    "text": ["type": "string", "minLength": 1],
                    "index": ["type": "integer", "minimum": 0],
                    "exact": ["type": "boolean", "default": false],
                    "offset_x": offsetProp, "offset_y": offsetProp, "icon": iconFlagProp,
                    "normalized": normalized,
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool(
                "hold", table.toolHold,
                [
                    "x": number(table.xPixels), "y": number(table.yPixels),
                    "text": ["type": "string", "minLength": 1],
                    "index": ["type": "integer", "minimum": 0],
                    "exact": ["type": "boolean", "default": false],
                    "offset_x": offsetProp, "offset_y": offsetProp, "icon": iconFlagProp,
                    "durationMs": ["type": "integer", "minimum": 100, "maximum": 10000, "default": 1000],
                    "seconds": number(table.holdSeconds),
                    "normalized": normalized,
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool(
                "long_press", table.toolLongPress,
                [
                    "x": number(table.xPixels), "y": number(table.yPixels),
                    "seconds": number(table.holdSeconds), "normalized": normalized, "device": device,
                ], required: ["x", "y"]),
            tool(
                "swipe",
                table.toolSwipe,
                [
                    "points": [
                        "type": "array", "minItems": 2,
                        "description": table.swipePointsDesc,
                        "items": [
                            "type": "object",
                            "properties": ["x": number(table.xPixels), "y": number(table.yPixels)],
                            "required": ["x", "y"],
                        ],
                    ],
                    "duration": [
                        "type": "number", "exclusiveMinimum": 0,
                        "description": table.swipeDurationDesc,
                    ],
                    "normalized": normalized,
                    "device": device,
                ], required: ["points"]),
            tool(
                "hold_drag",
                table.toolHoldDrag,
                [
                    "from": pointObjectSchema,
                    "to": pointObjectSchema,
                    "x1": number(table.xPixels), "y1": number(table.yPixels),
                    "x2": number(table.xPixels), "y2": number(table.yPixels),
                    "holdMs": ["type": "integer", "minimum": 100, "maximum": 10000, "default": 1000],
                    "durationMs": ["type": "integer", "minimum": 16, "maximum": 10000, "default": 1000],
                    "normalized": normalized,
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool(
                "scroll",
                table.toolScroll,
                [
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "ticks": ["type": "integer", "minimum": 1, "maximum": 1000, "default": 5],
                    "at": pointObjectSchema,
                    "x": number(table.xPixels), "y": number(table.yPixels),
                    "normalized": normalized,
                    "until_text": ["type": "string", "minLength": 1],
                    "exact": ["type": "boolean", "default": false],
                    "collect": ["type": "boolean", "default": false],
                    "max_scrolls": ["type": "integer", "minimum": 1, "maximum": 50],
                    "end_after": ["type": "integer", "minimum": 1, "maximum": 10],
                    "min_confidence": minConfidenceProp,
                    "content_only": ["type": "boolean", "default": true],
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ], required: ["direction"]),
            tool(
                "type_text", table.toolTypeText,
                [
                    "text": ["type": "string"], "device": device,
                    "clear_before": ["type": "boolean"], "commit_ime": ["type": "boolean"],
                    "press_enter": ["type": "boolean"], "submit": ["type": "boolean"],
                    "ensure_chinese_ime": ["type": "boolean"],
                    "use_clipboard": ["type": "boolean"],
                ], required: ["text"]),
            tool(
                "press_key",
                table.toolPressKey,
                [
                    "key": ["type": "string"], "modifiers": ["type": "array", "items": ["type": "string"]],
                    "device": device,
                ],
                required: ["key"]),
            tool(
                "keyboard_sequence",
                table.toolKeyboardSequence,
                [
                    "steps": MCPKeyboardSequence.schema, "actions": MCPKeyboardSequence.schema,
                    "device": device, "include_image": ["type": "boolean"],
                ]),
            tool("home", table.toolHome, ["device": device]),
            tool(
                "wake", table.toolWake,
                [
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool("lock", table.toolLock, ["device": device]),
            tool(
                "unlock", table.toolUnlock,
                [
                    "passcode": ["type": "string", "minLength": 1],
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ], required: ["passcode"]),
            tool(
                "mute", table.toolMute,
                [
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool(
                "unmute", table.toolUnmute,
                [
                    "wait_text": waitTextProp, "timeout_ms": timeoutMsProp, "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool(
                "record_start", table.toolRecordStart,
                [
                    "outputPath": ["type": "string"],
                    "maxDurationSeconds": ["type": "integer", "minimum": 1, "maximum": 3600, "default": 300],
                    "fps": ["type": "integer", "minimum": 1, "maximum": 120],
                    "audio": ["type": "boolean", "default": true],
                    "device": device,
                ]),
            tool("record_stop", table.toolRecordStop, ["device": device]),
            tool(
                "act",
                language == .zh
                    ? "顺序执行点击、文字点击、滑动、输入、按键、主屏幕、延时与等待文字；失败立即停止。"
                    : "Execute ordered tap, tap_text, swipe, type, key, home, delay and wait_text steps; stop on failure.",
                [
                    "steps": actSteps,
                    "device": device,
                ], required: ["steps"]),
            tool("setup_status", table.toolSetupStatus, ["device": device], readOnly: true),
            tool(
                "acquire",
                table.toolAcquire,
                [
                    "device": device,
                    "reason": ["type": "string", "minLength": 1, "description": table.reasonParam],
                    "label": ["type": "string", "description": table.labelParam],
                    "idleTimeoutSeconds": [
                        "type": "number", "minimum": 1, "maximum": 86400, "default": 600,
                        "description": table.idleTimeoutParam,
                    ],
                    "force": ["type": "boolean", "default": false, "description": table.forceParam],
                ], required: ["reason"]),
            tool(
                "wait",
                table.toolWait,
                [
                    "device": device,
                    "reason": ["type": "string", "minLength": 1, "description": table.reasonParam],
                    "label": ["type": "string", "description": table.labelParam],
                    "idleTimeoutSeconds": [
                        "type": "number", "minimum": 1, "maximum": 86400, "default": 600,
                        "description": table.idleTimeoutParam,
                    ],
                    "waitSeconds": [
                        "type": "number", "minimum": 1, "maximum": 3600, "default": 600,
                        "description": table.waitSecondsParam,
                    ],
                ], required: ["reason"]),
            tool(
                "release",
                table.toolRelease,
                [
                    "lease": ["type": "string", "minLength": 1, "description": table.leaseParam]
                ], required: ["lease"]),
            tool(
                "photo_list",
                table.toolPhotoList,
                [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 500, "default": 50],
                    "device": device,
                ], readOnly: true),
            tool(
                "photo_pull",
                table.toolPhotoPull,
                [
                    "path": ["type": "string", "minLength": 1],
                    "output": ["type": "string"],
                    "device": device,
                ], required: ["path"], readOnly: true),
            tool(
                "photo_delete",
                table.toolPhotoDelete,
                [
                    "path": ["type": "string", "minLength": 1],
                    "device": device,
                ], required: ["path"]),
            tool(
                "photo_push",
                table.toolPhotoPush,
                [
                    "path": ["type": "string"],
                    "source": ["type": "string"],
                    "filename": ["type": "string"],
                    "data": ["type": "string"],
                    "content": ["type": "string"],
                    "device": device,
                ]),
            tool(
                "file_list",
                table.toolFileList,
                [
                    "path": ["type": "string", "default": "/"],
                    "bundle_id": ["type": "string"],
                    "device": device,
                ], readOnly: true),
            tool(
                "file_pull",
                table.toolFilePull,
                [
                    "path": ["type": "string", "minLength": 1],
                    "bundle_id": ["type": "string"],
                    "output": ["type": "string"],
                    "device": device,
                ], required: ["path"], readOnly: true),
            tool(
                "file_push",
                table.toolFilePush,
                [
                    "path": ["type": "string", "minLength": 1],
                    "bundle_id": ["type": "string"],
                    "source": ["type": "string"],
                    "data": ["type": "string"],
                    "content": ["type": "string"],
                    "device": device,
                ], required: ["path"]),
            tool(
                "file_remove",
                table.toolFileRemove,
                [
                    "path": ["type": "string", "minLength": 1],
                    "bundle_id": ["type": "string"],
                    "recursive": ["type": "boolean", "default": false],
                    "device": device,
                ], required: ["path"]),
            tool(
                "app_list",
                table.toolAppList,
                [
                    "device": device
                ], readOnly: true),
            tool(
                "open_app",
                table.toolOpenApp,
                [
                    "app": ["type": "string", "minLength": 1],
                    "bundle_id": ["type": "string"],
                    "settle": ["type": "boolean"],
                    "wait_text": waitTextProp,
                    "timeout_ms": timeoutMsProp,
                    "screentext": screentextFlagProp,
                    "device": device,
                ]),
            tool(
                "device_info",
                table.toolDeviceInfo,
                [
                    "device": device
                ], readOnly: true),
            tool(
                "device_logs",
                table.toolDeviceLogs,
                [
                    "seconds": ["type": "number", "minimum": 0.2, "maximum": 30.0, "default": 2.0],
                    "lines": ["type": "integer", "minimum": 1, "maximum": 2000, "default": 200],
                    "contains": ["type": "string"],
                    "device": device,
                ], readOnly: true),
            tool(
                "assistivetouch",
                table.toolAssistiveTouch,
                [
                    "enabled": ["type": "boolean"],
                    "device": device,
                ]),
            tool(
                "task",
                table.toolTask,
                [
                    "prompt": ["type": "string"],
                    "resume": ["type": "string"],
                    "task": ["type": "string"],
                    "thinking_level": [
                        "type": "string",
                        "enum": ["minimal", "low", "medium", "high"],
                        "default": "low",
                    ],
                    "max_steps": ["type": "integer", "minimum": 1, "maximum": 50, "default": 12],
                    "approve": ["type": "boolean", "default": true],
                    "device": device,
                ]),
        ]
    }

    private static var actSteps: [String: Any] {
        let number: [String: Any] = ["type": "number"]
        let boolean: [String: Any] = ["type": "boolean"]
        let text: [String: Any] = ["type": "string", "minLength": 1]
        let edge: [String: Any] = ["type": "integer", "minimum": 1, "default": MCPServer.longEdge]
        func step(_ type: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            var properties = properties
            properties["type"] = ["type": "string", "enum": [type]]
            return [
                "type": "object", "additionalProperties": false, "properties": properties,
                "required": ["type"] + required,
            ]
        }
        var typing: [String: Any] = ["text": text]
        for option in TextEntry.textOptions { typing[option] = boolean }
        let matching: [String: Any] = [
            "text": text, "exact": boolean, "index": ["type": "integer", "minimum": 0], "maxEdge": edge,
        ]
        var tapText = matching
        tapText["hold"] = ["type": "number", "minimum": 0, "maximum": 60]
        tapText["offset_x"] = ["type": "integer"]
        tapText["offset_y"] = ["type": "integer"]
        tapText["icon"] = boolean
        var waiting = matching
        waiting["timeout"] = ["type": "number", "minimum": 0, "maximum": 6, "default": 6]
        return [
            "type": "array", "minItems": 1, "maxItems": 16,
            "items": [
                "oneOf": [
                    step("tap", ["x": number, "y": number, "normalized": boolean, "hold": number], ["x", "y"]),
                    step("tap_text", tapText, ["text"]),
                    step(
                        "swipe",
                        [
                            "points": [
                                "type": "array", "minItems": 2,
                                "items": [
                                    "type": "object", "properties": ["x": number, "y": number], "required": ["x", "y"],
                                ],
                            ], "duration": number, "normalized": boolean,
                        ], ["points"]),
                    step("type", typing, ["text"]),
                    step("key", ["key": text, "modifiers": ["type": "array", "items": text]], ["key"]),
                    step("home", [:]),
                    step("delay", ["seconds": ["type": "number", "minimum": 0, "maximum": 6]], ["seconds"]),
                    step("wait_text", waiting, ["text"]),
                ]
            ],
        ]
    }

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: Any],
        required: [String] = [], readOnly: Bool = false
    ) -> [String: Any] {
        var properties = properties
        properties["device"] = properties["device"] ?? device(for: StringsMCP(language: .en))
        properties["device_id"] = properties["device"]
        properties["lease"] =
            properties["lease"] ?? ["type": "string", "description": StringsMCP(language: .en).leaseParam]
        properties["include_image"] = [
            "type": "boolean", "default": true, "description": StringsMCP(language: .en).includeImage,
        ]
        if !readOnly {
            properties["observe"] = ["type": "string", "enum": ["full", "ocr_diff", "none"], "default": "full"]
        }
        var schema: [String: Any] = ["type": "object", "properties": properties, "required": required]
        if name == "keyboard_sequence" {
            schema["anyOf"] = [["required": ["steps"]], ["required": ["actions"]]]
        }
        return [
            "name": name, "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": readOnly],
        ]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }
}

/// An action translated to the app's HTTP API. Building it has no device side effects.
struct MCPToolRequest {
    let path: String
    let body: [String: Any]

    /// Nil means the name is not an action tool. Listing and screenshots have no POST body.
    /// `language` defaults to English so direct callers (tests, embeddings) stay stable.
    static func action(
        named name: String, arguments: [String: Any], longEdge: Int, language: AppLanguage = .en
    ) throws -> MCPToolRequest? {
        let device = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
        switch name {
        case "act":
            let batch = try ActRequest(arguments)
            let steps = try batch.steps.map { step -> [String: Any] in
                let type = step["type"] as! String
                if ["tap", "swipe", "tap_text"].contains(type) {
                    var translated = try action(named: type, arguments: step, longEdge: longEdge, language: language)!
                        .body
                    translated["type"] = type
                    if type == "tap", let hold = step["hold"] { translated["hold"] = hold }
                    return translated
                }
                var translated = step
                if type == "wait_text", translated["maxEdge"] == nil { translated["maxEdge"] = longEdge }
                return translated
            }
            return MCPToolRequest(path: "/act", body: withDevice(["steps": steps], device))
        case "ocr_screen", "tap_text", "screentext":
            let table = StringsAPI(language: language)
            let edge = try OCRRequest.maxEdge(arguments, table: table) ?? longEdge
            _ = try OCRRequest.minConfidence(arguments, table: table)
            _ = try OCRRequest.contentOnly(arguments, table: table)
            if name == "tap_text" { _ = try TextTapRequest(arguments, table: table) }
            var body: [String: Any] = ["maxEdge": edge]
            if name == "tap_text" {
                for key in ["text", "exact", "index", "hold", "offset_x", "offset_y", "icon"]
                where arguments[key] != nil {
                    body[key] = arguments[key]
                }
            } else {
                for key in ["min_confidence", "content_only"] where arguments[key] != nil {
                    body[key] = arguments[key]
                }
            }
            let path: String
            switch name {
            case "ocr_screen": path = "/ocr"
            case "screentext": path = "/screentext"
            default: path = "/tap_text"
            }
            return MCPToolRequest(path: path, body: try withPostAction(withDevice(body, device), arguments))
        case "move_pointer":
            let body = try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
            for key in ["x", "y"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0
                else {
                    throw MCPServer.MCPError(StringsMCP(language: language).coordinateFinite(key))
                }
            }
            return MCPToolRequest(path: "/move", body: try withPostAction(body, arguments))
        case "adjust_pointer":
            var body: [String: Any] = ["click": false]
            for key in ["dx", "dy"] {
                guard let value = arguments[key] as? NSNumber,
                    CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                    (-32...32).contains(value.doubleValue), value.doubleValue.rounded() == value.doubleValue
                else { throw MCPServer.MCPError(StringsMCP(language: language).hidCountRange(key)) }
                body[key] = value.intValue
            }
            return MCPToolRequest(path: "/nudge", body: try withPostAction(withDevice(body, device), arguments))
        case "click_pointer":
            return MCPToolRequest(
                path: "/nudge",
                body: try withPostAction(withDevice(["dx": 0, "dy": 0, "click": true], device), arguments))
        case "tap":
            if arguments["text"] != nil, arguments["x"] == nil, arguments["y"] == nil {
                let body = try pointOrTextBody(arguments, longEdge: longEdge, language: language)
                return MCPToolRequest(path: "/tap", body: try withPostAction(body, arguments))
            }
            return MCPToolRequest(
                path: "/tap",
                body: try withPostAction(
                    try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language), arguments))
        case "double_tap", "double-tap":
            let body = try pointOrTextBody(arguments, longEdge: longEdge, language: language)
            return MCPToolRequest(path: "/double_tap", body: try withPostAction(body, arguments))
        case "triple_tap", "triple-tap":
            let body = try pointOrTextBody(arguments, longEdge: longEdge, language: language)
            return MCPToolRequest(path: "/triple_tap", body: try withPostAction(body, arguments))
        case "hold":
            var body = try pointOrTextBody(arguments, longEdge: longEdge, language: language)
            if let durationMs = arguments["durationMs"] ?? arguments["duration_ms"] {
                guard let val = OCRRequest.number(durationMs), (100...10_000).contains(val) else {
                    throw MCPServer.MCPError("durationMs must be within 100...10000 ms")
                }
                body["durationMs"] = Int(val)
            } else if let seconds = arguments["seconds"] ?? arguments["duration"] {
                guard let val = OCRRequest.number(seconds) else {
                    throw MCPServer.MCPError("hold duration must be a number")
                }
                let sec = val >= 100 ? val / 1000.0 : val
                guard (0.1...10.0).contains(sec) else {
                    throw MCPServer.MCPError("hold duration must be within 100...10000 ms (0.1...10.0 s)")
                }
                body["duration"] = sec
            }
            return MCPToolRequest(path: "/hold", body: try withPostAction(body, arguments))
        case "long_press":
            var body = try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
            body["hold"] = arguments["seconds"] ?? 1.0
            return MCPToolRequest(path: "/tap", body: try withPostAction(body, arguments))
        case "swipe":
            var body = try scaled(arguments, ["points"], longEdge: longEdge, language: language)
            body["duration"] = arguments["duration"] ?? 0.3
            return MCPToolRequest(path: "/swipe", body: try withPostAction(body, arguments))
        case "hold_drag", "hold-drag":
            let body = try buildHoldDragBody(arguments, longEdge: longEdge, language: language)
            return MCPToolRequest(path: "/hold_drag", body: try withPostAction(body, arguments))
        case "scroll":
            let body = try buildScrollBody(arguments, longEdge: longEdge, language: language)
            return MCPToolRequest(path: "/scroll", body: try withPostAction(body, arguments))
        case "type_text":
            var body: [String: Any] = ["text": arguments["text"] ?? ""]
            for option in TextEntry.textOptions {
                if let value = arguments[option] {
                    guard TextEntry.isBoolean(value) else {
                        throw MCPServer.MCPError(StringsMCP(language: language).booleanRequired(option))
                    }
                    body[option] = value
                }
            }
            return MCPToolRequest(path: "/type", body: try withPostAction(withDevice(body, device), arguments))
        case "press_key":
            let keyName = (arguments["key"] as? String) ?? ""
            if keyName.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("mute") == .orderedSame {
                throw MCPServer.MCPError(
                    "mute is excluded from press_key; use mute or unmute so ringer state is verified over USB"
                )
            }
            return MCPToolRequest(
                path: "/key",
                body: try withPostAction(
                    withDevice(["key": keyName, "modifiers": arguments["modifiers"] ?? []], device),
                    arguments))
        case "home":
            return MCPToolRequest(path: "/home", body: try withPostAction(withDevice([:], device), arguments))
        case "wake":
            return MCPToolRequest(path: "/wake", body: try withPostAction(withDevice([:], device), arguments))
        case "lock":
            return MCPToolRequest(path: "/lock", body: withDevice([:], device))
        case "unlock":
            guard let passcode = arguments["passcode"] as? String,
                !passcode.isEmpty,
                passcode.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
            else {
                throw MCPServer.MCPError("passcode is required and must be printable US-ASCII")
            }
            return MCPToolRequest(
                path: "/unlock",
                body: try withPostAction(withDevice(["passcode": passcode], device), arguments))
        case "mute":
            return MCPToolRequest(path: "/mute", body: try withPostAction(withDevice([:], device), arguments))
        case "unmute":
            return MCPToolRequest(path: "/unmute", body: try withPostAction(withDevice([:], device), arguments))
        case "record_start", "recording_start":
            let options = try ScreenRecorderManager.Options.parse(body: arguments)
            var body: [String: Any] = [
                "maxDurationSeconds": options.maxDurationSeconds,
                "audio": options.audio,
            ]
            if let outputPath = options.outputPath { body["outputPath"] = outputPath }
            if let fps = options.fps { body["fps"] = fps }
            return MCPToolRequest(path: "/recording/start", body: withDevice(body, device))
        case "record_stop", "recording_stop":
            return MCPToolRequest(path: "/recording/stop", body: withDevice([:], device))
        case "photo_list":
            var body: [String: Any] = [:]
            if let limit = arguments["limit"] { body["limit"] = limit }
            return MCPToolRequest(path: "/photos/list", body: withDevice(body, device))
        case "photo_pull":
            guard let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw MCPServer.MCPError("path is required for photo_pull")
            }
            var body: [String: Any] = ["path": path]
            if let output = arguments["output"] ?? arguments["destination"] {
                body["output"] = output
            }
            return MCPToolRequest(path: "/photos/pull", body: withDevice(body, device))
        case "photo_delete":
            guard let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw MCPServer.MCPError("path is required for photo_delete")
            }
            return MCPToolRequest(path: "/photos/delete", body: withDevice(["path": path], device))
        case "photo_push":
            var body: [String: Any] = [:]
            for key in ["path", "source", "file", "filename", "name", "data", "base64", "content", "text"]
            where arguments[key] != nil {
                body[key] = arguments[key]
            }
            guard !body.isEmpty else {
                throw MCPServer.MCPError("photo_push requires path/source or base64 data")
            }
            return MCPToolRequest(path: "/photos/push", body: withDevice(body, device))
        case "file_list":
            var body: [String: Any] = ["path": (arguments["path"] as? String) ?? "/"]
            if let bundleID = arguments["bundle_id"] ?? arguments["bundleId"] {
                body["bundle_id"] = bundleID
            }
            return MCPToolRequest(path: "/files/list", body: withDevice(body, device))
        case "file_pull":
            guard let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw MCPServer.MCPError("path is required for file_pull")
            }
            var body: [String: Any] = ["path": path]
            if let bundleID = arguments["bundle_id"] ?? arguments["bundleId"] {
                body["bundle_id"] = bundleID
            }
            if let output = arguments["output"] ?? arguments["destination"] {
                body["output"] = output
            }
            return MCPToolRequest(path: "/files/pull", body: withDevice(body, device))
        case "file_push":
            guard
                let path =
                    ((arguments["path"] as? String) ?? (arguments["destination"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw MCPServer.MCPError("path is required for file_push")
            }
            var body: [String: Any] = ["path": path]
            for key in ["bundle_id", "bundleId", "source", "local_path", "file", "data", "base64", "content", "text"]
            where arguments[key] != nil {
                body[key] = arguments[key]
            }
            return MCPToolRequest(path: "/files/push", body: withDevice(body, device))
        case "file_remove":
            guard let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw MCPServer.MCPError("path is required for file_remove")
            }
            var body: [String: Any] = ["path": path]
            if let bundleID = arguments["bundle_id"] ?? arguments["bundleId"] {
                body["bundle_id"] = bundleID
            }
            if let recursive = arguments["recursive"] {
                body["recursive"] = recursive
            }
            return MCPToolRequest(path: "/files/remove", body: withDevice(body, device))
        case "app_list":
            return MCPToolRequest(path: "/apps/list", body: withDevice([:], device))
        case "open_app":
            let rawApp =
                (arguments["app"] as? String) ?? (arguments["bundle_id"] as? String)
                ?? (arguments["bundleId"] as? String) ?? (arguments["name"] as? String)
            let appTarget = rawApp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !appTarget.isEmpty else {
                throw MCPServer.MCPError("app or bundle_id is required for open_app")
            }
            var body: [String: Any] = ["app": appTarget]
            if let bundleID = arguments["bundle_id"] ?? arguments["bundleId"] {
                body["bundle_id"] = bundleID
            }
            return MCPToolRequest(
                path: "/open_app",
                body: try withPostAction(withDevice(body, device), arguments)
            )
        case "device_info":
            return MCPToolRequest(path: "/device_info", body: withDevice([:], device))
        case "device_logs":
            var body: [String: Any] = [:]
            for key in ["seconds", "lines", "max_lines", "contains", "process", "filter"]
            where arguments[key] != nil {
                body[key] = arguments[key]
            }
            return MCPToolRequest(path: "/device_logs", body: withDevice(body, device))
        case "assistivetouch", "assistive_touch":
            var body: [String: Any] = [:]
            if let enabled = arguments["enabled"] {
                body["enabled"] = enabled
            }
            return MCPToolRequest(path: "/assistivetouch", body: withDevice(body, device))
        case "task":
            let parsed = try GeminiTaskExecutor.RequestOptions.parse(body: arguments)
            var body: [String: Any] = [
                "thinking_level": parsed.thinkingLevel.rawValue,
                "max_steps": parsed.maxSteps,
                "approve": parsed.approvePendingSafety,
            ]
            if let prompt = parsed.prompt { body["prompt"] = prompt }
            if let resume = parsed.resumeTaskID { body["resume"] = resume }
            return MCPToolRequest(path: "/task", body: withDevice(body, device))
        default:
            return nil
        }
    }

    private static func pointOrTextBody(
        _ arguments: [String: Any], longEdge: Int, language: AppLanguage
    ) throws -> [String: Any] {
        let device = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
        if let rawText = arguments["text"] as? String, arguments["x"] == nil, arguments["y"] == nil {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPServer.MCPError("text must not be empty")
            }
            let edge = try OCRRequest.maxEdge(arguments, table: StringsAPI(language: language)) ?? longEdge
            var body: [String: Any] = ["text": rawText, "maxEdge": edge]
            for key in ["exact", "index", "hold", "gap", "offset_x", "offset_y", "icon"] where arguments[key] != nil {
                body[key] = arguments[key]
            }
            return withDevice(body, device)
        }
        return try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
    }

    private static func buildHoldDragBody(
        _ arguments: [String: Any], longEdge: Int, language: AppLanguage
    ) throws -> [String: Any] {
        let device = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
        var base: [String: Any]
        if let from = arguments["from"] as? [String: Any], let to = arguments["to"] as? [String: Any] {
            var flat = arguments
            flat["x1"] = from["x"]
            flat["y1"] = from["y"]
            flat["x2"] = to["x"]
            flat["y2"] = to["y"]
            base = try scaled(flat, ["x1", "y1", "x2", "y2"], longEdge: longEdge, language: language)
        } else {
            base = try scaled(arguments, ["x1", "y1", "x2", "y2"], longEdge: longEdge, language: language)
        }
        if let holdMs = arguments["holdMs"] ?? arguments["hold_ms"] {
            guard let val = OCRRequest.number(holdMs), (100...10_000).contains(val) else {
                throw MCPServer.MCPError("holdMs must be within 100...10000 ms")
            }
            base["holdMs"] = Int(val)
        }
        if let durationMs = arguments["durationMs"] ?? arguments["duration_ms"] {
            guard let val = OCRRequest.number(durationMs), (16...10_000).contains(val) else {
                throw MCPServer.MCPError("durationMs must be within 16...10000 ms")
            }
            base["durationMs"] = Int(val)
        }
        return withDevice(base, device)
    }

    private static func buildScrollBody(
        _ arguments: [String: Any], longEdge: Int, language: AppLanguage
    ) throws -> [String: Any] {
        let device = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
        guard
            let rawDir = (arguments["direction"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            DeviceInput.ScrollDirection(rawValue: rawDir) != nil
        else {
            throw MCPServer.MCPError("direction is required and must be up, down, left, or right")
        }
        let ticks: Int
        if let rawTicks = arguments["ticks"], !(rawTicks is NSNull) {
            guard let val = OCRRequest.number(rawTicks), val.rounded() == val, (1...1000).contains(Int(val)) else {
                throw MCPServer.MCPError("ticks must be an integer within 1...1000")
            }
            ticks = Int(val)
        } else {
            ticks = 5
        }
        var body: [String: Any] = ["direction": rawDir, "ticks": ticks]
        if let at = arguments["at"] as? [String: Any], at["x"] != nil, at["y"] != nil {
            var flat = arguments
            flat["x"] = at["x"]
            flat["y"] = at["y"]
            let scaledAt = try scaled(flat, ["x", "y"], longEdge: longEdge, language: language)
            body.merge(scaledAt) { _, new in new }
        } else if arguments["x"] != nil || arguments["y"] != nil {
            let scaledAt = try scaled(arguments, ["x", "y"], longEdge: longEdge, language: language)
            body.merge(scaledAt) { _, new in new }
        }
        if let untilText = (arguments["until_text"] ?? arguments["untilText"]) as? String {
            let trimmed = untilText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPServer.MCPError("until_text must not be empty")
            }
            body["until_text"] = trimmed
        }
        if let rawExact = arguments["exact"] {
            guard let exact = PostActionOptions.parseBoolFlag(rawExact) else {
                throw MCPServer.MCPError(StringsMCP(language: language).booleanRequired("exact"))
            }
            body["exact"] = exact
        }
        if let rawCollect = arguments["collect"] {
            guard let collect = PostActionOptions.parseBoolFlag(rawCollect) else {
                throw MCPServer.MCPError(StringsMCP(language: language).booleanRequired("collect"))
            }
            body["collect"] = collect
        }
        if let rawMaxScrolls = arguments["max_scrolls"] ?? arguments["maxScrolls"] {
            guard let val = OCRRequest.number(rawMaxScrolls), val.rounded() == val, (1...50).contains(Int(val)) else {
                throw MCPServer.MCPError("max_scrolls must be an integer within 1...50")
            }
            body["max_scrolls"] = Int(val)
        }
        if let rawEndAfter = arguments["end_after"] ?? arguments["endAfter"] {
            guard let val = OCRRequest.number(rawEndAfter), val.rounded() == val, (1...10).contains(Int(val)) else {
                throw MCPServer.MCPError("end_after must be an integer within 1...10")
            }
            body["end_after"] = Int(val)
        }
        let table = StringsAPI(language: language)
        if let minConf = try OCRRequest.minConfidence(arguments, table: table) {
            body["min_confidence"] = minConf
        }
        if arguments["content_only"] != nil || arguments["contentOnly"] != nil {
            body["content_only"] = try OCRRequest.contentOnly(arguments, table: table)
        }
        return withDevice(body, device)
    }

    private static func withPostAction(
        _ body: [String: Any], _ arguments: [String: Any]
    ) throws -> [String: Any] {
        let hasPostField =
            arguments["wait_text"] != nil || arguments["waitText"] != nil
            || arguments["timeout_ms"] != nil || arguments["timeoutMs"] != nil
            || arguments["screentext"] != nil || arguments["settle"] != nil
        guard hasPostField else { return body }
        let postOptions = try PostActionOptions.parse(body: arguments)
        var updated = body
        if let waitText = postOptions.waitText {
            updated["waitText"] = waitText
            updated["timeoutMs"] = postOptions.timeoutMs
        } else if arguments["timeout_ms"] != nil || arguments["timeoutMs"] != nil {
            updated["timeoutMs"] = postOptions.timeoutMs
        }
        if postOptions.includeScreentext {
            updated["screentext"] = true
        }
        if postOptions.settle && arguments["settle"] != nil {
            updated["settle"] = true
        }
        return updated
    }

    /// Pixel coordinates keep the HTTP API's existing rules. Explicit normalized
    /// coordinates use 0...1000 on each axis, independent of screenshot aspect ratio.
    private static func scaled(
        _ arguments: [String: Any], _ keys: [String], longEdge: Int, language: AppLanguage
    ) throws -> [String: Any] {
        var body: [String: Any] = ["maxEdge": longEdge]
        let table = StringsMCP(language: language)
        var normalized = false
        if let raw = arguments["normalized"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw MCPServer.MCPError(table.normalizedBoolean)
            }
            normalized = value.boolValue
        }
        func coordinate(_ value: Any?, key: String) throws -> Double {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, (0...1000).contains(number.doubleValue)
            else { throw MCPServer.MCPError(table.normalizedRange(key)) }
            return number.doubleValue / 1000.0
        }
        for key in keys {
            guard let value = arguments[key] else {
                throw MCPServer.MCPError(StringsMCP(language: language).parameterRequired(key))
            }
            if normalized, key == "points" {
                guard let points = value as? [[String: Any]], points.count >= 2 else {
                    throw MCPServer.MCPError(table.normalizedPoints)
                }
                body[key] = try points.map { point in
                    ["x": try coordinate(point["x"], key: "x"), "y": try coordinate(point["y"], key: "y")]
                }
            } else if normalized {
                body[key] = try coordinate(value, key: key)
            } else {
                body[key] = value
            }
        }
        if normalized { body["fraction"] = true }
        return withDevice(body, (arguments["device"] as? String) ?? (arguments["device_id"] as? String))
    }

    private static func withDevice(_ body: [String: Any], _ device: String?) -> [String: Any] {
        guard let device else { return body }
        return body.merging(["device": device]) { $1 }
    }
}
