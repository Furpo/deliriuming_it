-- The weapon of a ragdolled armed NPC (armed.lua) in the ragdoll's right hand, with a muzzle flash per shot.
--
-- Drawn here, not bonemerged: the weapon's attachment bone is not a physics bone, and a ragdoll leaves it unposed, so a
-- merged weapon never shows. The hand's bone matrix is where the gun goes.

-- Hand-bone offsets (forward, right, up in units; pitch, yaw, roll in degrees): where an HL2 world model sits in a
-- ValveBiped hand. Convars so they can be tuned in game.
local cv = {}
for k, v in pairs({ fwd = 4, right = -1, up = 0, pitch = 0, yaw = 0, roll = 180 }) do
	cv[k] = CreateClientConVar("dmr_gun_off_" .. k, tostring(v), true, false)
end

local function gunOf(ent)
	local model = ent:GetNW2String("DMR_GunModel", "")
	if model == "" then
		if IsValid(ent.DMR_GunCS) then ent.DMR_GunCS:Remove() end
		ent.DMR_GunCS = nil
		return nil
	end
	local cs = ent.DMR_GunCS
	if not IsValid(cs) or cs:GetModel() ~= model then
		if IsValid(cs) then cs:Remove() end
		cs = ClientsideModel(model, RENDERGROUP_OPAQUE)
		if not IsValid(cs) then return nil end
		cs:SetNoDraw(true)
		ent.DMR_GunCS = cs
		ent:CallOnRemove("DMR_GunCS", function() if IsValid(cs) then cs:Remove() end end)
	end
	cs:SetSkin(ent:GetNW2Int("DMR_GunSkin", 0))
	return cs
end

local function place(ent, cs)
	local b = ent:LookupBone("ValveBiped.Bip01_R_Hand")
	local m = b and ent:GetBoneMatrix(b)
	if not m then return false end
	-- Where the NPC held this weapon, in its hand bone's frame (armed.lua took it from the NPC's anim_attachment_RH).
	if ent:GetNW2Bool("DMR_GunHas", false) then
		local loc = Matrix()
		loc:SetTranslation(ent:GetNW2Vector("DMR_GunPos", vector_origin))
		loc:SetAngles(ent:GetNW2Angle("DMR_GunAng", angle_zero))
		local g = m * loc
		cs:SetPos(g:GetTranslation())
		cs:SetAngles(g:GetAngles())
		return true
	end
	local pos, ang = m:GetTranslation(), m:GetAngles()
	pos = pos + ang:Forward() * cv.fwd:GetFloat() + ang:Right() * cv.right:GetFloat() + ang:Up() * cv.up:GetFloat()
	ang:RotateAroundAxis(ang:Right(), cv.pitch:GetFloat())
	ang:RotateAroundAxis(ang:Up(), cv.yaw:GetFloat())
	ang:RotateAroundAxis(ang:Forward(), cv.roll:GetFloat())
	cs:SetPos(pos)
	cs:SetAngles(ang)
	return true
end

-- The left arm on the gun's forend (armed.lua flags DMR_TwoHands and sends the forend in the right hand's frame,
-- DMR_GunFore). Two-bone IK on the drawn bones: the upper arm and the forearm turned so the hand reaches the forend, the
-- elbow where it bends now, the fingers carried with the hand. Called by cl_ragdolls.lua's render after the bones are set.
local function rotAbout(axis, ang, pivot)
	local c, s = math.cos(ang), math.sin(ang)
	local x, y, z, t = axis.x, axis.y, axis.z, 1 - c
	local r = Matrix({
		{ t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0 },
		{ t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0 },
		{ t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0 },
		{ 0, 0, 0, 1 },
	})
	-- Turning about the pivot: the pivot stays where it is.
	local p = pivot - r * pivot
	r:SetTranslation(p)
	return r
end

-- The rotation taking the direction a to the direction b (unit vectors), about `pivot`.
local function turn(a, b, pivot)
	local axis = a:Cross(b)
	local len = axis:Length()
	if len < 1e-5 then return Matrix() end
	return rotAbout(axis / len, math.atan2(len, a:Dot(b)), pivot)
end

-- Fingers closed round the grip (a ragdoll's hand is open: its fingers have no objects and keep the model's relaxed
-- pose). Each finger bone is turned about its own joint, parent first so the segments add up, the bones under it with it.
local gripAxis = CreateClientConVar("dmr_grip_axis", "0", true, false, "Which of a finger bone's own axes it curls about (0 pitch, 1 yaw, 2 roll)")
local gripDeg = CreateClientConVar("dmr_grip_deg", "1", true, false, "Scale of the fingers' curl round a gun (0: open hands)")
local CURL = { { 0, 30 }, { 1, 50 }, { 2, 35 } } -- {segment suffix index, degrees}
local FINGERS = {
	{ "Finger1", "Finger11", "Finger12", 1 }, { "Finger2", "Finger21", "Finger22", 1 },
	{ "Finger3", "Finger31", "Finger32", 1 }, { "Finger4", "Finger41", "Finger42", 1 },
	{ "Finger0", "Finger01", "Finger02", 0.4 },
}
local function curl(ent, side)
	local k = gripDeg:GetFloat()
	if k <= 0 then return end
	local ax = gripAxis:GetInt()
	for _, f in ipairs(FINGERS) do
		local parentNew, parentOld
		for seg = 1, 3 do
			local bone = ent:LookupBone("ValveBiped.Bip01_" .. side .. "_" .. f[seg])
			local m = bone and ent:GetBoneMatrix(bone)
			if not m then break end
			local p = ent:GetBoneParent(bone)
			local pm = parentNew or (p and p >= 0 and ent:GetBoneMatrix(p))
			local po = parentOld or pm
			if pm and po then
				local deg = CURL[seg][2] * k * f[4]
				local ang = Angle(ax == 0 and deg or 0, ax == 1 and deg or 0, ax == 2 and deg or 0)
				local r = Matrix()
				r:SetAngles(ang)
				local nm = pm * (po:GetInverseTR() * m) * r
				ent:SetBoneMatrix(bone, nm)
				parentNew, parentOld = nm, m
			end
		end
	end
end

function DMR_TwoHandIK(ent)
	local two = ent:GetNW2Bool("DMR_TwoHands", false)
	if ent:GetNW2Bool("DMR_GunHas", false) then curl(ent, "R") end
	if not two then return end
	local rh = ent:LookupBone("ValveBiped.Bip01_R_Hand")
	local ua, fa, lh = ent:LookupBone("ValveBiped.Bip01_L_UpperArm"), ent:LookupBone("ValveBiped.Bip01_L_Forearm"), ent:LookupBone("ValveBiped.Bip01_L_Hand")
	if not (rh and ua and fa and lh) then return end
	local rm, um, fm, hm = ent:GetBoneMatrix(rh), ent:GetBoneMatrix(ua), ent:GetBoneMatrix(fa), ent:GetBoneMatrix(lh)
	if not (rm and um and fm and hm) then return end
	local target = rm * ent:GetNW2Vector("DMR_GunFore", vector_origin)
	local S, E0, H0 = um:GetTranslation(), fm:GetTranslation(), hm:GetTranslation()
	local a, b = S:Distance(E0), E0:Distance(H0)
	if a < 1 or b < 1 then return end
	-- Only where the hand can reach it without crossing the body: the grip eases in as the forend comes within 85 per cent
	-- of the arm's length of the shoulder and is gone beyond 100 (a gun hanging at the right hip is not reached by a hand
	-- through the chest). Between, the hand's target moves from where it is to the forend.
	local reach = a + b
	local w = math.Clamp((reach - S:Distance(target)) / (0.15 * reach), 0, 1)
	if w <= 0 then return end
	target = H0 + (target - H0) * w
	local to = target - S
	local d = to:Length()
	if d < 1 then return end
	local dd = math.Clamp(d, math.abs(a - b) + 0.5, a + b - 0.5)
	local u = to / d
	local x = (a * a - b * b + dd * dd) / (2 * dd)
	local h = math.sqrt(math.max(a * a - x * x, 0))
	-- The elbow bends where it bends now: its side of the line from the shoulder to the hand.
	local p0 = (E0 - S) - u * (E0 - S):Dot(u)
	if p0:Length() < 0.5 then p0 = -ent:GetUp() end
	local pole = p0:GetNormalized()
	local E = S + u * x + pole * h
	local H = S + u * dd
	-- Upper arm: its direction to the new elbow; the forearm goes with it, then turns about the elbow to reach the hand.
	local r1 = turn((E0 - S):GetNormalized(), (E - S):GetNormalized(), S)
	local H1 = r1 * H0
	local r2 = turn((H1 - E):GetNormalized(), (H - E):GetNormalized(), E)
	local R = r2 * r1
	-- The hand turns with the forearm; the fingers with the hand (what has no object of its own).
	local new = R * hm
	ent:SetBoneMatrix(ua, r1 * um)
	ent:SetBoneMatrix(fa, R * fm)
	ent:SetBoneMatrix(lh, new)
	local delta = new * hm:GetInverseTR()
	local under = { [lh] = true }
	for i = 0, ent:GetBoneCount() - 1 do
		local p = ent:GetBoneParent(i)
		if p and under[p] then
			under[i] = true
			local old = ent:GetBoneMatrix(i)
			if old then ent:SetBoneMatrix(i, delta * old) end
		end
	end
	curl(ent, "L")
end

hook.Add("PostDrawOpaqueRenderables", "DMR_Armed", function()
	for _, ent in ipairs(ents.FindByClass("prop_ragdoll")) do
		if ent:GetNW2String("DMR_GunModel", "") ~= "" or ent.DMR_GunCS then
			local cs = gunOf(ent)
			if cs and place(ent, cs) then
				cs:SetupBones()
				cs:DrawModel()
				-- A muzzle flash when the shot count moves.
				local n = ent:GetNW2Int("DMR_GunShot", 0)
				if n ~= ent.DMR_GunShotSeen then
					ent.DMR_GunShotSeen = n
					local id = cs:LookupAttachment("muzzle")
					local a = id > 0 and cs:GetAttachment(id)
					local at = a and a.Pos or cs:GetPos()
					local ed = EffectData()
					ed:SetEntity(cs)
					ed:SetAttachment(id > 0 and id or 1)
					ed:SetScale(1)
					util.Effect("MuzzleFlash", ed)
					local d = DynamicLight(ent:EntIndex())
					if d then
						d.pos, d.r, d.g, d.b, d.brightness, d.size, d.decay, d.dietime = at, 255, 180, 80, 3, 140, 2000, CurTime() + 0.08
					end
				end
			end
		end
	end
end)
