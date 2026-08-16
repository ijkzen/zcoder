# Terminal authentication uses the QR URL's sid+hash, not a Z.AI OAuth login

The web remote page shows a Z.AI account login, but the relay's wire protocol authenticates terminals purely with the QR credential: `auth_init(role: "terminal")` → `auth_challenge(nonce)` → `auth_response` proving possession of the `hash` param via `HMAC-SHA256(passHash, "$nonce|$role|$sid")` (both roles use this order — see `calculateProof` in the desktop's `out/main/index.js`, and docs/protocol/01-relay-transport.md; an earlier revision of this ADR misstated the order as `sid|nonce|role`). The Flutter app implements this handshake directly and has no login screen.

**Why not OAuth:** the relay never demands an account for the terminal flow we reverse-engineered, and registering a public OAuth client for a third-party app is not something we can do. Adding OAuth later would only mean an extra step before the same handshake.

**Considered:** full OAuth replication (rejected: needs a registered client, adds a browser round-trip, and the protocol doesn't require it); making the user paste the raw hash (rejected: scanning already gives us the hash inside the URL).

**Consequence:** if the relay starts enforcing account login, v1 breaks for new pairings — the recovery path is to add an embedded-browser OAuth step, keeping the sid+hash handshake underneath.
