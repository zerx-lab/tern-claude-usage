--!strict
-- Block `claude-usage.usage`: Claude Pro/Max quota windows (5 h, 7 d, per-model weekly, extra
-- usage) for every known login, refreshed on a timer. Launch argument "login" starts a login.

local login = require("./lib/login")
local poller = require("./lib/poller")
local view = require("./lib/view")

type State = view.BlockState

local function close_flow(st: State)
	if st.flow then
		login.cancel(st.flow)
		st.flow = nil
	end
end

local function start_login(st: State)
	close_flow(st)
	local cx = st.cx
	st.flow = login.start(cx, function()
		cx:render()
	end, function(id)
		st.flow = nil
		-- The new account appears after the tick reloads the sources; the view selects it then.
		st.want = id
		cx:toast("success", "Claude 账户已登录", "正在获取用量")
		poller.tick(true)
		cx:render()
	end)
end

local function selected(st: State): poller.Entry?
	return view.visible()[st.sel]
end

local function cycle_interval(delta: number)
	local list = poller.INTERVALS
	local cur = poller.state.settings.interval
	local idx = 1
	for i, v in list do
		if v <= cur then
			idx = i
		end
	end
	idx = math.clamp(idx + delta, 1, #list)
	poller.set_setting("interval", list[idx])
	poller.tick(false)
end

local function toggle(key: string)
	poller.set_setting(key, not (poller.state.settings :: any)[key])
	poller.tick(false)
end

local function login_key(st: State, key: Key): boolean
	local flow = st.flow
	if key.name == "escape" then
		close_flow(st)
	elseif key.name == "paste" then
		flow.input = string.gsub(key.text or "", "%s+", "")
		login.submit_text(flow, flow.input)
	elseif key.name == "enter" then
		login.submit_text(flow, flow.input)
	elseif key.name == "backspace" then
		flow.input = string.sub(flow.input, 1, -2)
	elseif key.text and #key.text > 0 and not key.ctrl and not key.meta then
		flow.input ..= key.text
	else
		return false
	end
	return true
end

local usage_block: BlockDef<State> = {
	init = function(cx, args, _saved)
		local st: State = { cx = cx, sel = 1, flow = nil, help = false, confirm = nil, want = nil }
		poller.subscribe(cx)
		if args[1] == "login" then
			start_login(st)
		end
		return st
	end,

	title = view.title,

	view = view.render,

	key = function(st, key, _cx)
		if st.flow and st.flow.phase ~= "starting" and st.flow.phase ~= "exchanging" then
			return login_key(st, key)
		end
		if st.flow and key.name == "escape" then
			close_flow(st)
			return true
		end
		local n = #view.visible()
		local name = key.name
		if name == "r" then
			poller.tick(true)
		elseif name == "l" then
			start_login(st)
		elseif name == "j" or name == "down" then
			st.sel = math.min(st.sel + 1, math.max(n, 1))
		elseif name == "k" or name == "up" then
			st.sel = math.max(st.sel - 1, 1)
		elseif name == "x" or name == "delete" or name == "backspace" then
			local e = selected(st)
			if e and e.account.kind == "own" then
				st.confirm = e.account.id
			elseif e then
				st.cx:toast("info", "只能移除本插件登录的账户", "Claude Code / omp 的登录请在对应工具中退出，或用 c / o 关闭来源")
			end
		elseif name == "enter" and st.confirm then
			poller.remove_own(st.confirm :: string)
			st.confirm = nil
			st.sel = math.max(math.min(st.sel, #view.visible()), 1)
		elseif name == "escape" and st.confirm then
			st.confirm = nil
		elseif name == "+" or name == "=" then
			cycle_interval(1)
		elseif name == "-" then
			cycle_interval(-1)
		elseif name == "c" then
			toggle("claude_code")
		elseif name == "o" then
			toggle("omp")
		elseif name == "s" then
			poller.set_setting("status_line", not poller.state.settings.status_line)
			poller.tick(false)
		elseif name == "?" or (name == "/" and key.shift) or name == "h" then
			st.help = not st.help
		else
			return false
		end
		return true
	end,

	event = function(st, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		local act, value = ev.act, ev.value
		if act == "refresh" then
			poller.tick(true)
		elseif act == "login" then
			start_login(st)
		elseif act == "logout" then
			st.confirm = view.own_target(st)
		elseif act == "cancel" then
			close_flow(st)
		elseif act == "open_url" and st.flow and st.flow.url then
			cx:open(st.flow.url)
		elseif act == "copy_url" and st.flow and st.flow.url then
			cx:copy(st.flow.url)
			cx:toast("info", "授权链接已复制")
		elseif act == "select" then
			for i, e in view.visible() do
				if e.account.id == value then
					st.sel = i
				end
			end
		elseif act == "remove" and value then
			poller.remove_own(value)
			st.confirm = nil
			st.sel = math.max(math.min(st.sel, #view.visible()), 1)
		elseif act == "keep" then
			st.confirm = nil
		elseif act == "help" then
			st.help = not st.help
		end
	end,
}

tern.block.define("usage", usage_block)

poller.start()
