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

## GTA IV measurement, second recording (2026-11-24)

A 240 s recording (63 skeletons) while the player wounded and then killed peds from a roof. Peds that were lying (head
level with the pelvis) never held their gun arm on the player: the arm direction stayed fixed (drift under 20 degrees, or
none at all for the dead) while the angle to the player changed freely as the player moved. Wounded peds got up, propped
and fell again with flailing arms, also without aiming. Standing peds aimed at 18-25 degrees. So a downed ped in GTA IV
does not shoot from the ground in this data; `dmr_aim_chance` 0.15 and `dmr_aim_range` 300 stay as a deliberately rare
concession, not a measured behaviour.

### Tuned after the third and fourth recordings (2026-11-24)

The reaction time is now 2.5-5.5 s (it was 0.6-1.4 s): the cops measured in GTA IV began to bring the gun round 3-5 s after
being hit (one while still stumbling, one after lying still), held it about 3 s and dropped it when the player walked
off. `dmr_range` (whoever hit it last) falls from 1500 to 300 units, the same as `dmr_aim_range`, so a target that walks
away is lost by the existing look (`pickTarget` every 0.4 s returns nothing, the NPC goes idle). Not implemented: the
"only armed peds, only against a weak weapon" rule the player described for standing peds.

### Later (2026-11-25): shooting the downed, dropping guns, both hands, the gun where it was held

- **Zombies** keep the game's ragdolls (`dmr_zombies` 0): `DMR_HasMapped` is false for an NPC whose class has "zombie".
- **A downed NPC is shot at.** The owner is no longer `FL_NOTARGET` (`dmr_live_shootable`): it is drawn with alpha 0, not the
  no-draw flag, and kept with its centre on the body's pelvis, so the others aim at the body and hit the ragdoll (its hits
  are the owner's, live.lua). NPCs have a team (`DMR_TeamOf`: Combine, rebel; the ragdoll's `DMR_Team`); every 0.5 s those of
  the other team within 1800 units are made hostile to it if they were not (and given back what they were when it is
  over) and take it as their enemy when they see it and have none nearer. Checked: a rebel took a downed Combine as its
  enemy and took it from 45 to 27 hp.
- **A killed ragdolled NPC drops its gun.** The weapon had stayed hidden with its owner and the clients kept drawing the gun
  in the corpse's hand. `DMR_LiveDied` now has the weapon shown, dropped at the hand and moving as it, and the drawn gun
  cleared.
- **The gun is where the NPC held it.** The weapon is bonemerged to the NPC: its own `ValveBiped.Bip01_R_Hand` bone is the
  NPC's hand bone (measured: local offset 0 for every HL2 weapon and NPC) and its model hangs from `ValveBiped.Weapon_bone`
  (5 forward, 1.5 right, 5 down of the hand). So the clients draw the model at the right hand bone with no offset. (The first
  version used the NPC's `anim_attachment_RH`, 2.7 forward and 1.7 right with a roll of 180: the gun sat beside the palm and
  the hand at the wrong end of it.) The barrel's direction, the muzzle and the forend come from the weapon's own bones.
- **Fingers** close round the grip on the clients (`dmr_grip_deg`, `dmr_grip_axis`: a ragdoll's fingers have no objects and
  stay open): each finger bone turned about its pitch axis, 30/50/35 degrees per segment, the thumb less.
- **Long guns in both hands** (`dmr_two_hands`). `pointArm` on the left arm toward the forend did not work (the arm did not
  move, or flailed when the right arm carried the gun too): the physical arm is NM's and the left hand is put on the forend
  as the body is drawn, only where the forend is within the arm's reach of the shoulder (a gun hanging at the right hip is not
  reached through the chest), a two-bone solve on the bones (`DMR_TwoHandIK`, cl_armed.lua, called by cl_ragdolls.lua's render).
  The forend is 60 per cent from the grip to the muzzle. Seen in frames of shot Combine with an AR2: the gun across the
  body with both arms on it. Not measured in numbers; the physical hand is where NM has it.

### Tried and dropped: the gun as a body of NM's (2026-11-25)

A gun body made by the fork and joined to the right hand part (so hand and gun would collide with the spine and the
head) was built and worked in a few runs (commit 336d4bb, reverted in 288c621). It was dropped as a bad direction:
NM's body is meant to be the character, and a prop in it changes how the arm moves and ties the gun to the module's
internals. The gun stays what it was: drawn on the clients at the right hand bone (the weapon's own bonemerge frame),
the left hand on the forend by client IK, the fingers closed on the grip. Hand and gun can therefore go through the
body; that is accepted.

### After play (2026-11-25): which way the gun points, shooting back, standing still

- **The gun pointed back at its own body.** The hand's forward axis is the barrel and follows the forearm outward (dot 0.6
  to 0.99, measured, the NPC standing and its ragdoll alike), but a lying body's arm flops and the forearm can point at the
  feet. The gun arm is now carried: a loose `pointArm` (`dmr_carry`, stiffness 8) toward the head's way when the body lies
  and forward (level) when it stands, whenever it is not aiming. Frames of knocked-down Combine: the AR2 out to the side
  or up over the shoulder, no longer back along the body.
- **Standing still after a body shot.** A shot NPC stayed a ragdoll until the shot task was over (seconds), doing
  nothing. One that is on its feet (head 20 units over the pelvis, slower than 1.5 m/s for 0.4 s, at least 0.9 s after the
  hit, no blast) is now given back to its own AI (`dmr_live_upright_back`): measured, back after 0.9-1.0 s, its AI
  enemy the player. Only a fall keeps the ragdoll.
- **Shooting from the ground, again.** GTA IV's downed peds did not shoot in the recordings, but a player prefers a fight, so
  the defaults are `dmr_aim_chance` 0.8, `dmr_aim_range` 600, `dmr_range` 900, a reaction of 1 to 2.5 s and 1.5 to 3.5 s
  of rest: a knocked-down Combine 4 m from the player fired 11 shots in 3 s. NB: an archived cvar keeps the value it had
  when the game last saved it (`cfg/server.vdf`), whatever the default has become since; a changed default needs the
  old line removed there.
