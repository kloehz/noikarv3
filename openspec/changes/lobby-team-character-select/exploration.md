# Exploration: lobby-team-character-select

### Current State

- Authentication already gates ENet admission: `MatchManager` validates the JWT, then immediately spawns a player and acknowledges the client. The first UI currently contains login/register **and** a character `OptionButton`.
- The client flow is `LOGIN → LOBBY (create/join) → CONNECTING → IN_GAME`; it enters `IN_GAME` immediately after authentication. No server-owned lobby roster, ready state, or room host exists.
- `MatchDirector` is the server-only phase owner and `MatchState` is globally replicated through Netfox `StateSynchronizer`. Team assignment is server-side, deterministic, and mutable only in `LOBBY`. The present transition is `LOBBY → COUNTDOWN → PVE_RACE`.
- `ServerState.character_id` is globally replicated with each spawned player. Therefore spawning players or using global state during selection would disclose enemy character choices. Netfox visibility filters exist, but are not configured for this flow.

### Affected Areas

- `client/connection_manager.gd` — make the login panel authentication-only; retain create/join as the second screen; render server snapshots for lobby and character selection instead of entering gameplay on auth.
- `scenes/connection_menu.tscn` — remove the login character control; compose lobby/team/ready/select panels with focus paths and a two-card Aatrox/Ivern grid.
- `common/match_manager.gd` — own authenticated lobby membership, server RPC validation, host election, private snapshot delivery, and defer `_spawn_player()` until selection completes.
- `common/match_director.gd`, `common/match_state.gd` — add a server-driven `CHARACTER_SELECT` phase and its tick deadline; keep roster/selection data out of globally synchronized `MatchState`.
- `common/resources/match_rules.gd`, `common/resources/default_match_rules.tres` — add the 30-second selection duration and convert it to NetworkTime ticks.
- `common/event_bus.gd` — add presentation events for server snapshots and effective lobby/selection state changes.
- `common/BaseEntity.gd`, `scenes/BaseEntity.tscn`, `common/components/ServerState.gd` — keep the existing server-validated actor application only at post-selection player spawn; do not expose pre-launch player entities.
- `tests/unit/` and `tests/integration/` — cover authority, phase/timer behavior, private payload shaping, roster churn, and deferred spawning.

### Approaches

1. **Server-owned roster plus team-scoped reliable snapshots** — keep mutable lobby/selection records only on `MatchManager`; send a sanitized snapshot with `rpc_id()` to every authenticated peer, containing only that peer's team members.
   - Pros: smallest change; prevents enemy roster/selection bytes from being replicated; fits existing server RPC and `MatchDirector` patterns; no Netfox visibility lifecycle to manage.
   - Cons: requires explicit late-join/reconnect snapshot delivery and UI cache handling.
   - Effort: Medium.

2. **One replicated lobby-state node per team with `PeerVisibilityFilter`** — use two `StateSynchronizer` nodes and set visibility to each team.
   - Pros: automatic full-state catch-up and declarative Netfox delivery.
   - Cons: more scene and synchronizer complexity; membership changes require visibility refreshes; global lifecycle data and team-private data still need a careful split.
   - Effort: Medium-High.

### Recommendation

Use **Approach 1**. Add a server-only lobby record keyed by authenticated peer ID: account display name, immutable server-assigned team, lobby-ready flag, selected character, selection-ready flag, and host peer ID. It is never a `MatchState` property and never a player `ServerState` property before launch.

The server accepts only authenticated senders and validates every mutation against its phase and sender record:

| Action | Server validation and result |
| --- | --- |
| Join lobby | JWT-authenticated; capacity at most `max_players_per_team * 2`; server assigns/recomputes teams only in `LOBBY`. |
| Lobby ready | Sender exists, phase is `LOBBY`; toggle its own ready state only. |
| Start | Sender is the server-recorded host, phase is `LOBBY`, roster is non-empty, both teams exist, and every member is lobby-ready. Server freezes the roster/teams, clears selections, and enters `CHARACTER_SELECT`. |
| Select Aatrox/Ivern | Sender exists, phase is `CHARACTER_SELECT`, ID is one of `warrior`/`ivern_ranger`; changing a choice clears only that sender's selection-ready state. |
| Selection ready | Sender has a valid selection and phase is `CHARACTER_SELECT`; launch only when every frozen member on both teams is selection-ready. |

`CHARACTER_SELECT` MUST use a tick-counted 30-second deadline (`MatchRules.seconds_to_ticks`), not a scene timer. On the all-ready condition the server writes the chosen IDs into `peer_data`, spawns all players, and proceeds to the existing match countdown/setup. On deadline expiry, it returns to `LOBBY` and clears lobby-ready/selection state; it MUST NOT spawn players or open the map.

For visibility, send each peer a reliable snapshot containing phase/deadline, its own team, whether it is host, and **only its team's** member names, ready flags, and selections. The server separately sends the same shape to the other team. Global `MatchState` may replicate the phase and deadline, but MUST NOT contain peer IDs, roster arrays, names, selections, or per-team readiness. The UI must render exclusively from its latest private snapshot, so enemy details are neither displayed nor delivered.

The current dedicated-server flow has no trusted “room creator” identity available to the game server. The smallest authoritative definition is: **the first successfully authenticated member becomes host, stored by the server and never client-assignable**. If product semantics require the Noray room creator specifically, Noray/provisioning must pass a signed creator account ID to the dedicated server before this change can claim that guarantee.

Disconnect rules: during `LOBBY`, remove the member, clear remaining lobby-ready flags, deterministically recompute teams, and re-elect host to the lowest authenticated peer if needed. During `CHARACTER_SELECT`, any selected-roster disconnect aborts to `LOBBY`, clears ready/selection state, and recomputes teams; this prevents silently launching a changed roster. An empty room retains the existing server shutdown behavior. Late joins are admitted only in `LOBBY`; joins after start are rejected/disconnected rather than observing a private selection phase.

### Risks

- The current phase spec declares exactly nine phases and the manager currently spawns initial mobs at server startup. Proposal/spec work must explicitly revise that lifecycle and gate all gameplay spawning until selection completion.
- “Host = room creator” cannot be proven from current game-server inputs. First-authenticated host is authoritative but may differ from the creator during a race; signed provisioning metadata is the stronger, larger alternative.
- The current global `ServerState.character_id` and player spawning path leak selections once entities exist. Deferred spawning and private RPC payload tests are mandatory privacy boundaries, not UI-only behavior.
- This feature will exceed the 400 changed-line review budget. Forecast at least two slices: server state/phase/privacy tests first, then composed UI and end-to-end wiring.

### Ready for Proposal

Yes — propose the server-only lobby record, `CHARACTER_SELECT` phase, team-scoped reliable snapshots, deferred player spawn, and the explicit first-authenticated-host rule (or raise signed creator metadata as a product requirement).
