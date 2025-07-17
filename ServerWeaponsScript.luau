local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local curWeaponsSystemFolder = script.Parent
local weaponsSystemFolder = ReplicatedStorage:FindFirstChild("WeaponsSystem")
local weaponsSystemInitialized = false

local function initializeWeaponsSystemAssets()
	if not weaponsSystemInitialized then
		local effectsFolder = weaponsSystemFolder.Assets.Effects
		local partNonZeroTransparencyValues = {
			["BulletHole"] = 1, ["Explosion"] = 1, ["Pellet"] = 1, ["Scorch"] = 1,
			["Bullet"] = 1, ["Plasma"] = 1, ["Railgun"] = 1,
		}
		local decalNonZeroTransparencyValues = { ["ScorchMark"] = 0.25 }
		local particleEmittersToDisable = { ["Smoke"] = true }
		local imageLabelNonZeroTransparencyValues = { ["Impact"] = 0.25 }
		for _, descendant in pairs(effectsFolder:GetDescendants()) do
			if descendant:IsA("BasePart") then
				if partNonZeroTransparencyValues[descendant.Name] ~= nil then
					descendant.Transparency = partNonZeroTransparencyValues[descendant.Name]
				else
					descendant.Transparency = 0
				end
			elseif descendant:IsA("Decal") then
				descendant.Transparency = 0
				if decalNonZeroTransparencyValues[descendant.Name] ~= nil then
					descendant.Transparency = decalNonZeroTransparencyValues[descendant.Name]
				else
					descendant.Transparency = 0
				end
			elseif descendant:IsA("ParticleEmitter") then
				descendant.Enabled = true
				if particleEmittersToDisable[descendant.Name] ~= nil then
					descendant.Enabled = false
				else
					descendant.Enabled = true
				end
			elseif descendant:IsA("ImageLabel") then
				if imageLabelNonZeroTransparencyValues[descendant.Name] ~= nil then
					descendant.ImageTransparency = imageLabelNonZeroTransparencyValues[descendant.Name]
				else
					descendant.ImageTransparency = 0
				end
			end
		end
		weaponsSystemInitialized = true
	end
end

if weaponsSystemFolder == nil then
	weaponsSystemFolder = curWeaponsSystemFolder:Clone()
	initializeWeaponsSystemAssets()
	weaponsSystemFolder.Parent = ReplicatedStorage
end

if ServerScriptService:FindFirstChild("ServerWeaponsScript") == nil then
	script.Parent = ServerScriptService
	initializeWeaponsSystemAssets()
	local WeaponsSystem = require(weaponsSystemFolder.WeaponsSystem)
	if not WeaponsSystem.doingSetup and not WeaponsSystem.didSetup then
		WeaponsSystem.setup()
	end

	print("Setting up sniper ragdoll system...")

	--||Override BulletWeapon onHit to add damage + sniper ragdoll||--
	local BulletWeapon = require(weaponsSystemFolder.WeaponTypes.BulletWeapon)
	local originalOnHit = BulletWeapon.onHit

	BulletWeapon.onHit = function(self, hitInfo)
		-- Call original onHit first (handles visual effects, sounds, etc)
		if originalOnHit then
			originalOnHit(self, hitInfo)
		end

		-- Add damage system call
		local hitPart = hitInfo.part
		if hitPart and hitPart.Parent then
			local humanoid = self.weaponsSystem.getHumanoid(hitPart)
			if humanoid then
				-- Get damage from weapon config
				local damage = self:getConfigValue("Damage", 50)

				-- Call damage system
				WeaponsSystem.doDamage(humanoid, damage, "bullet", self.player, hitInfo, {weapon = self})
			end
		end
	end

	--||Hook into the damage system||--
	local originalDoDamage = WeaponsSystem.doDamage
	WeaponsSystem.doDamage = function(target, amount, damageType, dealer, hitInfo, damageData)
		-- Check if dealer has sniper equipped
		local isSniper = false
		if dealer and dealer.Character then
			local tool = dealer.Character:FindFirstChildOfClass("Tool")
			if tool and (tool.Name == "Sniper" or tool.Name:find("Sniper")) then
				isSniper = true
			end
		end

		-- Call original damage function first
		if originalDoDamage then
			originalDoDamage(target, amount, damageType, dealer, hitInfo, damageData)
		end

		-- Apply enhanced sniper ragdoll if sniper hit
		if isSniper and target and target:IsA("Humanoid") and target.Health > 0 then
			local character = target.Parent
			local ragdollConstraints = character:FindFirstChild("RagdollConstraints")
			local hasRagdollTag = CollectionService:HasTag(target, "Ragdoll")

			task.spawn(function()
				-- Force ragdoll manually
				target.PlatformStand = true
				task.wait(0.05)
				target:ChangeState(Enum.HumanoidStateType.Physics)

				-- Manually trigger ragdoll constraints
				local ragdollConstraints = character:FindFirstChild("RagdollConstraints")
				if ragdollConstraints then
					for _, constraint in pairs(ragdollConstraints:GetChildren()) do
						if constraint:IsA("Constraint") and constraint:FindFirstChild("RigidJoint") then
							local rigidJoint = constraint.RigidJoint.Value
							if rigidJoint then
								rigidJoint.Part1 = nil
							end
						end
					end
				end

				-- Add enhanced sniper knockback
				local rootPart = character:FindFirstChild("HumanoidRootPart")
				if rootPart and dealer and dealer.Character and dealer.Character:FindFirstChild("HumanoidRootPart") then
					local shooterPos = dealer.Character.HumanoidRootPart.Position
					local targetPos = rootPart.Position
					local knockbackDirection = (targetPos - shooterPos).Unit

					-- Stronger knockback for sniper
					local bodyVelocity = Instance.new("BodyVelocity")
					bodyVelocity.MaxForce = Vector3.new(6000, 2000, 6000)
					bodyVelocity.Velocity = knockbackDirection * 75 + Vector3.new(0, 35, 0)
					bodyVelocity.Parent = rootPart

					game:GetService("Debris"):AddItem(bodyVelocity, 0.6)
				end

				-- Longer ragdoll time for sniper
				task.wait(5)
				if target and target.Parent and target.Health > 0 then
					target.PlatformStand = false
					target:ChangeState(Enum.HumanoidStateType.Freefall)
				end
			end)
		end
	end

	print("Sniper ragdoll system setup complete!")

	local function setupClientWeaponsScript(player)
		local clientWeaponsScript = player.PlayerGui:FindFirstChild("ClientWeaponsScript")
		if clientWeaponsScript == nil then
			clientWeaponsScript = weaponsSystemFolder.ClientWeaponsScript:Clone()
			clientWeaponsScript.Parent = player.PlayerGui
		end
	end

	Players.PlayerAdded:Connect(function(player)
		setupClientWeaponsScript(player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		setupClientWeaponsScript(player)
	end
end

if curWeaponsSystemFolder.Name == "WeaponsSystem" then
	curWeaponsSystemFolder:Destroy()
end
