-- Death ragdolls (ROADMAP M11, docs/adr/0028): an NPC or a player with a humanoid model that dies leaves a server
-- ragdoll with NM on it at once (ragdolls.lua), in the pose and moving as it died, and the killing hit goes to it as the
-- Playroom's room takes one (follow/room.rs) on a fatally injured body (health 49): its ShotTask's dying reaction
-- (`shot`, `shotRelax`), no getting up, later hits reacting till its health is 0 (the room's death: `STOP all`, `relax`).
--
-- NPCs: their ragdoll is made on the server for it (SetShouldServerRagdoll, as ai_serverragdolls 1 makes them all),
-- without the game's push of the killing hit (the room's impulse is it). Players: GMod's death ragdoll is the client's
-- (no FOLLOW there, docs/adr/0002), so it's taken away and a server ragdoll of the player's model is made in its place,
-- posed from the player's bones; the client's camera follows it as GMod's death camera follows its own.
--
-- At most dmr_autoattach_max of them have NM (and dmr_max_agents in all): a new one takes NM off the oldest, as does
-- dmr_autoattach_time; NM's off means an ordinary ragdoll in its place (DMR_DetachRagdoll). Removed (a fade, cleanup,
-- undo, the player's next death), NM goes with it (ragdolls.lua's OnRemove).

local M = 0.0254

local npcs = CreateConVar("dmr_autoattach_npc", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"NM on the death ragdolls of NPCs with humanoid models (made on the server for it), reacting to the killing hit")
local players = CreateConVar("dmr_autoattach_players", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"NM on players' death ragdolls: a server ragdoll of the player's model in place of GMod's client one, the death camera on it")
local maxDeaths = CreateConVar("dmr_autoattach_max", "4", FCVAR_ARCHIVE,
	"Death ragdolls with NM at once (within dmr_max_agents): a new one takes NM off the oldest")
local keepFor = CreateConVar("dmr_autoattach_time", "30", FCVAR_ARCHIVE,
	"Seconds a death ragdoll keeps NM before it's an ordinary ragdoll (0: till dmr_autoattach_max takes it)")

local stagger = CreateConVar("dmr_death_stagger", "1", FCVAR_ARCHIVE,
	"A bullet that kills: the body staggers as a shot one does (reaching for the wound) for a moment and then dies; a headshot flails and falls without holding a wound (0: the dying reaction, limp)")

local dyingTime = CreateConVar("dmr_death_time", "6", FCVAR_ARCHIVE,
	"Seconds (about) a body shot that kills takes to die: it staggers holding the wound, weakens, and dies at the end (dmr_death_stagger)")

-- How recent the last hit has to be to be the killing one (s).
local HIT_AGE = 0.5
-- The game's push of a killing hit on an NPC, kept out of its ragdoll: Source makes up its own for a zero force
-- (CalcDamageForceVector), so a negligible one (N s) stands in.
local NO_PUSH = Vector(0, 0, 1e-4)

local function at(p) return string.format("%.4f,%.4f,%.4f", p.x * M, p.y * M, p.z * M) end
local function dir(d) return string.format("%.4f,%.4f,%.4f", d.x, d.y, d.z) end

-- GMod's ragdolls work with this fork (VBOX3D_NM_006) and a limit above 0.
local function possible()
	if maxDeaths:GetInt() <= 0 then return false end
	local iface = DMR.InterfaceVersion()
	return iface ~= nil and (tonumber(iface:match("(%d+)$")) or 0) >= 6
end

local function wanted(ent)
	if ent:IsPlayer() then return players:GetBool() end
	return ent:IsNPC() and npcs:GetBool()
end

-- Whether a bullet's hit on `ent` is in its head hitbox (the model's own hitboxes, a little padded).
function DMR_IsHeadshot(ent, dmg)
	if not (dmg:IsBulletDamage() or dmg:IsDamageType(DMG_BUCKSHOT)) then return false end
	local pos = dmg:GetDamagePosition()
	if pos:IsZero() or not ent.GetHitboxSet then return false end
	local set = ent:GetHitboxSet()
	local pad = 3
	for i = 0, (ent:GetHitBoxCount(set) or 0) - 1 do
		if ent:GetHitBoxHitGroup(i, set) == HITGROUP_HEAD then
			local bone = ent:GetHitBoxBone(i, set)
			local m = bone and ent:GetBoneMatrix(bone)
			local mins, maxs = ent:GetHitBoxBounds(i, set)
			if m and mins and maxs then
				local lp = m:GetInverse() * pos
				if lp.x >= mins.x - pad and lp.x <= maxs.x + pad and lp.y >= mins.y - pad and lp.y <= maxs.y + pad
					and lp.z >= mins.z - pad and lp.z <= maxs.z + pad then
					return true
				end
			end
		end
	end
	return false
end

-- The hit as the room's reactions take it (reactions.lua's translation): kind, where, which way, the weapon.
local function hitOf(ent, dmg)
	local pos = dmg:GetDamagePosition()
	if pos:IsZero() then pos = ent:WorldSpaceCenter() end
	local att, force = dmg:GetAttacker(), dmg:GetDamageForce()
	local from = IsValid(att) and (att.EyePos and att:EyePos() or att:GetPos()) or pos
	local h = { pos = pos, time = CurTime(), damage = dmg:GetDamage(), force = force, from = from }
	if dmg:IsBulletDamage() or dmg:IsDamageType(DMG_BUCKSHOT) then
		local d = force:IsZero() and (pos - from) or force
		h.kind, h.dir, h.weapon = "shot", d:GetNormalized(), DMR_WeaponOf(dmg)
		h.head = DMR_IsHeadshot(ent, dmg)
	elseif dmg:IsExplosionDamage() then
		h.kind, h.centre = "blast", DMR_BlastCentre(ent, dmg, pos)
	elseif dmg:IsDamageType(DMG_BURN) or dmg:IsDamageType(DMG_SLOWBURN) then
		h.kind = "burn"
	elseif dmg:IsDamageType(DMG_CLUB) or dmg:IsDamageType(DMG_SLASH) then
		h.kind = "melee"
	elseif dmg:IsDamageType(DMG_SHOCK) then
		h.kind = "taser"
	end
	return h
end
DMR_HitOf = hitOf

-- The room's lines for the killing hit `h` on the ragdoll: the room's fatally injured (health under 50, its ShotTask's
-- dying reaction, no getting up), then the hit as the room takes it, its damage on that health (at 0 the room's death).
-- No hit known (a fall, a crush, `kill`): just its death.
local FATALLY_INJURED = 49
-- The body's dying as the room takes it: the shot's stagger (reaching for the wound) is the room's ShotTask, whose state
-- (standing, injured, fatally injured) is the health it finds when a hit lands. So the dying is the killing hit again
-- every second and a half on a health that falls from 200 to 0 over about dmr_death_time s (a body staggering,
-- weakening, going down, reaching for the wound), and `health value=0` at the end, the room's death. The body stays NM's
-- the whole time.
local function dyingLines(hit)
	local total = math.max(1.5, dyingTime:GetFloat()) * math.Rand(0.85, 1.15)
	local n = math.max(1, math.floor(total / 1.5))
	local later = {}
	for i = 1, n do
		local t = i * total / (n + 1)
		later[#later + 1] = { t, "health value=" .. math.max(1, math.floor(200 * (1 - i / (n + 1)))) }
		later[#later + 1] = { t + 0.02, hit }
	end
	later[#later + 1] = { total, "health value=0" }
	return later
end

local function deathLines(rag, h)
	if not h or CurTime() - h.time > HIT_AGE then return { "health value=0" } end
	local hit
	if h.kind == "shot" then
		local part = DMR_RagdollPartAt(rag, h.pos, h.dir)
		-- A headshot: NM plays (the arms flail, it stays up a moment) without a shot's reaching for the wound; then it falls.
		if stagger:GetBool() and h.head then
			return { "health value=" .. FATALLY_INJURED, "button name=windmill", "button name=stayup" },
				{ { 0.8, "button name=STOP_all" }, { 0.9, "health value=0" } }
		end
		hit = string.format("shot at=%s dir=%s weapon=%s%s", at(h.pos), dir(h.dir), h.weapon, part and (" part=" .. part) or "")
		-- Any other bullet: the stagger of a shot that does not kill (reaching for the wound, standing), and then its death.
		if stagger:GetBool() then
			return { "health value=200", hit }, dyingLines(hit)
		end
	elseif h.kind == "blast" then
		hit = "blast at=" .. at(h.centre)
	elseif h.kind == "burn" then
		hit = "burn"
	elseif h.kind == "melee" then
		hit = string.format("melee damage=%.2f at=%s impulse=%s head=%s", h.damage, at(h.pos), at(h.force), at(h.from))
	elseif h.kind == "taser" then
		hit = "taser at=" .. at(h.pos)
	end
	if not hit then return { "health value=0" } end
	return { "health value=" .. FATALLY_INJURED, hit }
end

-- The death ragdolls NM is on, oldest first: {ent, owner (a player), since}.
local corpses = {}

local function prune()
	for i = #corpses, 1, -1 do
		local c = corpses[i]
		if not IsValid(c.ent) or not c.ent.DMR_Agent then table.remove(corpses, i) end
	end
end

-- A player's camera on their death ragdoll (cl_ragdolls.lua).
local function follow(ply, rag)
	if not IsValid(ply) then return end
	ply.DMR_Corpse = rag
	ply:SetNW2Entity("DMR_Corpse", rag)
end

-- NM off a death ragdoll: an ordinary ragdoll in its place, a player's camera moved to it.
local function release(c)
	if not IsValid(c.ent) or not c.ent.DMR_Agent then return end
	local old = c.ent
	local color, owner = old:GetNW2Vector("DMR_PlayerColor"), old:GetNW2Entity("DMR_Owner")
	local new = DMR_DetachRagdoll(old)
	if not IsValid(new) then return end
	if IsValid(owner) then
		new:SetNW2Vector("DMR_PlayerColor", color)
		new:SetNW2Entity("DMR_Owner", owner)
	end
	if IsValid(c.owner) and c.owner.DMR_Corpse == old then follow(c.owner, new) end
end

-- Room for one more: the oldest death ragdolls let go of while there are dmr_autoattach_max of them or dmr_max_agents
-- bodies have NM (not asked for a ragdoll that has NM already, `had`). Whether there's room.
local function makeRoom(had)
	prune()
	while #corpses > 0 and (#corpses >= maxDeaths:GetInt() or not (had or DMR_AgentRoom())) do
		release(table.remove(corpses, 1))
	end
	return #corpses < maxDeaths:GetInt() and (had or DMR_AgentRoom())
end

-- NM on a death ragdoll (kept on one that has it, live.lua's) and the room's lines to it (by default the killing hit
-- `h`'s). The agent's id, or nil and why.
local function attach(rag, h, owner, lines, later)
	if not makeRoom(rag.DMR_Agent ~= nil) then return nil, "no room (dmr_autoattach_max, dmr_max_agents)" end
	local id, why = DMR_AttachRagdoll(rag)
	if not id then return nil, why end
	rag.DMR_Death = true
	corpses[#corpses + 1] = { ent = rag, owner = owner, since = CurTime() }
	if not lines then lines, later = deathLines(rag, h) end
	for _, line in ipairs(lines) do DMR_React(rag, line) end
	-- What comes later (the end of a stagger: its death), if the body still has NM then.
	for _, l in ipairs(later or {}) do
		timer.Simple(l[1], function()
			if IsValid(rag) and rag.DMR_Agent then DMR_React(rag, l[2]) end
		end)
	end
	hook.Run("DMR_DeathRagdoll", rag, owner)
	return id
end

-- The killing hit, and for an NPC its ragdoll made on the server without the game's push.
hook.Add("EntityTakeDamage", "DMR_Deaths", function(ent, dmg)
	if not (ent:IsNPC() or ent:IsPlayer()) or not wanted(ent) or not DMR_HasMapped(ent) then return end
	ent.DMR_LastHit = hitOf(ent, dmg)
	if ent:IsNPC() and possible() and dmg:GetDamage() >= ent:Health() then
		ent:SetShouldServerRagdoll(true)
		local h = ent.DMR_LastHit.kind
		if (h == "shot" and not (stagger:GetBool() and ent.DMR_LastHit.head)) or h == "blast" or h == "melee" then dmg:SetDamageForce(NO_PUSH) end
	end
end)

-- An NPC's server ragdoll: NM on it, posed and moving as the NPC died (the game's own ragdolling, ADR 0027's swap).
hook.Add("CreateEntityRagdoll", "DMR_Deaths", function(owner, rag)
	-- One that died as a ragdoll (live.lua): that ragdoll is its corpse.
	if not IsValid(owner) or owner.DMR_Live or not owner:IsNPC() or not npcs:GetBool() or not possible() then return end
	if not IsValid(rag) or rag:GetClass() ~= "prop_ragdoll" or not DMR_IsMapped(rag) then return end
	local h, name = owner.DMR_LastHit, tostring(owner)
	-- Undo and cleanup take the corpse in the NPC's place.
	undo.ReplaceEntity(owner, rag)
	cleanup.ReplaceEntity(owner, rag)
	-- The game gives the ragdoll its objects' motion after this hook: NM takes it over a tick later.
	timer.Simple(0, function()
		if not IsValid(rag) or rag.DMR_Agent then return end
		local id, why = attach(rag, h)
		if not id and why then print("[DMR] NM isn't on " .. name .. "'s death ragdoll: " .. tostring(why)) end
	end)
end)

-- A ragdoll of a player's or an NPC's model as it looks, posed from its bones and moving as it was (a player's death
-- ragdoll, live.lua's). The ragdoll, or nil for a model NM can't drive.
function DMR_RagdollFrom(ent)
	local rag = ents.Create("prop_ragdoll")
	rag:SetModel(ent:GetModel())
	rag:SetPos(ent:GetPos())
	rag:SetAngles(Angle(0, ent:GetAngles().y, 0))
	rag:SetSkin(ent:GetSkin())
	for i = 0, ent:GetNumBodyGroups() - 1 do rag:SetBodygroup(i, ent:GetBodygroup(i)) end
	rag:SetColor(ent:GetColor())
	rag:SetRenderMode(ent:GetRenderMode())
	rag:SetMaterial(ent:GetMaterial())
	for i = 0, #(ent:GetMaterials() or {}) - 1 do
		local m = ent:GetSubMaterial(i)
		if m ~= "" then rag:SetSubMaterial(i, m) end
	end
	rag:Spawn()
	rag:Activate()
	if not DMR_IsMapped(rag) then
		rag:Remove()
		return nil
	end
	-- As GMod's own: the world and things, not players and NPCs.
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	if ent:IsPlayer() then
		-- The player's colour on their model (the PlayerColor material proxy, cl_ragdolls.lua).
		rag:SetNW2Vector("DMR_PlayerColor", ent:GetPlayerColor())
		rag:SetNW2Entity("DMR_Owner", ent)
	end
	local vel = ent:GetVelocity()
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local p = rag:GetPhysicsObjectNum(i)
		local b = ent:LookupBone(rag:GetBoneName(rag:TranslatePhysBoneToBone(i)))
		local m = b and ent:GetBoneMatrix(b)
		if IsValid(p) and m then
			p:SetPos(m:GetTranslation(), true)
			p:SetAngles(m:GetAngles())
			p:SetVelocity(vel)
			p:Wake()
		end
	end
	return rag
end

local function dropCorpse(ply)
	if IsValid(ply.DMR_Corpse) then ply.DMR_Corpse:Remove() end
	ply.DMR_Corpse = nil
	ply:SetNW2Entity("DMR_Corpse", NULL)
end

-- After the gamemode's DoPlayerDeath (its CreateRagdoll): GMod's client ragdoll gives way to a server one with NM.
hook.Add("PlayerDeath", "DMR_Deaths", function(ply)
	-- Died as a ragdoll (live.lua's drunk): that ragdoll is their corpse (DMR_DiedAsRagdoll).
	if ply.DMR_Live then return end
	-- One death ragdoll a player, as GMod's.
	dropCorpse(ply)
	if not players:GetBool() or not possible() or not DMR_HasMapped(ply) then return end
	local h = ply.DMR_LastHit
	local rag = DMR_RagdollFrom(ply)
	if not rag then return end
	local id, why = attach(rag, h, ply)
	if not id then
		rag:Remove()
		if why then print("[DMR] NM isn't on " .. tostring(ply) .. "'s death ragdoll: " .. tostring(why)) end
		return
	end
	-- Made in this tick: removed before the clients hear of it.
	local theirs = ply:GetRagdollEntity()
	if IsValid(theirs) then theirs:Remove() end
	follow(ply, rag)
end)

-- An NPC or a player that died as a ragdoll with NM (live.lua): that ragdoll is their death ragdoll, NM kept. The hit
-- that killed it went to it as any hit does (reactions.lua): the room's fatally injured body takes it (a death without a
-- hit, its death at once). True, or false and why (death ragdolls off for it, no room).
function DMR_DiedAsRagdoll(rag, owner)
	if not IsValid(rag) or not rag.DMR_Agent then return false, "no NM on it" end
	if not wanted(owner) or not possible() then return false, "death ragdolls are off" end
	local h = owner.DMR_LastHit
	local lines = { (h and CurTime() - h.time <= HIT_AGE) and ("health value=" .. FATALLY_INJURED) or "health value=0" }
	local ply = owner:IsPlayer() and owner or nil
	-- One death ragdoll a player: the last one goes.
	if ply then dropCorpse(ply) end
	local id, why = attach(rag, nil, ply, lines)
	if not id then return false, why end
	if ply then follow(ply, rag) end
	return true
end

hook.Add("PlayerSpawn", "DMR_Deaths", function(ply) ply:SetNW2Entity("DMR_Corpse", NULL) end)

hook.Add("PlayerDisconnected", "DMR_Deaths", dropCorpse)

-- A model's first NM body makes its 21 hulls in the fork (~0.9 s at once): for the NPCs and players that may die,
-- their model is fitted and its hulls made ahead, a part a tick (ragdolls.lua's DMR_PrepareModel).
local function warmUp(ent)
	if not IsValid(ent) or not wanted(ent) or not possible() or not DMR_HasMapped(ent) then return end
	DMR_PrepareModel(ent:GetModel())
end

hook.Add("OnEntityCreated", "DMR_DeathsWarm", function(ent)
	if ent:IsNPC() then timer.Simple(0, function() warmUp(ent) end) end
end)
hook.Add("PlayerSpawn", "DMR_DeathsWarm", function(ply) timer.Simple(0, function() warmUp(ply) end) end)

-- dmr_autoattach_time: NM off the death ragdolls that have had it that long.
timer.Create("DMR_Deaths", 1, 0, function()
	prune()
	local keep = keepFor:GetFloat()
	if keep <= 0 then return end
	for i = #corpses, 1, -1 do
		if CurTime() - corpses[i].since >= keep then release(table.remove(corpses, i)) end
	end
end)

-- The death ragdolls with NM, oldest first (dmr_status, the bench).
function DMR_DeathRagdolls()
	prune()
	local out = {}
	for _, c in ipairs(corpses) do out[#out + 1] = c.ent end
	return out
end
