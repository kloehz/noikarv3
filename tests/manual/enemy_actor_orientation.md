# Enemy Actor Orientation Verification

Headless GUT tests verify the per-actor `visual_forward_yaw` correction
applied by `BaseEntity._load_character_actor` and the AI chase yaw formula
in `AIComponent._move_towards / _look_at_target`. Scenes whose imported
GLB model uses +Z as the visible forward (Hecarim, Ivern, KogMaw) declare
`visual_forward_yaw = PI` on their root `CharacterActor` node so the actor
mesh aligns with the entity's local -Z (Godot's movement forward axis).
Scenes whose imported model already faces -Z (Aatrox, PlayerHero, pet
actors) keep the default 0; flipping those would invert their facing.

The AI chase contract (`atan2(dir.x, dir.z)`) computes a `look_yaw` that
points the entity's local -Z toward the target. Combined with the
per-scene actor yaw, the mesh renders the enemy facing the target while
walking toward it.

Imported GLB meshes cannot be inspected deterministically from a headless
test — `BaseEntity` strips visual nodes in headless mode and a GLB's
geometry orientation is not exposed as a stable gameplay property. The
manual graphical check below is the only acceptance step that proves the
visual mesh actually faces forward at spawn.

Run a graphical server and client, start a match, and observe one actor
from each wave while it chases a player:

1. Confirm Hecarim, Ivern, and KogMaw move toward the player without
   walking backward; their models must face their direction of travel.
2. Confirm the Aatrox boss moves toward the player facing its direction of
   travel; it inherits its default yaw (0) since the imported model
   already faces -Z.
3. Confirm the PlayerHero Aatrox model also faces its direction of travel
   while moving under player control; it inherits its default yaw (0)
   since the imported model already faces -Z.
4. Confirm `HecarimTank.tscn`, `IvernHeal.tscn`, `IvernRanger.tscn`, and
   `KogMawDmg.tscn` declare `visual_forward_yaw = PI`; the other actor
   scenes keep the default 0.

This is a graphical acceptance check for imported assets. The automated
tests keep the per-actor yaw split and prove the AI chase math aligns the
mesh with the entity's movement forward.