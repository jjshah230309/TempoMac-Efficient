import Foundation
import AppKit
import AuthenticationServices
import CryptoKit

/// Direct Spotify connection via OAuth (Authorization Code + PKCE) — no Last.fm,
/// no client secret. Opens a secure sign-in sheet, stores the refresh token, and
/// transparently refreshes the access token. Only scope: read recently-played.
@MainActor
final class SpotifyAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SpotifyAuth()

    @Published var status: String?
    @Published var connected: Bool

    private enum K {
        static let client = "spotify.clientid"
        static let access = "spotify.access"
        static let refresh = "spotify.refresh"
        static let expires = "spotify.expires"
    }
    static let redirectURI = "tempo://callback"
    private let scopes = "user-read-recently-played"
    private var session: ASWebAuthenticationSession?

    private override init() {
        connected = UserDefaults.standard.string(forKey: K.refresh) != nil
        super.init()
    }

    var clientID: String { UserDefaults.standard.string(forKey: K.client) ?? "" }
    func setClientID(_ s: String) {
        UserDefaults.standard.set(s.trimmingCharacters(in: .whitespaces), forKey: K.client)
    }

    // MARK: - Connect

    func connect() async {
        let cid = clientID
        guard !cid.isEmpty else { status = "Enter your Spotify Client ID first."; return }

        let verifier = Self.randomVerifier()
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: cid),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.codeChallenge(verifier)),
            .init(name: "scope", value: scopes),
        ]
        guard let url = comps.url else { return }

        status = "Opening Spotify…"
        do {
            let callback = try await authenticate(url: url)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                status = "No authorization code returned."; return
            }
            try await exchange(code: code, verifier: verifier, clientID: cid)
            connected = true
            status = "Connected"
        } catch {
            status = "Sign-in cancelled."
        }
    }

    func disconnect() {
        [K.access, K.refresh, K.expires].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        connected = false; status = nil
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "tempo") { cb, err in
                if let cb { cont.resume(returning: cb) }
                else { cont.resume(throwing: err ?? URLError(.userCancelledAuthentication)) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            s.start()
        }
    }

    // MARK: - Tokens

    private func exchange(code: String, verifier: String, clientID: String) async throws {
        let body = ["grant_type": "authorization_code", "code": code,
                    "redirect_uri": Self.redirectURI, "client_id": clientID, "code_verifier": verifier]
        let data = try await tokenRequest(body)
        try storeToken(data)
    }

    /// Returns a usable access token, refreshing if expired. nil if not connected.
    func validToken() async -> String? {
        let d = UserDefaults.standard
        if let access = d.string(forKey: K.access),
           d.double(forKey: K.expires) > Date().timeIntervalSince1970 + 60 {
            return access
        }
        guard let refresh = d.string(forKey: K.refresh), !clientID.isEmpty else { return nil }
        let body = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]
        guard let data = try? await tokenRequest(body), (try? storeToken(data)) != nil else { return nil }
        return d.string(forKey: K.access)
    }

    private func tokenRequest(_ body: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    @discardableResult
    private func storeToken(_ data: Data) throws -> Bool {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else { throw URLError(.badServerResponse) }
        let d = UserDefaults.standard
        d.set(access, forKey: K.access)
        if let r = j["refresh_token"] as? String { d.set(r, forKey: K.refresh) }
        d.set(Date().timeIntervalSince1970 + ((j["expires_in"] as? Double) ?? 3600), forKey: K.expires)
        return true
    }

    // MARK: - PKCE helpers

    private static func randomVerifier() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<96).map { _ in chars.randomElement()! })
    }
    private static func codeChallenge(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApplication.shared.windows.first ?? ASPresentationAnchor() }
    }
}
