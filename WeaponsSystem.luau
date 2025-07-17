local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local IsServer = RunService:IsServer()

local WeaponData = script.Parent:WaitForChild("WeaponData")
local WeaponsSystemFolder = script.Parent
local WeaponTypes = WeaponsSystemFolder:WaitForChild("WeaponTypes")
local Libraries = WeaponsSystemFolder:WaitForChild("Libraries")
local ShoulderCamera = require(Libraries:WaitForChild("ShoulderCamera"))
local WeaponsGui = require(Libraries:WaitForChild("WeaponsGui"))
local SpringService = require(Libraries:WaitForChild("SpringService"))
local ancestorHasTag = require(Libraries:WaitForChild("ancestorHasTag"))
ShoulderCamera.SpringService = SpringService

local Configuration = WeaponsSystemFolder:WaitForChild("Configuration")
local ConfigurationValues = {
	SprintEnabled = Configuration:WaitForChild("SprintEnabled"),
	SlowZoomWalkEnabled = Configuration:WaitForChild("SlowZoomWalkEnabled"),
}

local WEAPON_TAG = "WeaponsSystemWeapon"
local WEAPON_TYPES_LOOKUP = {}

local REMOTE_EVENT_NAMES = {
	"WeaponFired",
	"WeaponHit",
	"WeaponReloadRequest",
	"WeaponReloaded",
	"WeaponReloadCanceled",
	"WeaponActivated"
}
local REMOTE_FUNCTION_NAMES = {}

do
	local function onNewWeaponType(weaponTypeModule)
		if not weaponTypeModule:IsA("ModuleScript") then
			return
		end
		local weaponTypeName = weaponTypeModule.Name
		xpcall(function()
			coroutine.wrap(function()
				local weaponType = require(weaponTypeModule)
				assert(typeof(weaponType) == "table", string.format("WeaponType \"%s\" did not return a valid table", weaponTypeModule:GetFullName()))
				WEAPON_TYPES_LOOKUP[weaponTypeName] = weaponType
			end)()
		end, function(errMsg)
			warn(string.format("Error while loading %s: %s", weaponTypeModule:GetFullName(), errMsg))
			warn(debug.traceback())
		end)
	end
	for _, child in pairs(WeaponTypes:GetChildren()) do
		onNewWeaponType(child)
	end
	WeaponTypes.ChildAdded:Connect(onNewWeaponType)
end

local WeaponsSystem = {}
WeaponsSystem.didSetup = false
WeaponsSystem.knownWeapons = {}
WeaponsSystem.connections = {}
WeaponsSystem.networkFolder = nil
WeaponsSystem.remoteEvents = {}
WeaponsSystem.remoteFunctions = {}
WeaponsSystem.currentWeapon = nil
WeaponsSystem.aimRayCallback = nil

WeaponsSystem.CurrentWeaponChanged = Instance.new("BindableEvent")

local NetworkingCallbacks = require(WeaponsSystemFolder:WaitForChild("NetworkingCallbacks"))
NetworkingCallbacks.WeaponsSystem = WeaponsSystem

local _damageCallback = nil
local _getTeamCallback = nil

function WeaponsSystem.setDamageCallback(cb)
	_damageCallback = cb
end

function WeaponsSystem.setGetTeamCallback(cb)
	_getTeamCallback = cb
end

function WeaponsSystem.setup()
	if WeaponsSystem.didSetup then
		warn("Warning: trying to run WeaponsSystem setup twice on the same module.")
		return
	end
	print(script.Parent:GetFullName(), "is now active.")

	WeaponsSystem.doingSetup = true

	if IsServer then
		local networkFolder = Instance.new("Folder")
		networkFolder.Name = "Network"

		for _, remoteEventName in pairs(REMOTE_EVENT_NAMES) do
			local remoteEvent = Instance.new("RemoteEvent")
			remoteEvent.Name = remoteEventName
			remoteEvent.Parent = networkFolder

			local callback = NetworkingCallbacks[remoteEventName]
			if not callback then
				warn("There is no server callback implemented for the WeaponsSystem RemoteEvent \"%s\"!")
				warn("A default no-op function will be implemented so that the queue cannot be abused.")
				callback = function() end
			end
			WeaponsSystem.connections[remoteEventName .. "Remote"] = remoteEvent.OnServerEvent:Connect(function(...)
				callback(...)
			end)
			WeaponsSystem.remoteEvents[remoteEventName] = remoteEvent
		end
		for _, remoteFuncName in pairs(REMOTE_FUNCTION_NAMES) do
			local remoteFunc = Instance.new("RemoteEvent")
			remoteFunc.Name = remoteFuncName
			remoteFunc.Parent = networkFolder

			local callback = NetworkingCallbacks[remoteFuncName]
			if not callback then
				warn("There is no server callback implemented for the WeaponsSystem RemoteFunction \"%s\"!")
				warn("A default no-op function will be implemented so that the queue cannot be abused.")
				callback = function() end
			end
			remoteFunc.OnServerInvoke = function(...)
				return callback(...)
			end
			WeaponsSystem.remoteFunctions[remoteFuncName] = remoteFunc
		end

		networkFolder.Parent = WeaponsSystemFolder
		WeaponsSystem.networkFolder = networkFolder
	else
		WeaponsSystem.StarterGui = game:GetService("StarterGui")

		WeaponsSystem.camera = ShoulderCamera.new(WeaponsSystem)
		WeaponsSystem.gui = WeaponsGui.new(WeaponsSystem)

		if ConfigurationValues.SprintEnabled.Value then
			WeaponsSystem.camera:setSprintEnabled(ConfigurationValues.SprintEnabled.Value)
		end

		if ConfigurationValues.SlowZoomWalkEnabled.Value then
			WeaponsSystem.camera:setSlowZoomWalkEnabled(ConfigurationValues.SlowZoomWalkEnabled.Value)
		end

		local networkFolder = WeaponsSystemFolder:WaitForChild("Network", math.huge)

		for _, remoteEventName in pairs(REMOTE_EVENT_NAMES) do
			coroutine.wrap(function()
				local remoteEvent = networkFolder:WaitForChild(remoteEventName, math.huge)
				local callback = NetworkingCallbacks[remoteEventName]
				if callback then
					WeaponsSystem.connections[remoteEventName .. "Remote"] = remoteEvent.OnClientEvent:Connect(function(...)
						callback(...)
					end)
				end
				WeaponsSystem.remoteEvents[remoteEventName] = remoteEvent
			end)()
		end
		for _, remoteFuncName in pairs(REMOTE_FUNCTION_NAMES) do
			coroutine.wrap(function()
				local remoteFunc = networkFolder:WaitForChild(remoteFuncName, math.huge)
				local callback = NetworkingCallbacks[remoteFuncName]
				if callback then
					remoteFunc.OnClientInvoke = function(...)
						return callback(...)
					end
				end
				WeaponsSystem.remoteFunctions[remoteFuncName] = remoteFunc
			end)()
		end

		Players.LocalPlayer.CharacterAdded:Connect(WeaponsSystem.onCharacterAdded)
		if Players.LocalPlayer.Character then
			WeaponsSystem.onCharacterAdded(Players.LocalPlayer.Character)
		end

		WeaponsSystem.networkFolder = networkFolder
		WeaponsSystem.camera:setEnabled(false)
	end

	WeaponsSystem.connections.weaponAdded = CollectionService:GetInstanceAddedSignal(WEAPON_TAG):Connect(WeaponsSystem.onWeaponAdded)
	WeaponsSystem.connections.weaponRemoved = CollectionService:GetInstanceRemovedSignal(WEAPON_TAG):Connect(WeaponsSystem.onWeaponRemoved)

	for _, instance in pairs(CollectionService:GetTagged(WEAPON_TAG)) do
		WeaponsSystem.onWeaponAdded(instance)
	end

	WeaponsSystem.doingSetup = false
	WeaponsSystem.didSetup = true
end

function WeaponsSystem.onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")
	WeaponsSystem.connections.seated = humanoid.Seated:Connect(function(isSeated)
		if isSeated then
			WeaponsSystem.seatedWeapon = character:FindFirstChildOfClass("Tool")
			humanoid:UnequipTools()
			WeaponsSystem.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		else
			WeaponsSystem.StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
			humanoid:EquipTool(WeaponsSystem.seatedWeapon)
		end
	end)
end

function WeaponsSystem.shutdown()
	if not WeaponsSystem.didSetup then
		return
	end

	for _, weapon in pairs(WeaponsSystem.knownWeapons) do
		weapon:onDestroyed()
	end
	WeaponsSystem.knownWeapons = {}

	if IsServer and WeaponsSystem.networkFolder then
		WeaponsSystem.networkFolder:Destroy()
	end
	WeaponsSystem.networkFolder = nil
	WeaponsSystem.remoteEvents = {}
	WeaponsSystem.remoteFunctions = {}

	for _, connection in pairs(WeaponsSystem.connections) do
		if typeof(connection) == "RBXScriptConnection" then
			connection:Disconnect()
		end
	end
	WeaponsSystem.connections = {}
end

function WeaponsSystem.getWeaponTypeFromTags(instance)
	for _, tag in pairs(CollectionService:GetTags(instance)) do
		local weaponTypeFound = WEAPON_TYPES_LOOKUP[tag]
		if weaponTypeFound then
			return weaponTypeFound
		end
	end

	return nil
end

function WeaponsSystem.createWeaponForInstance(weaponInstance)
	coroutine.wrap(function()
		local weaponType = WeaponsSystem.getWeaponTypeFromTags(weaponInstance)
		if not weaponType then
			local weaponTypeObj = weaponInstance:WaitForChild("WeaponType")

			if weaponTypeObj and weaponTypeObj:IsA("StringValue") then
				local weaponTypeName = weaponTypeObj.Value
				local weaponTypeFound = WEAPON_TYPES_LOOKUP[weaponTypeName]
				if not weaponTypeFound then
					warn(string.format("Cannot find the weapon type \"%s\" for the instance %s!", weaponTypeName, weaponInstance:GetFullName()))
					return
				end

				weaponType = weaponTypeFound
			else
				warn("Could not find a WeaponType tag or StringValue for the instance ", weaponInstance:GetFullName())
				return
			end
		end

		if WeaponsSystem.getWeaponForInstance(weaponInstance) then
			warn("Already got ", weaponInstance:GetFullName())
			warn(debug.traceback())
			return
		end

		assert(weaponType, "Got invalid weaponType")

		local weapon = weaponType.new(WeaponsSystem, weaponInstance)
		WeaponsSystem.knownWeapons[weaponInstance] = weapon
	end)()
end

function WeaponsSystem.getWeaponForInstance(weaponInstance)
	if not typeof(weaponInstance) == "Instance" then
		warn("WeaponsSystem.getWeaponForInstance(weaponInstance): 'weaponInstance' was not an instance.")
		return nil
	end

	return WeaponsSystem.knownWeapons[weaponInstance]
end

function WeaponsSystem.onWeaponAdded(weaponInstance)
	local weapon = WeaponsSystem.getWeaponForInstance(weaponInstance)
	if not weapon then
		WeaponsSystem.createWeaponForInstance(weaponInstance)
	end
end

function WeaponsSystem.onWeaponRemoved(weaponInstance)
	local weapon = WeaponsSystem.getWeaponForInstance(weaponInstance)
	if weapon then
		weapon:onDestroyed()
	end
	WeaponsSystem.knownWeapons[weaponInstance] = nil
end

function WeaponsSystem.getRemoteEvent(name)
	if not WeaponsSystem.networkFolder then
		return
	end

	local remoteEvent = WeaponsSystem.remoteEvents[name]
	if IsServer then
		if not remoteEvent then
			warn("No RemoteEvent named ", name)
			return nil
		end

		return remoteEvent
	else
		if not remoteEvent then
			remoteEvent = WeaponsSystem.networkFolder:WaitForChild(name, math.huge)
		end

		return remoteEvent
	end
end

function WeaponsSystem.getRemoteFunction(name)
	if not WeaponsSystem.networkFolder then
		return
	end

	local remoteFunc = WeaponsSystem.remoteFunctions[name]
	if IsServer then
		if not remoteFunc then
			warn("No RemoteFunction named ", name)
			return nil
		end

		return remoteFunc
	else
		if not remoteFunc then
			remoteFunc = WeaponsSystem.networkFolder:WaitForChild(name, math.huge)
		end

		return remoteFunc
	end
end

--||Fixed Camera Reset Issue||--
function WeaponsSystem.setWeaponEquipped(weapon, equipped)
	assert(not IsServer, "WeaponsSystem.setWeaponEquipped should only be called on the client.")
	if not weapon then
		return
	end

	local lastWeapon = WeaponsSystem.currentWeapon
	local hasWeapon = false
	local weaponChanged = false

	if lastWeapon == weapon then
		if not equipped then
			WeaponsSystem.currentWeapon = nil
			hasWeapon = false
			weaponChanged = true
		else
			weaponChanged = false
		end
	else
		if equipped then
			WeaponsSystem.currentWeapon = weapon
			hasWeapon = true
			weaponChanged = true
		end
	end

	--||Camera System Reset||--
	if WeaponsSystem.camera then
		-- Disable camera first to prevent interpolation issues
		WeaponsSystem.camera:setEnabled(false)

		-- Reset camera settings while disabled
		WeaponsSystem.camera:resetZoomFactor()
		WeaponsSystem.camera:setHasScope(false)

		-- Re-enable and configure if weapon equipped
		if hasWeapon then
			WeaponsSystem.camera:setEnabled(true)

			if WeaponsSystem.currentWeapon then
				WeaponsSystem.camera:setZoomFactor(WeaponsSystem.currentWeapon:getConfigValue("ZoomFactor", 1.1))
				WeaponsSystem.camera:setHasScope(WeaponsSystem.currentWeapon:getConfigValue("HasScope", false))
			end
		end
	end

	if WeaponsSystem.gui then
		WeaponsSystem.gui:setEnabled(hasWeapon)

		if WeaponsSystem.currentWeapon then
			WeaponsSystem.gui:setCrosshairWeaponScale(WeaponsSystem.currentWeapon:getConfigValue("CrosshairScale", 1))
		else
			WeaponsSystem.gui:setCrosshairWeaponScale(1)
		end
	end

	if weaponChanged then
		WeaponsSystem.CurrentWeaponChanged:Fire(weapon.instance, lastWeapon and lastWeapon.instance)
	end
end

function WeaponsSystem.getHumanoid(part)
	while part and part ~= workspace do
		if part:IsA("Model") and part.PrimaryPart and part.PrimaryPart.Name == "HumanoidRootPart" then
			return part:FindFirstChildOfClass("Humanoid")
		end

		part = part.Parent
	end
end

function WeaponsSystem.getPlayerFromHumanoid(humanoid)
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character and humanoid:IsDescendantOf(player.Character) then
			return player
		end
	end
end

--||Ragdoll-Only Damage System||--
local function _ragdollOnlyDamageCallback(system, target, amount, damageType, dealer, hitInfo, damageData)
	if target and target:IsA("Humanoid") and target.Health > 0 then
		local character = target.Parent
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local dealerPlayer = dealer

		if humanoid and dealerPlayer and dealerPlayer:IsA("Player") then
			local targetPlayer = WeaponsSystem.getPlayerFromHumanoid(humanoid)

			if WeaponsSystem.playersOnDifferentTeams(dealerPlayer, targetPlayer) then
				humanoid:ChangeState(Enum.HumanoidStateType.Physics)

				local rootPart = character:FindFirstChild("HumanoidRootPart")
				if rootPart and hitInfo and hitInfo.p then
					local knockbackForce = 50
					local knockbackDirection = (rootPart.Position - hitInfo.p).Unit + Vector3.new(0, 0.3, 0)

					local bodyVelocity = Instance.new("BodyVelocity")
					bodyVelocity.MaxForce = Vector3.new(4000, 4000, 4000)
					bodyVelocity.Velocity = knockbackDirection * knockbackForce
					bodyVelocity.Parent = rootPart

					game:GetService("Debris"):AddItem(bodyVelocity, 0.5)

					task.spawn(function()
						task.wait(3)
						if humanoid and humanoid.Parent and humanoid.Health > 0 then
							humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
						end
					end)
				end
			end
		end
	end
end

function WeaponsSystem.doDamage(target, amount, damageType, dealer, hitInfo, damageData)
	if not target or ancestorHasTag(target, "WeaponsSystemIgnore") then
		return
	end

	if IsServer then
		if target:IsA("Humanoid") and dealer:IsA("Player") and dealer.Character then
			local dealerHumanoid = dealer.Character:FindFirstChildOfClass("Humanoid")
			local targetPlayer = Players:GetPlayerFromCharacter(target.Parent)
			if dealerHumanoid and target ~= dealerHumanoid and targetPlayer then
				WeaponData:FireClient(targetPlayer, "HitByOtherPlayer", dealer.Character.HumanoidRootPart.CFrame.Position)
			end
		end

		local handler = _damageCallback or _ragdollOnlyDamageCallback
		handler(WeaponsSystem, target, amount, damageType, dealer, hitInfo, damageData)
	end
end

local function _defaultGetTeamCallback(player)
	return 0
end

function WeaponsSystem.getTeam(player)
	local handler = _getTeamCallback or _defaultGetTeamCallback
	return handler(player)
end

function WeaponsSystem.playersOnDifferentTeams(player1, player2)
	if player1 == player2 or player1 == nil or player2 == nil then
		return true
	end

	local player1Team = WeaponsSystem.getTeam(player1)
	local player2Team = WeaponsSystem.getTeam(player2)
	return player1Team == 0 or player1Team ~= player2Team
end

return WeaponsSystem
