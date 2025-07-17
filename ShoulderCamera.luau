local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local UserGameSettings = UserSettings():GetService("UserGameSettings")

local LocalPlayer = Players.LocalPlayer
if RunService:IsClient() then
	while not LocalPlayer do
		Players.PlayerAdded:Wait()
		LocalPlayer = Players.LocalPlayer
	end
end
local Settings = UserSettings()
local GameSettings = Settings.GameSettings

local CAMERA_RENDERSTEP_NAME = "ShoulderCameraUpdate"
local ZOOM_ACTION_NAME = "ShoulderCameraZoom"
local SPRINT_ACTION_NAME = "ShoulderCameraSprint"

--||Updated Controllable States - Excludes Ragdoll States||--
local CONTROLLABLE_HUMANOID_STATES = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Freefall] = true,
	[Enum.HumanoidStateType.Jumping] = true,
	[Enum.HumanoidStateType.Swimming] = false,
	[Enum.HumanoidStateType.Landed] = true,
	-- Explicitly exclude ragdoll/dead states
	[Enum.HumanoidStateType.Dead] = false,
	[Enum.HumanoidStateType.Physics] = false,
	[Enum.HumanoidStateType.PlatformStanding] = false,
}

-- Gamepad thumbstick utilities
local k = 0.5
local lowerK = 0.9
local function SCurveTransform(t)
	t = math.clamp(t, -1,1)
	if t >= 0 then
		return (k*t) / (k - t + 1)
	end
	return -((lowerK*-t) / (lowerK + t + 1))
end

local DEADZONE = 0.25
local function toSCurveSpace(t)
	return (1 + DEADZONE) * (2*math.abs(t) - 1) - DEADZONE
end

local function fromSCurveSpace(t)
	return t/2 + 0.5
end

local function gamepadLinearToCurve(thumbstickPosition)
	return Vector2.new(
		math.clamp(math.sign(thumbstickPosition.X) * fromSCurveSpace(SCurveTransform(toSCurveSpace(math.abs(thumbstickPosition.X)))), -1, 1),
		math.clamp(math.sign(thumbstickPosition.Y) * fromSCurveSpace(SCurveTransform(toSCurveSpace(math.abs(thumbstickPosition.Y)))), -1, 1))
end

local function isBackAccessory(instance)
	if instance and instance:IsA("Accessory") then
		local handle = instance:WaitForChild("Handle", 5)
		if handle and handle:IsA("Part") then
			local bodyBackAttachment = handle:WaitForChild("BodyBackAttachment", 5)
			if bodyBackAttachment and bodyBackAttachment:IsA("Attachment") then
				return true
			end

			local waistBackAttachment = handle:WaitForChild("WaistBackAttachment", 5)
			if waistBackAttachment and waistBackAttachment:IsA("Attachment") then
				return true
			end
		end
	end

	return false
end

local function removeBackAccessoriesFromCharacter(character)
	for _, child in ipairs(character:GetChildren()) do
		coroutine.wrap(function()
			if isBackAccessory(child) then
				child:Destroy()
			end
		end)()
	end
end

local descendantAddedConnection = nil
local function onCharacterAdded(character)
	removeBackAccessoriesFromCharacter(character)
	descendantAddedConnection = character.DescendantAdded:Connect(function(descendant)
		coroutine.wrap(function()
			if isBackAccessory(descendant) then
				descendant:Destroy()
			end
		end)()
	end)
end

local function onCharacterRemoving(character)
	if descendantAddedConnection then
		descendantAddedConnection:Disconnect()
		descendantAddedConnection = nil
	end
end

if RunService:IsClient() then
	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
	LocalPlayer.CharacterRemoving:Connect(onCharacterRemoving)
end

local ShoulderCamera = {}
ShoulderCamera.__index = ShoulderCamera
ShoulderCamera.SpringService = nil

function ShoulderCamera.new(weaponsSystem)
	local self = setmetatable({}, ShoulderCamera)
	self.weaponsSystem = weaponsSystem

	self.fieldOfView = 70
	self.minPitch = math.rad(-75)
	self.maxPitch = math.rad(75)
	self.normalOffset = Vector3.new(2.25, 2.25, 10.5)
	self.zoomedOffsetDistance = 8
	self.normalCrosshairScale = 1
	self.zoomedCrosshairScale = 0.75
	self.defaultZoomFactor = 1
	self.canZoom = true
	self.zoomInputs = { Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2 }
	self.sprintInputs = { Enum.KeyCode.LeftShift }
	self.mouseRadsPerPixel = Vector2.new(1 / 480, 1 / 480)
	self.zoomedMouseRadsPerPixel = Vector2.new(1 / 1200, 1 / 1200)
	self.touchSensitivity = Vector2.new(1 / 100, 1 / 100)
	self.zoomedTouchSensitivity = Vector2.new(1 / 200, 1 / 200)
	self.touchDelayTime = 0.25
	self.recoilDecay = 2
	self.rotateCharacterWithCamera = true
	self.gamepadSensitivityModifier = Vector2.new(0.85, 0.65)
	self.zoomWalkSpeed = 16
	self.normalWalkSpeed = 16
	self.sprintingWalkSpeed = 24

	self.enabled = false
	self.yaw = 0
	self.pitch = 0
	self.currentCFrame = CFrame.new()
	self.currentOffset = self.normalOffset
	self.currentRecoil = Vector2.new(0, 0)
	self.currentMouseRadsPerPixel = self.mouseRadsPerPixel
	self.currentTouchSensitivity = self.touchSensitivity
	self.mouseLocked = true
	self.touchPanAccumulator = Vector2.new(0, 0)
	self.currentTool = nil
	self.sprintingInputActivated = false
	self.desiredWalkSpeed = self.normalWalkSpeed
	self.sprintEnabled = false
	self.slowZoomWalkEnabled = false
	self.desiredFieldOfView = self.fieldOfView
	self.zoomedFromInput = false
	self.forcedZoomed = false
	self.zoomState = false
	self.zoomAlpha = 0
	self.hasScope = false
	self.hideToolWhileZoomed = false
	self.currentZoomFactor = self.defaultZoomFactor
	self.zoomedFOV = self.fieldOfView
	self.gamepadPan = Vector2.new(0, 0)
	self.movementPan = Vector2.new(0, 0)
	self.lastThumbstickPos = Vector2.new(0, 0)
	self.lastThumbstickTime = nil
	self.currentGamepadSpeed = 0
	self.lastGamepadVelocity = Vector2.new(0, 0)

	self.lastOcclusionDistance = 0
	self.lastOcclusionReachedTime = 0
	self.defaultTimeUntilZoomOut = 0
	self.timeUntilZoomOut = self.defaultTimeUntilZoomOut
	self.timeLastPoppedWayIn = 0
	self.isZoomingOut = false
	self.tweenOutTime = 0.2
	self.curOcclusionTween = nil
	self.occlusionTweenObject = nil

	self.sideCorrectionGoalVector = nil
	self.lastSideCorrectionMagnitude = 0
	self.lastSideCorrectionReachedTime = 0
	self.revertSideCorrectionSpeedMultiplier = 2
	self.defaultTimeUntilRevertSideCorrection = 0.75
	self.timeUntilRevertSideCorrection = self.defaultTimeUntilRevertSideCorrection
	self.isRevertingSideCorrection = false

	self.originalCameraType = nil
	self.originalCameraSubject = nil
	self.originalFieldOfView = nil
	self.originalRootJointC0 = nil

	self.eventConnections = {}
	self.raycastIgnoreList = {}
	self.currentCamera = nil
	self.currentCharacter = nil
	self.currentHumanoid = nil
	self.currentRootPart = nil
	self.controlModule = nil
	self.random = Random.new()

	return self
end

function ShoulderCamera:setEnabled(enabled)
	if self.enabled == enabled then
		return
	end
	self.enabled = enabled

	if self.enabled then
		if self.currentCamera then
			self.originalCameraType = self.currentCamera.CameraType
			self.originalCameraSubject = self.currentCamera.CameraSubject
			self.originalFieldOfView = self.currentCamera.FieldOfView
		end

		RunService:BindToRenderStep(CAMERA_RENDERSTEP_NAME, Enum.RenderPriority.Camera.Value - 1, function(dt) self:onRenderStep(dt) end)
		ContextActionService:BindAction(ZOOM_ACTION_NAME, function(...) self:onZoomAction(...) end, false, unpack(self.zoomInputs))
		ContextActionService:BindAction(SPRINT_ACTION_NAME, function(...) self:onSprintAction(...) end, false, unpack(self.sprintInputs))

		table.insert(self.eventConnections, LocalPlayer.CharacterAdded:Connect(function(character) self:onCurrentCharacterChanged(character) end))
		table.insert(self.eventConnections, LocalPlayer.CharacterRemoving:Connect(function() self:onCurrentCharacterChanged(nil) end))
		table.insert(self.eventConnections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function() self:onCurrentCameraChanged(workspace.CurrentCamera) end))
		table.insert(self.eventConnections, UserInputService.InputBegan:Connect(function(inputObj, wasProcessed) self:onInputBegan(inputObj, wasProcessed) end))
		table.insert(self.eventConnections, UserInputService.InputChanged:Connect(function(inputObj, wasProcessed) self:onInputChanged(inputObj, wasProcessed) end))
		table.insert(self.eventConnections, UserInputService.InputEnded:Connect(function(inputObj, wasProcessed) self:onInputEnded(inputObj, wasProcessed) end))

		self:onCurrentCharacterChanged(LocalPlayer.Character)
		self:onCurrentCameraChanged(workspace.CurrentCamera)

		local cameraLook = self.currentCamera.CFrame.lookVector
		self.yaw = math.atan2(-cameraLook.X, -cameraLook.Z)
		self.pitch = math.asin(cameraLook.Y)

		self.currentCamera.CameraType = Enum.CameraType.Scriptable

		self:setZoomFactor(self.currentZoomFactor)

		workspace.CurrentCamera.CameraSubject = self.currentRootPart

		self.occlusionTweenObject = Instance.new("NumberValue")
		self.occlusionTweenObject.Name = "OcclusionTweenObject"
		self.occlusionTweenObject.Parent = script
		self.occlusionTweenObject.Changed:Connect(function(value)
			self.lastOcclusionDistance = value
		end)

		self.weaponsSystem.aimRayCallback = function()
			local cameraCFrame = self.currentCFrame
			return Ray.new(cameraCFrame.p, cameraCFrame.LookVector * 500)
		end
	else
		RunService:UnbindFromRenderStep(CAMERA_RENDERSTEP_NAME)
		ContextActionService:UnbindAction(ZOOM_ACTION_NAME)
		ContextActionService:UnbindAction(SPRINT_ACTION_NAME)

		if self.currentHumanoid then
			self.currentHumanoid.AutoRotate = true
		end

		--||Restore Original Joint States||--
		if self.rootJoint and self.originalRootJointC0 then
			self.rootJoint.C0 = self.originalRootJointC0
		end

		if self.currentCamera then
			self.currentCamera.CameraType = Enum.CameraType.Custom

			if self.currentHumanoid then
				self.currentCamera.CameraSubject = self.currentHumanoid
			end

			if self.originalFieldOfView then
				self.currentCamera.FieldOfView = self.originalFieldOfView
			else
				self.currentCamera.FieldOfView = 70
			end
		end

		self:updateZoomState()

		self.yaw = 0
		self.pitch = 0

		for _, conn in pairs(self.eventConnections) do
			conn:Disconnect()
		end
		self.eventConnections = {}

		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true

		self.originalCameraType = nil
		self.originalCameraSubject = nil
		self.originalFieldOfView = nil
		self.originalRootJointC0 = nil
	end
end

function ShoulderCamera:onRenderStep(dt)
	if not self.enabled or
		not self.currentCamera or
		not self.currentCharacter or
		not self.currentHumanoid or
		not self.currentRootPart
	then
		return
	end

	--||Early Exit for Ragdoll States||--
	if not self:isHumanoidControllable() then
		-- Don't try to control character when ragdolled/dead
		return
	end

	if self.mouseLocked and not GuiService:GetEmotesMenuOpen() then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end

	self:processGamepadInput(dt)

	if self.hasScope then
		ShoulderCamera.SpringService:Target(self, 0.8, 8, { zoomAlpha = self.zoomState and 1 or 0 })
		ShoulderCamera.SpringService:Target(self.currentCamera, 0.8, 8, { FieldOfView = self.desiredFieldOfView })
	else
		ShoulderCamera.SpringService:Target(self, 0.8, 3, { zoomAlpha = self.zoomState and 1 or 0 })
		ShoulderCamera.SpringService:Target(self.currentCamera, 0.8, 3, { FieldOfView = self.desiredFieldOfView })
	end

	if self.sprintEnabled or self.slowZoomWalkEnabled then
		self.desiredWalkSpeed = self.normalWalkSpeed
		if self.sprintEnabled and (self.sprintingInputActivated or self:sprintFromTouchInput() or self:sprintFromGamepadInput()) and not self.zoomState then
			self.desiredWalkSpeed = self.sprintingWalkSpeed
		end
		if self.slowZoomWalkEnabled and self.zoomAlpha > 0.1 then
			self.desiredWalkSpeed = self.zoomWalkSpeed
		end

		ShoulderCamera.SpringService:Target(self.currentHumanoid, 0.95, 4, { WalkSpeed = self.desiredWalkSpeed })
	end

	local rootPartPos = self.currentRootPart.CFrame.Position
	local rootPartUnrotatedCFrame = CFrame.new(rootPartPos)
	local yawRotation = CFrame.Angles(0, self.yaw, 0)
	local pitchRotation = CFrame.Angles(self.pitch + self.currentRecoil.Y, 0, 0)
	local xOffset = CFrame.new(self.normalOffset.X, 0, 0)
	local yOffset = CFrame.new(0, self.normalOffset.Y, 0)
	local zOffset = CFrame.new(0, 0, self.normalOffset.Z)
	local collisionRadius = self:getCollisionRadius()
	local cameraYawRotationAndXOffset =
		yawRotation * 		
		xOffset 			
	local cameraFocus = rootPartUnrotatedCFrame * cameraYawRotationAndXOffset

	local vecToFocus = cameraFocus.p - rootPartPos
	local rayToFocus = Ray.new(rootPartPos, vecToFocus + (vecToFocus.Unit * collisionRadius))
	local hitPart, hitPoint, hitNormal = self:penetrateCast(rayToFocus, self.raycastIgnoreList)
	local currentTime = tick()
	local sideCorrectionGoalVector = Vector3.new()
	if hitPart then
		hitPoint = hitPoint + (hitNormal * collisionRadius)
		sideCorrectionGoalVector = hitPoint - cameraFocus.p
		if sideCorrectionGoalVector.Magnitude >= self.lastSideCorrectionMagnitude then
			if currentTime > self.lastSideCorrectionReachedTime + self.timeUntilRevertSideCorrection and self.lastSideCorrectionMagnitude ~= 0 then
				self.timeUntilRevertSideCorrection = self.defaultTimeUntilRevertSideCorrection * 2
			elseif self.lastSideCorrectionMagnitude == 0 and self.timeUntilRevertSideCorrection ~= self.defaultTimeUntilRevertSideCorrection then
				self.timeUntilRevertSideCorrection = self.defaultTimeUntilRevertSideCorrection
			end
			self.lastSideCorrectionMagnitude = sideCorrectionGoalVector.Magnitude
			self.lastSideCorrectionReachedTime = currentTime
			self.isRevertingSideCorrection = false
		else
			self.isRevertingSideCorrection = true
		end
	elseif self.lastSideCorrectionMagnitude ~= 0 then
		self.isRevertingSideCorrection = true
	end
	if self.isRevertingSideCorrection then
		if sideCorrectionGoalVector.Magnitude > self.lastSideCorrectionMagnitude - 1 and sideCorrectionGoalVector.Magnitude ~= 0 then
			self.lastSideCorrectionReachedTime = currentTime
		end
		if currentTime > self.lastSideCorrectionReachedTime + self.timeUntilRevertSideCorrection then
			local sideCorrectionChangeAmount = dt * (vecToFocus.Magnitude) * self.revertSideCorrectionSpeedMultiplier
			self.lastSideCorrectionMagnitude = self.lastSideCorrectionMagnitude - sideCorrectionChangeAmount
			if sideCorrectionGoalVector.Magnitude >= self.lastSideCorrectionMagnitude then
				self.lastSideCorrectionMagnitude = sideCorrectionGoalVector.Magnitude
				self.lastSideCorrectionReachedTime = currentTime
				self.isRevertingSideCorrection = false
			end
		end
	end

	cameraYawRotationAndXOffset = cameraYawRotationAndXOffset + (-vecToFocus.Unit * self.lastSideCorrectionMagnitude)
	cameraFocus = rootPartUnrotatedCFrame * cameraYawRotationAndXOffset
	self.currentCamera.Focus = cameraFocus

	local cameraCFrameInSubjectSpace =
		cameraYawRotationAndXOffset *
		pitchRotation * 	
		yOffset *			
		zOffset				
	self.currentCFrame = rootPartUnrotatedCFrame * cameraCFrameInSubjectSpace

	if self.zoomAlpha > 0 then
		local trueZoomedOffset = math.max(self.zoomedOffsetDistance - self.lastOcclusionDistance, 0)
		self.currentCFrame = self.currentCFrame:lerp(self.currentCFrame + trueZoomedOffset * self.currentCFrame.LookVector.Unit, self.zoomAlpha)
	end

	self.currentCamera.CFrame = self.currentCFrame

	local occlusionDistance = self.currentCamera:GetLargestCutoffDistance(self.raycastIgnoreList)
	if occlusionDistance > 1e-5 then
		occlusionDistance = occlusionDistance + collisionRadius
	end
	if occlusionDistance >= self.lastOcclusionDistance then
		if self.curOcclusionTween ~= nil then
			self.curOcclusionTween:Cancel()
			self.curOcclusionTween = nil
		end
		if currentTime > self.lastOcclusionReachedTime + self.timeUntilZoomOut and self.lastOcclusionDistance ~= 0 then
			self.timeUntilZoomOut = self.defaultTimeUntilZoomOut * 2
		elseif self.lastOcclusionDistance == 0  and self.timeUntilZoomOut ~= self.defaultTimeUntilZoomOut then
			self.timeUntilZoomOut = self.defaultTimeUntilZoomOut
		end

		if occlusionDistance / self.normalOffset.Z > 0.8 and self.timeLastPoppedWayIn == 0 then
			self.timeLastPoppedWayIn = currentTime
		end

		self.lastOcclusionDistance = occlusionDistance
		self.lastOcclusionReachedTime = currentTime
		self.isZoomingOut = false
	else
		self.isZoomingOut = true
		if occlusionDistance > self.lastOcclusionDistance - 2 and occlusionDistance ~= 0 then
			self.lastOcclusionReachedTime = currentTime
		end

		if currentTime < self.timeLastPoppedWayIn + self.defaultTimeUntilZoomOut and self.lastOcclusionDistance / self.normalOffset.Z > 0.8 then
			self.lastOcclusionDistance = occlusionDistance
			self.lastOcclusionReachedTime = currentTime
			self.isZoomingOut = false
		elseif currentTime >= self.timeLastPoppedWayIn + self.defaultTimeUntilZoomOut and self.timeLastPoppedWayIn ~= 0 then
			self.timeLastPoppedWayIn = 0
		end
	end

	if currentTime >= self.lastOcclusionReachedTime + self.timeUntilZoomOut and not self.zoomState then
		if self.curOcclusionTween == nil then
			self.occlusionTweenObject.Value = self.lastOcclusionDistance
			local tweenInfo = TweenInfo.new(self.tweenOutTime)
			local goal = {}
			goal.Value = self.lastOcclusionDistance - self.normalOffset.Z
			self.curOcclusionTween = TweenService:Create(self.occlusionTweenObject, tweenInfo, goal)
			self.curOcclusionTween:Play()
		end
	end

	local currentOffsetDir = self.currentCFrame.LookVector.Unit
	self.currentCFrame = self.currentCFrame + (currentOffsetDir * self.lastOcclusionDistance)
	self.currentCamera.CFrame = self.currentCFrame

	self.currentRecoil = self.currentRecoil - (self.currentRecoil * self.recoilDecay * dt)

	--||Only Control Character if Humanoid is Controllable||--
	if self:isHumanoidControllable() and self.rotateCharacterWithCamera then
		self.currentHumanoid.AutoRotate = false
		self.currentRootPart.CFrame = CFrame.Angles(0, self.yaw, 0) + self.currentRootPart.Position
		self:applyRootJointFix()
	else
		-- Restore AutoRotate when not controllable
		if self.currentHumanoid then
			self.currentHumanoid.AutoRotate = true
		end
	end

	self:handlePartTransparencies()
	self:handleTouchToolFiring()
end

function ShoulderCamera:applyRootJointFix()
	--||Only Apply Joint Fix if Humanoid is Controllable||--
	if not self:isHumanoidControllable() then
		return
	end

	if self.rootJoint then
		local translationScale = self.zoomState and Vector3.new(0.25, 0.25, 0.25) or Vector3.new(0.5, 0.5, 0.5)
		local rotationScale = self.zoomState and 0.15 or 0.2
		local rootRotation = self.rootJoint.Part0.CFrame - self.rootJoint.Part0.CFrame.Position
		local rotation = self.rootJoint.Transform - self.rootJoint.Transform.Position
		local yawRotation = CFrame.Angles(0, self.yaw, 0)
		local leadRotation = rootRotation:toObjectSpace(yawRotation)
		local rotationFix = self.rootRigAttach.CFrame
		if self:isHumanoidControllable() then
			rotationFix = self.rootJoint.Transform:inverse() * leadRotation * rotation:Lerp(CFrame.new(), 1 - rotationScale) + (self.rootJoint.Transform.Position * translationScale)
		end

		self.rootJoint.C0 = CFrame.new(self.rootJoint.C0.Position, self.rootJoint.C0.Position + rotationFix.LookVector.Unit)
	end
end

function ShoulderCamera:sprintFromTouchInput()
	local moveVector = nil
	local activeController = nil
	local activeControllerIsTouch = nil
	if self.controlModule then
		moveVector = self.controlModule:GetMoveVector()
		activeController = self.controlModule:GetActiveController()
	end
	if moveVector and activeController then
		activeControllerIsTouch = activeController.thumbstickFrame ~= nil or activeController.thumbpadFrame ~= nil
	end

	if activeControllerIsTouch then
		return (moveVector and moveVector.Magnitude >= 0.9)
	else
		return false
	end
end

function ShoulderCamera:sprintFromGamepadInput()
	return self.movementPan.Magnitude > 0.9
end

function ShoulderCamera:onCurrentCharacterChanged(character)
	self.currentCharacter = character
	if self.currentCharacter then
		self.raycastIgnoreList[1] = self.currentCharacter
		self.currentHumanoid = character:WaitForChild("Humanoid")
		self.currentRootPart = character:WaitForChild("HumanoidRootPart")

		self.rootRigAttach = self.currentRootPart:WaitForChild("RootRigAttachment")
		self.rootJoint = character:WaitForChild("LowerTorso"):WaitForChild("Root")
		self.currentWaist = character:WaitForChild("UpperTorso"):WaitForChild("Waist")
		self.currentWrist = character:WaitForChild("RightHand"):WaitForChild("RightWrist")
		self.wristAttach0 = character:WaitForChild("RightLowerArm"):WaitForChild("RightWristRigAttachment")
		self.wristAttach1 = character:WaitForChild("RightHand"):WaitForChild("RightWristRigAttachment")
		self.rightGripAttachment = character:WaitForChild("RightHand"):WaitForChild("RightGripAttachment")

		--||Store Original Joint State||--
		if self.rootJoint then
			self.originalRootJointC0 = self.rootJoint.C0
		end

		self.currentTool = character:FindFirstChildOfClass("Tool")

		--||Listen for Humanoid State Changes||--
		self.eventConnections.humanoidStateChanged = self.currentHumanoid.StateChanged:Connect(function(oldState, newState)
			-- Force disable zoom when entering ragdoll states
			if newState == Enum.HumanoidStateType.Dead or newState == Enum.HumanoidStateType.Physics then
				self.zoomedFromInput = false
				self:updateZoomState()
			end
		end)

		self.eventConnections.humanoidDied = self.currentHumanoid.Died:Connect(function()
			self.zoomedFromInput = false
			self:updateZoomState()
		end)
		self.eventConnections.characterChildAdded = character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				self.currentTool = child
				self:updateZoomState()
			end
		end)
		self.eventConnections.characterChildRemoved = character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") and self.currentTool == child then
				self.currentTool = character:FindFirstChildOfClass("Tool")
				self:updateZoomState()
			end
		end)

		if Players.LocalPlayer then
			local PlayerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
			if PlayerScripts then
				local PlayerModule = PlayerScripts:FindFirstChild("PlayerModule")
				if PlayerModule then
					self.controlModule = require(PlayerModule:FindFirstChild("ControlModule"))
				end
			end
		end
	else
		if self.eventConnections.humanoidStateChanged then
			self.eventConnections.humanoidStateChanged:Disconnect()
			self.eventConnections.humanoidStateChanged = nil
		end
		if self.eventConnections.humanoidDied then
			self.eventConnections.humanoidDied:Disconnect()
			self.eventConnections.humanoidDied = nil
		end
		if self.eventConnections.characterChildAdded then
			self.eventConnections.characterChildAdded:Disconnect()
			self.eventConnections.characterChildAdded = nil
		end
		if self.eventConnections.characterChildRemoved then
			self.eventConnections.characterChildRemoved:Disconnect()
			self.eventConnections.characterChildRemoved = nil
		end

		self.currentTool = nil
		self.currentHumanoid = nil
		self.currentRootPart = nil
		self.controlModule = nil
		self.originalRootJointC0 = nil
	end
end

function ShoulderCamera:onCurrentCameraChanged(camera)
	if self.currentCamera == camera then
		return
	end

	self.currentCamera = camera

	if self.currentCamera then
		self.raycastIgnoreList[2] = self.currentCamera

		if self.eventConnections.cameraTypeChanged then
			self.eventConnections.cameraTypeChanged:Disconnect()
			self.eventConnections.cameraTypeChanged = nil
		end
		self.eventConnections.cameraTypeChanged = self.currentCamera:GetPropertyChangedSignal("CameraType"):Connect(function()
			if self.enabled then
				self.currentCamera.CameraType = Enum.CameraType.Scriptable
			end
		end)
	end
end

--||Updated Humanoid Controllable Check||--
function ShoulderCamera:isHumanoidControllable()
	if not self.currentHumanoid then
		return false
	end
	local humanoidState = self.currentHumanoid:GetState()
	-- Explicit check - if not in the table or explicitly false, return false
	local isControllable = CONTROLLABLE_HUMANOID_STATES[humanoidState]
	return isControllable == true
end

function ShoulderCamera:getCollisionRadius()
	if not self.currentCamera then
		return 0
	end
	local viewportSize = self.currentCamera.ViewportSize
	local aspectRatio = viewportSize.X / viewportSize.Y
	local fovRads = math.rad(self.fieldOfView)
	local imageHeight = math.tan(fovRads) * math.abs(self.currentCamera.NearPlaneZ)
	local imageWidth = imageHeight * aspectRatio

	local cornerPos = Vector3.new(imageWidth, imageHeight, self.currentCamera.NearPlaneZ)
	return cornerPos.Magnitude
end

function ShoulderCamera:penetrateCast(ray, ignoreList)
	local tries = 0
	local hitPart, hitPoint, hitNormal, hitMaterial = nil, ray.Origin + ray.Direction, Vector3.new(0, 1, 0), Enum.Material.Air
	while tries < 50 do
		tries = tries + 1
		hitPart, hitPoint, hitNormal, hitMaterial = workspace:FindPartOnRayWithIgnoreList(ray, ignoreList, false, true)
		if hitPart and not hitPart.CanCollide then
			table.insert(ignoreList, hitPart)
		else
			break
		end
	end
	return hitPart, hitPoint, hitNormal, hitMaterial
end

function ShoulderCamera:getRelativePitch()
	if self.currentRootPart then
		local pitchRotation = CFrame.Angles(self.pitch, 0, 0)
		local relativeRotation = self.currentRootPart.CFrame:toObjectSpace(pitchRotation)
		local relativeLook = relativeRotation.lookVector

		local angle = math.asin(relativeLook.Y)
		return math.clamp(angle, self.minPitch, self.maxPitch)
	end
	return self.pitch
end

function ShoulderCamera:getCurrentFieldOfView()
	if self.zoomState then
		return self.zoomedFOV
	else
		return self.fieldOfView
	end
end

function ShoulderCamera:handlePartTransparencies()
	local partsLookup = {}
	local accoutrementsLookup = {}

	for _, child in pairs(self.currentCharacter:GetChildren()) do
		local hidden = false
		if child:IsA("BasePart") then
			hidden = partsLookup[child.Name] == true
			child.LocalTransparencyModifier = hidden and 1 or 0
		elseif child:IsA("Accoutrement") then
			local descendants = child:GetDescendants()
			local accoutrementParts = {}
			for _, desc in pairs(descendants) do
				if desc:IsA("Attachment") and accoutrementsLookup[desc.Name] then
					hidden = true
				elseif desc:IsA("BasePart") then
					table.insert(accoutrementParts, desc)
				end
			end
			for _, part in pairs(accoutrementParts) do
				part.LocalTransparencyModifier = hidden and 1 or 0
			end
		elseif child:IsA("Tool") then
			hidden = self.zoomState and (self.hasScope or self.hideToolWhileZoomed)
			for _, part in pairs(child:GetDescendants()) do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = hidden and 1 or 0
				end
			end
		end
	end
end

function ShoulderCamera:setSprintEnabled(enabled)
	self.sprintEnabled = enabled
end

function ShoulderCamera:setSlowZoomWalkEnabled(enabled)
	self.slowZoomWalkEnabled = enabled
end

function ShoulderCamera:setHasScope(hasScope)
	if self.hasScope == hasScope then
		return
	end

	self.hasScope = hasScope
	self:updateZoomState()
end

function ShoulderCamera:onSprintAction(actionName, inputState, inputObj)
	self.sprintingInputActivated = inputState == Enum.UserInputState.Begin
end

function ShoulderCamera:isZoomed()
	return self.zoomState
end

function ShoulderCamera:setHideToolWhileZoomed(hide)
	self.hideToolWhileZoomed = hide
end

function ShoulderCamera:setZoomFactor(zoomFactor)
	self.currentZoomFactor = zoomFactor
	local nominalFOVRadians = math.rad(self.fieldOfView)
	local nominalImageHeight = math.tan(nominalFOVRadians / 2)
	local zoomedImageHeight = nominalImageHeight / self.currentZoomFactor
	self.zoomedFOV = math.deg(math.atan(zoomedImageHeight) * 2)
	self:updateZoomState()
end

function ShoulderCamera:resetZoomFactor()
	self:setZoomFactor(self.defaultZoomFactor)
end

function ShoulderCamera:setForceZoomed(zoomed)
	if self.forcedZoomed == zoomed then return end
	self.forcedZoomed = zoomed
	self:updateZoomState()
end

function ShoulderCamera:setZoomedFromInput(zoomedFromInput)
	if self.zoomedFromInput == zoomedFromInput or (self.currentHumanoid and self.currentHumanoid:GetState() == Enum.HumanoidStateType.Dead) then
		return
	end

	self.zoomedFromInput = zoomedFromInput
	self:updateZoomState()
end

function ShoulderCamera:updateZoomState()
	local isZoomed = self.forcedZoomed
	if self.canZoom and not self.forcedZoomed then
		isZoomed = self.zoomedFromInput
	end

	if not self.enabled or not self.currentTool then
		isZoomed = false
	end

	--||Disable Zoom if Humanoid Not Controllable||--
	if not self:isHumanoidControllable() then
		isZoomed = false
	end

	self.zoomState = isZoomed

	self.currentMouseRadsPerPixel = isZoomed and self.zoomedMouseRadsPerPixel or self.mouseRadsPerPixel
	self.currentTouchSensitivity = isZoomed and self.zoomedTouchSensitivity or self.touchSensitivity

	if self.weaponsSystem and self.weaponsSystem.gui then
		self.weaponsSystem.gui:setCrosshairScaleTarget(self.zoomState and self.zoomedCrosshairScale or self.normalCrosshairScale)
		self.weaponsSystem.gui:setCrosshairEnabled(not self.zoomState or not self.hasScope)
		self.weaponsSystem.gui:setScopeEnabled(self.zoomState and self.hasScope)
		if self.currentTool then
			self.currentTool.ManualActivationOnly = self.zoomState and self.hasScope and UserInputService.TouchEnabled
		end
	end

	if self.currentCamera then
		self.desiredFieldOfView = self:getCurrentFieldOfView()
	end
end

function ShoulderCamera:onZoomAction(actionName, inputState, inputObj)
	if not self.enabled or not self.canZoom or not self.currentCamera or not self.currentCharacter or not self.weaponsSystem.currentWeapon then
		self:setZoomedFromInput(false)
		return Enum.ContextActionResult.Pass
	end

	--||Don't Allow Zoom if Humanoid Not Controllable||--
	if not self:isHumanoidControllable() then
		self:setZoomedFromInput(false)
		return Enum.ContextActionResult.Pass
	end

	self:setZoomedFromInput(inputState == Enum.UserInputState.Begin)
	return Enum.ContextActionResult.Sink
end

function ShoulderCamera:setCurrentRecoilIntensity(x, y)
	self.currentRecoil = Vector2.new(x, y)
end

function ShoulderCamera:addRecoil(recoilAmount)
	self.currentRecoil = self.currentRecoil + recoilAmount
end

function ShoulderCamera:applyInput(yaw, pitch)
	local yInvertValue = UserGameSettings:GetCameraYInvertValue()
	self.yaw = self.yaw + yaw
	self.pitch = math.clamp(self.pitch + pitch * yInvertValue, self.minPitch, self.maxPitch)
end

function ShoulderCamera:processGamepadInput(dt)
	local gamepadPan = self.gamepadPan
	if gamepadPan then
		gamepadPan = gamepadLinearToCurve(gamepadPan)
		if gamepadPan.X == 0 and gamepadPan.Y == 0 then
			self.lastThumbstickTime = nil
			if self.lastThumbstickPos.X == 0 and self.lastThumbstickPos.Y == 0 then
				self.currentGamepadSpeed = 0
			end
		end

		local finalConstant = 0
		local currentTime = tick()

		if self.lastThumbstickTime then
			local elapsed = (currentTime - self.lastThumbstickTime) * 10
			self.currentGamepadSpeed = self.currentGamepadSpeed + (6 * ((elapsed ^ 2) / 0.7))

			if self.currentGamepadSpeed > 6 then self.currentGamepadSpeed = 6 end

			if self.lastGamepadVelocity then
				local velocity = (gamepadPan - self.lastThumbstickPos) / (currentTime - self.lastThumbstickTime)
				local velocityDeltaMag = (velocity - self.lastGamepadVelocity).Magnitude

				if velocityDeltaMag > 12 then
					self.currentGamepadSpeed = self.currentGamepadSpeed * (20 / velocityDeltaMag)
					if self.currentGamepadSpeed > 6 then
						self.currentGamepadSpeed = 6
					end
				end
			end

			finalConstant = GameSettings.GamepadCameraSensitivity * self.currentGamepadSpeed * dt
			self.lastGamepadVelocity = (gamepadPan - self.lastThumbstickPos) / (currentTime - self.lastThumbstickTime)
		end
		self.lastThumbstickPos = gamepadPan
		self.lastThumbstickTime = currentTime

		local yawInput = -gamepadPan.X * finalConstant * self.gamepadSensitivityModifier.X
		local pitchInput = finalConstant * gamepadPan.Y * GameSettings:GetCameraYInvertValue() * self.gamepadSensitivityModifier.Y

		self:applyInput(yawInput, pitchInput)
	end
end

function ShoulderCamera:handleTouchToolFiring()
	if self.touchObj then
		if self.lastTapEndTime then
			local touchTime = tick() - self.lastTapEndTime
			if touchTime < self.touchDelayTime and self.currentTool and self.touchPanAccumulator.Magnitude < 0.5 and not self.firingTool and not self.applyingTouchPan then
				self.firingTool = true
				self.currentTool:Activate()
			end
		end
	else
		if self.currentTool and self.firingTool then
			self.currentTool:Deactivate()
		end
		self.firingTool = false
	end
end

function ShoulderCamera:isTouchPositionForCamera(pos)
	if LocalPlayer then
		local guiObjects = LocalPlayer.PlayerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)
		for _, guiObject in ipairs(guiObjects) do
			if guiObject.Name == "DynamicThumbstickFrame" then
				return false
			end
		end
		return true
	end
	return false
end

function ShoulderCamera:onInputBegan(inputObj, wasProcessed)
	if self.touchObj then
		self.touchObj = nil
		wasProcessed = false
	end

	if inputObj.KeyCode == Enum.KeyCode.Thumbstick2 then
		self.gamepadPan = Vector2.new(inputObj.Position.X, inputObj.Position.Y)
	elseif inputObj.KeyCode == Enum.KeyCode.Thumbstick1 then
		self.movementPan = Vector2.new(inputObj.Position.X, inputObj.Position.Y)
	elseif inputObj.UserInputType == Enum.UserInputType.Touch then
		local touchStartPos = Vector2.new(inputObj.Position.X, inputObj.Position.Y)
		if not wasProcessed and self:isTouchPositionForCamera(touchStartPos) and not self.touchObj then
			self.touchObj = inputObj
			self.touchStartTime = tick()
			self.eventConnections.touchChanged = inputObj.Changed:Connect(function(prop)
				if prop == "Position" then
					local touchTime = tick() - self.touchStartTime

					local newTouchPos = Vector2.new(inputObj.Position.X, inputObj.Position.Y)
					local delta = (newTouchPos - touchStartPos) * self.currentTouchSensitivity
					local yawInput = -delta.X
					local pitchInput = -delta.Y
					if self.touchPanAccumulator.Magnitude > 0.01 and touchTime > self.touchDelayTime then
						if not self.applyingTouchPan then
							self.applyingTouchPan = true
							self.touchPanAccumulator = Vector2.new(0, 0)
						end
					end
					self:applyInput(yawInput, pitchInput)
					self.touchPanAccumulator = self.touchPanAccumulator + Vector2.new(yawInput, pitchInput)
					touchStartPos = newTouchPos
				end
			end)
		end
	end
end

function ShoulderCamera:onInputChanged(inputObj, wasProcessed)
	if inputObj.UserInputType == Enum.UserInputType.MouseMovement then
		local yawInput = -inputObj.Delta.X * self.currentMouseRadsPerPixel.X
		local pitchInput = -inputObj.Delta.Y * self.currentMouseRadsPerPixel.Y

		self:applyInput(yawInput, pitchInput)
	elseif inputObj.KeyCode == Enum.KeyCode.Thumbstick2 then
		self.gamepadPan = Vector2.new(inputObj.Position.X, inputObj.Position.Y)
	elseif inputObj.KeyCode == Enum.KeyCode.Thumbstick1 then
		self.movementPan = Vector2.new(inputObj.Position.X, inputObj.Position.Y)
	end
end

function ShoulderCamera:onInputEnded(inputObj, wasProcessed)
	if inputObj.KeyCode == Enum.KeyCode.Thumbstick2 then
		self.gamepadPan = Vector2.new(0, 0)
	elseif inputObj.KeyCode == Enum.KeyCode.Thumbstick1 then
		self.movementPan = Vector2.new(0, 0)
	elseif inputObj.UserInputType == Enum.UserInputType.Touch then
		if self.touchObj == inputObj then
			if self.eventConnections and self.eventConnections.touchChanged then
				self.eventConnections.touchChanged:Disconnect()
				self.eventConnections.touchChanged = nil
			end

			local touchTime = tick() - self.touchStartTime
			if self.currentTool and self.firingTool then
				self.currentTool:Deactivate()
			elseif self.zoomState and self.hasScope and touchTime < self.touchDelayTime and not self.applyingTouchPan then
				self.currentTool:Activate()
				self.currentTool:Deactivate()
			end
			self.firingTool = false

			self.touchPanAccumulator = Vector2.new(0, 0)
			if touchTime < self.touchDelayTime and not self.applyingTouchPan then
				self.lastTapEndTime = tick()
			else
				self.lastTapEndTime = nil
			end
			self.applyingTouchPan = false

			self.gamepadPan = Vector2.new(0, 0)
			self.touchObj = nil
		end
	end
end

return ShoulderCamera
