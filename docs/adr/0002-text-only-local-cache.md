# Conversations are cached locally as plain text only

The app keeps an on-device cache of the conversation list and every row's rendered text, so the user can browse sessions while the device is offline or the connection is down. Structured extras (diffs, full tool-call payloads, usage) are not cached.

**Why:** the cache exists to make the list fast and the history readable offline — the four stated pain points were reconnect churn, missing notifications, sluggish rendering, and cluttered UI, not offline inspection of diffs. Caching everything would multiply storage and schema work for no v1 use.

**Considered:** no cache (rejected: offline history was a stated requirement); full structured cache (rejected: storage and implementation cost with no v1 payoff).

**Consequence:** after a reconnection, cached rows are reconciled against the new snapshot; anything the cache lacks (e.g. a diff the user wants to inspect) is simply not shown in v1.
