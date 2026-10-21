// shots-helper: stateless native bridge for the TS daemon.
// Every subcommand prints one JSON object on stdout. Exit codes:
//   0 ok, 1 error ({"error": "..."}), 2 backend unavailable ({"unavailable": "..."}).
import Foundation

func emit(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    emit(["error": message])
    exit(code)
}

func readStdinJSON() -> [String: Any] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("stdin is not a JSON object")
    }
    return obj
}

/// Runs an async body on the main thread's run loop and exits when it finishes.
func runAsync(_ body: @escaping () async -> Void) -> Never {
    Task {
        await body()
        exit(0)
    }
    dispatchMain()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: shots-helper <meta|context|ocr|fm-status|classify|tags|clipboard|permissions> [args]")
}
let rest = Array(args.dropFirst())

func requirePath(_ i: Int = 0) -> String {
    guard rest.count > i else { fail("\(command): missing path argument") }
    return rest[i]
}

switch command {
case "meta":
    emit(screenshotMetadata(path: requirePath()))
case "context":
    emit(captureContext())
case "ocr":
    let languages = rest.count > 1 ? rest[1].split(separator: ",").map(String.init) : []
    do { emit(try recognizeText(path: requirePath(), languages: languages)) } catch { fail("ocr: \(error)") }
case "fm-status":
    emit(foundationModelStatus())
case "classify":
    let input = readStdinJSON()
    runAsync { await classifyWithFoundationModels(input) }
case "tags":
    // tags <path> [--remove a,b] tag...
    var tagArgs = Array(rest.dropFirst())
    var remove: [String] = []
    if tagArgs.first == "--remove", tagArgs.count >= 2 {
        remove = tagArgs[1].split(separator: ",").map(String.init)
        tagArgs.removeFirst(2)
    }
    do { emit(try setFinderTags(path: requirePath(), tags: tagArgs, remove: remove)) } catch { fail("tags: \(error)") }
case "clipboard":
    do { emit(try copyImageToClipboard(path: requirePath())) } catch { fail("clipboard: \(error)") }
case "permissions":
    emit(permissionStatus())
default:
    fail("unknown command \(command)")
}
