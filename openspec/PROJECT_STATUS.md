# Handover & Project Status: noikarv-3

**Date**: 2026-04-12
**Current State**: Core Loop Functional (Netfox v2.x Stable)

## 🏗️ Technical Architecture (Server Authority)

This project uses **Netfox v2.x** with a strict **Authority Split** pattern to ensure a smooth "Brawler" feel with zero-lag movement and cheat-proof stats.

### 1. Authority Breakdown
- **Entity Root (`BaseEntity`)**: Owned by the **Player** (Peer ID).
- **`LogicComponent`**: Owned by the **Player**. Handles movement and local input prediction.
- **`RollbackSynchronizer`**: Owned by the **Player**. Syncs position and input for prediction.
- **`ServerState` (Critical)**: Owned by the **Server** (Peer 1). Holds variables that players cannot touch (Health, Death state, Knockback Impulses).
- **`StateSynchronizer`**: Owned by the **Server**. Broadcasts logical state from host to clients.

### 2. Synchronization Strategy
To avoid "Unknown Property" warnings and jitter:
- **Physics**: Handled by `RollbackSynchronizer` (Global Position, Velocity).
- **Logic**: Handled by `StateSynchronizer` inside the `ServerState` node (Health, Death, Impulses).
- **Proxies**: `BaseEntity.gd` acts as a proxy, updating local components when network variables change.

## ✅ Features Implemented

### 🎮 Movement & Controls
- **Strafe Mode**: Player always faces the camera direction. WASD moves relative to the view.
- **Rakion Camera**: Right-click to rotate the body and camera. Mouse is captured for precision.
- **Smoothing**: `TickInterpolator` used for other players, disabled for the local player to eliminate visual delay.

### ⚔️ Combat System
- **Volumetric Melee**: Uses `ShapeCast3D` (Sphere) for generous and robust hit detection.
- **Authoritative Damage**: Server calculates hits and applies damage to `ServerState`.
- **Authoritative Knockback**: Server sets a `knockback_impulse` in the victim's `ServerState`. The victim's `LogicComponent` detects and applies it to their own velocity.

### ⚰️ Life Cycle
- **Death**: At 0 HP, `is_dead` is synced. Visuals hide, collisions disable, and control is locked.
- **Respawn**: Authoritative 3-second timer on the server. Resets position, health, and state.
- **Training Dummies**: Fully integrated entities that can be hit, killed, and pushed.

## ⚠️ Important for the next Session
- **Input Map**: Ensure `move_left`, `move_right`, `move_forward`, `move_backward`, `shoot`, and `toggle_menu` are defined in the editor.
- **Scene Structure**: NEVER remove the `ServerState` node; it is the bridge for authoritative data.
- **Adding new properties**: Always add them to `ServerState.gd` if they are server-dictated, and update the `StateSynchronizer` properties list.

## 🚀 Next Steps (Phase 1 & 2)
1. **DASH / Dodge**: Implement a quick burst of speed with a cooldown.
2. **STUN**: Brief movement lock when receiving damage.
3. **ARENA**: Replace the flat floor with a proper map using Godot CSG nodes.
4. **KILL-Z**: Add a logic to die if falling off the map.
