# Security Policy

Portavoz is a privacy-first application; security reports are treated as top priority.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Email `security@portavoz.app` with details and reproduction steps. You will get an acknowledgment within 72 hours.

## Design commitments

- Audio, transcripts, and summaries stay on-device by default.
- API keys live in the Keychain, never in the database or preferences.
- Voice embeddings (biometric-grade data) never leave the device and are deletable in one action.
- Meeting-content HTTP operations require explicit configuration or invocation, cross one policy-checked gateway, persist an immutable content-free attempt before transport, and never follow redirects. If the receipt cannot be stored, the transfer does not start.
- Meeting Detail shows whether tracked work stayed local or a remote transfer was attempted. For databases upgraded to receipt schema v7, it discloses the date tracking began instead of making claims about earlier activity.
- Model downloads are verified against pinned SHA-256 checksums.
- The MCP interface is local JSON-RPC over process stdio; it opens no network listener. A future network transport would require localhost binding and authentication before shipping.
