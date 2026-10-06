--!strict
-- The usage block's view: one card per account with a one-line meter per quota window, pace
-- against an even spend, reset countdowns, extra-usage spend and a short history; plus the login
-- panel. Layout follows the pane width (`cx.cols`): text never wraps, secondary details drop out
-- as the pane narrows, and the full detail stays in tooltips.

local poller = require("./poller")
local time = require("./time")
local usage = require("./usage")

local ui = tern.ui

local M = {}

export type BlockState = {
	cx: BlockCx,
	sel: number,
	flow: any,
	help: boolean,
	confirm: string?,
	-- Account id to select once it shows up (after a login).
	want: string?,
}

-- Width classes: narrow < 60 cells ≤ medium < 90 cells ≤ wide.
type Fit = { narrow: boolean, wide: boolean }

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- One line of text, cut with … when it doesn't fit.
local function line(spans: { Span }, props: { [string]: any }?): Node
	local p: { [string]: any } = { spans = spans, truncate = "end" }
	for k, v in props or {} do
		p[k] = v
	end
	return ui.node("text", p)
end

local function button(text: string, tone: string, action: string, title: string?): Node
	return with(ui.badge(text, tone), { actions = { click = action }, key = "btn:" .. action, title = title, basis = "content" })
end

local function pct_text(p: number?): string
	if p == nil then
		return "—"
	end
	local r = math.floor(p * 10 + 0.5) / 10
	if r == math.floor(r) then
		return string.format("%d%%", r)
	end
	return string.format("%.1f%%", r)
end

local function money(v: number?, currency: string?): string
	if v == nil then
		return "—"
	end
	local sym = if currency == nil or currency == "USD" then "$" else currency .. " "
	return sym .. string.format("%.2f", v)
end

local SOURCE = { own = "插件登录", ["claude-code"] = "Claude Code", omp = "omp" }
M.SOURCE = SOURCE

local DATA_SOURCE = { api = "API", ["claude-code-cache"] = "CC 缓存", disk = "缓存" }

-- Short window names for the label column: 5h, 7d, 7d Opus, the bucket key.
local function short_label(w: usage.Window): string
	if w.id == "5h" or w.id == "7d" then
		return w.id
	end
	local scoped = string.match(w.label, "^7 天 · (.+)$")
	if scoped then
		return "7d " .. scoped
	end
	return (string.gsub(w.label, "^其他额度 · ", ""))
end

-- Reset column: a live countdown inside a day, else `2d13h`; the local time when wide.
local function reset_node(w: usage.Window, now: number, fit: Fit): Node
	local props = { gap = "xs", basis = "content", key = "reset" }
	if w.resets_at == nil then
		return ui.node("row", props, { line({ ui.span(if w.kind == "session" then "未开始" else "", "muted") }) })
	end
	local at = w.resets_at :: number
	local left = at - now
	if left <= 0 then
		return ui.node("row", props, { line({ ui.span("已重置", "muted") }) })
	end
	local children: { Node } = {}
	if left < 86400 then
		table.insert(children, with(ui.node("elapsed", { age = -left * 1000, format = "short" }), { title = "距重置" }))
	else
		table.insert(children, line({ ui.span(time.short(left), "num") }, { title = "距重置 " .. time.duration(left) }))
	end
	if fit.wide then
		table.insert(children, line({ ui.span(time.clock(at, now), "muted") }))
	end
	return with(ui.node("row", props, children), { title = "重置于 " .. time.clock(at, now) })
end

-- One muted line under a window: the pace against an even spend. Narrow panes only get it when the
-- window runs out before its reset.
local function pace_line(w: usage.Window, now: number, fit: Fit): (Node?, string?)
	local pace = usage.pace(w, now)
	if not pace then
		return nil, nil
	end
	local pc = pace :: usage.Pace
	local spans: { Span } = {}
	local tip = string.format("时间已过 %d%%", math.floor(pc.elapsed * 100 + 0.5))
	local function add(text: string, style: string)
		if #spans > 0 then
			table.insert(spans, ui.span(" · ", "dim"))
		end
		table.insert(spans, ui.span(text, style))
	end
	if pc.exhaust_in then
		local t = pc.exhaust_in :: number
		add(string.format("约 %s 后用尽 %s", time.short(t), time.clock(now + t, now)), "error")
		tip ..= string.format(" · 按当前速度约 %s 后用尽", time.duration(t))
	elseif pc.projected then
		local proj = math.min(pc.projected :: number, 100)
		tip ..= " · 预计重置时约 " .. pct_text(proj)
		if not fit.narrow then
			add("预计 " .. pct_text(proj), if proj >= 85 then "warning" else "muted")
		end
	end
	if not fit.narrow and math.abs(pc.delta) >= 1 and (w.pct or 0) > 0 then
		local ahead = pc.delta > 0
		add(string.format("节奏 %s%d%%", if ahead then "+" else "−", math.floor(math.abs(pc.delta) + 0.5)), if ahead and pc.delta >= 10 then "warning" elseif ahead then "muted" else "success")
	end
	if #spans == 0 then
		return nil, tip
	end
	return line(spans, { key = "p:" .. w.id, title = tip }), tip
end

local LABEL_W = { narrow = "6ch", medium = "9ch" }

local function window_rows(w: usage.Window, now: number, fit: Fit): { Node }
	local rows: { Node } = {}
	local pace = usage.pace(w, now)
	local pace_node, tip = pace_line(w, now, fit)
	local props: { [string]: any } = {
		value = (w.pct or 0) / 100,
		thresholds = { warn = 0.6, bad = 0.85 },
		label = nil,
		size = "sm",
		grow = 1,
		title = w.label .. " " .. pct_text(w.pct) .. (if tip then " · " .. tip else ""),
	}
	if pace then
		props.marks = { { at = (pace :: usage.Pace).elapsed, tone = "muted", title = "时间进度" } }
	end
	if w.dollars and not fit.narrow then
		local d = w.dollars :: any
		props.total = money(d.used, nil) .. "/" .. money(d.limit, nil)
	end
	local width = if fit.narrow then LABEL_W.narrow else LABEL_W.medium
	table.insert(rows, ui.node("row", { gap = "sm", key = "w:" .. w.id }, {
		line({ ui.span(short_label(w), if w.active then "strong" else "") }, { min = { w = width }, max = { w = width }, basis = "content", title = w.label .. (if w.active then "（当前生效的限制）" else "") }),
		ui.node("meter", props),
		line({ ui.span(pct_text(w.pct), "num") }, { min = { w = "6ch" }, basis = "content", key = "pct", title = "已用 " .. pct_text(w.pct) }),
		reset_node(w, now, fit),
	}))
	if pace_node then
		table.insert(rows, with(pace_node :: Node, { min = { w = 0 } }))
	end
	if w.locked then
		table.insert(rows, line({ ui.span("已锁定: " .. (w.locked :: string), "error") }, { key = "l:" .. w.id }))
	end
	return rows
end

local REASONS = {
	user_disabled = "已在设置中关闭",
	out_of_credits = "额度用完",
	org_level_disabled = "组织禁用",
}

local function extra_row(x: usage.Extra, fit: Fit): Node
	local width = if fit.narrow then LABEL_W.narrow else LABEL_W.medium
	local label = line({ ui.span("额外") }, { min = { w = width }, max = { w = width }, basis = "content", title = "额外用量（本月）" })
	if not x.enabled then
		local reason = if x.reason then REASONS[x.reason :: string] or (x.reason :: string) else nil
		return ui.node("row", { gap = "sm", key = "extra" }, {
			label,
			line({ ui.span("未启用" .. (if reason and not fit.narrow then " · " .. reason else ""), "muted") }, { title = reason }),
		})
	end
	if x.limit then
		return ui.node("row", { gap = "sm", key = "extra" }, {
			label,
			ui.node("meter", {
				value = (x.pct or 0) / 100,
				thresholds = { warn = 0.6, bad = 0.9 },
				label = money(x.used, x.currency),
				total = "/ " .. money(x.limit, x.currency),
				size = "sm",
				grow = 1,
				title = "额外用量（本月）",
			}),
		})
	end
	return ui.node("row", { gap = "sm", key = "extra" }, {
		label,
		line({ ui.span(money(x.used, x.currency), "num"), ui.span(" 已用 · 无上限", "muted") }),
	})
end

local function history_row(e: poller.Entry, fit: Fit): Node?
	if fit.narrow then
		return nil
	end
	local s: { { any } } = {}
	local w: { { any } } = {}
	for _, sample in e.history do
		local label = os.date("%H:%M", math.floor(sample.t)) :: string
		if sample.s then
			table.insert(s, { label, sample.s })
		end
		if sample.w then
			table.insert(w, { label, sample.w })
		end
	end
	local children: { Node } = {}
	local width = LABEL_W.medium
	if #s >= 3 then
		table.insert(children, line({ ui.span("5h 走势", "muted") }, { min = { w = width }, max = { w = width }, basis = "content" }))
		table.insert(children, with(ui.spark(s), { grow = 1 }))
	end
	if #w >= 3 and fit.wide then
		table.insert(children, line({ ui.span("7d", "muted") }, { basis = "content" }))
		table.insert(children, with(ui.spark(w), { grow = 1 }))
	end
	if #children == 0 then
		return nil
	end
	return ui.node("row", { gap = "sm", key = "hist" }, children)
end

local function account_card(e: poller.Entry, selected: boolean, confirm: boolean, now: number, fit: Fit): Node
	local plan = poller.plan(e)
	local head: { Span } = { ui.span(poller.label(e), "strong") }
	if plan then
		table.insert(head, ui.span(" " .. (plan :: string), "accent"))
	end
	if not fit.narrow then
		table.insert(head, ui.span(" · " .. (SOURCE[e.account.kind] or e.account.kind), "muted"))
	end

	local body: { Node } = {}
	if e.account.problem then
		table.insert(body, line({ ui.span("omp 已停用此凭据", "error") }, { title = e.account.problem }))
	end
	if e.usage then
		local u = e.usage :: usage.Usage
		for _, w in u.windows do
			for _, row in window_rows(w, now, fit) do
				table.insert(body, row)
			end
		end
		if u.extra then
			table.insert(body, extra_row(u.extra :: usage.Extra, fit))
		end
		local hist = history_row(e, fit)
		if hist then
			table.insert(body, hist :: Node)
		end
	elseif not e.error and not e.account.problem then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("获取用量…", "muted") } }))
	end

	local foot: { Node } = {}
	if e.busy then
		table.insert(foot, ui.node("spinner", { style = "dots", label = { ui.span(if e.busy == "refresh" then "刷新令牌" else "获取中", "muted") } }))
	elseif e.fetched_at then
		local age = math.max(0, now - (e.fetched_at :: number))
		table.insert(foot, line({ ui.span("更新于", "dim") }, { basis = "content" }))
		table.insert(foot, ui.node("elapsed", { age = age * 1000, format = "short" }))
		table.insert(foot, line({ ui.span("前" .. (if fit.narrow then "" else " · " .. (DATA_SOURCE[e.data_source or ""] or "?")), "dim") }))
	end
	if e.backoff_until and (e.backoff_until :: number) > now then
		table.insert(foot, line({ ui.span("· 重试", "dim") }, { basis = "content" }))
		table.insert(foot, ui.node("elapsed", { age = -((e.backoff_until :: number) - now) * 1000, format = "short" }))
	end
	if #foot > 0 then
		table.insert(body, ui.node("row", { gap = "xs", key = "foot" }, foot))
	end
	if e.error then
		table.insert(body, ui.node("text", { spans = { ui.span(e.error :: string, "error") }, lines = 2, key = "err", title = e.error }))
	end
	if e.account.kind == "own" and confirm then
		table.insert(body, ui.node("row", { key = "rm", gap = "sm" }, {
			line({ ui.span("移除此登录？", "warning") }),
			button("移除", "error", "remove=" .. e.account.id),
			button("取消", "neutral", "keep"),
		}))
	end

	local org = e.profile and e.profile.org_name
	return with(ui.card(head, body), {
		key = "acct:" .. e.account.id,
		tone = if e.error or e.account.problem then "error" else nil,
		mark = if selected then "pick" else nil,
		actions = { click = "select=" .. e.account.id },
		title = (SOURCE[e.account.kind] or e.account.kind) .. (if org then " · " .. (org :: string) else ""),
	})
end

local function login_card(flow: any, fit: Fit): Node
	local body: { Node } = {}
	if flow.phase == "starting" then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("准备登录…", "muted") } }))
	elseif flow.phase == "exchanging" then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("换取令牌…", "muted") } }))
	else
		local hint = if flow.listening
			then "在浏览器授权后自动完成；打不开 localhost 时粘贴地址栏 URL"
			else "授权后复制页面上的 code#state，在此粘贴（⌘V）"
		table.insert(body, ui.node("text", { spans = { ui.span(hint, "muted") }, lines = if fit.narrow then 3 else 2 }))
		local input = flow.input ~= "" and flow.input or nil
		table.insert(body, line({
			ui.span("› ", "accent"),
			if input then ui.span(input, "code") else ui.span("粘贴回调 URL 或授权码", "dim"),
		}, { truncate = "start" }))
	end
	if flow.error then
		table.insert(body, ui.node("text", { spans = { ui.span(flow.error, "error") }, lines = 2, title = flow.error }))
	end
	local actions: { Node } = {}
	if flow.url then
		table.insert(actions, button("打开授权页", "accent", "open_url"))
		table.insert(actions, button("复制链接", "neutral", "copy_url"))
	end
	table.insert(actions, button("重来", "neutral", "login"))
	table.insert(actions, button("取消", "neutral", "cancel", "Esc"))
	table.insert(body, ui.node("row", { gap = "sm", wrap = true }, actions))
	return with(ui.card({ ui.span("登录 Claude 账户", "strong") }, body), { key = "login", tone = "accent" })
end

local KEYS = {
	{ { "r" }, "立即刷新" },
	{ { "l" }, "登录账户" },
	{ { "j", "k" }, "选择账户" },
	{ { "x" }, "移除插件登录的账户" },
	{ { "+", "-" }, "刷新间隔" },
	{ { "c" }, "开关 Claude Code 来源" },
	{ { "o" }, "开关 omp 来源" },
	{ { "s" }, "开关状态栏" },
	{ { "?" }, "显示/隐藏本说明" },
}

local function help_card(): Node
	local s = poller.state.settings
	local function onoff(v: boolean): string
		return if v then "开" else "关"
	end
	local keys: { Node } = {}
	for i, k in KEYS do
		table.insert(keys, ui.node("row", { gap = "xs", key = "k" .. i, basis = "content" }, {
			ui.node("kbd", { keys = k[1] }),
			line({ ui.span(k[2], "muted") }),
		}))
	end
	return with(ui.card({ ui.span("按键与设置", "strong") }, {
		ui.node("row", { gap = "md", wrap = true }, keys),
		ui.node("text", { spans = {
			ui.span(string.format("刷新 %ds（后台 %ds）· Claude Code %s · omp %s · 状态栏 %s", s.interval, s.background, onoff(s.claude_code), onoff(s.omp), onoff(s.status_line)), "muted"),
		} }),
		ui.node("text", { spans = {
			ui.span("进度条上的竖线是窗口已过去的时间比例；用量超过它说明比均匀使用更快。悬停各行可看完整说明。", "dim"),
		} }),
	}), { key = "help" })
end

function M.title(_st: BlockState): string?
	for _, e in poller.state.entries do
		if e.usage and not e.duplicate_of then
			local s, w
			for _, win in (e.usage :: usage.Usage).windows do
				if win.id == "5h" then
					s = win.pct
				elseif win.id == "7d" then
					w = win.pct
				end
			end
			return string.format("Claude 5h %s · 7d %s", pct_text(s), pct_text(w))
		end
	end
	return "Claude 用量"
end

function M.visible(): { poller.Entry }
	local out: { poller.Entry } = {}
	for _, e in poller.state.entries do
		if not e.duplicate_of then
			table.insert(out, e)
		end
	end
	return out
end

-- The plugin-login account the header's logout button acts on: the selected one, else the first.
function M.own_target(st: BlockState): string?
	local entries = M.visible()
	local cur = entries[st.sel]
	if cur and cur.account.kind == "own" then
		return cur.account.id
	end
	for _, e in entries do
		if e.account.kind == "own" then
			return e.account.id
		end
	end
	return nil
end

function M.render(st: BlockState, cx: BlockCx): BlockView
	local now = os.time()
	local cols = cx.cols or 80
	local fit: Fit = { narrow = cols < 60, wide = cols >= 90 }
	if st.want then
		for i, e in M.visible() do
			if e.account.id == st.want then
				st.sel, st.want = i, nil
			end
		end
	end
	local s = poller.state
	local main: { Node } = {}

	local status: Node
	if s.ticking then
		status = ui.node("spinner", { style = "dots", key = "status", basis = "content", title = "刷新中" })
	elseif s.next_at then
		status = with(ui.node("elapsed", { age = -math.max(0, (s.next_at :: number) - now) * 1000, format = "short" }), { key = "status", title = "下次刷新" })
	else
		status = line({ ui.span("已暂停", "dim") }, { key = "status", basis = "content", title = "状态栏关闭且面板未打开时不轮询" })
	end
	table.insert(main, ui.node("row", { gap = "sm", key = "head" }, {
		line({ ui.span(if fit.narrow then "Claude" else "Claude 订阅额度", "strong") }, { grow = 1, min = { w = 0 } }),
		status,
		button("刷新", "accent", "refresh", "r"),
		(function(): Node
			local own = M.own_target(st)
			if own then
				return button("退出登录", "neutral", "logout", "移除插件登录的账户（需确认）")
			end
			return button("登录", "neutral", "login", "l：登录 Claude 订阅账户")
		end)(),
		button("?", "neutral", "help", "按键与设置"),
	}))

	if st.flow then
		table.insert(main, login_card(st.flow, fit))
	end
	if st.help then
		table.insert(main, help_card())
	end

	local entries = M.visible()
	for i, e in entries do
		table.insert(main, account_card(e, i == st.sel and #entries > 1, st.confirm == e.account.id, now, fit))
	end
	local dups = #s.entries - #entries
	if dups > 0 then
		table.insert(main, line({ ui.span(string.format("另有 %d 个来源指向同一账户，已合并", dups), "dim") }, { key = "dups" }))
	end
	if #entries == 0 and not s.ticking and not st.flow then
		table.insert(main, with(ui.card({ ui.span("还没有 Claude 账户", "strong") }, {
			ui.node("text", { spans = { ui.span("按 l 登录 Pro / Max 账户；已登录 Claude Code 时会自动读取。", "muted") } }),
		}), { key = "empty" }))
	end

	return { main = ui.col(main) }
end

return M
