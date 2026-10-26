import Foundation

struct KeySpec: Identifiable {
    let name: String
    let hint: String?
    var id: String { name }
}

enum Format: String {
    case env, export, json
}

enum Mode {
    /// Print the values to stdout.
    case get(Format)
    /// Exec a command with the values in its environment.
    case run([String])
    /// Merge the values into a dotenv file.
    case write(String)
}

struct Request {
    let keys: [KeySpec]
    let reason: String?
    let mode: Mode
    let timeout: TimeInterval?
    let palette: Palette
}

let usage = """
askenv: ask a person for environment values in a floating window

  askenv run KEY... [options] -- COMMAND [ARGS...]
      Run COMMAND with the values set as environment variables.
      The values never reach stdout. Use this from agents.

  askenv write FILE KEY... [options]
      Merge the values into a dotenv FILE (written with mode 0600).

  askenv get KEY... [options] [--format env|export|json]
      Print the values to stdout. Whoever reads stdout sees them.

A KEY may carry a hint after a colon:
  askenv run "STRIPE_KEY:Restricted key, test mode" -- npm test

Options:
  --reason TEXT       Why the values are needed, shown in the window
  --timeout SECONDS   Give up with exit status 124 if nobody answers
  --color COLOR       Color of the light: indigo, ember, jade, ocean, rose,
                      gold, mono, or a hex color such as #ff6a3d.
                      Defaults to $ASKENV_COLOR, then indigo.

Exit status: 0 provided, 1 cancelled, 2 usage error, 124 timed out.
For run, the exit status is the command's own.

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("askenv: \(message)\n".utf8))
    exit(2)
}

func parseArguments(_ arguments: [String]) -> Request {
    var args = arguments
    guard let command = args.first else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    args.removeFirst()
    if ["-h", "--help", "help"].contains(command) {
        print(usage, terminator: "")
        exit(0)
    }

    var commandLine: [String] = []
    if let dash = args.firstIndex(of: "--") {
        commandLine = Array(args[(dash + 1)...])
        args = Array(args[..<dash])
    }

    var positionals: [String] = []
    var reason: String?
    var format = Format.env
    var timeout: TimeInterval?
    var colorName = ProcessInfo.processInfo.environment["ASKENV_COLOR"]
    var index = 0
    while index < args.count {
        let arg = args[index]
        func value() -> String {
            index += 1
            guard index < args.count else { fail("\(arg) needs a value") }
            return args[index]
        }
        switch arg {
        case "--reason":
            reason = value()
        case "--format":
            let raw = value()
            guard let parsed = Format(rawValue: raw) else { fail("unknown format \(raw)") }
            format = parsed
        case "--color":
            colorName = value()
        case "--timeout":
            let raw = value()
            guard let seconds = TimeInterval(raw), seconds > 0 else { fail("invalid timeout \(raw)") }
            timeout = seconds
        default:
            if arg.hasPrefix("--") { fail("unknown option \(arg)") }
            positionals.append(arg)
        }
        index += 1
    }

    let mode: Mode
    switch command {
    case "run":
        guard !commandLine.isEmpty else { fail("run needs a command after --") }
        mode = .run(commandLine)
    case "write":
        guard commandLine.isEmpty else { fail("write does not take a command") }
        guard !positionals.isEmpty else { fail("write needs a FILE") }
        mode = .write(positionals.removeFirst())
    case "get":
        guard commandLine.isEmpty else { fail("get does not take a command") }
        mode = .get(format)
    default:
        fail("unknown command \(command)\n\n\(usage)")
    }

    guard !positionals.isEmpty else { fail("name at least one KEY") }
    var seen = Set<String>()
    let keys = positionals.map { spec -> KeySpec in
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            fail("invalid KEY name \"\(name)\"")
        }
        guard seen.insert(name).inserted else { fail("\(name) is listed twice") }
        let hint = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return KeySpec(name: name, hint: hint.isEmpty ? nil : hint)
    }

    var palette = Palette.presets["indigo"]!
    if let colorName, !colorName.isEmpty {
        guard let chosen = Palette.named(colorName) else {
            fail("unknown color \"\(colorName)\"; use \(Palette.presetNames.joined(separator: ", ")) or a hex color")
        }
        palette = chosen
    }

    return Request(keys: keys, reason: reason, mode: mode, timeout: timeout, palette: palette)
}
