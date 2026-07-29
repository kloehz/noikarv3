# lobby-team-character-select Specification

## Purpose

Define the server-authoritative, team-private pre-match flow from authentication through character selection and launch.

## Requirements

### Requirement: Login-to-Room UI Progression

The client UI MUST present authentication first, then create-or-join room controls after successful authentication, then the lobby or character-selection view only after the server confirms membership. The client MUST preserve keyboard/gamepad navigation. The server owns admission; the client owns presentation only.

#### Scenario: Authenticated player enters a room

- GIVEN a player has authenticated successfully
- WHEN the server confirms a create or join request
- THEN the client shows the lobby view for its confirmed membership

#### Scenario: Room admission fails

- GIVEN an authenticated player submits a create or join request
- WHEN the server rejects it
- THEN the client remains on room controls and shows the rejection

### Requirement: Two-Team Lobby Membership and Readiness

The server MUST maintain authenticated members in exactly RED and BLUE teams, enforce configured team capacity, and provide each member only its own team roster and readiness. Host status MUST derive only from a short-lived backend-attested, single-use room-creator handle whose validated account ID matches the member's authenticated JWT identity; raw account IDs MUST NOT traverse Noray provisioning. The trusted provisioner MUST bind the handle to a concrete provisioned server-instance ID and unique per-instance world credential before launch; player JWTs and normal clients MUST NOT redeem handles. Missing, invalid, expired, replayed, wrongly bound, or unauthenticated redemption MUST fail closed before provisioned ENet admission. Members MAY set only their own lobby-ready state; the server MUST clear readiness after roster churn. The client renders its latest private snapshot.

#### Scenario: Team members become ready

- GIVEN confirmed members in LOBBY
- WHEN each member marks itself ready
- THEN each team member receives its team's updated readiness

#### Scenario: Member disconnects in LOBBY

- GIVEN a lobby member disconnects
- WHEN the server recomputes membership and host
- THEN it clears lobby readiness and sends refreshed team-private snapshots

### Requirement: Host-Controlled Selection Start

The server MUST accept a selection-start request only from the current host while all current lobby members are ready. The server MUST reject non-host, wrong-phase, or incomplete-readiness requests without mutating state. The client MUST show start controls only when its snapshot marks it host.

#### Scenario: Host starts selection

- GIVEN all LOBBY members are ready and the requester is host
- WHEN the requester starts selection
- THEN the server freezes the roster and enters CHARACTER_SELECT

#### Scenario: Non-host starts selection

- GIVEN a ready lobby and a non-host member
- WHEN that member requests selection start
- THEN the server rejects the request and remains in LOBBY

### Requirement: Timed Character Selection and Launch

The server MUST run CHARACTER_SELECT for exactly 30 seconds in network ticks, accept only allowed character IDs from frozen-roster members, and record selection-ready only with a valid choice. The client MUST render a keyboard/gamepad-navigable Aatrox/Ivern selection grid from its private snapshot. The server MUST launch gameplay and spawn players only when every frozen-roster member is selection-ready.

#### Scenario: All players complete selection

- GIVEN a frozen roster in CHARACTER_SELECT
- WHEN every member submits a valid character and marks selection-ready
- THEN the server launches gameplay with those selected characters

#### Scenario: Selection deadline expires

- GIVEN CHARACTER_SELECT has not completed
- WHEN its 30-second tick deadline is reached
- THEN the server returns to LOBBY, clears readiness and selections, and spawns no player

### Requirement: Team-Private Snapshots and Server Validation

The server MUST send reliable snapshots only to their recipient and MUST NOT serialize enemy names, peer IDs, readiness, or selections. It MUST validate authentication, sender identity, phase, frozen membership, capacity, and action payload for every lobby RPC. Invalid actions and late joins after selection starts MUST NOT mutate state.

#### Scenario: Opponent data is withheld

- GIVEN RED and BLUE members share a lobby
- WHEN either receives a private snapshot
- THEN it contains only its own team's roster and selections

#### Scenario: Invalid or late action arrives

- GIVEN an unauthenticated, invalid-choice, or late-joining requester
- WHEN it sends a lobby action
- THEN the server rejects it without changing lobby or selection state

### Requirement: Selection Disconnect Recovery

The server MUST return to LOBBY, clear readiness and selections, and spawn no player when a frozen-roster member disconnects during CHARACTER_SELECT. The client MUST render the resulting confirmed lobby snapshot.

#### Scenario: Frozen member disconnects

- GIVEN CHARACTER_SELECT has started with a frozen roster
- WHEN any frozen member disconnects
- THEN the server cancels selection and returns remaining members to LOBBY
