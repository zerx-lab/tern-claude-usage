--!strict
-- Window half: palette commands that pop the usage block up as a floating panel, and a
-- status-line segment fed by the host poller's summary in kv "status", showing the provider
-- picked by the block's tabs.

local time = require("./lib/time")
local KIND = "claude-usage.usage"

type Window = { pct: number?, resets_at: number? }
type Row = { provider: string?, label: string?, plan: string?, error: string?, session: Window?, weekly: Window? }

local summary: { updated: number?, enabled: boolean?, provider: string?, accounts: { Row } }? = nil

local function read_summary(): boolean
	local ok, s = pcall(tern.kv.get, "status")
	if not ok or type(s) ~= "table" then
		return false
	end
	local prev = summary :: any
	local changed = prev == nil or prev.updated ~= s.updated or prev.provider ~= s.provider
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

-- Claude's segment keeps its bare `5h 42% (2h13m) · 7d 18%`; others are prefixed with their name.
local PREFIX = { claude = "", gpt = "GPT " }
local NAME = { claude = "Claude", gpt = "GPT" }

tern.chrome.status(function(_pane)
	local s = summary
	if s == nil or s.enabled == false then
		return nil
	end
	local provider = s.provider or "claude"
	local rows: { Row } = {}
	for _, r in s.accounts do
		if (r.provider or "claude") == provider then
			table.insert(rows, r)
		end
	end
	local row = rows[1]
	if row == nil then
		return nil
	end
	if row.session == nil and row.weekly == nil then
		if row.error then
			return { { text = (NAME[provider] or provider) .. " ⚠", icon = "sparkle", tone = "error", command = "plugin.claude-usage.open" } }
		end
		return nil
	end
	local now = os.time()
	-- The first window present (5 h, else 7 d for plans without one) carries the reset countdown.
	local parts: { string } = {}
	for _, item in { { "5h", row.session }, { "7d", row.weekly } } do
		local w: Window? = item[2]
		if w then
			local part = item[1] .. " " .. pct(w)
			local at = w.resets_at
			if #parts == 0 and at and at > now then
				part ..= " (" .. time.short(at - now) .. ")"
			end
			table.insert(parts, part)
		end
	end
	local text = (PREFIX[provider] or "") .. table.concat(parts, " · ")
	if #rows > 1 then
		text ..= string.format(" +%d", #rows - 1)
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
	title = "订阅用量（Claude / GPT）：显示 / 隐藏额度浮窗",
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
