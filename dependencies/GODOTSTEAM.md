# Optional Steam dependency — gameplay acceptance remains unverified

Noikar's Steam UI and session adapter are implemented, but **Steam gameplay
is not certified**. The pinned peer promotes ordered-unreliable messages to reliable
delivery. Netfox uses that mode for state and rollback updates; property setters and
successful SDK initialization do not prove equivalent network behavior.

## Reproduce the dependency

- GodotSteam **4.23.1 GDExtension**, Steamworks **1.65**; Godot minimum **4.4**.
- [Official release](https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.23.1).
- Archive: `godotsteam-4.23.1-gdextension-plugin-4.4.zip.tar.xz`.
- SHA-256: `37d53ede5eda11d2247d70c1af91f95a4777ad2a419fc8a24de1cc816d21cc0a`.
- Install with `python3 tools/install_steam.py`, then reopen Godot to register it.
  Installation verifies the archive and refuses to overwrite modified dependency files.
  Binaries are ignored, not committed; upstream licenses remain in the installed addon.
- Use the integrated `SteamMultiplayerPeer`, not the archived standalone peer addon.
  Respect upstream licenses and Steamworks redistribution terms when packaging.

The adapter uses `NOIKAR_STEAM_APP_ID`; debug builds default to development AppID
480. Release builds require an explicit non-480 AppID. Steam must already be running;
the adapter does not start/install it. Without the addon/client, LAN remains available.

## What has actually been verified

| Gate | Result |
| --- | --- |
| macOS arm64 ABI on exact Godot `4.8.beta1.official.4d10419ca` | PASS |
| Actual Steam SDK initialization and P2P host socket | PASS; see `docs/evidence/steam-platform.json` |
| Real Noikar menu/picker, explicit send-only UI, SDK-boundary lifecycle fixtures | PASS; no real friend invitations sent |
| Ordered-unreliable send semantics | FAIL in executable characterization of exact upstream source |
| Actual Netfox traffic over Steam between accounts | NOT RUN |
| Two-machine invitation/acceptance/full gameplay | NOT RUN |
| Six-distinct-account Steam capacity/full gameplay | NOT RUN |

Latest local regression: **469/469 GUT tests, 2,779 assertions**, zero engine/script
errors; six expected warnings and 24 inherited fixture orphans remain. Python
contracts pass 14/14. Disposable backend/API/Godot HTTP tests pass under `go test
-race`; the opt-in native LAN host/guest graphical test also passes separately.
These results do not turn the known-red Steam transfer contract green.

The manual ABI/SDK probe is explicitly opt-in:

```sh
NOIKAR_TEST_MODE=1 NOIKAR_STEAM_PROBE=1 \
  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  -s tests/manual/steam_platform_probe.gd
```

It does not read friends or send invitations. Its mode/channel check verifies
setters only, **not packet delivery modes or ordering**.

## Known-red transfer contract

In [the exact upstream v4.23.1 source](https://codeberg.org/godotsteam/godotsteam/raw/tag/v4.23.1/godotsteam_multiplayer_peer.cpp),
`_get_steam_packet_flags()` maps `TRANSFER_MODE_UNRELIABLE_ORDERED` to
`k_nSteamNetworkingSend_Reliable`. This is a real semantic difference, not proof of
a failed match: it can introduce retransmission/head-of-line delays and must not be
silently accepted as Netfox performance parity.

To reproduce, download that source to a local scratch path, then run:

```sh
python3 tests/manual/verify_steam_ordered_contract.py --source /path/to/godotsteam_multiplayer_peer.cpp
```

The script verifies source SHA-256
`9670cb68c74b5bcaa6391f091074ccfd21a0738d3e7e234c812efdded26b50c2`, compiles
the unmodified upstream send-flag method with a minimal C++ harness, and executes
three contracts. Reliable and unreliable pass; ordered-unreliable fails because
the reliable flag is set. This is source-level characterization, not a binary
packet-exchange test. It intentionally remains a separate, reported red gate.

**Next step:** measure actual Steam/Netfox traffic under loss, jitter and reordering
before deciding whether a transport wrapper is necessary. The source-level mode
difference alone does not prove harmful gameplay behavior. No custom wrapper is
implemented or approved; any later correction needs its own delivery/channel tests
and real account gameplay validation.

Steam is transport, not Noikar authentication. Internet account testing also needs
the separately authorized HTTPS backend rollout; no live backend was deployed.
