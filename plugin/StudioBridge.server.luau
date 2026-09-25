--!nocheck
-- StudioBridge bootstrap. Fetches the bridge core from the local MCP server and runs it, so the core can be
-- updated with the `reload` command without reinstalling this plugin or restarting Studio.

local HttpService = game:GetService("HttpService")

local SOURCE_URL = "http://127.0.0.1:44777/plugin/source"

local host = {
	sessionId = HttpService:GenerateGUID(false),
	generation = 0,
	alive = true,
	connections = {},
	onUnload = nil,
	bundle = script,
}

local hasLoadstring = pcall(function()
	assert(loadstring("return 1"))
end)

local function fetchSource()
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = SOURCE_URL,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode({ id = host.sessionId }),
	})
	if ok and response.Success then
		return HttpService:JSONDecode(response.Body).source
	end
	return nil
end

function host.reload()
	for _, connection in host.connections do
		connection:Disconnect()
	end
	host.connections = {}
	host.generation += 1
	-- Hot-reloadable core from the bridge where possible, otherwise the copy bundled with the plugin.
	local source = if hasLoadstring then fetchSource() else nil
	if source then
		local chunk, err = loadstring(source, "=StudioBridgeCore")
		if chunk then
			task.spawn(chunk(), plugin, host)
			return
		end
		warn("[StudioBridge] core failed to compile: " .. tostring(err))
	end
	task.spawn(require(script:WaitForChild("Core")), plugin, host)
end

plugin.Unloading:Connect(function()
	host.alive = false
	if host.onUnload then
		host.onUnload()
	end
end)

task.spawn(host.reload)
