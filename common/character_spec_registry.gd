# res://common/character_spec_registry.gd
## Maps every CharacterActor scene to its CharacterSpec resource.
## Single lookup used by BaseEntity/PetEntity/EnemyEntity so the headless
## server can load combat data without touching visual actor scenes.
class_name CharacterSpecRegistry
extends RefCounted

const SPEC_BY_ACTOR_PATH: Dictionary = {
	"res://scenes/characters/Aatrox.tscn": "res://common/resources/specs/aatrox.tres",
	"res://scenes/characters/PlayerHero.tscn": "res://common/resources/specs/player_hero.tres",
	"res://scenes/characters/HecarimTank.tscn": "res://common/resources/specs/hecarim_tank.tres",
	"res://scenes/characters/IvernHeal.tscn": "res://common/resources/specs/ivern_heal.tres",
	"res://scenes/characters/IvernRanger.tscn": "res://common/resources/specs/ivern_ranger.tres",
	"res://scenes/characters/KogMawDmg.tscn": "res://common/resources/specs/kogmaw_dmg.tres",
	"res://scenes/characters/PetDmg.tscn": "res://common/resources/specs/pet_dmg.tres",
	"res://scenes/characters/PetHeal.tscn": "res://common/resources/specs/pet_heal.tres",
	"res://scenes/characters/PetTank.tscn": "res://common/resources/specs/pet_tank.tres",
	"res://scenes/characters/pets/dps/PetDpsT1Vladimir.tscn": "res://common/resources/specs/pet_dps_t1_vladimir.tres",
	"res://scenes/characters/pets/dps/PetDpsT2Gwen.tscn": "res://common/resources/specs/pet_dps_t2_gwen.tres",
	"res://scenes/characters/pets/dps/PetDpsT3Jax.tscn": "res://common/resources/specs/pet_dps_t3_jax.tres",
	"res://scenes/characters/pets/dps/PetDpsT4Ezreal.tscn": "res://common/resources/specs/pet_dps_t4_ezreal.tres",
	"res://scenes/characters/pets/support/PetSupT1Yuumi.tscn": "res://common/resources/specs/pet_sup_t1_yuumi.tres",
	"res://scenes/characters/pets/support/PetSupT2Bard.tscn": "res://common/resources/specs/pet_sup_t2_bard.tres",
	"res://scenes/characters/pets/support/PetSupT3Janna.tscn": "res://common/resources/specs/pet_sup_t3_janna.tres",
	"res://scenes/characters/pets/support/PetSupT4Nami.tscn": "res://common/resources/specs/pet_sup_t4_nami.tres",
	"res://scenes/characters/pets/tank/PetTankT1Alistar.tscn": "res://common/resources/specs/pet_tank_t1_alistar.tres",
	"res://scenes/characters/pets/tank/PetTankT2Garen.tscn": "res://common/resources/specs/pet_tank_t2_garen.tres",
	"res://scenes/characters/pets/tank/PetTankT3Thresh.tscn": "res://common/resources/specs/pet_tank_t3_thresh.tres",
	"res://scenes/characters/pets/tank/PetTankT4Galio.tscn": "res://common/resources/specs/pet_tank_t4_galio.tres",
}

static func spec_path_for(actor_path: String) -> String:
	return SPEC_BY_ACTOR_PATH.get(actor_path, "")

## Loads the spec for an actor scene path. ResourceLoader caches by path,
## so repeated loads across entities are cheap. Returns null when the actor
## has no registered spec (caller should fall back to actor-based data).
static func load_for(actor_path: String) -> CharacterSpec:
	var spec_path := spec_path_for(actor_path)
	if spec_path.is_empty():
		return null
	return load(spec_path) as CharacterSpec
