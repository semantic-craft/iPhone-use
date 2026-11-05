#!/usr/bin/env python3
"""Structural lint gate enforcing architectural invariants across Sources/."""

from pathlib import Path
import re
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES_DIR = REPO_ROOT / "Sources"

STATE_DIR_NIL_RE = re.compile(
    r'["\']IPHONE_USE_STATE_DIR["\']\s*\]\s*[!=]=\s*nil'
)
GHOSTHAND_SOCK_RE = re.compile(r"\.ghosthand/daemon\.sock")
WAKE_ACTION_PARSE_RE = re.compile(
    r"func\s+shouldWakeControl\s*\([^)]*\)\s*->\s*Bool\s*\{[^}]*Action\.parse\(path:\s*normalizedPath\)\s*!=\s*nil",
    re.DOTALL,
)


def check_swift_content(rel_path: str, content: str) -> list[str]:
    errors: list[str] = []
    if rel_path != "Sources/iPhoneUse/Devices/DeviceAddressing.swift":
        for match in STATE_DIR_NIL_RE.finditer(content):
            line = content.count("\n", 0, match.start()) + 1
            errors.append(
                f"{rel_path}:{line}: Forbidden direct IPHONE_USE_STATE_DIR nil check. "
                "Fix: call RuntimeEnvironment.isLiveHardwareAllowed(environment:) from "
                "Sources/iPhoneUse/Devices/DeviceAddressing.swift so production daemons with "
                "~/Library/Logs/iPhoneUse are not treated as hermetic tests."
            )
    for match in GHOSTHAND_SOCK_RE.finditer(content):
        line = content.count("\n", 0, match.start()) + 1
        errors.append(
            f"{rel_path}:{line}: Forbidden ~/.ghosthand/daemon.sock coupling. "
            "Fix: route device control through native USB/BLE channels instead of external Ghosthand sockets."
        )
    if rel_path == "Sources/iPhoneUse/API/ControlAPI.swift":
        if not WAKE_ACTION_PARSE_RE.search(content):
            errors.append(
                f"{rel_path}: shouldWakeControl(normalizedPath:) must delegate directly to "
                "Action.parse(path: normalizedPath) != nil. Fix: remove hand-synced control route sets "
                "in ControlAPI.waitForWake and derive control wake routes from Action.parse."
            )
    return errors


def run_selftest() -> int:
    past_mistakes = [
        (
            "Sources/iPhoneUse/API/ControlAPI.swift",
            'if ProcessInfo.processInfo.environment["IPHONE_USE_STATE_DIR"] == nil { }\n'
            "static func shouldWakeControl(normalizedPath: String) -> Bool { Action.parse(path: normalizedPath) != nil }",
            "Forbidden direct IPHONE_USE_STATE_DIR nil check",
        ),
        (
            "Sources/iPhoneUse/Input/GhosthandPrimitives.swift",
            'let path = "~/.ghosthand/daemon.sock"\n',
            "Forbidden ~/.ghosthand/daemon.sock coupling",
        ),
        (
            "Sources/iPhoneUse/API/ControlAPI.swift",
            'static let controlPaths: Set<String> = ["/tap", "/swipe"]\n'
            "static func shouldWakeControl(normalizedPath: String) -> Bool { controlPaths.contains(normalizedPath) }",
            "shouldWakeControl(normalizedPath:) must delegate directly to Action.parse",
        ),
    ]
    for rel_path, sample, expected_substring in past_mistakes:
        found = check_swift_content(rel_path, sample)
        if not any(expected_substring in err for err in found):
            print(
                f"SELFTEST FAILED: expected '{expected_substring}' for {rel_path}, got {found}",
                file=sys.stderr,
            )
            return 1
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return run_selftest()

    if run_selftest() != 0:
        return 1

    violations: list[str] = []
    for path in sorted(SOURCES_DIR.rglob("*.swift")):
        rel_path = path.relative_to(REPO_ROOT).as_posix()
        content = path.read_text(encoding="utf-8")
        violations.extend(check_swift_content(rel_path, content))

    if violations:
        for violation in violations:
            print(violation, file=sys.stderr)
        return 1

    print("structural-lint: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
