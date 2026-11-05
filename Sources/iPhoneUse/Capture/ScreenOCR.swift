import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

/// Best-effort, local recognition of the exact screenshot bytes supplied by the caller.
enum ScreenOCR {
    /// Scrollable content band (`6% < y < 92%` of screen height) excluding the top status bar
    /// (clock, battery, network indicators) and the bottom home indicator bar.
    static let contentBandMinYFraction = 0.06
    static let contentBandMaxYFraction = 0.92

    struct Item: Equatable {
        let text: String
        let x: Int
        let y: Int
        let boxX: Int
        let boxY: Int
        let width: Int
        let height: Int
        let confidence: Double
        let source: String

        init(
            text: String, box: CGRect, width: Int, height: Int,
            confidence: Double = 1.0, source: String = "pixels"
        ) {
            self.text = text
            let minX = box.minX * Double(width)
            let minY = (1 - box.maxY) * Double(height)
            let w = max(1, Int((box.width * Double(width)).rounded()))
            let h = max(1, Int((box.height * Double(height)).rounded()))
            self.boxX = Int(minX.rounded())
            self.boxY = Int(minY.rounded())
            self.width = w
            self.height = h
            self.x = Int((minX + box.width * Double(width) / 2).rounded())
            self.y = Int((minY + box.height * Double(height) / 2).rounded())
            self.confidence = confidence
            self.source = source
        }

        init(
            text: String, x: Int, y: Int,
            boxX: Int? = nil, boxY: Int? = nil,
            width: Int = 0, height: Int = 0,
            confidence: Double = 1.0,
            source: String = "pixels"
        ) {
            self.text = text
            self.x = x
            self.y = y
            let resolvedWidth = max(0, width)
            let resolvedHeight = max(0, height)
            self.width = resolvedWidth
            self.height = resolvedHeight
            self.boxX = boxX ?? (resolvedWidth > 0 ? x - resolvedWidth / 2 : x)
            self.boxY = boxY ?? (resolvedHeight > 0 ? y - resolvedHeight / 2 : y)
            self.confidence = confidence
            self.source = source
        }

        /// Ghosthand `screentext` line format: `x,y wxh text` in the screenshot coordinate space.
        var screentextLine: String {
            "\(boxX),\(boxY) \(width)x\(height) \(text)"
        }

        var lineJSON: [String: Any] {
            [
                "text": text,
                "x": boxX,
                "y": boxY,
                "width": width,
                "height": height,
                "confidence": confidence,
                "source": source,
            ]
        }

        var json: [String: Any] {
            [
                "text": text,
                "x": x,
                "y": y,
                "boxX": boxX,
                "boxY": boxY,
                "width": width,
                "height": height,
                "confidence": confidence,
                "source": source,
            ]
        }
    }

    struct Result {
        let width: Int
        let height: Int
        let items: [Item]
        var screenHash: String = ""

        /// Filters recognized items by minimum confidence and/or the scrollable content band
        /// (`0.06 < y / height < 0.92`), excluding volatile status-bar and home-indicator regions.
        func filtering(minConfidence: Double? = nil, contentOnly: Bool = false) -> Result {
            if minConfidence == nil && !contentOnly {
                return self
            }
            let h = Double(max(1, height))
            let filtered = items.filter { item in
                if let minConfidence, item.confidence < minConfidence {
                    return false
                }
                if contentOnly, height > 0 {
                    let yFrac = Double(item.y) / h
                    if yFrac <= ScreenOCR.contentBandMinYFraction || yFrac >= ScreenOCR.contentBandMaxYFraction {
                        return false
                    }
                }
                return true
            }
            return Result(width: width, height: height, items: filtered, screenHash: screenHash)
        }

        var screentext: String {
            items.map(\.screentextLine).joined(separator: "\n")
        }

        var screenTextJSON: [String: Any] {
            [
                "width": width,
                "height": height,
                "lines": items.map(\.lineJSON),
                "screentext": screentext,
            ]
        }

        func json(device: String) -> [String: Any] {
            [
                "device": device,
                "width": width,
                "height": height,
                "items": items.map(\.json),
                "lines": items.map(\.lineJSON),
                "screentext": screentext,
                "screenHash": screenHash,
            ]
        }

        var summary: String {
            "\nOCR (x,y): "
                + items.map { item in
                    let encoded = try? JSONSerialization.data(withJSONObject: item.text, options: [.fragmentsAllowed])
                    let quoted = encoded.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
                    return "\(quoted) (\(item.x),\(item.y))"
                }.joined(separator: " | ")
        }
    }

    static func decode(_ data: Data) -> Result? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let width = json["width"] as? Int, let height = json["height"] as? Int,
            width > 0, height > 0, let hash = json["screenHash"] as? String, !hash.isEmpty,
            let raw = json["items"] as? [[String: Any]]
        else { return nil }
        var items: [Item] = []
        for item in raw {
            guard let text = item["text"] as? String, let x = item["x"] as? Int, let y = item["y"] as? Int else {
                return nil
            }
            let boxX = item["boxX"] as? Int
            let boxY = item["boxY"] as? Int
            let w = (item["width"] as? Int) ?? 0
            let h = (item["height"] as? Int) ?? 0
            let confidence = (item["confidence"] as? NSNumber)?.doubleValue ?? 1.0
            items.append(
                Item(
                    text: text, x: x, y: y,
                    boxX: boxX, boxY: boxY, width: w, height: h, confidence: confidence))
        }
        return Result(width: width, height: height, items: items, screenHash: hash)
    }

    static func sorted(_ items: [Item]) -> [Item] {
        items.sorted {
            if $0.y / 12 != $1.y / 12 { return $0.y / 12 < $1.y / 12 }
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.text < $1.text
        }
    }

    private struct CacheKey: Equatable {
        let device: String
        let width: Int
        let height: Int
        let hash: String
    }

    private struct FrameSignature {
        let width: Int
        let height: Int
        let cells: [UInt8]
        let hash: String
    }

    private static let lock = NSLock()
    private static var cache: [(CacheKey, Result, [UInt8])] = []
    private static let maximumLumaDelta = 16
    private static let significantLumaDelta = 6
    private static let significantPixelRatio = 2000
    private static var recentSignatures: [FrameSignature] = []
    private static var previous: [String: Set<String>] = [:]

    struct Diff {
        let added: [String]
        let removed: [String]
        let unchanged: Bool
        let screenHash: String

        var summary: String {
            let changes = (added.map { "+" + $0 } + removed.map { "-" + $0 }).joined(separator: "\n")
            return "screenHash: \(screenHash) unchanged: \(unchanged)" + (changes.isEmpty ? "" : "\n" + changes)
        }
    }

    static func diff(device: String, current: Result) -> Diff {
        lock.lock()
        defer { lock.unlock() }
        let texts = Set(current.items.map(\.text))
        let old = previous[device]
        previous[device] = texts
        return Diff(
            added: texts.subtracting(old ?? []).sorted(), removed: (old ?? []).subtracting(texts).sorted(),
            unchanged: old == texts, screenHash: current.screenHash)
    }

    static func summaryDiff(for result: Result, device: String) -> String {
        diff(device: device, current: result).summary
    }

    /// Hash decoded pixels with a 2-level L-infinity tolerance on an 8x8 luminance grid
    /// so USB H.264/YUV LSB quantization noise does not invalidate a static screen.
    static func stabilitySignature(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return frameHashLocked(image)
    }

    /// SHA-256 of dimensions and every decoded 8-bit luminance pixel, without tolerance.
    static func screenHash(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        return content(image)?.hash ?? ""
    }

    private static func content(_ image: CGImage) -> (hash: String, luma: [UInt8])? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { return nil }
        let hash = SHA256.hash(data: Data("\(image.width)x\(image.height):".utf8) + Data(pixels)).map {
            String(format: "%02x", $0)
        }.joined()
        return (hash, pixels)
    }

    private static func canReuse(_ current: [UInt8], reference: [UInt8]) -> Bool {
        guard current.count == reference.count, !current.isEmpty else { return false }
        var significant = 0
        for (pixel, old) in zip(current, reference) {
            let delta = abs(Int(pixel) - Int(old))
            guard delta <= maximumLumaDelta else { return false }
            if delta > significantLumaDelta {
                significant += 1
                guard significant * significantPixelRatio <= current.count else { return false }
            }
        }
        return true
    }

    private static func frameHashLocked(_ image: CGImage) -> String {
        let sampleW = min(max(image.width, 1), 8)
        let sampleH = min(max(image.height, 1), 8)
        var cells = [UInt8](repeating: 0, count: sampleW * sampleH)
        let rendered = cells.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: sampleW, height: sampleH,
                    bitsPerComponent: 8, bytesPerRow: sampleW, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
            return true
        }
        guard rendered else { return "" }
        if let match = recentSignatures.last(where: { sig in
            sig.width == image.width && sig.height == image.height && sig.cells.count == cells.count
                && zip(sig.cells, cells).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
        }) {
            return match.hash
        }
        let hash = SHA256.hash(data: Data("\(image.width)x\(image.height):".utf8) + Data(cells)).map {
            String(format: "%02x", $0)
        }.joined()
        recentSignatures.append(FrameSignature(width: image.width, height: image.height, cells: cells, hash: hash))
        if recentSignatures.count > 16 { recentSignatures.removeFirst() }
        return hash
    }

    static func recognize(
        _ data: Data, device: String = "", recognition: (CGImage) throws -> [Item] = detect
    ) -> Result {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return Result(width: 0, height: 0, items: []) }
        // Serialize recognition too: concurrent callers of the same frame share one Vision pass.
        lock.lock()
        defer { lock.unlock() }
        let pixels = content(image)
        let hash = pixels?.hash ?? ""
        let key = CacheKey(device: device, width: image.width, height: image.height, hash: hash)
        if !hash.isEmpty, let index = cache.firstIndex(where: { $0.0 == key }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            return hit.1
        }
        if let pixels,
            let hit = cache.last(where: {
                $0.0.device == device && $0.0.width == image.width && $0.0.height == image.height
                    && canReuse(pixels.luma, reference: $0.2)
            })
        {
            let result = Result(width: image.width, height: image.height, items: hit.1.items, screenHash: hash)
            // Keep the original recognized pixels as the reference: noise must not drift cumulatively.
            cache.append((key, result, hit.2))
            if cache.count > 8 { cache.removeFirst() }
            return result
        }
        do {
            let items = try recognition(image)
            let result = Result(width: image.width, height: image.height, items: sorted(items), screenHash: hash)
            if let pixels {
                cache.append((key, result, pixels.luma))
                if cache.count > 8 { cache.removeFirst() }
            }
            return result
        } catch {
            // A failed recognition is not a cacheable empty screen.
            return Result(width: image.width, height: image.height, items: [])
        }
    }
    private static func detect(_ image: CGImage) throws -> [Item] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation -> Item? in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return Item(
                text: candidate.string, box: observation.boundingBox,
                width: image.width, height: image.height, confidence: Double(candidate.confidence))
        }
    }

    /// Formats a failure-informative OCR error that preserves `StringsAPI.current.ocrTextNotFound`
    /// while appending up to 30 visible strings (`saw: [...]`) so agents do not need an extra
    /// round-trip just to inspect what text was actually on screen.
    static func formatNotFoundError(
        query: String,
        in result: Result,
        baseMessage: String = StringsAPI.current.ocrTextNotFound
    ) -> String {
        let visible = result.items
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !visible.isEmpty else {
            return baseMessage
        }
        let sample = visible.prefix(30).map { item -> String in
            let escaped = item.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ", ")
        return "\(baseMessage) (query: \"\(query)\"; saw: [\(sample)])"
    }

    /// Ghosthand tiered OCR matching: exact full-line matches win over substring matches.
    /// Supports both 0-based `index` and 1-based `oneBasedIndex` (top-to-bottom).
    static func matchTiered(
        _ result: Result,
        text query: String,
        exact: Bool = false,
        index: Int? = nil,
        oneBasedIndex: Bool = false,
        requireExplicitIndexWhenMultiple: Bool = false
    ) throws -> Item {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, result.width > 0, result.height > 0 else {
            throw DeviceError(formatNotFoundError(query: query, in: result))
        }
        let exactMatches = result.items.filter { item in
            exact
                ? item.text == query
                : item.text.caseInsensitiveCompare(query) == .orderedSame
        }
        let winningTier: [Item]
        if !exactMatches.isEmpty {
            winningTier = exactMatches
        } else if exact {
            winningTier = []
        } else {
            winningTier = result.items.filter {
                $0.text.range(of: query, options: .caseInsensitive) != nil
            }
        }
        guard !winningTier.isEmpty else {
            throw DeviceError(formatNotFoundError(query: query, in: result))
        }
        if let rawIndex = index {
            let resolvedIndex: Int
            if oneBasedIndex {
                resolvedIndex = rawIndex >= 1 ? rawIndex - 1 : rawIndex
            } else {
                resolvedIndex = rawIndex
            }
            guard resolvedIndex >= 0, resolvedIndex < winningTier.count else {
                throw DeviceError(formatNotFoundError(query: query, in: result))
            }
            return winningTier[resolvedIndex]
        }
        if requireExplicitIndexWhenMultiple && winningTier.count > 1 {
            let listing = winningTier.enumerated().map { offset, item in
                "\(offset + 1). \"\(item.text)\" (\(item.boxX),\(item.boxY) \(item.width)x\(item.height))"
            }.joined(separator: "; ")
            throw DeviceError("multiple OCR matches for \"\(query)\": \(listing)")
        }
        return winningTier[0]
    }
}
