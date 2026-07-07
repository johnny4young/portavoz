# Security Policy

Portavoz is a privacy-first application; security reports are treated as top priority.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Email `security@portavoz.app` with details and reproduction steps. You will get an acknowledgment within 72 hours.

## Design commitments

- Audio, transcripts, and summaries stay on-device by default.
- API keys live in the Keychain, never in the database or preferences.
- Voice embeddings (biometric-grade data) never leave the device and are deletable in one action.
- Model downloads are verified against pinned SHA-256 checksums.
- Any local server surface (e.g. the MCP server) binds to localhost only and requires a session token.
