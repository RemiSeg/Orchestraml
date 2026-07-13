# CLI

Thin HTTP client for the coordinator. It owns request construction, response decoding, SSE parsing, and presentation; it owns no domain or persistence rules.

| Module | Purpose |
|---|---|
| `Client` | Typed HTTP/protocol boundary and SSE reconnect cursor |
| `Formatter` | Stable JSON and concise human output |
