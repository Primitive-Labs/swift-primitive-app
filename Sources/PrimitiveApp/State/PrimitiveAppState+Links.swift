import Foundation
import JsBaoClient

// MARK: - Platform link routing

/// What `PrimitiveAppState.routePlatformLink(_:)` did with a URL.
public enum PlatformLinkOutcome: Sendable {
    /// A document share link — the document was selected/opened.
    case openedDocument(id: String)
    /// An invitation accept link — the invitation was accepted and the
    /// document list refreshed. Carries the resolved grant counts.
    case acceptedInvitation(documents: Int, groups: Int)
    /// A magic-link sign-in URL — the token was verified and the session
    /// applied (`.authSuccess` fired).
    case signedInViaMagicLink
    /// Not one of Primitive's link shapes — hand it to your app's own
    /// routing (this is where `myapp://settings`-style routes live).
    case notAPlatformLink(URL)
}

public enum PlatformLinkError: Error, LocalizedError {
    /// `routePlatformLink` was called before the client existed (very
    /// early in launch). Re-dispatch after `initialize()` completes.
    case clientNotReady
    public var errorDescription: String? {
        "The Primitive client isn't ready yet — link arrived too early in launch."
    }
}

extension PrimitiveAppState {
    /// Default routing for Primitive's own link shapes, for use from
    /// `.onOpenURL` and notification tap handlers:
    ///
    ///  - document share links (`…/document/<id>`, including alias links,
    ///    resolved via the server) → `selectDocument`
    ///  - invitation accept links (`…?inviteToken=…`) →
    ///    `invitations.accept` + document refresh
    ///  - magic-link sign-in URLs (`…?magic_token=…`) → verified, session
    ///    applied
    ///
    /// Anything else returns `.notAPlatformLink` — check for it and run
    /// your app's own routes. The demo app shows the full pattern
    /// (typed `AppRoute` + URL/notification adapters); the template ships
    /// the minimal wiring.
    public func routePlatformLink(_ url: URL) async throws -> PlatformLinkOutcome {
        guard let client = await waitForPlatformLinkClient() else {
            throw PlatformLinkError.clientNotReady
        }
        let target = try await client.links.resolve(url: url)
        switch target {
        case .document(let id):
            selectDocument(id)
            return .openedDocument(id: id)
        case .invitation(let token):
            let result = try await client.invitations.accept(inviteToken: token)
            await fetchDocuments()
            return .acceptedInvitation(
                documents: result.grantsResolved.documents,
                groups: result.grantsResolved.groups
            )
        case .magicLink(let token, _):
            _ = try await client.magicLinkVerify(token: token)
            return .signedInViaMagicLink
        case .unknown:
            // Not a Primitive link shape we route (alias-based share links
            // were removed with app-scoped aliases in #1168).
            return .notAPlatformLink(url)
        }
    }

    private func waitForPlatformLinkClient(
        timeout: TimeInterval = 5,
        pollIntervalNs: UInt64 = 50_000_000
    ) async -> JsBaoClient? {
        if let client { return client }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            if let client { return client }
        }
        return client
    }
}
