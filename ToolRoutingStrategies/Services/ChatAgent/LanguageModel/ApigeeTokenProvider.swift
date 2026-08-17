import Foundation

// MARK: - The short-lived half of the credential
//
// FICTIONAL. Modelled on the OAuth 2.0 client-credentials grant, which is
// what an Apigee proxy in front of an LLM usually speaks:
//
//     POST /oauth/token
//     Authorization: Basic base64(clientID:clientSecret)
//     grant_type=client_credentials
//
//     → { "access_token": "…", "expires_in": 3599, "token_type": "Bearer" }
//
// Replace `fetchToken` with your company's actual grant. Everything above
// it — caching, coalescing, refresh, invalidation — is the part worth
// keeping whatever the grant turns out to be.
//
// Three properties this has to hold, none of which are optional in an
// eval run that fires 60 requests through the same credential:
//
//   CACHED       One token serves every request until it nears expiry.
//                Fetching per call would triple the traffic and rate-limit
//                the whole run.
//   COALESCED    Concurrent callers that arrive on a cold cache wait on
//                ONE in-flight fetch. Without this the first parallel
//                batch stampedes the token endpoint.
//   INVALIDATED  A 401 drops the cached token so the retry fetches a fresh
//                one — a token can be revoked before it expires, and the
//                clock skew that makes a token look valid here and expired
//                at the gateway is real.

nonisolated struct ApigeeCredentials: Hashable, Sendable {
    /// Token endpoint, e.g. `https://api.mycompany.com/oauth/token`.
    var tokenURL: URL
    var clientID: String
    var clientSecret: String
    /// FILL IN — optional in most deployments, required in some.
    var scope: String?
    /// Refresh this long before the token actually expires. Covers clock
    /// skew between this device and the gateway, plus the flight time of a
    /// request that starts just under the wire.
    var refreshLeeway: TimeInterval = 60

    init(
        tokenURL: URL,
        clientID: String,
        clientSecret: String,
        scope: String? = nil,
        refreshLeeway: TimeInterval = 60
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scope = scope
        self.refreshLeeway = refreshLeeway
    }
}

actor ApigeeTokenProvider {
    private struct CachedToken {
        let value: String
        let expiresAt: Date

        func isValid(now: Date, leeway: TimeInterval) -> Bool {
            now.addingTimeInterval(leeway) < expiresAt
        }
    }

    private let credentials: ApigeeCredentials
    private let transport: any HTTPTransport
    private var cached: CachedToken?
    /// The single in-flight fetch that concurrent callers await.
    private var refresh: Task<CachedToken, any Error>?

    init(credentials: ApigeeCredentials, transport: any HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.transport = transport
    }

    // MARK: Shared instances

    /// One provider per distinct credential, so every executor built from
    /// the same configuration shares a token instead of each fetching its
    /// own.
    ///
    /// - Parameter transport: Used only if this credential has no provider
    ///   yet. Tests seed a stub here before the executor asks for the same
    ///   credential; production callers omit it.
    static func shared(
        for credentials: ApigeeCredentials,
        transport: (any HTTPTransport)? = nil
    ) async -> ApigeeTokenProvider {
        await Registry.shared.provider(for: credentials, transport: transport)
    }

    private actor Registry {
        static let shared = Registry()
        private var providers: [ApigeeCredentials: ApigeeTokenProvider] = [:]

        func provider(
            for credentials: ApigeeCredentials,
            transport: (any HTTPTransport)?
        ) -> ApigeeTokenProvider {
            if let existing = providers[credentials] { return existing }
            let provider = ApigeeTokenProvider(
                credentials: credentials,
                transport: transport ?? URLSessionTransport()
            )
            providers[credentials] = provider
            return provider
        }
    }

    // MARK: Vending

    /// A token valid for at least `refreshLeeway` seconds.
    func token() async throws -> String {
        if let cached, cached.isValid(now: .now, leeway: credentials.refreshLeeway) {
            return cached.value
        }
        // Await the fetch already running rather than starting a second one.
        if let refresh { return try await refresh.value.value }

        let task = Task { [credentials, transport] in
            try await Self.fetchToken(credentials: credentials, transport: transport)
        }
        refresh = task
        defer { refresh = nil }

        let fetched = try await task.value
        cached = fetched
        return fetched.value
    }

    /// Drops the cached token if it is the one that just failed.
    ///
    /// The identity check matters: under concurrency another caller may
    /// already have replaced the token between the failing request and
    /// this call, and throwing away a working token would send every
    /// in-flight request back to the token endpoint.
    func invalidate(usedToken: String?) {
        guard let usedToken, cached?.value == usedToken else { return }
        cached = nil
    }

    // MARK: The grant itself — FILL IN

    private static func fetchToken(
        credentials: ApigeeCredentials,
        transport: any HTTPTransport
    ) async throws -> CachedToken {
        var request = URLRequest(url: credentials.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Client credentials as HTTP Basic. Some gateways want them in the
        // body instead (`client_id=…&client_secret=…`) — if yours does, move
        // them down into `form` and drop this header.
        let pair = "\(credentials.clientID):\(credentials.clientSecret)"
        let basic = Data(pair.utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        var form = ["grant_type": "client_credentials"]
        if let scope = credentials.scope, !scope.isEmpty {
            form["scope"] = scope
        }
        request.httpBody = Data(formEncoded(form).utf8)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw CustomModelError.tokenRequestFailed(
                status: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? "<unreadable body>"
            )
        }

        let payload: TokenResponse
        do {
            payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw CustomModelError.malformedTokenResponse(error.localizedDescription)
        }
        guard !payload.accessToken.isEmpty else {
            throw CustomModelError.malformedTokenResponse("access_token was empty")
        }

        // A gateway that omits `expires_in` gets a conservative five
        // minutes rather than an assumed hour — re-fetching early is
        // cheap, and holding a dead token is a 401 on a real request.
        let lifetime = TimeInterval(payload.expiresIn ?? 300)
        return CachedToken(value: payload.accessToken, expiresAt: Date.now.addingTimeInterval(lifetime))
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Transport

/// The one place the network is touched, so tests can drive the executor
/// and the token provider without one.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(timeout: TimeInterval = 120) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
