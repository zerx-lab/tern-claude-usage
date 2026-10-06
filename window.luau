--!strict
-- Window half: palette commands that pop the usage block up as a floating panel, and a
-- status-line segment fed by the host poller's summary in kv "status".

local time = require("./lib/time")
local KIND = "claude-usage.usage"

type Window = { pct: number?, resets_at: number? }
type Row = { label: string?, plan: string?, error: string?, session: Window?, weekly: Window? }

local summary: { updated: number?, enabled: boolean?, accounts: { Row } }? = nil

local function read_summary(): boolean
	local ok, s = pcall(tern.kv.get, "status")
	if not ok or type(s) ~= "table" then
		return false
	end
	local changed = summary == nil or (summary :: any).updated ~= s.updated
	summary = s
	return changed
end

local function pct(w: Window?): string
	if w == nil or w.pct == nil then
		return "—"
	end
	return string.format("%d%%", math.floor((w.pct :: number) + 0.5))
end

local function tone(row: Row): string?
	local worst = 0
	for _, w in { row.session, row.weekly } do
		if w and w.pct then
			worst = math.max(worst, w.pct :: number)
		end
	end
	if worst >= 85 then
		return "error"
	elseif worst >= 60 then
		return "warn"
	end
	return "muted"
end

tern.chrome.status(function(_pane)
	local s = summary
	if s == nil or s.enabled == false or #s.accounts == 0 then
		return nil
	end
	local row = s.accounts[1]
	if row.session == nil and row.weekly == nil then
		if row.error then
			return { { text = "Claude ⚠", icon = "sparkle", tone = "error", command = "plugin.claude-usage.open" } }
		end
		return nil
	end
	local now = os.time()
	local text = "5h " .. pct(row.session)
	local session = row.session
	if session and session.resets_at and (session.resets_at :: number) > now then
		text ..= " (" .. time.short((session.resets_at :: number) - now) .. ")"
	end
	text ..= " · 7d " .. pct(row.weekly)
	if #s.accounts > 1 then
		text ..= string.format(" +%d", #s.accounts - 1)
	end
	return { { text = text, icon = "sparkle", tone = tone(row), command = "plugin.claude-usage.open" } }
end)

-- The countdown in the segment moves by the minute; the data by the host's poll.
local last_minute = -1
local function watch()
	local minute = os.time() // 60
	if read_summary() or minute ~= last_minute then
		last_minute = minute
		tern.chrome.refresh()
	end
	tern.timer(15000, watch)
end
read_summary()
tern.timer(1000, watch)

-- The usage block in the focused pane's tab, if any.
local function find_panel(cx: WindowCx): (PaneInfo?, number?)
	local focused = cx.session:focused()
	local here = if focused then cx.session:pane(focused) else nil
	local tab = here and here.tab
	for _, p in cx.session:panes() do
		if p.block == KIND and p.tab == tab then
			return p, focused
		end
	end
	return nil, focused
end

-- Opens a usage block floating in the top-right corner over the focused tiled pane.
local function pop_up(cx: WindowCx, focused: number?, args: { string }?)
	local over = focused
	if over then
		local info = cx.session:pane(over)
		if info == nil or info.floating then
			over = nil
		end
	end
	local pane = cx:new_block(KIND, args)
	if pane then
		cx.layout:float(pane, over, "tr")
	end
end

tern.command({
	id = "open",
	title = "Claude 用量：显示 / 隐藏额度浮窗",
	icon = "sparkle",
	run = function(cx)
		local panel, focused = find_panel(cx)
		if panel == nil then
			pop_up(cx, focused)
		elseif panel.floating then
			cx.layout:close(panel.pane)
		else
			cx.layout:float(panel.pane, nil, "tr")
			cx.layout:focus(panel.pane)
		end
	end,
})

tern.command({
	id = "login",
	title = "Claude 用量：登录订阅账户",
	icon = "sparkle",
	run = function(cx)
		-- Launch arguments only reach a new block, so an open panel is replaced.
		local panel, focused = find_panel(cx)
		if panel then
			cx.layout:close(panel.pane)
		end
		pop_up(cx, focused, { "login" })
	end,
})
