#!/bin/sh
set -eu

HOST_NAME="com.aderx.requirementtracker.jira_capture"

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <chrome-extension-id> [chrome|edge]"
  exit 64
fi

EXTENSION_ID="$1"
BROWSER="${2:-chrome}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

case "$BROWSER" in
  chrome)
    MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
    ;;
  edge)
    MANIFEST_DIR="$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    ;;
  *)
    echo "Unsupported browser: $BROWSER"
    echo "Usage: $0 <chrome-extension-id> [chrome|edge]"
    exit 64
    ;;
esac

cd "$REPO_ROOT"
swift build -c release --product JiraRequirementNativeHost

HOST_PATH="$REPO_ROOT/.build/release/JiraRequirementNativeHost"
MANIFEST_PATH="$MANIFEST_DIR/$HOST_NAME.json"

mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST_PATH" <<JSON
{
  "name": "$HOST_NAME",
  "description": "RequirementTracker Jira capture native host",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXTENSION_ID/"
  ]
}
JSON

echo "Installed native messaging host:"
echo "$MANIFEST_PATH"
