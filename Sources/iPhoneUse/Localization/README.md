# Localization

## Overview
Provides compile-time verified bilingual (`zh` and `en`) string tables and runtime language preference management across the HTTP API, MCP server, native AppKit UI, and embedded Web viewer.

## Interface
- `[AppLanguage.swift:AppLanguage]` — `enum AppLanguage: String, CaseIterable` defining `.zh` and `.en`, `static func resolvingSystemLanguage(_ preferredLanguages: [String]) -> AppLanguage`, `static var systemDefault: AppLanguage`, and `var displayName: String`.
- `[AppLanguage.swift:AppLanguageStore]` — `final class AppLanguageStore` with `static let shared: AppLanguageStore`, `static let didChangeNotification: Notification.Name` (`"AppLanguageStore.didChange"`), `static let defaultsKey: String` (`"IPHONE_USE_LANGUAGE"`), `var language: AppLanguage`, `init(defaults: UserDefaults = .standard)`, and `func set(_ language: AppLanguage)`.
- `[AppLanguage.swift:LocalizedTable]` — `protocol LocalizedTable` requiring `static var zh: Self { get }`, `static var en: Self { get }`, and `init(language: AppLanguage)`.
- `[StringsAPI.swift:StringsAPI]` — `struct StringsAPI: LocalizedTable` providing `static var current: StringsAPI`, `static let zh: StringsAPI`, `static let en: StringsAPI`, and localized HTTP/API validation, `SwipeRequest`, `RequestCoordinates`, `DeviceRegistry` matching, and `DeviceInput.InputError` strings and formatting closures.
- `[StringsMCP.swift:StringsMCP]` — `struct StringsMCP: LocalizedTable` providing `static let zh: StringsMCP`, `static let en: StringsMCP`, MCP initialize `instructions`, parameter descriptions, tool descriptions (`toolListDevices`, `toolScreenshot`, `toolOCRScreen`, `toolTapText`, `toolMovePointer`, `toolAdjustPointer`, `toolClickPointer`, `toolTap`, `toolLongPress`, `toolSwipe`, `toolTypeText`, `toolPressKey`, `toolKeyboardSequence`, `toolHome`, `toolSetupStatus`, `toolAcquire`, `toolWait`, `toolRelease`, `toolScreentext`, `toolDoubleTap`, `toolTripleTap`, `toolHold`, `toolHoldDrag`, `toolScroll`, `toolWake`, `toolLock`, `toolUnlock`, `toolMute`, `toolUnmute`, `toolRecordStart`, `toolRecordStop`, `toolPhotoList`, `toolPhotoPull`, `toolPhotoDelete`, `toolPhotoPush`, `toolFileList`, `toolFilePull`, `toolFilePush`, `toolFileRemove`, `toolAppList`, `toolOpenApp`, `toolDeviceInfo`, `toolDeviceLogs`, `toolAssistiveTouch`, `toolTask`, `toolSwitchTrackMode`, `toolGetTrackStatus`, `toolGetAXTree`, `toolDecideTrack`), validation closures, `MCPServer` messages, and `MCPAccess` lock error strings.
- `[StringsUI.swift:StringsUI]` — `struct StringsUI: LocalizedTable` providing `static var current: StringsUI`, `static let zh: StringsUI`, `static let en: StringsUI`, and localized AppKit menu, window title, sidebar group/shortcut/status, connection overlay, and canvas strings.
- `[StringsWeb.swift:StringsWeb]` — `struct StringsWeb: LocalizedTable` providing `static let zh: StringsWeb`, `static let en: StringsWeb`, `var jsDictionary: [String: String]`, HTML template strings, and JavaScript viewer status strings.

## Invariants
- `[AppLanguage.swift:AppLanguage.resolvingSystemLanguage]` — Resolves to `.zh` if `(preferredLanguages.first ?? "en").hasPrefix("zh")`; otherwise defaults to `.en`.
- `[AppLanguage.swift:AppLanguage.displayName]` — Returns constant native language labels (`"中文"` for `.zh`, `"English"` for `.en`) independent of the active UI language.
- `[AppLanguage.swift:AppLanguageStore.language]` — Synchronizes read/write access to the active `AppLanguage` using an internal `NSLock`.
- `[AppLanguage.swift:AppLanguageStore.set]` — Persists `language.rawValue` under `AppLanguageStore.defaultsKey` (`"IPHONE_USE_LANGUAGE"`) on every call, but only mutates in-memory state and posts `AppLanguageStore.didChangeNotification` when `language != self.language`.
- `[AppLanguage.swift:LocalizedTable]` — Stored properties on conforming structs enforce at compile time that both `.zh` and `.en` define every localized entry.
- `[StringsMCP.swift:StringsMCP]` — Omits `static var current` so the standalone stdio MCP process must explicitly instantiate `StringsMCP(language:)` using the language fetched from `GET /config` rather than reading `AppLanguageStore.shared`.
- `[StringsUI.swift:StringsUI.pairingInstructions]` — Includes the alternate `controllerName` hint only when `controllerName` is non-nil, non-empty, and distinct from `advertisedName`.
- `[StringsWeb.swift:StringsWeb.jsDictionary]` — Exports 25 keys (`pauseButton`, `resumeButton`, and 23 `js*` properties) for JSON serialization into the web viewer inline script.

## Side Effects
- `[AppLanguage.swift:AppLanguage.systemDefault]` — Reads `Locale.preferredLanguages` from `Foundation`.
- `[AppLanguage.swift:AppLanguageStore.init]` — Reads `"IPHONE_USE_LANGUAGE"` from `UserDefaults` (defaulting to `UserDefaults.standard`) and falls back to `AppLanguage.systemDefault`.
- `[AppLanguage.swift:AppLanguageStore.set]` — Writes `language.rawValue` to `UserDefaults` under `"IPHONE_USE_LANGUAGE"` and posts `Notification.Name("AppLanguageStore.didChange")` to `NotificationCenter.default` when the language changes.
- `[StringsAPI.swift:StringsAPI.current]` — Reads `AppLanguageStore.shared.language`.
- `[StringsUI.swift:StringsUI.current]` — Reads `AppLanguageStore.shared.language`.

## Verification
- Run: `swift test`
