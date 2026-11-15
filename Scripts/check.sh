#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/XcodeRunnerChecks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -typecheck -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -sdk "$sdk_path" -module-cache-path "$check_dir/ModuleCache" XcodeRunner/*.swift
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/ModuleCache" \
  XcodeRunner/GitLineStats.swift XcodeRunner/GitDiff.swift XcodeRunner/GitChanges.swift XcodeRunner/ProjectIconCache.swift XcodeRunner/AppBuildSettings.swift XcodeRunner/ProjectAppIcon.swift XcodeRunner/ArchivePlan.swift XcodeRunner/ProjectVersion.swift XcodeRunner/Models.swift XcodeRunner/CommandRunner.swift XcodeRunner/BuildProgress.swift XcodeRunner/BuildDiagnostic.swift XcodeRunner/AppConsoleSession.swift \
  XcodeRunner/ProjectWatcher.swift XcodeRunner/XcodeTools.swift XcodeRunner/ToolJSON.swift XcodeRunner/SchemeRecommendation.swift XcodeRunner/DeviceUnlockGate.swift XcodeRunner/ConsoleTextUpdate.swift \
  Scripts/RegressionChecks.swift -o "$check_dir/RegressionChecks"
"$check_dir/RegressionChecks"
plutil -lint XcodeRunner.xcodeproj/project.pbxproj
