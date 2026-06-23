import Foundation

public enum GhosttyAutomationScript {
    public static let defaultApplicationPath = "/Applications/Ghostty.app"

    public struct AppleEventCodes: Equatable, Sendable {
        public let eventClass: String
        public let eventID: String
        public let configurationParameter: String
        public let workingDirectoryProperty: String
        public let initialInputProperty: String
        public let waitAfterCommandProperty: String

        public init(
            eventClass: String,
            eventID: String,
            configurationParameter: String,
            workingDirectoryProperty: String,
            initialInputProperty: String,
            waitAfterCommandProperty: String
        ) {
            self.eventClass = eventClass
            self.eventID = eventID
            self.configurationParameter = configurationParameter
            self.workingDirectoryProperty = workingDirectoryProperty
            self.initialInputProperty = initialInputProperty
            self.waitAfterCommandProperty = waitAfterCommandProperty
        }
    }

    public static let newTabAppleEventCodes = AppleEventCodes(
        eventClass: "Ghst",
        eventID: "NTab",
        configurationParameter: "GNtS",
        workingDirectoryProperty: "GScD",
        initialInputProperty: "GScI",
        waitAfterCommandProperty: "GScW"
    )

    public static func jxa(
        projectDirectory: String,
        command: String,
        knownWindowID: String? = nil,
        applicationPath: String = defaultApplicationPath
    ) -> String {
        let input = launchInput(projectDirectory: projectDirectory, command: command)
        let knownWindowValue = knownWindowID?.isEmpty == false ? jsStringLiteral(knownWindowID ?? "") : "null"

        return """
        const app = Application(\(jsStringLiteral(applicationPath)));
        app.launch();

        function existingWindow(id) {
          if (id === null) {
            return null;
          }
          try {
            const window = app.windows.byId(id);
            window.name();
            return window;
          } catch (error) {
            return null;
          }
        }

        const configuration = app.SurfaceConfiguration({
          initialWorkingDirectory: \(jsStringLiteral(projectDirectory)),
          initialInput: \(jsStringLiteral(input)),
          waitAfterCommand: true
        });

        let targetWindow = existingWindow(\(knownWindowValue));
        if (targetWindow) {
          app.newTab({in: targetWindow, withConfiguration: configuration});
        } else {
          targetWindow = app.newWindow({withConfiguration: configuration});
        }

        try {
          targetWindow.activateWindow();
        } catch (error) {}

        String(targetWindow.id());
        """
    }

    public static func launchInput(
        projectDirectory: String,
        command: String
    ) -> String {
        let shellInput = shellCommand(projectDirectory: projectDirectory, command: command)
        return shellInput.hasSuffix("\n") ? shellInput : shellInput + "\n"
    }

    public static func shellCommand(
        projectDirectory: String,
        command: String
    ) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return "cd \(shellSingleQuoted(projectDirectory))\n\(trimmedCommand)"
    }

    public static func openArguments(
        projectDirectory: String,
        inputFilePath: String,
        applicationPath: String = defaultApplicationPath
    ) -> [String] {
        [
            "-na",
            applicationPath,
            "--args"
        ] + applicationArguments(
            projectDirectory: projectDirectory,
            inputFilePath: inputFilePath
        )
    }

    public static func applicationArguments(
        projectDirectory: String,
        inputFilePath: String
    ) -> [String] {
        [
            "--working-directory=\(projectDirectory)",
            "--input=path:\(inputFilePath)"
        ]
    }

    public static func jsStringLiteral(_ value: String) -> String {
        var result = "\""

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u{%04X}", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }

        result += "\""
        return result
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
