/// Trakt.tv API client credentials (OAuth device flow).
///
/// Supplied at build time via `--dart-define=TRAKT_CLIENT_ID=...` and
/// `--dart-define=TRAKT_CLIENT_SECRET=...` (see `.env.example`). Empty by
/// default — the Trakt section in Settings is hidden until a client id is
/// configured. Never commit real credentials.
const String traktClientId = String.fromEnvironment('TRAKT_CLIENT_ID');
const String traktClientSecret = String.fromEnvironment('TRAKT_CLIENT_SECRET');
