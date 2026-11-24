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
	local pos, ang = m:GetTranslation(), m:GetAngles()
	pos = pos + ang:Forward() * cv.fwd:GetFloat() + ang:Right() * cv.right:GetFloat() + ang:Up() * cv.up:GetFloat()
	ang:RotateAroundAxis(ang:Right(), cv.pitch:GetFloat())
	ang:RotateAroundAxis(ang:Up(), cv.yaw:GetFloat())
	ang:RotateAroundAxis(ang:Forward(), cv.roll:GetFloat())
	cs:SetPos(pos)
	cs:SetAngles(ang)
	return true
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
