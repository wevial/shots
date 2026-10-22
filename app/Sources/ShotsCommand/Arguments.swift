import Foundation

/// A bad command line. Printed with the usage text; exit status 2.
struct UsageError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Parsed flags and positionals, in the spirit of Node's `util.parseArgs` (strict):
/// `--name value`, `--name=value`, boolean `--flag`, `--` ends the flags, and unknown
/// flags are an error.
struct Arguments {
    private(set) var values: [String: String] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positionals: [String] = []

    /// - Parameters:
    ///   - options: flags that take a value.
    ///   - booleans: flags that don't.
    init(_ arguments: [String], options: Set<String> = [], booleans: Set<String> = []) throws(UsageError) {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "--" {
                positionals += rest
                break
            }
            guard argument.hasPrefix("--"), argument.count > 2 else {
                positionals.append(argument)
                continue
            }
            let body = argument.dropFirst(2)
            let name = String(body.prefix { $0 != "=" })
            let inline = body.firstIndex(of: "=").map { String(body[body.index(after: $0)...]) }
            if options.contains(name) {
                guard let value = inline ?? rest.popFirst() else { throw UsageError("option --\(name) needs a value") }
                values[name] = value
            } else if booleans.contains(name) {
                if inline != nil { throw UsageError("option --\(name) does not take a value") }
                flags.insert(name)
            } else {
                throw UsageError("unknown option --\(name)")
            }
        }
    }

    subscript(option: String) -> String? { values[option] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}
