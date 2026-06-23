import Foundation

public enum GhosttyAutomationScript {
    public static let defaultApplicationPath = "/Applications/Ghostty.app"

    public static func jxa(
        projectDirectory: String,
        command: String,
        knownWindowID: String? = nil,
        applicationPath: String = defaultApplicationPath
    ) -> String {
        let shellInput = shellCommand(projectDirectory: projectDirectory, command: command)
        let input = shellInput.hasSuffix("\n") ? shellInput : shellInput + "\n"
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

    public static func shellCommand(
        projectDirectory: String,
        command: String
    ) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return "cd \(shellSingleQuoted(projectDirectory))\n\(trimmedCommand)"
    }

    public static func openArguments(
        projectDirectory: String,
        command: String,
        applicationPath: String = defaultApplicationPath
    ) -> [String] {
        [
            "-na",
            applicationPath,
            "--args",
            "--working-directory=\(projectDirectory)",
            "--initial-command=shell:\(shellCommand(projectDirectory: projectDirectory, command: command))"
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
