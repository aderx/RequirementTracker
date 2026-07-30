#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEV_APP="$ROOT_DIR/.build/widget-preview/需求记录 Dev.app"
DEV_WIDGET="$DEV_APP/Contents/PlugIns/RequirementCalendarWidget.appex"
DEV_APP_EXECUTABLE="$DEV_APP/Contents/MacOS/RequirementTracker"
DEV_WIDGET_EXECUTABLE="$DEV_WIDGET/Contents/MacOS/RequirementCalendarWidget"
DEV_WIDGET_BUNDLE_ID="com.xfu-work.RequirementTracker.dev.CalendarWidget"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

collect_development_pids() {
    local pid command
    while read -r pid command; do
        if [[ "$command" == "$DEV_APP_EXECUTABLE"*
            || "$command" == "$DEV_WIDGET_EXECUTABLE"* ]]; then
            print -r -- "$pid"
        fi
    done < <(ps -axo pid=,command=)
}

refresh_development_pids() {
    local pid
    development_pids=()

    while IFS= read -r pid; do
        [[ "$pid" == <-> ]] && development_pids+=("$pid")
    done < <(collect_development_pids)
}

if [[ -d "$DEV_WIDGET" ]]; then
    /usr/bin/pluginkit -r "$DEV_WIDGET" >/dev/null 2>&1 || true
fi

if [[ -d "$DEV_APP" ]]; then
    "$LSREGISTER" -u "$DEV_APP" >/dev/null 2>&1 || true
fi

typeset -a development_pids
refresh_development_pids

if (( ${#development_pids} > 0 )); then
    kill -TERM "${development_pids[@]}"

    for _ in {1..20}; do
        sleep 0.25
        refresh_development_pids
        (( ${#development_pids} == 0 )) && break
    done
fi

refresh_development_pids
if (( ${#development_pids} > 0 )); then
    kill -KILL "${development_pids[@]}"
    sleep 0.25
fi

refresh_development_pids
if (( ${#development_pids} > 0 )); then
    echo "Development RequirementTracker processes are still running: ${development_pids[*]}" >&2
    exit 1
fi

if /usr/bin/pluginkit -m -A -D -i "$DEV_WIDGET_BUNDLE_ID" | grep -q "$DEV_WIDGET_BUNDLE_ID"; then
    echo "Development Widget is still registered: $DEV_WIDGET_BUNDLE_ID" >&2
    exit 1
fi

echo "Development RequirementTracker App and Widget are stopped and unregistered."
