# 0038. Armed ragdolls: a live NPC keeps its weapon, aims with NM's pointArm and shoots from the ground

Status: proposed (2026-11-24). Refines 0029 (live bodies, whose owner was hidden with its weapon and could not shoot) and
0037 (the get-up).

## Context

A shot NPC becomes its ragdoll with NM (live.lua, 0029) and its AI stops: owner and weapon are hidden, so for the
seconds it lies there it is harmless, however hostile it is. GTA IV's NM peds shoot from the ground: the engine's
`pointArm` ("Point an arm.": `target`, `useLeftArm`, `twist`, `armStraightness`, `armStiffness`) drives an arm at a
target, and a `splitBody` behaviour ("Aim and fire a held weapon") exists in the engine's documentation. This module's
NM runtime registers 30 messages: `pointArm` is one (the room's "point" button sends it), `splitBody` is not (its name
is in a table of behaviour names, `nm_message_find` says there is no such message), so there is no engine-side firing
here and the shots are the game's.

## Decision

`addon/lua/dmr/armed.lua` (server) and `cl_armed.lua` (clients):

1. **The weapon in hand.** A live NPC with a firing weapon (the game's, or an addon's with a primary ammo type) tells
   the clients the weapon's model (`DMR_GunModel` on the ragdoll). The clients draw it at the right hand's bone matrix
   with a muzzle flash per shot (`DMR_GunShot`). It is not bonemerged: the weapon's attachment bone is not a physics
   bone and a ragdoll leaves it unposed, so a merged weapon never shows. The real weapon stays hidden with its owner.
2. **Aiming is NM's own.** Every 0.4 s the NPC looks for a target (its enemy, else the nearest it is hostile to
   (`Disposition == D_HT`) that it can see from the gun), and every 0.1 s `pointArm start=true useLeftArm=false
   target=<NM frame> armStiffness=18 armStraightness=0.9` goes to its body (`dmr_point`, `dmr_arm_stiffness`); a hit on
   the ragdoll takes it off for `dmr_stun` s (NM's shot reaction has the body), as does a get-up by the clip (0037:
   the parts are held on it).
3. **The shots are the game's.** The owner's `FireBullets` from the hand along the hand's forward (where the drawn gun
   points), pulled halfway to the target, with the ammo type's NPC damage, the weapon's sound, the weapon's burst
   rhythm (a table for the game's weapons, a pistol's for an addon's) and extra spread for the body's speed and for
   being hit lately (`dmr_inaccuracy`), and only while the gun points within `dmr_aim_cone` (30 degrees) of the
   target: it waits while the arm swings round.

## Attention (added after play: "trying his hardest to track the player")

The first version aimed at anything hostile within 2200 units, continuously. GTA IV's downed peds mostly do not shoot,
unless the player is right in front of them, so the NPC now has attention (`aim` in `armed.lua`): it notices only
something it is hostile to within `dmr_aim_range` (500 units) and within 70 degrees of where its head faces, or whoever hit
it last within `dmr_range` (1500); it reacts after 0.6-1.4 s; it goes for what it noticed with the chance
`dmr_aim_chance` (0.6), else ignores things for 4-8 s; it aims for about `dmr_aim_time` (4 s, 0.6x-1.4x), then rests 4-8
s; `pointArm` is sent every 0.25 s and `dmr_arm_stiffness` is 14. **These numbers are guesses from that description, not
GTA IV's**: its decision tables (`common\data\decision\*.ped`, `Combat\*.cmb`) are unlabelled numbers, and the
ShotTask code that would say when a downed ped may fire was not read. Measured with a Combine in game: 2 shots and about
5 s of aiming in 76 s of lying, against 61 shots in 60 s before; the distances in that check were not controlled (the NPC
walked up to the player before it was shot).

## What GTA IV does (measured, 2026-11-24)

Read from the running game (GTAIV.exe 1.2.0.59, offline; the ped skeletons' bone matrices recorded at 70 Hz, tools outside
this repository): peds standing 2-10 m from the player held the gun arm on him (the arm's direction within 5-10 degrees
of the direction to him) for tens of seconds; in four episodes where a ped went down (lying 20-80 s at 7-16 m, some dead and
some wounded, which the data does not tell apart) the arm pointed within 25 degrees of him 0-5% of the time, the hand
low and nearly still; two peds were propped up and moving 1.5-2 m/s for 15-20 s after going down, not aiming. So GTA IV's
downed peds do not track the player, and the defaults now make aiming from the ground rare: `dmr_aim_chance` 0.15,
`dmr_aim_range` 300, `dmr_aim_time` 3. Four episodes are few, and no downed ped was seen firing.

## Consequences

- Measured on a downed Combine with an SMG, 60 s each (`dmr_point 0`, then `1`): 15 shots inside the cone with the arm
  left to flop (when it happened to swing round) against 61 with `pointArm`. In the frames the gun arm is raised and
  extended toward the target, and sometimes lies along the ground. No shot fired while the body rose by the clip.
- A body lying on its arm, or face down, aims less well; nothing lifts the torso (NM has no message for it here).
- Hits on the ragdoll still reach the NPC as live.lua has them, so a hostile ragdoll can be shot back.
- A `DMR_ArmedFire(npc, pointing)` hook runs before each shot (the checks use it).
