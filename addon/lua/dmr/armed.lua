-- Armed ragdolls (docs/adr/0038): a hostile NPC that is its ragdoll with NM (live.lua: shot, not killed) keeps its weapon
-- in the ragdoll's right hand (drawn by the clients, cl_armed.lua) and shoots at what it is hostile to.
--
-- GTA IV's NM peds aim from the ground with NM's own `pointArm` (docs/api.md): the gun arm is driven toward the target,
-- here with the target's point sent again every 0.1 s as it moves, in NM's frame. The shots are the game's: the NPC's
-- FireBullets from the gun's hand along where it points, pulled halfway to the target (a body on the ground can't aim
-- well), with extra spread for how fast the body moves and for being hit lately, and only while the gun points within
-- dmr_aim_cone of the target. NPC and ragdoll stay as live.lua has them: the owner hidden with its weapon, hits on the
-- ragdoll its hits.
--
-- Not while the body gets up by the clip (module/src/follow/retarget.rs: its parts are held on it, docs/adr/0037).

local M = 0.0254

local armed = CreateConVar("dmr_armed", "1", { FCVAR_ARCHIVE, FCVAR_REPLICATED },
	"A hostile NPC that is a ragdoll with NM (live.lua) keeps its weapon in hand and shoots back")
local point = CreateConVar("dmr_point", "1", FCVAR_ARCHIVE,
	"NM's pointArm: a ragdolled NPC swings its gun arm toward its target, as GTA IV's NM peds do")
local armStiff = CreateConVar("dmr_arm_stiffness", "18", FCVAR_ARCHIVE, "pointArm's armStiffness (NM's default 15): how hard the arm holds the aim")
local cone = CreateConVar("dmr_aim_cone", "30", FCVAR_ARCHIVE, "Degrees: a ragdolled NPC only fires while its gun points this close to its target")
local range = CreateConVar("dmr_range", "2200", FCVAR_ARCHIVE, "How far (units) a ragdolled NPC looks for something to shoot")
local sloppy = CreateConVar("dmr_inaccuracy", "1", FCVAR_ARCHIVE, "Scale of the extra spread from the body's motion and recent hits (0: none)")
local stun = CreateConVar("dmr_stun", "0.8", FCVAR_ARCHIVE, "Seconds after being hit before a ragdolled NPC aims and fires again")

-- How often the target is looked for (s).
local AIM_EVERY = 0.4

-- The game's NPC weapons. ammo: the ammo type (damage 0 = the game's NPC damage for it); rate: s between shots in a
-- burst; burst/rest: shots in a burst, s between bursts.
local WEAPONS = {
	weapon_smg1 = { ammo = "SMG1", snd = "Weapon_SMG1.NPC_Single", rate = 0.09, burst = { 3, 6 }, rest = { 0.5, 1.2 }, spread = 0.045 },
	weapon_ar2 = { ammo = "AR2", snd = "Weapon_AR2.NPC_Single", rate = 0.1, burst = { 3, 5 }, rest = { 0.6, 1.3 }, spread = 0.035, tracer = "AR2Tracer" },
	weapon_pistol = { ammo = "Pistol", snd = "Weapon_Pistol.NPC_Single", rate = 0.4, burst = { 1, 2 }, rest = { 0.6, 1.2 }, spread = 0.04 },
	weapon_357 = { ammo = "357", snd = "Weapon_357.Single", rate = 0.9, burst = { 1, 1 }, rest = { 0.8, 1.4 }, spread = 0.02 },
	weapon_shotgun = { ammo = "Buckshot", snd = "Weapon_Shotgun.NPC_Single", rate = 0.9, burst = { 1, 1 }, rest = { 0.9, 1.5 }, spread = 0.08, num = 7 },
}
-- Not fired from the ground: melee, launchers, thrown.
local NO_FIRE = {
	weapon_crowbar = true, weapon_stunstick = true, weapon_rpg = true, weapon_frag = true, weapon_slam = true,
	weapon_crossbow = true, weapon_physcannon = true, weapon_physgun = true,
}

local function profile(w)
	local class = w:GetClass()
	if NO_FIRE[class] then return nil end
	if WEAPONS[class] then return WEAPONS[class] end
	-- A weapon from an addon: its primary ammo and sound, a pistol's rhythm.
	local ammo = game.GetAmmoName(w:GetPrimaryAmmoType())
	if not ammo then return nil end
	local p = istable(w.Primary) and w.Primary or {}
	return {
		ammo = ammo, snd = isstring(p.Sound) and p.Sound or "Weapon_Pistol.NPC_Single", rate = 0.12, burst = { 2, 4 }, rest = { 0.6, 1.3 },
		spread = 0.045, damage = isnumber(p.Damage) and p.Damage or nil, num = isnumber(p.NumShots) and p.NumShots or 1,
	}
end

-- NPC -> {rag, weapon, prof, nextShot, left, lastHit, target, nextAim, nextPoint, pointing, shots}.
local armedNpcs = {}

-- NM's pointArm off.
local function armStop(x)
	if x.pointing and IsValid(x.rag) and x.rag.DMR_Agent then
		DMR_Send(x.rag, "pointArm start=false useLeftArm=false")
	end
	x.pointing = false
end

local function forget(npc)
	local x = armedNpcs[npc]
	if not x then return end
	armStop(x)
	if IsValid(x.rag) then x.rag:SetNW2String("DMR_GunModel", "") end
	armedNpcs[npc] = nil
end

hook.Add("DMR_LiveStarted", "DMR_Armed", function(npc, rag)
	if not npc:IsNPC() or armedNpcs[npc] then return end
	local w = npc:GetActiveWeapon()
	if not armed:GetBool() or not IsValid(w) then return end
	local prof = profile(w)
	if not prof then return end
	armedNpcs[npc] = { rag = rag, weapon = w, prof = prof, nextShot = CurTime() + 1, left = 0, lastHit = CurTime(), nextAim = 0 }
	-- The clients draw the gun in the ragdoll's hand (cl_armed.lua): the real weapon is hidden with its owner.
	rag:SetNW2String("DMR_GunModel", w:GetModel())
	rag:SetNW2Int("DMR_GunSkin", w:GetSkin())
end)

hook.Add("DMR_LiveEnded", "DMR_Armed", forget)

-- A hit on the ragdoll is a hit on its owner: its aim is off for a moment.
hook.Add("EntityTakeDamage", "DMR_Armed", function(ent)
	local owner = ent.DMR_LiveOf
	local x = IsValid(owner) and armedNpcs[owner]
	if x then x.lastHit = CurTime() end
end)

-- Something the NPC is hostile to.
local function hostile(npc, e)
	if not IsValid(e) or e == npc or e:IsFlagSet(FL_NOTARGET) then return false end
	if e:IsPlayer() then
		if not e:Alive() then return false end
	elseif e:IsNPC() then
		if e:Health() <= 0 or e.DMR_Live then return false end
	else
		return false
	end
	return npc:Disposition(e) == D_HT
end

local function visible(x, npc, from, e)
	local tr = util.TraceLine({ start = from, endpos = e:BodyTarget(from), filter = { x.rag, npc }, mask = MASK_SHOT })
	return tr.Entity == e or tr.Fraction > 0.98
end

local function pickTarget(x, npc, from)
	local e = npc:GetEnemy()
	if hostile(npc, e) and visible(x, npc, from, e) then return e end
	local best, bd = nil, range:GetFloat() ^ 2
	for _, c in ipairs(ents.FindInSphere(from, range:GetFloat())) do
		local d = c:GetPos():DistToSqr(from)
		if d < bd and hostile(npc, c) and visible(x, npc, from, c) then best, bd = c, d end
	end
	return best
end

-- Where the gun is and which way it points: the ragdoll's right hand (the client draws the gun there, its barrel along the
-- hand's forward).
local function gunPose(x)
	local rag = x.rag
	local b = rag:LookupBone("ValveBiped.Bip01_R_Hand")
	local m = b and rag:GetBoneMatrix(b)
	if m then return m:GetTranslation(), m:GetForward() end
	return rag:WorldSpaceCenter(), rag:GetForward()
end

local function speedOf(rag)
	local s = rag.DMR_Agent and DMR.FollowState(rag.DMR_Agent)
	return s and Vector(s.com_v.x, s.com_v.y, s.com_v.z):Length() or 0
end

local function fire(x, npc, from, gdir, toTarget)
	local p = x.prof
	-- Along the gun, pulled halfway to the target.
	local dir = (gdir + toTarget):GetNormalized()
	from = from + gdir * 14
	-- Wider the faster the body moves and the more recently it was hit.
	local extra = (0.015 * speedOf(x.rag) + (CurTime() - x.lastHit < 1.5 and 0.05 or 0)) * sloppy:GetFloat()
	local s = p.spread + extra
	npc:FireBullets({
		Attacker = npc, Inflictor = x.weapon, Src = from, Dir = dir, Spread = Vector(s, s, 0), Num = p.num or 1, Damage = p.damage or 0,
		AmmoType = p.ammo, Tracer = 1, TracerName = p.tracer, IgnoreEntity = x.rag,
	})
	x.rag:EmitSound(p.snd)
	x.shots = (x.shots or 0) + 1
	x.rag:SetNW2Int("DMR_GunShot", x.shots)
end

-- The target (looked for every AIM_EVERY s) and NM's pointArm on it, its point in NM's frame (m from where NM's origin is).
local function aim(npc, x)
	local rag = x.rag
	if not IsValid(x.weapon) or not rag.DMR_Agent or rag.DMR_Rising then return armStop(x) end
	local now = CurTime()
	local from = gunPose(x)
	if now >= x.nextAim or not IsValid(x.target) then
		x.nextAim = now + AIM_EVERY
		x.target = pickTarget(x, npc, from)
	end
	local t = x.target
	if not IsValid(t) or not hostile(npc, t) then
		x.target = nil
		return armStop(x)
	end
	if not point:GetBool() or now - x.lastHit < stun:GetFloat() then return armStop(x) end
	if now < (x.nextPoint or 0) then return end
	x.nextPoint = now + 0.1
	local st = DMR.FollowState(rag.DMR_Agent)
	if not st then return end
	local nm = t:BodyTarget(from) * M - Vector(st.origin.x, st.origin.y, st.origin.z)
	local ok = DMR_Send(rag, string.format("pointArm start=true useLeftArm=false target=%.4f,%.4f,%.4f armStiffness=%g armStraightness=0.9",
		nm.x, nm.y, nm.z, armStiff:GetFloat()))
	x.pointing = ok and true or false
end

local function shoot(npc, x)
	local rag = x.rag
	if not IsValid(x.weapon) or not rag.DMR_Agent or rag.DMR_Rising then return end
	local now = CurTime()
	if now < x.nextShot or now - x.lastHit < stun:GetFloat() then return end
	local t = x.target
	if not IsValid(t) or not hostile(npc, t) then
		x.nextShot = now + 0.3
		return
	end
	local from, gdir = gunPose(x)
	-- Not while the gun points elsewhere: it waits (the arm is swinging round to the target).
	local toTarget = (t:BodyTarget(from) - from):GetNormalized()
	if gdir:Dot(toTarget) < math.cos(math.rad(cone:GetFloat())) then
		x.nextShot = now + 0.05
		x.left = 0
		return
	end
	if x.left <= 0 then x.left = math.random(x.prof.burst[1], x.prof.burst[2]) end
	hook.Run("DMR_ArmedFire", npc, x.pointing)
	fire(x, npc, from, gdir, toTarget)
	x.left = x.left - 1
	if x.left <= 0 then
		x.nextShot = now + math.Rand(x.prof.rest[1], x.prof.rest[2])
	else
		x.nextShot = now + x.prof.rate
	end
end

hook.Add("Think", "DMR_Armed", function()
	if next(armedNpcs) == nil then return end
	for npc, x in pairs(armedNpcs) do
		if not IsValid(npc) or not IsValid(x.rag) or not armed:GetBool() then
			forget(npc)
		else
			aim(npc, x)
			shoot(npc, x)
		end
	end
end)
