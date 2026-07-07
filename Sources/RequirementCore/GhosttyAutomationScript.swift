import Foundation

public enum GhosttyAutomationScript {
    public static let defaultApplicationPath = "/Applications/Ghostty.app"

    /// 通过 Ghostty 的脚本接口在「常规单实例」里启动脚本：
    /// 已知项目窗口存在则在其中新建 tab，否则新建窗口并返回窗口 ID。
    /// 工作目录与初始输入都只作用于本次创建的 surface，
    /// 不会污染用户手动打开的窗口或 tab。
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

        const configuration = {
          initialWorkingDirectory: \(jsStringLiteral(projectDirectory)),
          initialInput: \(jsStringLiteral(input)),
          waitAfterCommand: true
        };

        let targetWindow = existingWindow(\(knownWindowValue));
        if (targetWindow) {
          app.newTab({in: targetWindow, withConfiguration: configuration});
        } else {
          targetWindow = app.newWindow({withConfiguration: configuration});
        }

        try {
          app.activate();
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
