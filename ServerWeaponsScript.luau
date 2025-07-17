local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
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

	--||Hook into the existing damage system||--
	local originalDoDamage = WeaponsSystem.doDamage
	WeaponsSystem.doDamage = function(target, amount, damageType, dealer, hitInfo, damageData)
		print("DAMAGE DETECTED:", amount, "to", target and target.Parent and target.Parent.Name or "unknown")

		-- Check if dealer has sniper equipped
		local isSniper = false
		if dealer and dealer.Character then
			local tool = dealer.Character:FindFirstChildOfClass("Tool")
			if tool and (tool.Name == "Sniper" or tool.Name:find("Sniper")) then
				isSniper = true
				print("SNIPER DAMAGE DETECTED!")
			end
		end

		-- Call original damage function first
		if originalDoDamage then
			originalDoDamage(target, amount, damageType, dealer, hitInfo, damageData)
		end

		-- Apply ragdoll if sniper hit
		if isSniper and target and target:IsA("Humanoid") and target.Health > 0 then
			print("APPLYING SNIPER RAGDOLL to:", target.Parent.Name)

			task.spawn(function()
				-- Set to physics state
				target:ChangeState(Enum.HumanoidStateType.Physics)

				-- Add extra knockback
				local character = target.Parent
				local rootPart = character:FindFirstChild("HumanoidRootPart")
				if rootPart and dealer and dealer.Character and dealer.Character:FindFirstChild("HumanoidRootPart") then
					local shooterPos = dealer.Character.HumanoidRootPart.Position
					local targetPos = rootPart.Position
					local knockbackDirection = (targetPos - shooterPos).Unit

					local bodyVelocity = Instance.new("BodyVelocity")
					bodyVelocity.MaxForce = Vector3.new(4000, 1000, 4000)
					bodyVelocity.Velocity = knockbackDirection * 50 + Vector3.new(0, 25, 0)
					bodyVelocity.Parent = rootPart

					game:GetService("Debris"):AddItem(bodyVelocity, 0.4)
				end

				-- Recovery after time
				task.wait(3)
				if target.Health > 0 then
					print("Recovering from sniper ragdoll...")
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
