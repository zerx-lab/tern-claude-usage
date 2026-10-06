--!strict
-- Interactive OAuth login for a block: PKCE, a one-shot loopback listener (`nc -l 54545`) that
-- catches the browser redirect, and a paste fallback (`code#state` or the redirect URL).

local creds = require("./creds")
local oauth = require("./oauth")

local M = {}

export type Flow = {
	-- "starting" | "waiting" | "exchanging" | "error" | "done" | "cancelled"
	phase: string,
	url: string?,
	redirect: string?,
	pkce: oauth.Pkce?,
	-- Whether the loopback listener is up (the redirect lands here by itself).
	listening: boolean,
	input: string,
	error: string?,
	-- Ends a stale flow's callbacks.
	token: number,
	-- Runs whenever the flow changes.
	changed: () -> (),
	-- Runs with the stored account id after a successful login.
	finished: (string) -> (),
}

local RESPONSE = table.concat({
	"HTTP/1.1 200 OK",
	"Content-Type: text/html; charset=utf-8",
	"Connection: close",
	"",
	"<!doctype html><meta charset=utf-8><title>Claude 登录</title>"
		.. "<body style='font-family:system-ui;padding:3em;text-align:center'>"
		.. "<h2>已收到授权</h2><p>可以关闭此页面，回到 Tern 查看 Claude 用量。</p></body>",
}, "\r\n")

local seq = 0

local function open_browser(url: string, cx: BlockCx)
	local argv = if tern.runtime.os == "macos" then { "open", url } elseif tern.runtime.os == "linux" then { "xdg-open", url } else nil
	if argv then
		local ok = pcall(tern.process.run, argv, { timeout_ms = 10000 }, function(r)
			if r.status ~= 0 then
				cx:open(url)
			end
		end)
		if ok then
			return
		end
	end
	cx:open(url)
end
M.open_browser = open_browser

-- Releases a listener nobody will hit (cancel, or a paste won the race).
local function poke_listener()
	tern.fetch("http://localhost:" .. oauth.CALLBACK_PORT .. "/cancel", { timeout_ms = 2000 }, function(_r) end)
end

local function live(flow: Flow, token: number): boolean
	return flow.token == token and flow.phase ~= "cancelled" and flow.phase ~= "done"
end

function M.submit_code(flow: Flow, code: string, state: string?)
	local p = flow.pkce
	if not p or flow.phase == "exchanging" or not live(flow, flow.token) then
		return
	end
	local pkce = p :: oauth.Pkce
	if state and state ~= pkce.state then
		flow.error = "state 不匹配：请使用本次登录打开的授权页返回的授权码"
		flow.changed()
		return
	end
	flow.phase, flow.error = "exchanging", nil
	local token = flow.token
	flow.changed()
	oauth.exchange(code, pkce.state, pkce, flow.redirect :: string, function(tokens, err)
		if flow.token ~= token or flow.phase ~= "exchanging" then
			return
		end
		if not tokens then
			flow.phase, flow.error = "waiting", "换取令牌失败：" .. tostring(err)
			flow.changed()
			return
		end
		if flow.listening then
			poke_listener()
		end
		local id = creds.own_upsert(tokens :: oauth.Tokens)
		flow.phase = "done"
		flow.finished(id)
	end)
end

-- Handles pasted or typed text: submits it when it holds a code.
function M.submit_text(flow: Flow, text: string): boolean
	local code, state = oauth.parse_pasted(text)
	if not code then
		flow.error = "没有识别到授权码：粘贴浏览器地址栏里的回调 URL，或页面上显示的 code#state"
		return false
	end
	M.submit_code(flow, code :: string, state)
	return true
end

-- Starts a flow and opens the authorize page in the browser.
function M.start(cx: BlockCx, changed: () -> (), finished: (string) -> ()): Flow
	seq += 1
	local token = seq
	local flow: Flow = {
		phase = "starting",
		listening = false,
		input = "",
		token = token,
		changed = changed,
		finished = finished,
	}

	creds.random_bytes(function(random)
		if not live(flow, token) then
			return
		end
		local p = oauth.pkce(random)
		flow.pkce = p
		local listener_exited = false
		local ok = pcall(tern.process.run, { "nc", "-l", tostring(oauth.CALLBACK_PORT) }, { stdin = RESPONSE, timeout_ms = 600000 }, function(r)
			listener_exited = true
			flow.listening = false
			if not live(flow, token) or flow.redirect ~= oauth.LOOPBACK_REDIRECT then
				return
			end
			local code, state, err = oauth.parse_callback_request(r.stdout)
			if code then
				M.submit_code(flow, code :: string, state)
			elseif err then
				flow.error = "授权被拒绝：" .. (err :: string)
				flow.changed()
			else
				flow.changed()
			end
		end)
		-- A bind failure (port taken, no nc) exits at once; give it a moment before choosing.
		tern.timer(400, function()
			if not live(flow, token) then
				return
			end
			flow.listening = ok and not listener_exited
			flow.redirect = if flow.listening then oauth.LOOPBACK_REDIRECT else oauth.MANUAL_REDIRECT
			flow.url = oauth.authorize_url(p, flow.redirect :: string)
			flow.phase = "waiting"
			open_browser(flow.url :: string, cx)
			flow.changed()
		end)
	end)
	return flow
end

function M.cancel(flow: Flow)
	if flow.listening then
		poke_listener()
	end
	flow.phase = "cancelled"
	flow.token = -1
end

return M
