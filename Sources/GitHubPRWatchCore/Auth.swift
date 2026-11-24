import Foundation
import os

/// How the user signed in.
public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    /// Borrow the GitHub CLI's login. The token is read from `gh auth token` each time it's
    /// needed and never stored by this app, so `gh auth refresh` and `gh auth switch` keep working.
    case githubCLI
    /// OAuth device flow. The token goes in the Keychain.
    case deviceFlow
    /// A pasted personal access token. The token goes in the Keychain.
    case pastedToken
}

public enum AuthError: Error, Equatable, Sendable {
    /// `gh` isn't installed where we look.
    case cliNotFound
    /// `gh` ran but has no login for github.com.
    case cliNotSignedIn
    /// No token saved for a Keychain-backed method.
    case noSavedToken
}

/// Supplies a token for each request batch.
public protocol TokenProvider: Sendable {
    func token() async throws -> String
}

/// A fixed token. For pasted tokens being checked, tests, and renders.
public struct StaticTokenProvider: TokenProvider {
    private let value: String
    public init(_ value: String) { self.value = value }
    public func token() async throws -> String { value }
}

/// Reads a token saved in a `SecretStore`.
public struct StoredTokenProvider: TokenProvider {
    private let store: any SecretStore
    private let key: String

    public init(store: any SecretStore, key: String = SecretKeys.githubToken) {
        self.store = store
        self.key = key
    }

    public func token() async throws -> String {
        guard let token = store.read(key), !token.isEmpty else { throw AuthError.noSavedToken }
        return token
    }
}

// MARK: - GitHub CLI

/// Runs an executable and returns its standard output. Tests substitute a fake.
public protocol CommandRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Data
}

public struct CommandFailed: Error, Sendable {}

/// Runs a real `Process`, with standard error discarded and no standard input.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // gh reads GH_TOKEN and friends; a GUI app inherits little, which is what we want.
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Data, any Error>?>(initialState: continuation)
            let finish: @Sendable (Result<Data, any Error>) -> Void = { result in
                pending.withLock { pending in
                    defer { pending = nil }
                    return pending
                }?.resume(with: result)
            }
            DispatchQueue.global().async {
                // Drain before waiting so a large payload can't fill the pipe and deadlock.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let ok = process.terminationReason == .exit && process.terminationStatus == 0
                finish(ok ? .success(data) : .failure(CommandFailed()))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                finish(.failure(CommandFailed()))
            }
        }
    }
}

/// The GitHub CLI's login.
public struct GitHubCLI: TokenProvider {
    /// Where `gh` usually lives when a GUI app's PATH doesn't include it.
    public static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]

    private let runner: any CommandRunner
    private let locate: @Sendable () -> URL?

    public init(
        runner: any CommandRunner = ProcessRunner(),
        locate: @escaping @Sendable () -> URL? = { GitHubCLI.locate() }
    ) {
        self.runner = runner
        self.locate = locate
    }

    /// The first executable `gh` on `PATH`, then in the fallback directories.
    public static func locate(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let fromPath = (path ?? "").split(separator: ":").map(String.init)
        let fallbacks = fallbackDirectories.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
        var seen = Set<String>()
        for directory in fromPath + fallbacks where !directory.isEmpty && seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent("gh")
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    public var isInstalled: Bool { locate() != nil }

    /// Runs `gh auth token --hostname github.com`. Never cached.
    public func token() async throws -> String {
        guard let gh = locate() else { throw AuthError.cliNotFound }
        let data: Data
        do {
            data = try await runner.run(gh, ["auth", "token", "--hostname", "github.com"], timeout: 10)
        } catch {
            throw AuthError.cliNotSignedIn
        }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AuthError.cliNotSignedIn }
        return token
    }
}
