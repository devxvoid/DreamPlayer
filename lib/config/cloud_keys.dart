library;

/// Google Drive OAuth credentials (build-time only).
///
/// Supplied via `--dart-define` from `.env` (see `.env.example`).
/// Hidden in Settings until client id is configured. Never commit real
/// credentials. Create at console.cloud.google.com → Enable Drive API →
/// Credentials → Create OAuth 2.0 Client ID (Web).

const String gdriveClientId = String.fromEnvironment('GDRIVE_CLIENT_ID');
const String gdriveClientSecret = String.fromEnvironment('GDRIVE_CLIENT_SECRET');
