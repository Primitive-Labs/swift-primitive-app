/// PrimitiveApp — Swift client library for building apps on the Primitive platform.
///
/// Re-exports JsBaoClient and provides SwiftUI-ready state management,
/// credential loading, and shared UI components.

@_exported import JsBaoClient
// `YDocument` is a YSwift type that surfaces through PrimitiveAppState's
// `onDocumentOpened(doc:documentId:)` hook (and through JsBaoClient's
// `openDocument` return value). Re-exporting `YSwift` here means
// downstream apps can spell `YDocument` after `import PrimitiveApp`
// alone — they don't have to add `YSwift` to their Package.swift just
// to override the document-opened hook.
@_exported import YSwift

// Public API is provided by:
//   - PrimitiveAppState (State/PrimitiveAppState.swift)
//   - PrimitiveCredentials (Config/PrimitiveCredentials.swift)
//   - Shared views (Views/)
