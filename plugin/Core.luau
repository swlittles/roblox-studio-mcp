--!nocheck
-- StudioBridge core. Runs in every Studio DataModel (edit, play-test server, play-test clients).
--
-- Edit and server sessions talk to the bridge over HTTP. Play-test clients cannot use HttpService, so the
-- server session relays their traffic through a RemoteEvent. Where loadstring is unavailable (play-test
-- server/client), run_luau executes bytecode compiled by the bridge through the bundled Fiu interpreter.
-- This file is both bundled into the plugin and served by the bridge for hot reload in edit sessions.

return function(plugin, host)
	local HttpService = game:GetService("HttpService")
	local RunService = game:GetService("RunService")
	local LogService = game:GetService("LogService")
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local PORT = 44777
	local BASE = `http://127.0.0.1:{PORT}/plugin/`
	local RELAY_NAME = "__StudioBridgeRelay"
	local VERSION = 2

	local context = if RunService:IsEdit() then "edit" elseif RunService:IsServer() then "server" else "client"
	local sessionId = host.sessionId
	local generation = host.generation
	local pendingLogs = {}
	local pendingResults = {}
	local transport = "http"
	local relay: RemoteEvent? = nil

	local function isAlive()
		return host.alive and host.generation == generation
	end

	local function info()
		local player = if context == "client" then Players.LocalPlayer else nil
		return {
			id = sessionId,
			context = context,
			player = player and player.Name or nil,
			place = game.Name,
			placeId = game.PlaceId,
			version = VERSION,
			testActive = context ~= "edit",
		}
	end

	local function httpRequest(route, body, timeout)
		return HttpService:RequestAsync({
			Url = BASE .. route,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
			Timeout = timeout,
		})
	end

	local function request(route, extra, timeout)
		local body = info()
		for k, v in extra or {} do
			body[k] = v
		end
		return httpRequest(route, body, timeout)
	end

	-- Serialization --------------------------------------------------------------------------------------

	local function describe(value, depth, seen)
		depth = depth or 0
		seen = seen or {}
		local t = typeof(value)
		if t == "string" then
			return string.format("%q", value)
		elseif t == "Instance" then
			return `{value.ClassName}({value:GetFullName()})`
		elseif t == "Vector3" then
			return string.format("Vector3(%.2f, %.2f, %.2f)", value.X, value.Y, value.Z)
		elseif t == "CFrame" then
			local p = value.Position
			local lv = value.LookVector
			return string.format("CFrame(pos %.2f, %.2f, %.2f; look %.2f, %.2f, %.2f)", p.X, p.Y, p.Z, lv.X, lv.Y, lv.Z)
		elseif t == "Color3" then
			return string.format("Color3(%d, %d, %d)", value.R * 255, value.G * 255, value.B * 255)
		elseif t == "table" then
			if seen[value] or depth > 3 then
				return "{...}"
			end
			seen[value] = true
			local parts = {}
			local count = 0
			for k, v in value do
				count += 1
				if count > 80 then
					table.insert(parts, "...")
					break
				end
				local key = if type(k) == "number" then "" else `{tostring(k)} = `
				table.insert(parts, key .. describe(v, depth + 1, seen))
			end
			return "{" .. table.concat(parts, ", ") .. "}"
		end
		return tostring(value)
	end

	-- Code execution ----------------------------------------------------------------------------------------

	local hasLoadstring = pcall(function()
		assert(loadstring("return 1"))
	end)
	local fiu = nil
	local function getFiu()
		if not fiu then
			fiu = require(host.bundle:WaitForChild("Fiu"))
		end
		return fiu
	end

	local function decodeBase64(text)
		local EncodingService = game:GetService("EncodingService")
		return buffer.tostring(EncodingService:Base64Decode(buffer.fromstring(text)))
	end

	local function encodeBase64(buf)
		return buffer.tostring(game:GetService("EncodingService"):Base64Encode(buf))
	end

	local handlers = {}

	function handlers.run(args)
		local output = {}
		local function capture(prefix)
			return function(...)
				local parts = table.pack(...)
				for i = 1, parts.n do
					parts[i] = if type(parts[i]) == "string" then parts[i] else describe(parts[i])
				end
				table.insert(output, prefix .. table.concat(parts, " ", 1, parts.n))
			end
		end
		local env = setmetatable({
			print = capture(""),
			warn = capture("WARN: "),
			plugin = plugin,
			describe = describe,
		}, { __index = getfenv(1) })
		local fn
		if hasLoadstring then
			local compileError
			fn, compileError = loadstring(args.code, "=bridge")
			if not fn then
				return { ok = false, error = compileError, output = {} }
			end
			setfenv(fn, env)
		else
			if not args.bytecode then
				return { ok = false, error = "loadstring unavailable here and no bytecode was supplied", output = {} }
			end
			local F = getFiu()
			local settings = F.luau_newsettings()
			settings.vectorCtor = Vector3.new
			settings.vectorSize = 3
			fn = F.luau_load(decodeBase64(args.bytecode), env, settings)
		end
		local results = table.pack(xpcall(fn, debug.traceback))
		if not results[1] then
			return { ok = false, error = tostring(results[2]), output = output }
		end
		local returns = {}
		for i = 2, results.n do
			table.insert(returns, describe(results[i]))
		end
		return { ok = true, output = output, returns = returns }
	end

	-- Screenshots -------------------------------------------------------------------------------------------

	local function applyCamera(c)
		if not c then
			return
		end
		local camera = workspace.CurrentCamera
		if context == "client" and not c.release then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		if c.position and c.lookAt then
			local target = Vector3.new(table.unpack(c.lookAt))
			-- Studio's edit camera re-aims at Focus, so move the focus with it.
			camera.Focus = CFrame.new(target)
			camera.CFrame = CFrame.lookAt(Vector3.new(table.unpack(c.position)), target)
		end
		if c.fov then
			camera.FieldOfView = c.fov
		end
		if c.release and context == "client" then
			camera.CameraType = Enum.CameraType.Custom
		end
		task.wait(0.2)
	end

	local function tryStudioCapture(args)
		local ok, result = pcall(function()
			local CaptureService = game:GetService("StudioCaptureService")
			if not CaptureService:CanCaptureScreenshot() then
				return nil
			end
			local capture = CaptureService:CaptureScreenshot({
				Format = Enum.StudioCaptureScreenshotFormat.PNG,
				UICaptureMode = if args.includeUi then Enum.UICaptureMode.All else Enum.UICaptureMode.None,
			})
			if not capture then
				return nil
			end
			local deadline = os.clock() + 10
			while capture.BufferStatus ~= Enum.StudioCaptureBufferStatus.Ready and os.clock() < deadline do
				if capture.BufferStatus == Enum.StudioCaptureBufferStatus.Error then
					return nil
				end
				task.wait(0.05)
			end
			return { ok = true, png = encodeBase64(capture:GetBuffer()), width = capture.Resolution.X, height = capture.Resolution.Y, method = "StudioCaptureService" }
		end)
		return ok and result or nil
	end

	-- Client-only: CaptureService screenshot read back through EditableImage.
	local function tryExperienceCapture(args)
		if context ~= "client" then
			return nil
		end
		local ok, result = pcall(function()
			local CaptureService = game:GetService("CaptureService")
			local AssetService = game:GetService("AssetService")
			local contentId
			CaptureService:CaptureScreenshot(function(id)
				contentId = id
			end)
			local deadline = os.clock() + 4
			while not contentId and os.clock() < deadline do
				task.wait(0.05)
			end
			if not contentId then
				return nil
			end
			local image = AssetService:CreateEditableImageAsync(Content.fromUri(contentId))
			local size = image.Size
			local scale = math.min(1, (args.width or 960) / size.X)
			local w, h = math.floor(size.X * scale), math.floor(size.Y * scale)
			local src = image:ReadPixelsBuffer(Vector2.zero, size)
			local out = buffer.create(w * h * 3)
			for y = 0, h - 1 do
				local sy = math.floor(y / scale)
				for x = 0, w - 1 do
					local si = (sy * size.X + math.floor(x / scale)) * 4
					local di = (y * w + x) * 3
					buffer.writeu8(out, di, buffer.readu8(src, si))
					buffer.writeu8(out, di + 1, buffer.readu8(src, si + 1))
					buffer.writeu8(out, di + 2, buffer.readu8(src, si + 2))
				end
			end
			image:Destroy()
			return { ok = true, rgb = encodeBase64(out), width = w, height = h, method = "CaptureService" }
		end)
		if not ok then
			warn("[StudioBridge] CaptureService readback failed: " .. tostring(result))
		end
		return ok and result or nil
	end

	-- Fallback: software raycast render of the 3D scene with a flat overlay of visible GUI rectangles.
	local function raycastRender(args)
		local Lighting = game:GetService("Lighting")
		local camera = workspace.CurrentCamera
		local viewport = camera.ViewportSize
		local w = math.clamp(math.floor(args.width or 640), 64, 1280)
		local aspect = if viewport.X > 0 then viewport.X / viewport.Y else 16 / 9
		local h = math.floor(w / aspect)
		local cf = camera.CFrame
		local tanY = math.tan(math.rad(camera.FieldOfView) / 2)
		local tanX = tanY * aspect
		local exclude = { camera }
		-- Decorative parts are often CanQuery=false; make visible ones hittable for the duration of the render.
		local toggled = {}
		for _, d in workspace:GetDescendants() do
			if d:IsA("BasePart") then
				if d.Transparency >= 0.6 or d.Name == "HumanoidRootPart" then
					table.insert(exclude, d)
				elseif not d.CanQuery then
					d.CanQuery = true
					table.insert(toggled, d)
				end
			end
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = exclude
		params.IgnoreWater = true
		local shadowParams = RaycastParams.new()
		shadowParams.FilterType = Enum.RaycastFilterType.Exclude
		shadowParams.FilterDescendantsInstances = exclude

		local lights = {}
		for _, d in workspace:GetDescendants() do
			if d:IsA("Light") and d.Enabled and d.Brightness > 0 then
				local parent = d.Parent
				local pos = if parent:IsA("Attachment") then parent.WorldPosition elseif parent:IsA("BasePart") then parent.Position else nil
				if pos then
					local dir = nil
					if d:IsA("SpotLight") and parent:IsA("BasePart") then
						dir = parent.CFrame:VectorToWorldSpace(Vector3.FromNormalId(d.Face))
					elseif d:IsA("SpotLight") and parent:IsA("Attachment") then
						dir = parent.WorldCFrame:VectorToWorldSpace(Vector3.FromNormalId(d.Face))
					end
					table.insert(lights, {
						pos = pos,
						color = d.Color,
						range = d.Range,
						brightness = math.min(d.Brightness, 4),
						dir = dir,
						cosAngle = if dir then math.cos(math.rad(d.Angle / 2)) else nil,
					})
				end
			end
		end

		-- Bucket lights into a coarse grid so each pixel only considers nearby lights.
		local CELL = 24
		local lightGrid: { [number]: { any } } = {}
		local function cellKey(x: number, z: number): number
			return (math.floor(x / CELL) + 2000) * 4096 + (math.floor(z / CELL) + 2000)
		end
		for _, l in lights do
			local r = l.range
			for cx = math.floor((l.pos.X - r) / CELL), math.floor((l.pos.X + r) / CELL) do
				for cz = math.floor((l.pos.Z - r) / CELL), math.floor((l.pos.Z + r) / CELL) do
					local key = (cx + 2000) * 4096 + (cz + 2000)
					local bucket = lightGrid[key]
					if not bucket then
						bucket = {}
						lightGrid[key] = bucket
					end
					table.insert(bucket, l)
				end
			end
		end
		local noLights = {}

		local sun = Lighting:GetSunDirection()
		local sunUp = math.max(0, sun.Y)
		local moonDir = Lighting:GetMoonDirection()
		local skyLight = math.clamp(sunUp * 1.6, 0, 1)
		local ambient = Lighting.OutdoorAmbient:Lerp(Lighting.Ambient, 0.5)
		local ambientV = Vector3.new(ambient.R, ambient.G, ambient.B) * 0.9 + Vector3.new(0.05, 0.06, 0.08) * (1 - skyLight)
		local sunColor = Vector3.new(1, 0.95, 0.85) * skyLight + Vector3.new(0.25, 0.3, 0.42) * (1 - skyLight)
		local keyDir = if sunUp > 0.02 then sun else moonDir
		local exposure = args.exposure or 1
		local fogEnd = Lighting.FogEnd
		local fogColor = Lighting.FogColor
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		local hazeColor = if atmosphere then atmosphere.Color else fogColor
		local skyTop = Vector3.new(0.08, 0.1, 0.16):Lerp(Vector3.new(0.35, 0.55, 0.85), skyLight)
		local skyHorizon = Vector3.new(hazeColor.R, hazeColor.G, hazeColor.B)

		local terrain = workspace.Terrain
		local materialColor = {}
		local function surfaceColor(result)
			local inst = result.Instance
			if inst == terrain then
				local m = result.Material
				local c = materialColor[m]
				if not c then
					local ok, color = pcall(terrain.GetMaterialColor, terrain, m)
					c = if ok then color else Color3.new(0.4, 0.5, 0.3)
					materialColor[m] = c
				end
				return c, false
			end
			return inst.Color, inst.Material == Enum.Material.Neon
		end

		local out = buffer.create(w * h * 3)
		local origin = cf.Position
		local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
		local started = os.clock()
		for y = 0, h - 1 do
			local v = (1 - (y + 0.5) / h * 2) * tanY
			for x = 0, w - 1 do
				local u = ((x + 0.5) / w * 2 - 1) * tanX
				local dir = (look + right * u + up * v).Unit
				local result = workspace:Raycast(origin, dir * 3000, params)
				local color
				if result then
					local base, neon = surfaceColor(result)
					local baseV = Vector3.new(base.R, base.G, base.B)
					if neon then
						color = baseV * 1.3
					else
						local n = result.Normal
						local p = result.Position + n * 0.05
						local light = ambientV
						local ndl = n:Dot(keyDir)
						if ndl > 0 then
							local blocked = workspace:Raycast(p, keyDir * 400, shadowParams)
							if not blocked then
								light += sunColor * ndl
							end
						end
						for _, l in lightGrid[cellKey(p.X, p.Z)] or noLights do
							local toLight = l.pos - p
							local dist = toLight.Magnitude
							if dist < l.range and dist > 0 then
								local ld = toLight / dist
								local lambert = n:Dot(ld)
								if lambert > 0 then
									local spot = 1
									if l.dir then
										local c = (-ld):Dot(l.dir)
										spot = if c >= l.cosAngle then 1 else 0
									end
									if spot > 0 then
										local falloff = 1 - dist / l.range
										light += Vector3.new(l.color.R, l.color.G, l.color.B) * (lambert * falloff * falloff * l.brightness * 0.8)
									end
								end
							end
						end
						color = baseV * light
					end
					local fog = math.clamp(result.Distance / math.max(fogEnd, 1), 0, 1)
					color = color:Lerp(skyHorizon, fog * 0.85)
				else
					local t = math.clamp(dir.Y * 1.5, 0, 1)
					color = skyHorizon:Lerp(skyTop, t)
				end
				color *= exposure
				local i = (y * w + x) * 3
				buffer.writeu8(out, i, math.clamp(math.floor(color.X ^ (1 / 1.2) * 255), 0, 255))
				buffer.writeu8(out, i + 1, math.clamp(math.floor(color.Y ^ (1 / 1.2) * 255), 0, 255))
				buffer.writeu8(out, i + 2, math.clamp(math.floor(color.Z ^ (1 / 1.2) * 255), 0, 255))
			end
			if os.clock() - started > 0.05 then
				task.wait()
				started = os.clock()
			end
		end

		for _, d in toggled do
			d.CanQuery = false
		end

		-- GUI overlay: walks each ScreenGui like Roblox's Sibling ZIndexBehavior (children after parents,
		-- siblings by ZIndex), clipping to ClipsDescendants ancestors. Text is marked with an underline in
		-- its colour and listed separately.
		local texts = {}
		if context == "client" and args.includeUi ~= false and viewport.X > 0 then
			local sx, sy = w / viewport.X, h / viewport.Y
			local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			local inset = game:GetService("GuiService"):GetGuiInset()
			local function blend(x0: number, y0: number, x1: number, y1: number, c: Color3, alpha: number)
				for py = y0, y1 do
					for px = x0, x1 do
						local i = (py * w + px) * 3
						buffer.writeu8(out, i, math.floor(buffer.readu8(out, i) * (1 - alpha) + c.R * 255 * alpha))
						buffer.writeu8(out, i + 1, math.floor(buffer.readu8(out, i + 1) * (1 - alpha) + c.G * 255 * alpha))
						buffer.writeu8(out, i + 2, math.floor(buffer.readu8(out, i + 2) * (1 - alpha) + c.B * 255 * alpha))
					end
				end
			end
			local function drawViewport(vf: ViewportFrame, x0: number, y0: number, x1: number, y1: number, fullX0: number, fullY0: number, fullW: number, fullH: number)
				local vpCamera = vf.CurrentCamera
				local worldModel = vf:FindFirstChildWhichIsA("WorldModel")
				if not vpCamera or not worldModel then
					return
				end
				for _, d in worldModel:GetDescendants() do
					if d:IsA("BasePart") then
						d.CanQuery = d.Transparency < 0.6
					end
				end
				local vcf = vpCamera.CFrame
				local vTan = math.tan(math.rad(vpCamera.FieldOfView) / 2)
				local vAspect = math.max(fullW, 1) / math.max(fullH, 1)
				local lightDir = -vf.LightDirection.Unit
				local amb = Vector3.new(vf.Ambient.R, vf.Ambient.G, vf.Ambient.B)
				local lc = Vector3.new(vf.LightColor.R, vf.LightColor.G, vf.LightColor.B)
				local bg = vf.BackgroundColor3
				local vParams = RaycastParams.new()
				for py = y0, y1 do
					local v = (1 - ((py - fullY0 + 0.5) / math.max(1, fullH)) * 2) * vTan
					for px = x0, x1 do
						local u = (((px - fullX0 + 0.5) / math.max(1, fullW)) * 2 - 1) * vTan * vAspect
						local dir = (vcf.LookVector + vcf.RightVector * u + vcf.UpVector * v).Unit
						local hit = worldModel:Raycast(vcf.Position, dir * 1000, vParams)
						local col = Vector3.new(bg.R, bg.G, bg.B)
						if hit and hit.Instance:IsA("BasePart") then
							local c = hit.Instance.Color
							local lambert = math.max(0, hit.Normal:Dot(lightDir))
							col = Vector3.new(c.R, c.G, c.B) * (amb * 0.55 + lc * lambert * 0.7)
						end
						local i = (py * w + px) * 3
						buffer.writeu8(out, i, math.clamp(math.floor(col.X * 255), 0, 255))
						buffer.writeu8(out, i + 1, math.clamp(math.floor(col.Y * 255), 0, 255))
						buffer.writeu8(out, i + 2, math.clamp(math.floor(col.Z * 255), 0, 255))
					end
				end
			end
			local function draw(g: GuiObject, clip: { number })
				-- AbsolutePosition is measured from below the top bar inset for every ScreenGui.
				local pos = g.AbsolutePosition + inset
				local size = g.AbsoluteSize
				local fx0, fy0 = math.floor(pos.X * sx), math.floor(pos.Y * sy)
				local fx1, fy1 = math.floor((pos.X + size.X) * sx), math.floor((pos.Y + size.Y) * sy)
				local x0, y0 = math.max(fx0, clip[1]), math.max(fy0, clip[2])
				local x1, y1 = math.min(fx1, clip[3]), math.min(fy1, clip[4])
				if x1 >= x0 and y1 >= y0 then
					local alpha = 1 - g.BackgroundTransparency
					local c = g.BackgroundColor3
					if g:IsA("ImageLabel") or g:IsA("ImageButton") then
						alpha = math.max(alpha, (1 - g.ImageTransparency) * 0.5)
						c = g.ImageColor3
					end
					if alpha > 0.02 then
						blend(x0, y0, x1, y1, c, alpha)
					end
					if g:IsA("ViewportFrame") then
						drawViewport(g, x0, y0, x1, y1, fx0, fy0, fx1 - fx0 + 1, fy1 - fy0 + 1)
					end
					if (g:IsA("TextLabel") or g:IsA("TextButton") or g:IsA("TextBox")) and g.Text ~= "" and g.TextTransparency < 0.95 then
						local tc = g.TextColor3
						local tb = g.TextBounds
						local tx0 = pos.X
						if g.TextXAlignment == Enum.TextXAlignment.Center then
							tx0 = pos.X + (size.X - tb.X) / 2
						elseif g.TextXAlignment == Enum.TextXAlignment.Right then
							tx0 = pos.X + size.X - tb.X
						end
						local ux0 = math.max(clip[1], math.floor(tx0 * sx))
						local ux1 = math.min(clip[3], math.floor((tx0 + tb.X) * sx))
						local yy = math.floor((pos.Y + size.Y / 2) * sy)
						if yy >= clip[2] and yy <= clip[4] then
							blend(ux0, math.max(clip[2], yy - 1), ux1, math.min(clip[4], yy + 1), tc, 1)
						end
						local path = string.gsub(g:GetFullName(), "^.-PlayerGui%.", "")
						local content = g.ContentText
						if not utf8.len(content) then
							content = string.gsub(content, "[\128-\255]", "?")
						end
						table.insert(texts, string.format("(%d,%d %dx%d) %s: %s", math.floor(pos.X), math.floor(pos.Y), math.floor(size.X), math.floor(size.Y), path, content))
					end
				end
				return { math.max(fx0, clip[1]), math.max(fy0, clip[2]), math.min(fx1, clip[3]), math.min(fy1, clip[4]) }
			end
			local function walk(node: Instance, clip: { number })
				local children = {}
				for index, child in node:GetChildren() do
					if child:IsA("GuiObject") and child.Visible then
						table.insert(children, { g = child, z = child.ZIndex, index = index })
					end
				end
				table.sort(children, function(a, b)
					if a.z ~= b.z then
						return a.z < b.z
					end
					return a.index < b.index
				end)
				for _, item in children do
					local g = item.g
					local rect = draw(g, clip)
					walk(g, if g.ClipsDescendants then rect else clip)
				end
			end
			local screens = {}
			for _, gui in (playerGui and playerGui:GetChildren() or {}) do
				if gui:IsA("ScreenGui") and gui.Enabled then
					table.insert(screens, gui)
				end
			end
			table.sort(screens, function(a, b)
				return a.DisplayOrder < b.DisplayOrder
			end)
			for _, gui in screens do
				walk(gui, { 0, 0, w - 1, h - 1 })
			end
		end
		return { ok = true, rgb = encodeBase64(out), width = w, height = h, method = "raycast", texts = texts }
	end

	function handlers.camera(args)
		applyCamera(args.camera)
		return { ok = true }
	end

	function handlers.screenshot(args)
		applyCamera(args.camera)
		if args.method ~= "raycast" then
			local result = tryStudioCapture(args) or (args.method == "capture" or args.method == nil) and tryExperienceCapture(args)
			if result then
				return result
			end
		end
		return raycastRender(args)
	end

	function handlers.gui()
		if context ~= "client" then
			return { ok = false, error = "gui listing needs a client session" }
		end
		local lines = {}
		local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		for _, gui in playerGui:GetChildren() do
			if gui:IsA("LayerCollector") then
				table.insert(lines, `{gui.Name} [{gui.ClassName}] enabled={gui.Enabled}`)
				local function walk(node, indent)
					for _, g in node:GetChildren() do
						if g:IsA("GuiObject") then
							local text = if g:IsA("TextLabel") or g:IsA("TextButton") or g:IsA("TextBox") then ` "{g.ContentText}"` else ""
							local p, s = g.AbsolutePosition, g.AbsoluteSize
							table.insert(lines, string.format("%s%s [%s]%s (%d,%d %dx%d)%s", indent, g.Name, g.ClassName, g.Visible and "" or " hidden", math.floor(p.X), math.floor(p.Y), math.floor(s.X), math.floor(s.Y), text))
							if g.Visible then
								walk(g, indent .. "  ")
							end
						end
					end
				end
				if gui.Enabled then
					walk(gui, "  ")
				end
			end
		end
		return { ok = true, returns = lines }
	end

	-- Sync ------------------------------------------------------------------------------------------------

	local MANAGED = "BridgeManaged"

	local function coerce(instance, key, value)
		local current = instance[key]
		local kind = typeof(current)
		if type(value) == "table" then
			if kind == "Vector3" then
				return Vector3.new(table.unpack(value))
			elseif kind == "Color3" then
				return Color3.fromRGB(table.unpack(value))
			elseif kind == "Vector2" then
				return Vector2.new(table.unpack(value))
			end
		elseif kind == "EnumItem" and type(value) == "string" then
			return (Enum :: any)[tostring(current.EnumType)][value]
		end
		return value
	end

	local function setSource(script, source)
		if script.Source == source then
			return false
		end
		local ok = pcall(function()
			script.Source = source
		end)
		if not ok then
			game:GetService("ScriptEditorService"):UpdateSourceAsync(script, function()
				return source
			end)
		end
		return true
	end

	local function applyNode(instance, node, stats)
		for key, value in node.properties or {} do
			local ok, err = pcall(function()
				instance[key] = coerce(instance, key, value)
			end)
			if not ok then
				table.insert(stats.errors, `{instance:GetFullName()}.{key}: {err}`)
			end
		end
		if node.source ~= nil and instance:IsA("LuaSourceContainer") then
			if setSource(instance, node.source) then
				stats.updated += 1
			end
		end
		local wanted = {}
		for _, childNode in node.children or {} do
			wanted[childNode.name] = true
			local child = instance:FindFirstChild(childNode.name)
			if child and child.ClassName ~= childNode.className then
				child:Destroy()
				child = nil
			end
			if not child then
				child = Instance.new(childNode.className)
				child.Name = childNode.name
				child:SetAttribute(MANAGED, true)
				stats.created += 1
				applyNode(child, childNode, stats)
				child.Parent = instance
			else
				child:SetAttribute(MANAGED, true)
				applyNode(child, childNode, stats)
			end
		end
		for _, child in instance:GetChildren() do
			if child:GetAttribute(MANAGED) and not wanted[child.Name] then
				child:Destroy()
				stats.removed += 1
			end
		end
	end

	function handlers.sync(args)
		if context ~= "edit" then
			return { ok = false, error = "sync_project only works in the edit DataModel (stop the test first)." }
		end
		local stats = { created = 0, updated = 0, removed = 0, errors = {} }
		local history = game:GetService("ChangeHistoryService")
		local recording = history:TryBeginRecording("StudioBridge sync")
		for _, serviceNode in args.tree.children do
			local ok, service = pcall(game.GetService, game, serviceNode.className)
			if not ok or not service then
				table.insert(stats.errors, "Unknown service " .. serviceNode.className)
				continue
			end
			applyNode(service, serviceNode, stats)
		end
		if recording then
			history:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end
		local summary = `created {stats.created}, updated {stats.updated}, removed {stats.removed}`
		if #stats.errors > 0 then
			summary ..= "\nerrors:\n" .. table.concat(stats.errors, "\n")
		end
		return { ok = true, returns = { summary } }
	end

	-- Test control ------------------------------------------------------------------------------------------

	function handlers.test(args)
		local StudioTestService = game:GetService("StudioTestService")
		task.spawn(function()
			local ok, err = pcall(function()
				local testArgs = { bridge = true }
				if args.mode == "run" then
					StudioTestService:ExecuteRunModeAsync(testArgs)
				elseif args.mode == "multiplayer" then
					StudioTestService:ExecuteMultiplayerTestAsync(args.players or 2, testArgs)
				else
					StudioTestService:ExecutePlayModeAsync(testArgs)
				end
			end)
			if not ok then
				warn("[StudioBridge] test failed: " .. tostring(err))
			end
		end)
		return { ok = true }
	end

	function handlers.addplayers(args)
		game:GetService("StudioTestService"):AddPlayers(args.players or 1)
		return { ok = true }
	end

	function handlers.endtest()
		task.defer(function()
			game:GetService("StudioTestService"):EndTest("stopped by bridge")
		end)
		return { ok = true }
	end

	function handlers.leave()
		task.defer(function()
			game:GetService("StudioTestService"):LeaveTest()
		end)
		return { ok = true }
	end

	function handlers.tree(args)
		local node = game
		for name in string.gmatch(args.path or "Workspace", "[^%.]+") do
			local nextNode = node:FindFirstChild(name)
			if not nextNode and node == game then
				local ok, service = pcall(game.GetService, game, name)
				nextNode = ok and service or nil
			end
			if not nextNode then
				return { ok = false, error = `No child '{name}' under {node:GetFullName()}` }
			end
			node = nextNode
		end
		local lines = {}
		local function walk(instance, depth, indent)
			if #lines > 500 then
				return
			end
			local extra = ""
			if instance:IsA("BasePart") then
				local p = instance.Position
				extra = string.format(" @(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z)
			end
			table.insert(lines, `{indent}{instance.Name} [{instance.ClassName}]{extra}`)
			if depth <= 0 then
				local n = #instance:GetChildren()
				if n > 0 then
					table.insert(lines, `{indent}  ... {n} children`)
				end
				return
			end
			for _, child in instance:GetChildren() do
				walk(child, depth - 1, indent .. "  ")
			end
		end
		walk(node, args.depth or 2, "")
		return { ok = true, returns = lines }
	end

	function handlers.reload()
		task.delay(0.2, host.reload)
		return { ok = true }
	end

	-- Transport -------------------------------------------------------------------------------------------

	local function pushNow()
		if #pendingLogs == 0 and #pendingResults == 0 then
			return
		end
		local logs, results = pendingLogs, pendingResults
		pendingLogs, pendingResults = {}, {}
		local ok
		if transport == "relay" then
			-- RemoteEvent payloads are limited, so large result fields travel as separate chunks first.
			local CHUNK = 48000
			ok = relay ~= nil
			for _, r in results do
				for _, field in { "rgb", "png" } do
					local value = r[field]
					if ok and type(value) == "string" and #value > CHUNK then
						local total = math.ceil(#value / CHUNK)
						for i = 1, total do
							local sent, err = pcall(relay.FireServer, relay, "chunk", {
								commandId = r.commandId,
								field = field,
								index = i,
								total = total,
								data = string.sub(value, (i - 1) * CHUNK + 1, i * CHUNK),
							})
							if not sent then
								warn("[StudioBridge] relay chunk failed: " .. tostring(err))
								ok = false
								break
							end
						end
						r[field] = nil
						r[field .. "Chunks"] = total
					end
				end
			end
			if ok then
				local sent, err = pcall(relay.FireServer, relay, "push", { logs = logs, results = results })
				if not sent then
					warn("[StudioBridge] relay push failed: " .. tostring(err))
				end
				ok = sent
			end
		else
			ok = pcall(request, "push", { logs = logs, results = results }, 15)
		end
		if not ok then
			for _, r in results do
				table.insert(pendingResults, r)
			end
		end
	end

	local function execute(command)
		local handler = handlers[command.type]
		local ok, result = xpcall(function()
			if not handler then
				return { ok = false, error = "Unknown command " .. tostring(command.type) }
			end
			return handler(command.args or {})
		end, debug.traceback)
		if not ok then
			result = { ok = false, error = tostring(result) }
		end
		result.commandId = command.id
		table.insert(pendingResults, result)
		pushNow()
	end

	local logConnection = LogService.MessageOut:Connect(function(message, messageType)
		if string.find(message, "[StudioBridge]", 1, true) == 1 and messageType == Enum.MessageType.MessageOutput then
			return
		end
		table.insert(pendingLogs, { t = os.time(), type = messageType.Name, message = message })
		if #pendingLogs > 500 then
			table.remove(pendingLogs, 1)
		end
	end)
	table.insert(host.connections, logConnection)

	if context ~= "edit" and generation == 1 then
		-- Play-test DataModels start after errors may already have been logged.
		for _, entry in LogService:GetLogHistory() do
			table.insert(pendingLogs, { t = entry.timestamp, type = entry.messageType.Name, message = entry.message })
		end
	end

	host.onUnload = function()
		if transport == "http" then
			pcall(request, "bye", {}, 2)
		end
	end

	task.spawn(function()
		while isAlive() do
			task.wait(0.5)
			pushNow()
		end
	end)

	-- Server side of the client relay: poll and push over HTTP on behalf of each client session.
	local function startRelayServer()
		local existing = ReplicatedStorage:FindFirstChild(RELAY_NAME)
		if existing then
			existing:Destroy()
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = RELAY_NAME
		remote.Archivable = false
		remote.Parent = ReplicatedStorage
		local clients = {}
		local connection = remote.OnServerEvent:Connect(function(player, kind, payload)
			if kind == "hello" then
				local entry = clients[player]
				if entry and entry.info.id == payload.id then
					return
				end
				entry = { info = payload, active = true }
				clients[player] = entry
				task.spawn(function()
					while entry.active and isAlive() and player.Parent do
						local body = table.clone(entry.info)
						body.logs = {}
						local ok, response = pcall(httpRequest, "poll", body, 30)
						if ok and response.Success then
							local data = HttpService:JSONDecode(response.Body)
							if data.commands and #data.commands > 0 then
								remote:FireClient(player, "commands", data.commands)
							end
						else
							task.wait(2)
						end
					end
					local bye = table.clone(entry.info)
					pcall(httpRequest, "bye", bye, 2)
				end)
			elseif kind == "chunk" then
				local entry = clients[player]
				if entry then
					entry.chunks = entry.chunks or {}
					local key = `{payload.commandId}:{payload.field}`
					entry.chunks[key] = entry.chunks[key] or {}
					entry.chunks[key][payload.index] = payload.data
				end
			elseif kind == "push" then
				local entry = clients[player]
				if entry then
					for _, r in payload.results or {} do
						for _, field in { "rgb", "png" } do
							local total = r[field .. "Chunks"]
							if total then
								local key = `{r.commandId}:{field}`
								local parts = entry.chunks and entry.chunks[key] or {}
								r[field] = table.concat(parts, "", 1, total)
								r[field .. "Chunks"] = nil
								entry.chunks[key] = nil
							end
						end
					end
					-- Drop anything HttpService cannot encode rather than losing the whole batch.
					local function encodable(value)
						return pcall(HttpService.JSONEncode, HttpService, { value })
					end
					local logs = {}
					for _, entry2 in payload.logs or {} do
						if encodable(entry2) then
							table.insert(logs, entry2)
						end
					end
					local results = {}
					for _, r in payload.results or {} do
						if not encodable(r) then
							local bad = {}
							for k, value in r do
								if not encodable(value) then
									table.insert(bad, `{k}:{typeof(value)}`)
									r[k] = nil
								end
							end
							r.ok = false
							r.error = "relay could not encode fields: " .. table.concat(bad, ", ")
							if not encodable(r) then
								r = { commandId = r.commandId, ok = false, error = "relay could not encode result" }
							end
						end
						table.insert(results, r)
					end
					local body = table.clone(entry.info)
					body.logs = logs
					body.results = results
					local ok, err = pcall(httpRequest, "push", body, 30)
					if not ok then
						warn("[StudioBridge] relay forward failed: " .. tostring(err))
					end
				end
			end
		end)
		table.insert(host.connections, connection)
		table.insert(host.connections, Players.PlayerRemoving:Connect(function(player)
			if clients[player] then
				clients[player].active = false
				clients[player] = nil
			end
		end))
	end

	local function httpWorks()
		local ok, response = pcall(request, "push", { logs = {} }, 5)
		return ok and response.Success
	end

	task.spawn(function()
		if context == "client" then
			while not Players.LocalPlayer do
				task.wait(0.1)
			end
		end
		if context == "client" and not httpWorks() then
			transport = "relay"
			relay = ReplicatedStorage:WaitForChild(RELAY_NAME, 60)
			if not relay then
				return
			end
			table.insert(host.connections, relay.OnClientEvent:Connect(function(kind, commands)
				if kind == "commands" then
					for _, command in commands do
						task.spawn(execute, command)
					end
				end
			end))
			relay:FireServer("hello", info())
			return
		end
		if context == "server" then
			startRelayServer()
		end
		local warned = false
		while isAlive() do
			local ok, response = pcall(request, "poll", { logs = {} }, 30)
			if ok and response.Success then
				warned = false
				local data = HttpService:JSONDecode(response.Body)
				for _, command in data.commands or {} do
					task.spawn(execute, command)
				end
			else
				if not warned then
					warned = true
					print(`[StudioBridge] waiting for MCP bridge on port {PORT} ({context})`)
				end
				task.wait(2)
			end
		end
	end)
end
