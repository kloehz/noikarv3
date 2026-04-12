# Netfox Integration Notes

## Status: Pending Netfox Addon Installation

Netfox is the chosen networking solution for noikarv-3. This document tracks the integration status and remaining work.

## Current State

### Implemented ✓
- Folder structure with `res://core/` (server) and `res://client/` (client) isolation
- `.gdignore` files in `core/` and `client/` for build-time exclusion
- `GameManager` with environment detection (`_is_headless_environment()`)
- `EventBus` signals: `server_started`, `client_connected`
- Netfox node references (`/root/NetworkManager`, `/root/TickLoop`) in `GameManager`
- `dedicated_server` feature tag in `project.godot`

### Not Yet Implemented
- [ ] Netfox addon installation (`res://addons/netfox/`)
- [ ] Actual `NetworkManager` configuration and initialization
- [ ] `TickLoop` tick rate configuration (currently hardcoded to 60 TTS)
- [ ] Port configuration (currently using hardcoded `DEFAULT_PORT = 7777`)
- [ ] Client connection UI flow
- [ ] Server list / matchmaking

## Required Netfox Nodes

Netfox provides these nodes that should be added as autoloads or children of `GameManager`:

```
/root/NetworkManager  - Handles connection setup, RPC, and state sync
/root/TickLoop        - Fixed timestep loop for deterministic simulation
/root/NetworkRollback - For input/state rollback (prediction)
```

## Integration Checklist

### Phase 1: Addon Setup
- [ ] Install Netfox to `res://addons/netfox/`
- [ ] Configure Netfox in Project Settings
- [ ] Add `/root/NetworkManager` autoload
- [ ] Add `/root/TickLoop` autoload

### Phase 2: NetworkManager Configuration
- [ ] Configure server port range
- [ ] Set up `NetworkManager.start_server(port)` call
- [ ] Set up `NetworkManager.connect_to_server(address, port)` for client
- [ ] Configure RPC channels and reliability settings

### Phase 3: TickLoop Configuration
- [ ] Set tick rate (60 TPS target for this project)
- [ ] Configure physics interpolation
- [ ] Set up rollback settings

### Phase 4: Entity Synchronization
- [ ] Add `NetworkSynchronizer` to `BaseEntity.tscn`
- [ ] Configure sync properties (position, rotation, health)
- [ ] Set up input gathering for clients
- [ ] Test server authority and client prediction

## Testing Commands

### Start Dedicated Server
```bash
godot --headless --path . --editor  # With Netfox editor tools
# OR
godot --headless --dedicated_server --path .
```

### Connect Client
```bash
godot --path .
# Then use in-game UI to connect to localhost:7777
```

### Verification
```bash
# Verify export isolation
python3 tests/verify_export_isolation.py

# Verify headless server environment
python3 tests/verify_headless_server.py --quick
```

## References

- Netfox Documentation: https://github.com/noxfox/netfox (pending)
- Godot 4.x headless/server: https://docs.godotengine.org/en/stable/tutorials/platform/dedicated_server.html
- MultiplayerSynchronizer: https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html

## Open Questions

1. **Should we use NetworkRollback immediately or start with simple interpolation?**
   - Recommendation: Start with simple `MultiplayerSynchronizer` for MVP, add rollback later
   - Tradeoff: Simpler code vs. smoother client prediction

2. **What port range for dedicated servers?**
   - Currently: Default 7777
   - Suggestion: Support environment variable override for production

3. **How to handle NAT punch-through for peer-to-peer?**
   - Netfox may have built-in solutions
   - Fallback: Use relay server for initial release

4. **Tick rate for Jolt physics integration with Netfox TickLoop?**
   - 60 TPS is standard
   - Jolt physics runs at physics FPS (default 60)
   - May need to decouple game logic tick from physics tick
