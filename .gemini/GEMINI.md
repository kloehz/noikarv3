# noikarv-3 - Agent Context

This project follows the **Godot-Native** philosophy. Every agent working here MUST adhere to these principles.

## Core Mandates

### 1. Godot-Native Philosophy (Minimal Code)
- **Prefer Scenes over Code**: If a property can be set in the Inspector (Mesh, CollisionShape, Material, Timer wait time, etc.), it MUST be set in the `.tscn` file, not via code in `_ready()`.
- **Composition over Inheritance**: Use Nodes and Components (LogicComponent, VisualComponent) instead of creating deep inheritance trees.
- **Scene-First Design**: Design entities visually in the editor first. Use `@tool` mode when useful for editor previews.

### 2. Networking (Netfox v2.x)
- Use `RollbackSynchronizer` for physics/input prediction.
- Use `StateSynchronizer` for authoritative state (health, names, scores).
- Use `TickInterpolator` for visual smoothing.
- Physics logic MUST reside in `_rollback_tick(delta, tick, is_fresh)`.

### 3. Repository Persistence
- All work plans, technical designs, and decisions are stored in the `openspec/` directory.
- Custom skills and patterns are stored in `.gemini/skills/`.

## Architecture
- **Server Authority, Client Representation**: The server runs the logic; clients represent it visually.
- **Event Bus**: Use `EventBus` (autoload) for decoupled communication between systems.
