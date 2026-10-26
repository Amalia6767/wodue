#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$PROJECT_ROOT/.build"
mkdir -p "$BUILD_ROOT/module-cache" "$BUILD_ROOT/test-data"
names=(Model PlanningModel RuntimeMode DeadlineEngine DeadlineReminder FocusClock EventParser CanvasParser CanvasCalendarExport CalendarSync)
sources=()
for name in "${names[@]}"; do sources+=("$PROJECT_ROOT/Sources/$name.swift"); done
xcrun swiftc -parse-as-library -module-cache-path "$BUILD_ROOT/module-cache" \
    "${sources[@]}" "$PROJECT_ROOT/Tests/Tests.swift" -o "$BUILD_ROOT/model-tests" \
    -framework AppKit -framework EventKit -framework UserNotifications
# The fictional fixtures use UTC+08:00. This does not change any system setting.
TZ=Asia/Singapore "$BUILD_ROOT/model-tests" "$BUILD_ROOT/test-data"
