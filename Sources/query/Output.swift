import Foundation

/// Double-quoted dotenv value, readable by dotenv, Bun, Node and docker compose.
func dotenvQuote(_ value: String) -> String {
    var escaped = ""
    for character in value {
        switch character {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n": escaped += "\\n"
        case "\r": escaped += "\\r"
        case "$": escaped += "\\$"
        default: escaped.append(character)
        }
    }
    return "\"\(escaped)\""
}

/// Single-quoted POSIX shell word.
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Shell word for display: plain when safe, single-quoted otherwise.
func displayWord(_ word: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
    return !word.isEmpty && word.unicodeScalars.allSatisfy(safe.contains) ? word : shellQuote(word)
}

func render(_ values: [(String, String)], as format: Format) -> String {
    switch format {
    case .env:
        return values.map { "\($0.0)=\(dotenvQuote($0.1))\n" }.joined()
    case .export:
        return values.map { "export \($0.0)=\(shellQuote($0.1))\n" }.joined()
    case .json:
        var object: [String: String] = [:]
        for (key, value) in values { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Replaces existing `KEY=` / `export KEY=` lines and appends new ones,
/// keeping every other line. The file is replaced atomically with mode 0600.
func mergeDotenv(_ values: [(String, String)], into path: String) throws {
    let url = URL(fileURLWithPath: path)
    var lines: [String] = []
    if let existing = try? String(contentsOf: url, encoding: .utf8) {
        lines = existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }
    for (key, value) in values {
        let line = "\(key)=\(dotenvQuote(value))"
        let match = lines.firstIndex { raw in
            var trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            return trimmed.hasPrefix("\(key)=")
        }
        if let match { lines[match] = line } else { lines.append(line) }
    }
    let contents = Data((lines.joined(separator: "\n") + "\n").utf8)

    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).query-\(getpid())").path
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: contents)
        try handle.close()
    } catch {
        unlink(temporary)
        throw error
    }
    guard rename(temporary, url.path) == 0 else {
        let code = errno
        unlink(temporary)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Hands the values to their destination and ends the process.
func deliver(_ values: [(String, String)], for request: Request) -> Never {
    switch request.mode {
    case .get(let format):
        FileHandle.standardOutput.write(Data(render(values, as: format).utf8))
        exit(0)

    case .write(let path):
        do {
            try mergeDotenv(values, into: path)
        } catch {
            FileHandle.standardError.write(Data("query: could not write \(path): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let names = values.map(\.0).joined(separator: ", ")
        FileHandle.standardError.write(Data("query: wrote \(names) to \(path)\n".utf8))
        exit(0)

    case .run(let command):
        for (key, value) in values { setenv(key, value, 1) }
        var argv = command.map { strdup($0) }
        argv.append(nil)
        execvp(command[0], argv)
        let message = String(cString: strerror(errno))
        FileHandle.standardError.write(Data("query: \(command[0]): \(message)\n".utf8))
        exit(127)
    }
}
