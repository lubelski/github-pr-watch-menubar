import Foundation

/// The OAuth app the device flow signs in with.
public enum OAuthConfig {
    /// Empty until the app is registered. While empty, the UI hides the device-flow path.
    ///
    /// Prefer registering a GitHub App with read-only permissions (Pull requests, Checks,
    /// Commit statuses, Contents, Metadata) over an OAuth App: an OAuth App can only read
    /// private repos with the `repo` scope, which also grants write access.
    public static let clientID = ""

    /// Scopes for an OAuth App. A GitHub App ignores them and uses its own permissions.
    public static let scopes = "repo read:org"

    public static var isDeviceFlowAvailable: Bool { !clientID.isEmpty }
}

/// What the user needs to finish signing in on github.com.
public struct DeviceCode: Sendable, Equatable {
    public var deviceCode: String
    /// Shown to the user, such as `WDJB-MJHT`.
    public var userCode: String
    public var verificationURL: URL
    public var expiresAt: Date
    /// Seconds between polls, as GitHub asks.
    public var interval: TimeInterval

    public init(deviceCode: String, userCode: String, verificationURL: URL, expiresAt: Date, interval: TimeInterval) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

public enum DeviceFlowError: Error, Equatable, Sendable {
    case notConfigured
    /// The code expired before the user finished.
    case expired
    /// The user clicked Cancel on github.com.
    case accessDenied
    /// Any other error GitHub named, such as `device_flow_disabled`.
    case server(String)
    case badResponse
}

/// GitHub's OAuth device flow: request a code, show it, poll until the user approves.
/// https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
public struct DeviceFlow: Sendable {
    public var clientID: String
    public var scopes: String
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    static let codeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    public init(
        clientID: String = OAuthConfig.clientID,
        scopes: String = OAuthConfig.scopes,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.clientID = clientID
        self.scopes = scopes
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    /// Step 1: ask GitHub for a user code.
    public func requestCode() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw DeviceFlowError.notConfigured }
        let json = try await post(Self.codeURL, ["client_id": clientID, "scope": scopes])
        if let error = json["error"] as? String { throw DeviceFlowError.server(error) }
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:))
        else { throw DeviceFlowError.badResponse }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 900
        let interval = (json["interval"] as? NSNumber)?.doubleValue ?? 5
        return DeviceCode(
            deviceCode: deviceCode, userCode: userCode, verificationURL: uri,
            expiresAt: now().addingTimeInterval(expiresIn), interval: interval
        )
    }

    /// Step 2: poll until the user approves, denies, or the code expires. Cancel the task to stop.
    public func pollForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 1)
        while true {
            try await sleep(interval)
            try Task.checkCancellation()
            if now() >= code.expiresAt { throw DeviceFlowError.expired }
            let json = try await post(Self.tokenURL, [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = json["access_token"] as? String, !token.isEmpty { return token }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                // GitHub sends the new minimum interval; otherwise add 5 seconds as the spec says.
                interval = (json["interval"] as? NSNumber)?.doubleValue ?? (interval + 5)
            case "expired_token":
                throw DeviceFlowError.expired
            case "access_denied":
                throw DeviceFlowError.accessDenied
            case let other?:
                throw DeviceFlowError.server(other)
            case nil:
                throw DeviceFlowError.badResponse
            }
        }
    }

    private func post(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTPHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await transport.send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceFlowError.badResponse
        }
        return json
    }
}
