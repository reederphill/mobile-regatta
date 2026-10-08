# Game Center identity on the server: the verified teamPlayerID is the key

The service endpoint (#145) signs a player in with Game Center's identity verification signature. The server fetches the certificate at the signature's public key URL, chains it to the certificates the operator pins in `REGATTA_APPLE_ROOT_PEM`, and checks the RSA signature over teamPlayerID | bundle id | timestamp | salt. Only the teamPlayerID is signed, so it is the player's key (`players.team_player_id`). The client's gamePlayerID, which the lobby, block lists and leaderboards use, is bound 1:1 to it on first sign-in (`players.game_player_id UNIQUE`). A sign-in opens a session whose token (32 random bytes, only its SHA-256 stored) resumes it on later connections.

We did this because Game Center gives no server-verifiable gamePlayerID: the signature covers the teamPlayerID only. Keying on what Apple signs means a forged claim can't take over an existing account. Pinning the chain ourselves (swift-certificates on NIO) means the Linux server needs no FoundationNetworking or system keychain.

## The trust chain

Game Center serves the leaf certificate only. Apple's root signs an intermediate, and the intermediate signs the leaf. The PEM file therefore holds Apple's root and that intermediate. Self-signed certificates in the file are the trust anchors. The others are only links the chain may pass through: an intermediate on its own anchors nothing (`aLeafUnderAnIntermediateVerifiesWithTheIntermediatePinned`). When Apple rotates the intermediate, the new one has to be added to the file. Until it is, sign-ins fail as `untrustedCertificate`. Which intermediate currently issues the leaf has to be confirmed against a real payload (#175) before the first non-dev deploy (#167).

The public key URL must be `https://static.gc.apple.com/public-key/…` exactly: port 443, no query, user or fragment. The request line carries the path as the URL encodes it. Fetches in flight are capped (4); a sign-in past the cap is refused rather than queued.

## Considered options

- **Fetch the intermediate per Apple's chain (AIA) at sign-in:** a second outbound fetch per new key, and more for an attacker to steer. Pinning is one line of config.
- **Pin the intermediate as an anchor:** works, but it would trust anything the intermediate signs. It would also break silently on rotation. Rejected.
- **Key players on gamePlayerID:** it's what the game shows, but the server can't verify it.

## Consequences

- **The gamePlayerID is unsigned, and the first claimant wins.** Any player with a valid Apple signature can send a victim's gamePlayerID beside their own teamPlayerID before the victim first signs in. The victim is then refused (`gamePlayerIDConflict`) and locked out of online play. The attacker appears in the lobby, in block lists and on the leaderboard endpoints under the victim's id. This is the 1:1 bind #145 asks for, not a bug, but it is a real residual risk. A mitigation is still to be tracked: check the pair against Game Center or App Store Connect data before the first bind, or key lobby identity on the teamPlayerID.
- The gamePlayerID and alias are client-sized: only the frame caps limit them (16 KiB before sign-in, 32 MiB after). Postgres's unique btree index rejects a gamePlayerID over about 2.7 KB, which surfaces as `unavailable`. Both should get a length cap at sign-in.
- The restriction flags (`isUnderage`, multiplayer and communication restrictions) are the client's word until App Attest (#158).
- A connection may send frames up to 16 KiB until it is signed in, and the service cap after. It may hold at most 4 open streams before sign-in and 16 after. Every service behind identity, sessions and terms passes one gate (signed in, the service's restriction, the current terms), deny by default.
- Replay inside the 5-minute freshness window isn't detected. `/service` needs TLS in front of it (#167).
