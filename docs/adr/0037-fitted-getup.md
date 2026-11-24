# 0037. Get-up by animation on fitted bodies: Homer's clip retargeted onto the NPC's own body

Status: proposed (2026-11-24). Refines 0025 (the fitted body) and 0029 (live bodies, which gave the NPC back standing
where the body lay).

## Context

A body fitted to a model (`dms_fit`) stayed down: `room.rs` forced the animation get-up off for it, because the
Playroom's clips (`dms_game::getup::Clips`) put Homer's 21 parts on the player skeleton, in Homer's proportions, and
Lua held *Homer's* physics objects on them (`DMR.FollowPose`). A fitted body's objects are the module's, not Lua's. In
live.lua a lying NPC was therefore handed back standing after 1.5 s of stillness: it popped up.

## Decision

1. **Retarget the clip's frames onto the fitted body** (`module/src/follow/retarget.rs`). Both bodies have NM's 21
   parts, the same tree and frame conventions. Each part's rotation is the clip's, turned by the difference of the two
   bodies' standing frames for it (a few degrees at most); positions are walked down the part tree from the pelvis with
   the *fitted* body's offsets (a part's place in its parent's frame in the standing pose), so limbs keep the model's
   lengths. The pelvis follows the clip's, offset by how the standing pelvises differ. Nothing is scaled or filtered.
2. **The lying pose goes into the clip in Homer's proportions** (`Retarget::to_homer`, the same map the other way):
   `Clips::start` blends the lying frames into the clip over its first quarter second, and the retarget gives the
   fitted body's own pose back at t = 0.
3. **The module holds the parts on the clip** (`Follower::hold_on_clip`): every part's state set (`SetBodyState`,
   `VBOX3D_NM_006`) to the retargeted frame, moving as the clip moves it. `SetBodyState` is for outside the physics
   step, so Lua calls `DMR.FollowHold(id)` from its Think hook each tick while the agent rises (`DMR_Rising`, set by
   the `freeze` event as for Homer).
4. **The end is Homer's**: the clip's last pose, a new agent on the bodies as they are, `bodyBalance`
   (`respawn`). A hit during the rise gives the clip up (`cancel_rise`) and NM takes the body.
5. **The floor lock** (`Retarget::plant`, with the floor Lua passes to `DMR.FollowHold(id, floor)`): the clip's last
   frames stand on straighter legs than NM's stance, so the retarget's feet ended a few centimetres above the floor and
   NM took a body that was still falling: it often lost its balance. From 55 % of the standing pelvis height up, the
   pose is lowered (smoothly, never raised, by at most 12 cm) till the lower foot is where NM's stance has it over the
   floor (`placed`'s own bound: radius + half length). The user saw it: they "get up a bit further from the ground".
6. **live.lua waits for it**: a lying body with the get-up on (`r.getup ~= "off"`) is given back once it balances, or
   if it lies still 7 s without the room getting it up (the room's own rule: the head within 0.3 m of the pelvis's
   height, so a body propped up sitting never starts), or after `dmr_live_time` (now 30 s); with the get-up off it
   stands up where it lay as before.

## Consequences

- No new physics: the body is NM's own throughout, and the room's reactions (the shot, a blast) act on it as on any
  body. The clip itself is kinematic, as it is for Homer; `dmr_getup 1` (muscles) still takes the clip's poses as NM
  targets, unretargeted (Homer's proportions on a fitted body): a follow-up.
- Only the clips the Playroom has (`get_up_fast`, front and back). GTA IV chooses by health and what hurt the ped
  (injured, slow, normal, fast) and has transitions for lying on a side: a follow-up that needs the clips loaded.
- With the floor lock the share of get-ups after which the body fell again within 4 s went from 7 of 21 to 4 of 24 (the
  same four NPC types, 130 s, near misses from the others' gunfire included): fewer, not none.
- Checked in game on a Combine soldier, the super soldier, a metrocop and a citizen (shot, lay about 2 s, rose on the
  clip, balanced; a hit mid-rise cancelled it and the Combine rose again; a metrocop propped up sitting never got up
  and was given back after 7 s) and by unit tests of the retarget (`cargo test -p gmsv_dmr retarget`: the two directions undo each
  other, limbs keep the fitted lengths). Not checked: Xbox 360 data.
