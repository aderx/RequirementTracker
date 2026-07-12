# RequirementTracker

RequirementTracker is a lightweight macOS menu bar app for tracking requirement status, Jira links, merge request links, notes, and pause or stop reasons.

## Features

- Menu bar popup for quick requirement status updates.
- Overview window with status filters, fuzzy search, editable details, and timeline history.
- Support for pending, active, completed, tested, merged, paused, and stopped states.
- Pause and stop reasons for terminal or blocked requirements.
- Native macOS-style menus, windows, and controls.
- Local JSON storage. No requirement data is committed to this repository.

## Build

```bash
swift build
```

Release build:

```bash
swift build -c release
```

Run the development version:

```bash
swift run RequirementTracker
```

The Notification Center calendar widgets require a bundled app extension, so use the
development bundle when testing them:

```bash
Scripts/package-app.sh debug
open ".build/widget-preview/需求记录 Dev.app"
```

After launching the development app once, add either `完整月历` or `全年日历`
from the macOS widget gallery. Both widgets support the large and extra-large families.

## Local Data

Runtime data is stored outside the repository:

```text
~/Library/Application Support/RequirementTracker/requirements.json
```

Back up this file before manually editing historical data.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).
