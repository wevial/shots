import Foundation

/// One backend, built from the config.
public func createBackend(_ name: BackendName, config: Config, native: any Native) -> any Backend {
    switch name {
    case .apple: AppleBackend(native: native, timeout: config.timeout)
    case .claudeCode: ClaudeCodeBackend(config: config.claudeCode, timeout: config.timeout)
    case .codex: CodexBackend(config: config.codex, timeout: config.timeout)
    case .rules: RulesBackend(appRules: config.appRules)
    }
}

/// The configured chain, in order.
public func createBackends(config: Config, native: any Native) -> [any Backend] {
    config.backends.map { createBackend($0, config: config, native: native) }
}
