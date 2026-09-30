import Foundation

public struct ProjectCommandSpec: Equatable, Sendable {
    public var programArguments: [String]
    public var environmentOverrides: [String: String]

    public init(programArguments: [String], environmentOverrides: [String: String]) {
        self.programArguments = programArguments
        self.environmentOverrides = environmentOverrides
    }
}

public enum ProjectCommandResolver {
    private struct ParsedProjectCommand: Sendable {
        let arguments: [String]
        let environmentAssignments: [String: String]
    }

    public static func resolve(command: String, directory: String, port: Int) -> ProjectCommandSpec {
        if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let parsed = parseCommand(command) {
                return directCommand(arguments: parsed.arguments, environmentOverrides: parsed.environmentAssignments)
            }

            return ProjectCommandSpec(
                programArguments: ["/bin/zsh", "-c", command],
                environmentOverrides: [:]
            )
        }

        let packagePath = (directory as NSString).appendingPathComponent("package.json")
        guard
            let data = FileManager.default.contents(atPath: packagePath),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return directCommand(arguments: ["bun", "run", "start"])
        }

        let dependencies = (json["dependencies"] as? [String: Any] ?? [:]).merging(
            json["devDependencies"] as? [String: Any] ?? [:]
        ) { current, _ in current }
        let scripts = json["scripts"] as? [String: Any] ?? [:]

        if dependencies["next"] != nil {
            return directCommand(arguments: ["bun", "x", "next", "start", "-p", "\(port)"])
        }
        if dependencies["vite"] != nil {
            return directCommand(arguments: ["bun", "x", "vite", "--host", "--port", "\(port)"])
        }
        if scripts["start"] != nil {
            return directCommand(arguments: ["bun", "run", "start"])
        }
        if scripts["dev"] != nil {
            return directCommand(arguments: ["bun", "run", "dev"])
        }

        return directCommand(arguments: ["bun", "run", "start"])
    }

    private static let systemPathDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// User and Homebrew tools come before macOS's own binaries, whatever PATH Nest inherited.
    /// A GUI launch inherits only the system directories, which would otherwise shadow Homebrew.
    public static func launchPath(inheritedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String {
        let homeDirectory = NSHomeDirectory()
        let inherited = inheritedPath.split(separator: ":").map(String.init)
        let candidates = inherited.filter { !systemPathDirectories.contains($0) } + [
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.local/bin",
            AppSettings.nestBinDirectory,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin"
        ] + systemPathDirectories

        var seen: Set<String> = []
        var components: [String] = []

        for part in candidates where !part.isEmpty {
            if seen.insert(part).inserted {
                components.append(part)
            }
        }

        return components.joined(separator: ":")
    }

    private static func directCommand(
        arguments: [String],
        environmentOverrides: [String: String] = [:]
    ) -> ProjectCommandSpec {
        guard let executable = arguments.first else {
            return ProjectCommandSpec(
                programArguments: ["/bin/zsh", "-c", "exit 1"],
                environmentOverrides: environmentOverrides
            )
        }

        let programArguments: [String]
        if executable.contains("/") {
            programArguments = arguments
        } else {
            programArguments = ["/usr/bin/env"] + arguments
        }

        return ProjectCommandSpec(
            programArguments: programArguments,
            environmentOverrides: environmentOverrides
        )
    }

    private static func parseCommand(_ command: String) -> ParsedProjectCommand? {
        var tokens: [String] = []
        var current = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false
        var isEscaping = false
        var isEscapingInDoubleQuotes = false
        var tokenStarted = false
        let shellOnlyCharacters = CharacterSet(charactersIn: "|&;<>$`~*?[]\n")
        // Inside double quotes a shell still expands $ and `, and a backslash only escapes these.
        let doubleQuoteExpansions: Set<Character> = ["$", "`"]
        let doubleQuoteEscapable: Set<Character> = ["$", "`", "\"", "\\", "\n"]

        for character in command {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if isEscapingInDoubleQuotes {
                if !doubleQuoteEscapable.contains(character) { current.append("\\") }
                current.append(character)
                isEscapingInDoubleQuotes = false
                continue
            }

            if inSingleQuotes {
                if character == "'" {
                    inSingleQuotes = false
                } else {
                    current.append(character)
                }
                continue
            }

            if inDoubleQuotes {
                if character == "\"" {
                    inDoubleQuotes = false
                } else if character == "\\" {
                    isEscapingInDoubleQuotes = true
                } else if doubleQuoteExpansions.contains(character) {
                    return nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\\" {
                isEscaping = true
                tokenStarted = true
                continue
            }

            if character == "'" {
                inSingleQuotes = true
                tokenStarted = true
                continue
            }

            if character == "\"" {
                inDoubleQuotes = true
                tokenStarted = true
                continue
            }

            // A `#` starting a word begins a shell comment.
            if character == "#" && !tokenStarted {
                return nil
            }

            if character.unicodeScalars.allSatisfy(shellOnlyCharacters.contains) {
                return nil
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                tokenStarted = false
                continue
            }

            current.append(character)
            tokenStarted = true
        }

        guard !isEscaping, !isEscapingInDoubleQuotes, !inSingleQuotes, !inDoubleQuotes else { return nil }

        if !current.isEmpty {
            tokens.append(current)
        }

        guard !tokens.isEmpty else { return nil }

        var environmentAssignments: [String: String] = [:]
        var argumentStartIndex = 0

        while argumentStartIndex < tokens.count,
              let assignment = parseEnvironmentAssignment(tokens[argumentStartIndex]) {
            environmentAssignments[assignment.key] = assignment.value
            argumentStartIndex += 1
        }

        let arguments = Array(tokens.dropFirst(argumentStartIndex))
        guard !arguments.isEmpty else { return nil }

        return ParsedProjectCommand(
            arguments: arguments,
            environmentAssignments: environmentAssignments
        )
    }

    private static func parseEnvironmentAssignment(_ token: String) -> (key: String, value: String)? {
        guard let separatorIndex = token.firstIndex(of: "=") else { return nil }
        let key = String(token[..<separatorIndex])
        let value = String(token[token.index(after: separatorIndex)...])

        guard isValidEnvironmentKey(key) else { return nil }
        return (key, value)
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        guard first == "_" || first.isLetter else { return false }
        return key.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
