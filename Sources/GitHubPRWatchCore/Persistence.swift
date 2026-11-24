import Foundation
import os

/// Loads and saves one value. Views, settings and the last snapshot each have one.
/// Tests and windowless renders use `InMemoryDocumentStore`.
public protocol DocumentStore<Document>: Sendable {
    associatedtype Document: Codable & Sendable
    /// `nil` when nothing was saved yet.
    func load() throws -> Document?
    func save(_ document: Document) throws
}

/// A JSON file, written atomically.
public struct JSONFileStore<Document: Codable & Sendable>: DocumentStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/GitHub PR Watch/<name>`.
    public init(applicationSupportFile name: String) {
        self.init(url: Self.applicationSupportDirectory.appendingPathComponent(name))
    }

    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitHub PR Watch", isDirectory: true)
    }

    public func load() throws -> Document? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONCoding.decoder.decode(Document.self, from: Data(contentsOf: url))
    }

    public func save(_ document: Document) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(document).write(to: url, options: .atomic)
    }
}

/// Keeps the value in memory.
public final class InMemoryDocumentStore<Document: Codable & Sendable>: DocumentStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Document?
    /// How many times `save` ran. For tests.
    public private(set) var saveCount = 0

    public init(_ value: Document? = nil) {
        self.value = value
    }

    public func load() throws -> Document? {
        lock.withLock { value }
    }

    public func save(_ document: Document) throws {
        lock.withLock {
            value = document
            saveCount += 1
        }
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Settings that aren't views. Saved as `config.json`.
public struct AppConfig: Codable, Sendable, Equatable {
    public var authMethod: AuthMethod?
    /// The last signed-in user, so the UI can show who it is before the first poll.
    public var viewer: Viewer?
    public var watchedRepos: [String]
    public var onboardingComplete: Bool
    public var selectedViewID: UUID?
    /// Seconds between polls when the rate limit allows.
    public var pollInterval: TimeInterval
    public var guardCheckPatterns: [String]

    public init(
        authMethod: AuthMethod? = nil, viewer: Viewer? = nil, watchedRepos: [String] = [], onboardingComplete: Bool = false,
        selectedViewID: UUID? = nil, pollInterval: TimeInterval = PollPolicy.defaultInterval,
        guardCheckPatterns: [String] = ClassificationContext.defaultGuardCheckPatterns
    ) {
        self.authMethod = authMethod
        self.viewer = viewer
        self.watchedRepos = watchedRepos
        self.onboardingComplete = onboardingComplete
        self.selectedViewID = selectedViewID
        self.pollInterval = pollInterval
        self.guardCheckPatterns = guardCheckPatterns
    }
}
