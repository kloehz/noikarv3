---
name: godot-native-philosophy
description: >
  Prioritizes Godot's built-in scene system and nodes over procedural code for configuration.
  Trigger: When modifying .tscn files or writing initialization code in .gd files.
license: Apache-2.0
metadata:
  author: gentleman-programming
  version: "1.0"
---

## When to Use

- When adding meshes, collision shapes, or materials.
- When configuring node properties like Timer wait times, UI layout, or light settings.
- When setting up initial state for an entity.

## Critical Patterns

- **Inspector First**: If it can be set in the Inspector, it MUST be set there.
- **Scene Composition**: Use the scene tree for structure. Don't add children via code if they are constant.
- **Minimal _ready()**: Initialization code should only handle dynamic runtime state (authority checks, variable references).

## Code Examples

### BAD (Procedural)
```gdscript
func _ready():
    var mesh = BoxMesh.new()
    $MeshInstance3D.mesh = mesh
    $Timer.wait_time = 2.0
```

### GOOD (Godot-Native)
- Property `Mesh` assigned in `MeshInstance3D` in the `.tscn`.
- Property `Wait Time` set to `2.0` in the `.tscn`.
- Script is empty or only handles logic.

## Resources
- **Documentation**: See `.gemini/GEMINI.md` for project mandates.
