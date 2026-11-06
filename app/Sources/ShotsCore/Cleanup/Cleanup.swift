import Foundation

// Clean Up: screenshots taken to show something to fix right now (often to a coding agent)
// and worthless after. The classifier judges `scratch` in the same call that files the shot;
// these hints, from the capture context alone, steer it.

/// What the capture context says about a shot being scratch, as prompt lines. Empty when
/// nothing stands out.
public func scratchHints(_ ctx: AppContext?, scratchApps: [String]) -> [String] {
    var hints: [String] = []
    let apps = Set(scratchApps.map { $0.lowercased() })
    if let app = [ctx?.bundleId, ctx?.appName].compactMap({ $0?.lowercased() }).first(where: apps.contains) {
        let name = ctx?.appName.flatMap { $0.isEmpty ? nil : $0 } ?? app
        hints.append("captured in \(name), a coding or development tool")
    }
    if let url = ctx?.url, let host = URL(string: url)?.host(percentEncoded: false)?.lowercased(), isDevHost(host, url: url) {
        hints.append("the browser tab is a local, development or preview build (\(host))")
    }
    return hints
}

/// localhost and friends, private addresses, explicit ports, `dev`/`staging`/`preview` hosts
/// and hosting providers' preview domains.
func isDevHost(_ host: String, url: String) -> Bool {
    if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) { return true }
    if [".localhost", ".local", ".test", ".internal", ".vercel.app", ".netlify.app", ".pages.dev"].contains(where: host.hasSuffix) {
        return true
    }
    if host.wholeMatch(of: /(10|192\.168|172\.(1[6-9]|2\d|3[01]))(\.\d+){2,3}/) != nil { return true }
    if URL(string: url)?.port != nil { return true }
    let words = host.split(whereSeparator: { $0 == "." || $0 == "-" })
    return words.contains { ["dev", "staging", "stage", "stg", "preview", "qa", "sandbox"].contains($0) }
}

/// Judges scratch for a shot filed before the classifier did, by running the chain on its
/// stored text and context. Only the verdict is stored; the file stays where it is.
public func judgeScratch(_ shot: ShotRow, deps: Deps) async throws -> Bool {
    guard FileManager.default.fileExists(atPath: shot.path) else { throw ShotsError("file is gone: \(shot.path)") }
    let context = shotContext(shot)
    let decision = try await runChain(
        classifyInput(for: shot, context: context, config: deps.config),
        backends: deps.backends, config: deps.config, privacy: privacyVerdict(deps.config, context: context), rules: deps.rules
    )
    try await deps.database.setScratch(shot.id, decision.final.scratch)
    return decision.final.scratch
}

/// The classifier's input for an indexed shot, from what the index stored about it.
func classifyInput(for shot: ShotRow, context: AppContext?, config: Config) -> ClassifyInput {
    let dimensions: ClassifyInput.Dimensions? =
        if let width = shot.width, let height = shot.height, width != 0, height != 0 {
            .init(width: width, height: height)
        } else {
            nil
        }
    return ClassifyInput(
        imagePath: shot.path, ocrText: shot.ocrText, appContext: context, captureType: shot.captureType,
        dimensions: dimensions, categories: config.categories, categoryHints: config.categoryHints,
        scratchHints: scratchHints(context, scratchApps: config.scratchApps)
    )
}
