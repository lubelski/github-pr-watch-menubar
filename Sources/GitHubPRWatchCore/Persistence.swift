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
    /// Rewrites what an older build saved before it is decoded. The file on disk changes only
    /// at the next save.
    public let migrate: (@Sendable (Data) -> Data)?

    public init(url: URL, migrate: (@Sendable (Data) -> Data)? = nil) {
        self.url = url
        self.migrate = migrate
    }

    /// `~/Library/Application Support/GitHub PR Watch/<name>`.
    public init(applicationSupportFile name: String, migrate: (@Sendable (Data) -> Data)? = nil) {
        self.init(url: Self.applicationSupportDirectory.appendingPathComponent(name), migrate: migrate)
    }

    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitHub PR Watch", isDirectory: true)
    }

    public func load() throws -> Document? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(Document.self, from: migrate?(data) ?? data)
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
    /// The global notification settings. `nil` (an older file) means the defaults.
    public var notifications: NotificationSettings?

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
