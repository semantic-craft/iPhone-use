# USB

## Overview

Provides USB system, media, file-transfer, app-management, syslog, and accessibility channels for connected iPhones (`USBSystemProvider`, `StateDirUSBSystemProvider`), along with a dynamic `MobileDevice.framework` lockdown bridge (`MobileDeviceLockdownBridge`) for querying live hardware metadata, toggling AssistiveTouch, and rendering fallback hardware screens.

## Interface

- `[USBSystemChannels.swift:USBFileEntry]` - `Codable`, `Equatable` struct representing a file or directory entry (`path`, `name`, `type`, `size`, `modified`, `mediaType`, `json()`, `toJSON()`).
- `[USBSystemChannels.swift:USBAppEntry]` - `Codable`, `Equatable` struct representing an installed iOS application (`bundleId`, `name`, `version`, `system`, `installing`, `fileSharing`, `homeScreen`, `json()`, `toJSON()`).
- `[USBSystemChannels.swift:USBDeviceInfo]` - `Codable`, `Equatable` struct representing iPhone lockdown metadata (`udid`, `name`, `model`, `modelName`, `iosVersion`, `build`, `serialNumber`, `batteryPercent`, `charging`, `externalPower`, `storageTotalBytes`, `storageFreeBytes`, `language`, `locale`, `timeZone`, `wifiAddress`, `sim`, `locked`, `assistiveTouchEnabled`, nested `SIMLine` and `SIMInfo` structs, `json()`, `toJSON()`).
- `[USBSystemChannels.swift:USBSystemProvider]` - Protocol defining 14 USB system and media operations (`listPhotos`, `pullPhoto`, `deletePhotos`, `pushPhoto`, `listFiles`, `pullFile`, `pushFile`, `removeFile`, `listApps`, `openApp`, `deviceInfo`, `deviceLogs`, `getAssistiveTouch`, `setAssistiveTouch`).
- `[USBSystemChannels.swift:StateDirUSBSystemProvider]` - `final class` implementing `USBSystemProvider` (`shared`, `supportedPhotoExtensions`, `videoExtensions`, `init(environmentProvider:)`, `init(baseDirectory:)`, `resolveBaseDirectory(environment:)`, `appendLog(deviceID:process:message:)`, `activeApp(for:)`, and all `USBSystemProvider` methods) backed by `<IPHONE_USE_STATE_DIR>/usb/<deviceID>/` and live `MobileDeviceLockdownBridge` calls when permitted.
- `[USBSystemChannels.swift:MobileDeviceLockdownSnapshot]` - `Codable`, `Equatable` value type storing live lockdown properties (`udid`, `name`, `productType`, `modelName`, `iosVersion`, `build`, `serialNumber`, `wifiAddress`, `bluetoothAddress`, `timeZone`, `passwordProtected`, `trusted`, `batteryPercent`, `charging`, `externalPower`, `storageTotalBytes`, `storageFreeBytes`, `language`, `locale`, `sim`, `assistiveTouchEnabled`).
- `[USBSystemChannels.swift:MobileDeviceLockdownBridge]` - Namespace enum bridging `MobileDevice.framework` (`marketingModelName(for:)`, `attachedDevices()`, `findDevice(matching:)`, `getAssistiveTouch(matching:)`, `setAssistiveTouch(matching:enabled:)`, `renderLiveHardwareScreenPNG(for:activeApp:maxWidth:maxEdge:)`).

## Invariants

- `[USBSystemChannels.swift:StateDirUSBSystemProvider.normalizeVirtualPath]` - Rejects any virtual path containing `.` or `..` traversal segments with `GhosthandError.invalidArgument`.
- `[USBSystemChannels.swift:StateDirUSBSystemProvider.containerRoot]` - When `appBundleID` is specified, the target app must exist in `installed_apps.json` (throwing `not-found` HTTP 404 otherwise) and must have `fileSharing == true` (throwing `permission-denied` HTTP 403 otherwise).
- `[USBSystemChannels.swift:StateDirUSBSystemProvider.deletePhotos]` - Rejects execution with `GhosthandError.deviceLocked` when `isLocked == true`, requires non-empty `names` without `..`, and verifies that every requested photo exists in `media/DCIM` before deleting any file.
- `[USBSystemChannels.swift:StateDirUSBSystemProvider.pushPhoto]` - Rejects execution with `GhosthandError.deviceLocked` when `isLocked == true`, requires non-empty image/video bytes, a filename without `/` or `..`, and an extension in `supportedPhotoExtensions`.
- `[USBSystemChannels.swift:StateDirUSBSystemProvider.removeFile]` - Rejects root path `/` removal and forbids deleting `/DCIM` or `/DCIM/*` when `appBundleID` is nil/empty (`dcim-remove-forbidden` HTTP 400).
- `[USBSystemChannels.swift:StateDirUSBSystemProvider.deviceLogs]` - Enforces finite `seconds` within `0.2...120.0` and `limit` within `1...10_000` (same `1...10_000` bound as `listPhotos`).
- `[USBSystemChannels.swift:MobileDeviceLockdownBridge.attachedDevices]` - Accepts only devices with `AMDeviceGetInterfaceType` equal to `1` or `2`, prefers interface type `1` (USB) when deduplicating by `udid`, and returns snapshots sorted ascending by `udid`.
- `[USBSystemChannels.swift:MobileDeviceLockdownBridge.findDevice]` - When `query` is nil, empty, or `"default"`, returns a device only if `attachedDevices().count == 1`; otherwise requires an exact match on `udid` or `name` or a prefix match on `udid`.

## Side Effects

- `[USBSystemChannels.swift:StateDirUSBSystemProvider]` - Serializes state directory access with `NSLock`, creates and mutates `<stateDir>/usb/<deviceID>/` (`media/DCIM/100APPLE`, `media/PublicStaging`, `apps/<bundleId>`, `installed_apps.json`, `active_app.json`, `assistive_touch.json`, `syslog.txt`), writes pulled photos/files to local destination paths, and invokes `sendSpotlightLaunch` during `openApp`.
- `[USBSystemChannels.swift:MobileDeviceLockdownBridge.symbols]` - Dynamically loads `/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice` via `dlopen(..., RTLD_LAZY)` and resolves `AMDCreateDeviceList` and `AMDevice*` functions via `dlsym`.
- `[USBSystemChannels.swift:MobileDeviceLockdownBridge.attachedDevices]` - Connects to attached iOS devices, validates pairing, opens/closes lockdown sessions to query `com.apple.mobile.battery`, `com.apple.disk_usage`, `com.apple.international`, and `com.apple.Accessibility`, and reads/writes the device snapshot cache at `~/Library/Logs/iPhoneUse/known_usb_devices.json`.
- `[USBSystemChannels.swift:MobileDeviceLockdownBridge.setAssistiveTouch]` - Opens a lockdown session on the target iPhone and writes `AssistiveTouchEnabledByiTunes` in domain `com.apple.Accessibility` via `AMDeviceSetValue`.

## Verification

- Run: `swift test`
