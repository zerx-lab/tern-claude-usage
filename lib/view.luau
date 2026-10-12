--!strict
-- The usage block's view: Claude / GPT tabs; a cross-account summary once a provider has two
-- accounts with data; the accounts as cards (one meter line per quota window, pace, reset
-- countdowns, extra spend or credits, a short history) or as compact one-line rows with the
-- selected account's card below; plus the login, rename, settings and help panels. Layout follows
-- the pane width (`cx.cols`): text never wraps, secondary details drop out as the pane narrows,
-- wide panes put cards side by side, and the full detail stays in tooltips.

local login = require("./login")
local poller = require("./poller")
local stats = require("./stats")
local time = require("./time")
local usage = require("./usage")

local ui = tern.ui

local M = {}

export type BlockState = {
	cx: BlockCx,
	sel: number,
	flow: any,
	help: boolean,
	-- The settings panel is open.
	settings: boolean,
	confirm: string?,
	-- Account id to select once it shows up (after a login).
	want: string?,
	-- Rename in progress: the account id and the text typed so far.
	edit: { id: string, text: string }?,
}

-- Width classes: narrow < 60 cells ≤ medium < 90 cells ≤ wide.
type Fit = { narrow: boolean, wide: boolean }

local function fit_of(cols: number): Fit
	return { narrow = cols < 60, wide = cols >= 90 }
end

-- Cards sit side by side from this pane width (two cards of at least 58 cells).
local GRID_COLS = 120

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

local SOURCE = { own = "插件登录", ["claude-code"] = "Claude Code", codex = "Codex CLI", omp = "omp" }
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

-- One muted line under a window: the pace against an even spend. The run-out warning always
-- shows; the projection and pace delta need room and the pace setting.
local function pace_line(w: usage.Window, now: number, fit: Fit): (Node?, string?)
	local pace = usage.pace(w, now)
	if not pace then
		return nil, nil
	end
	local pc = pace :: usage.Pace
	local extras = poller.state.settings.show_pace and not fit.narrow
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
		if extras then
			add("预计 " .. pct_text(proj), if proj >= 85 then "warning" else "muted")
		end
	end
	if extras and math.abs(pc.delta) >= 1 and (w.pct or 0) > 0 then
		local ahead = pc.delta > 0
		add(string.format("节奏 %s%d%%", if ahead then "+" else "−", math.floor(math.abs(pc.delta) + 0.5)), if ahead and pc.delta >= 10 then "warning" elseif ahead then "muted" else "success")
	end
	if #spans == 0 then
		return nil, tip
	end
	return line(spans, { key = "p:" .. w.id, title = tip }), tip
end

local LABEL_W = { narrow = "6ch", medium = "9ch" }

local function label_width(fit: Fit): string
	return if fit.narrow then LABEL_W.narrow else LABEL_W.medium
end

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
	local width = label_width(fit)
	table.insert(rows, ui.node("row", { gap = "sm", key = "w:" .. w.id }, {
		line({ ui.span(w.short or short_label(w), if w.active then "strong" else "") }, { min = { w = width }, max = { w = width }, basis = "content", title = w.label .. (if w.active then "（当前生效的限制）" else "") }),
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
	local width = label_width(fit)
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

local function credits_row(c: usage.Credits, fit: Fit): Node
	local width = label_width(fit)
	local value: { Span } = if c.unlimited
		then { ui.span("无限", "success") }
		else { ui.span(if c.balance then string.format("%g", c.balance :: number) else "—", "num"), ui.span(" credits", "muted") }
	return ui.node("row", { gap = "sm", key = "credits" }, {
		line({ ui.span("余额") }, { min = { w = width }, max = { w = width }, basis = "content", title = "ChatGPT credits：额度用完后按 credits 继续使用" }),
		line(value),
	})
end

local function history_row(e: poller.Entry, fit: Fit): Node?
	if fit.narrow or not poller.state.settings.show_history then
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

-- The selected account's actions: rename, status-line pin, hide, move, remove.
local function account_actions(e: poller.Entry): Node
	local id = e.account.id
	local pref = poller.pref(e)
	local children: { Node } = {
		button("重命名", "neutral", "rename=" .. id, "e：设置别名"),
		button(if pref.pinned then "取消固定" else "固定到状态栏", if pref.pinned then "accent" else "neutral", "pin=" .. id, "p：状态栏「固定」模式显示此账户"),
		button(if pref.hidden then "取消隐藏" else "隐藏", "neutral", "hide=" .. id, "h：隐藏后不显示、不刷新、不进状态栏和汇总"),
		button("↑", "neutral", "up=" .. id, "K（Shift+k）：上移（切换为手动排序）"),
		button("↓", "neutral", "down=" .. id, "J（Shift+j）：下移（切换为手动排序）"),
	}
	if e.account.kind == "own" then
		table.insert(children, button("移除", "error", "ask_remove=" .. id, "x：移除插件登录的账户（需确认）"))
	end
	return ui.node("row", { gap = "sm", wrap = true, key = "acts" }, children)
end

type CardOpts = { mark: boolean, active: boolean, confirm: boolean, now: number, fit: Fit }

local function account_card(e: poller.Entry, o: CardOpts): Node
	local fit, now = o.fit, o.now
	local pref = poller.pref(e)
	local plan = poller.plan(e)
	local head: { Span } = { ui.span(poller.label(e), "strong") }
	if pref.alias and not fit.narrow then
		table.insert(head, ui.span(" " .. poller.account_name(e), "muted"))
	end
	if plan then
		table.insert(head, ui.span(" " .. (plan :: string), "accent"))
	end
	if not fit.narrow then
		table.insert(head, ui.span(" · " .. (SOURCE[e.account.kind] or e.account.kind), "muted"))
	end
	if pref.pinned then
		table.insert(head, ui.span(" · 状态栏", "accent"))
	end
	if pref.hidden then
		table.insert(head, ui.span(" · 已隐藏", "warning"))
	end

	local body: { Node } = {}
	if pref.hidden then
		table.insert(body, line({ ui.span("已隐藏：不刷新、不进状态栏和汇总", "muted") }, { key = "hidden" }))
	end
	if e.account.problem then
		table.insert(body, line({ ui.span("omp 已停用此凭据", "error") }, { title = e.account.problem }))
	end
	if e.usage then
		local u = e.usage :: usage.Usage
		local scoped = poller.state.settings.show_scoped
		for _, w in u.windows do
			if scoped or w.kind == "session" or w.kind == "weekly" then
				for _, row in window_rows(w, now, fit) do
					table.insert(body, row)
				end
			end
		end
		if u.extra then
			table.insert(body, extra_row(u.extra :: usage.Extra, fit))
		end
		if u.credits then
			table.insert(body, credits_row(u.credits :: usage.Credits, fit))
		end
		local hist = history_row(e, fit)
		if hist then
			table.insert(body, hist :: Node)
		end
	elseif not e.error and not e.account.problem and not pref.hidden then
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
	if e.account.kind == "own" and o.confirm then
		table.insert(body, ui.node("row", { key = "rm", gap = "sm" }, {
			line({ ui.span("移除此登录？", "warning") }),
			button("移除", "error", "remove=" .. e.account.id),
			button("取消", "neutral", "keep"),
		}))
	elseif o.active then
		table.insert(body, account_actions(e))
	end

	local org = e.profile and e.profile.org_name
	return with(ui.card(head, body), {
		key = "acct:" .. e.account.id,
		tone = if e.error or e.account.problem then "error" else nil,
		mark = if o.mark then "pick" else nil,
		actions = { click = "select=" .. e.account.id },
		title = poller.account_name(e) .. " · " .. (SOURCE[e.account.kind] or e.account.kind) .. (if org then " · " .. (org :: string) else ""),
	})
end

local function find_window(e: poller.Entry, id: string): usage.Window?
	local u = e.usage
	if u then
		for _, w in (u :: usage.Usage).windows do
			if w.id == id then
				return w
			end
		end
	end
	return nil
end

-- One line per account: name, plan, 5 h and 7 d meters, the first reset; a click selects it.
local function compact_row(e: poller.Entry, selected: boolean, now: number, fit: Fit): Node
	local pref = poller.pref(e)
	local plan = poller.plan(e)
	local name_w = if fit.narrow then "10ch" elseif fit.wide then "22ch" else "14ch"
	local tip = poller.account_name(e) .. (if plan then " · " .. (plan :: string) else "") .. " · " .. (SOURCE[e.account.kind] or e.account.kind)
	local children: { Node } = {
		line({ ui.span(if selected then "▸" else " ", "accent") }, { basis = "content", key = "sel" }),
		line({ ui.span(poller.short_name(e), if pref.hidden then "dim" elseif pref.pinned then "strong accent" else "strong") }, { min = { w = name_w }, max = { w = name_w }, basis = "content", key = "name", title = tip }),
	}
	if not fit.narrow then
		table.insert(children, line({ ui.span(plan or "", "accent") }, { min = { w = "8ch" }, max = { w = "8ch" }, basis = "content", key = "plan" }))
	end
	if e.usage then
		local first: usage.Window? = nil
		for _, id in { "5h", "7d" } do
			local w = find_window(e, id)
			table.insert(children, line({ ui.span(id, "dim") }, { basis = "content", key = "l" .. id }))
			if w then
				first = first or w
				local pace = usage.pace(w, now)
				table.insert(children, ui.node("meter", {
					key = "m" .. id,
					value = (w.pct or 0) / 100,
					thresholds = { warn = 0.6, bad = 0.85 },
					size = "sm",
					grow = 1,
					marks = if pace then { { at = (pace :: usage.Pace).elapsed, tone = "muted", title = "时间进度" } } else nil,
					title = w.label .. " " .. pct_text(w.pct),
				}))
			else
				table.insert(children, line({ ui.span("—", "dim") }, { grow = 1, key = "m" .. id, title = "此套餐没有该窗口" }))
			end
			table.insert(children, line({ ui.span(if w then pct_text(w.pct) else "", "num") }, { min = { w = "5ch" }, basis = "content", key = "p" .. id }))
		end
		if fit.wide and first and first.resets_at and (first.resets_at :: number) > now then
			local left = (first.resets_at :: number) - now
			table.insert(children, line({ ui.span(time.short(left), "muted") }, { min = { w = "7ch" }, basis = "content", key = "reset", title = first.id .. " 重置于 " .. time.clock(first.resets_at :: number, now) }))
		end
		if e.error then
			table.insert(children, line({ ui.span("⚠", "error") }, { basis = "content", key = "warn", title = e.error }))
		end
		if pref.hidden then
			table.insert(children, line({ ui.span("已隐藏", "dim") }, { basis = "content", key = "hidden", title = "不刷新、不进状态栏和汇总；h 取消隐藏" }))
		end
	elseif e.error then
		table.insert(children, line({ ui.span(e.error :: string, "error") }, { grow = 1, min = { w = 0 }, key = "err", title = e.error }))
	elseif pref.hidden then
		table.insert(children, line({ ui.span("已隐藏", "dim") }, { grow = 1, key = "hidden" }))
	else
		table.insert(children, ui.node("spinner", { style = "dots", key = "spin", label = { ui.span("获取用量…", "muted") } }))
	end
	return with(ui.node("row", { gap = "sm", key = "row:" .. e.account.id }, children), {
		actions = { click = "select=" .. e.account.id },
		title = tip,
	})
end

-- Averages, spare capacity and the account to use next, over the shown (not hidden) accounts.
local function summary_card(entries: { poller.Entry }, now: number, fit: Fit): Node?
	local rows: { stats.Row } = {}
	for _, e in entries do
		if not poller.pref(e).hidden and not e.account.problem then
			table.insert(rows, poller.row(e))
		end
	end
	local s = stats.summarize(rows, now)
	if s.with_data < 2 then
		return nil
	end
	local width = label_width(fit)
	local body: { Node } = {}
	for _, item in { { "5h", s.session, "session" }, { "7d", s.weekly, "weekly" } } do
		local ws: stats.WinStats? = item[2]
		if ws == nil then
			continue
		end
		local w = ws :: stats.WinStats
		local marks = {}
		for _, r in rows do
			local win: stats.Win? = (r :: any)[item[3]]
			if win and win.pct then
				table.insert(marks, { at = (win.pct :: number) / 100, tone = usage.tone(win.pct), title = (r.name or "") .. " " .. pct_text(win.pct) })
			end
		end
		local children: { Node } = {
			line({ ui.span(item[1] .. " 平均") }, { min = { w = width }, max = { w = width }, basis = "content" }),
			ui.node("meter", {
				value = w.avg / 100,
				thresholds = { warn = 0.6, bad = 0.85 },
				size = "sm",
				grow = 1,
				marks = marks,
				title = string.format("%d 个账户 · 平均 %s · 最低 %s · 最高 %s（刻度为各账户）", w.n, pct_text(w.avg), pct_text(w.min), pct_text(w.max)),
			}),
			line({ ui.span(pct_text(w.avg), "num") }, { min = { w = "6ch" }, basis = "content" }),
		}
		if not fit.narrow then
			table.insert(children, line({ ui.span(string.format("余 %.1f 份", w.spare), if w.spare < 0.5 then "warning" else "muted") }, {
				basis = "content",
				title = string.format("各账户未用的 %s 额度合计，折合 %.1f 个完整窗口", item[1], w.spare),
			}))
		end
		table.insert(body, ui.node("row", { gap = "sm", key = "sum:" .. item[1] }, children))
	end
	local spans: { Span } = { ui.span(string.format("可用 %d/%d", s.usable, s.with_data), if s.usable == 0 then "error" else "muted") }
	if s.best then
		local b = s.best :: stats.Row
		table.insert(spans, ui.span(" · 最空闲 ", "dim"))
		table.insert(spans, ui.span(b.name or "", "success"))
		if not fit.narrow then
			table.insert(spans, ui.span(string.format(" %s", pct_text(stats.load(b))), "muted"))
		end
	end
	if s.recover and s.recover_at then
		table.insert(spans, ui.span(" · 最早恢复 ", "dim"))
		table.insert(spans, ui.span(((s.recover :: stats.Row).name or "") .. " " .. time.short((s.recover_at :: number) - now), "warning"))
	end
	if s.errors > 0 then
		table.insert(spans, ui.span(string.format(" · 出错 %d", s.errors), "error"))
	end
	local foot = line(spans, { key = "sum:foot", title = "最空闲：5h / 7d 中较高者最低的可用账户（点击选中）" })
	if s.best then
		foot = with(foot, { actions = { click = "select=" .. ((s.best :: stats.Row).id or "") } })
	end
	table.insert(body, foot)
	return with(ui.card({ ui.span("汇总", "strong"), ui.span(string.format(" · %d 个账户", s.total), "muted") }, body), { key = "summary" })
end

local function login_card(flow: any, fit: Fit): Node
	local body: { Node } = {}
	if flow.phase == "starting" then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("准备登录…", "muted") } }))
	elseif flow.phase == "exchanging" then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("换取令牌…", "muted") } }))
	else
		table.insert(body, ui.node("text", { spans = { ui.span(login.hint(flow), "muted") }, lines = if fit.narrow then 3 else 2 }))
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
	return with(ui.card({ ui.span("登录 " .. (login.NAME[flow.provider] or "") .. " 账户", "strong") }, body), { key = "login", tone = "accent" })
end

local function edit_card(st: BlockState): Node?
	local edit = st.edit
	if edit == nil then
		return nil
	end
	local e = M.entry(edit.id)
	if e == nil then
		return nil
	end
	local text = edit.text
	return with(ui.card({ ui.span("重命名 ", "strong"), ui.span(poller.account_name(e :: poller.Entry), "muted") }, {
		line({
			ui.span("› ", "accent"),
			if text ~= "" then ui.span(text, "code") else ui.span("输入别名，留空恢复为邮箱", "dim"),
		}, { truncate = "start", key = "input" }),
		ui.node("row", { gap = "sm", wrap = true }, {
			button("保存", "accent", "save_edit", "Enter"),
			button("取消", "neutral", "cancel_edit", "Esc"),
		}),
	}), { key = "edit", tone = "accent" })
end

local LAYOUTS = { { "auto", "自动" }, { "cards", "卡片" }, { "compact", "紧凑" } }
local SORTS = { { "manual", "手动" }, { "usage", "用量" }, { "reset", "重置时间" }, { "name", "名称" } }
local STATUS_MODES = { { "one", "固定/首个" }, { "best", "最空闲" }, { "all", "全部" } }
local STATUS_SCOPES = { { "tab", "当前标签" }, { "both", "两家" } }
local SHOW = { { "show_pace", "节奏" }, { "show_history", "走势" }, { "show_scoped", "分模型/其他额度" }, { "show_hidden", "已隐藏账户" } }
local SOURCES = { { "claude_code", "Claude Code" }, { "codex", "Codex CLI" }, { "omp", "omp" } }

local function interval_text(s: number): string
	return if s % 60 == 0 then string.format("%dm", s // 60) else string.format("%ds", s)
end

local function settings_card(): Node
	local s = poller.state.settings :: any
	local function group(label: string, chips: { Node }): Node
		local children: { Node } = { line({ ui.span(label, "muted") }, { min = { w = "7ch" }, max = { w = "7ch" }, basis = "content" }) }
		for _, c in chips do
			table.insert(children, c)
		end
		return ui.node("row", { gap = "sm", wrap = true, key = "set:" .. label }, children)
	end
	local function choices(key: string, list: { { string } }): { Node }
		local out: { Node } = {}
		for _, item in list do
			table.insert(out, button(item[2], if s[key] == item[1] then "accent" else "neutral", "set=" .. key .. ":" .. item[1]))
		end
		return out
	end
	local function toggles(list: { { string } }): { Node }
		local out: { Node } = {}
		for _, item in list do
			table.insert(out, button(item[2], if s[item[1]] then "accent" else "neutral", "toggle=" .. item[1]))
		end
		return out
	end
	local status = toggles({ { "status_line", "显示" } })
	for _, c in choices("status_mode", STATUS_MODES) do
		table.insert(status, c)
	end
	for _, c in choices("status_scope", STATUS_SCOPES) do
		table.insert(status, c)
	end
	local intervals: { Node } = {}
	for _, v in poller.INTERVALS do
		table.insert(intervals, button(interval_text(v), if s.interval == v then "accent" else "neutral", "set=interval:" .. v))
	end
	return with(ui.card({ ui.span("设置", "strong"), ui.span(" · 两个标签共用，自动保存", "muted") }, {
		group("布局", choices("layout", LAYOUTS)),
		group("排序", choices("sort", SORTS)),
		group("显示", toggles(SHOW)),
		group("状态栏", status),
		group("来源", toggles(SOURCES)),
		group("刷新", intervals),
		ui.node("text", { spans = { ui.span("自动布局：两个账户以内用卡片，更多时用紧凑行 + 选中账户的卡片；面板宽于 120 列时卡片并排。", "dim") }, lines = 2 }),
	}), { key = "settings" })
end

local KEYS = {
	{ { "Tab" }, "切换 Claude / GPT（也可按 1 / 2）" },
	{ { "r" }, "立即刷新" },
	{ { "l" }, "登录当前标签的账户（可多个）" },
	{ { "j", "k" }, "选择账户" },
	{ { "J", "K" }, "移动账户（手动排序）" },
	{ { "e" }, "重命名（别名）" },
	{ { "p" }, "固定到状态栏" },
	{ { "h" }, "隐藏 / 取消隐藏" },
	{ { "a" }, "显示 / 收起已隐藏账户" },
	{ { "v" }, "切换布局（自动 / 卡片 / 紧凑）" },
	{ { "x" }, "移除插件登录的账户" },
	{ { "+", "-" }, "刷新间隔" },
	{ { "c" }, "开关 Claude Code / Codex 来源（随当前标签）" },
	{ { "o" }, "开关 omp 来源" },
	{ { "s" }, "开关状态栏" },
	{ { "," }, "设置" },
	{ { "?" }, "显示/隐藏本说明" },
}

local function help_card(): Node
	local keys: { Node } = {}
	for i, k in KEYS do
		table.insert(keys, ui.node("row", { gap = "xs", key = "k" .. i, basis = "content" }, {
			ui.node("kbd", { keys = k[1] }),
			line({ ui.span(k[2], "muted") }),
		}))
	end
	return with(ui.card({ ui.span("按键", "strong") }, {
		ui.node("row", { gap = "md", wrap = true }, keys),
		ui.node("text", { spans = {
			ui.span("进度条上的竖线是窗口已过去的时间比例；用量超过它说明比均匀使用更快。汇总进度条上的刻度是各账户的用量。悬停各行可看完整说明。", "dim"),
		} }),
	}), { key = "help" })
end

-- `Claude 5h 42% · 7d 18%` / `GPT 7d 9%` for the shown provider's pinned account, else the first
-- one with data.
function M.title(_st: BlockState): string?
	local name = poller.PROVIDER_NAME[poller.state.settings.provider]
	local chosen: poller.Entry? = nil
	for _, e in poller.ordered(poller.state.settings.provider, false) do
		if e.usage and (chosen == nil or poller.pref(e).pinned) then
			chosen = e
			if poller.pref(e).pinned then
				break
			end
		end
	end
	if chosen then
		local parts: { string } = {}
		for _, win in ((chosen :: poller.Entry).usage :: usage.Usage).windows do
			if win.id == "5h" or win.id == "7d" then
				table.insert(parts, win.id .. " " .. pct_text(win.pct))
			end
		end
		if #parts > 0 then
			return name .. " " .. table.concat(parts, " · ")
		end
	end
	return name .. " 用量"
end

-- The shown provider's accounts in panel order (hidden ones too while they are listed).
function M.visible(): { poller.Entry }
	local s = poller.state.settings
	return poller.ordered(s.provider, s.show_hidden)
end

function M.entry(id: string): poller.Entry?
	for _, e in poller.state.entries do
		if e.account.id == id then
			return e
		end
	end
	return nil
end

-- The layout the shown accounts get: "cards" or "compact".
function M.layout(n: number): string
	local l = poller.state.settings.layout
	if l == "auto" then
		return if n >= 3 then "compact" else "cards"
	end
	return l
end

function M.render(st: BlockState, cx: BlockCx): BlockView
	local now = os.time()
	local cols = cx.cols or 80
	local fit = fit_of(cols)
	local entries = M.visible()
	if st.want then
		for i, e in entries do
			if e.account.id == st.want then
				st.sel, st.want = i, nil
			end
		end
	end
	st.sel = math.clamp(st.sel, 1, math.max(#entries, 1))
	local s = poller.state
	local provider = s.settings.provider
	local main: { Node } = {}

	local status: Node
	if s.ticking then
		status = ui.node("spinner", { style = "dots", key = "status", basis = "content", title = "刷新中" })
	elseif s.next_at then
		status = with(ui.node("elapsed", { age = -math.max(0, (s.next_at :: number) - now) * 1000, format = "short" }), { key = "status", title = "下次刷新" })
	else
		status = line({ ui.span("已暂停", "dim") }, { key = "status", basis = "content", title = "状态栏关闭且面板未打开时不轮询" })
	end
	local head: { Node } = {}
	for i, p in poller.PROVIDERS do
		local name = poller.PROVIDER_NAME[p]
		table.insert(head, button(name, if p == provider then "accent" else "neutral", "tab=" .. p, string.format("%d / Tab：%s 订阅额度", i, name)))
	end
	local caption = if fit.narrow then "" elseif #entries > 1 then string.format("%d 个账户", #entries) else "订阅额度"
	table.insert(head, line({ ui.span(caption, "muted") }, { grow = 1, min = { w = 0 } }))
	table.insert(head, status)
	table.insert(head, button("刷新", "accent", "refresh", "r"))
	table.insert(head, button(if fit.narrow then "+" else "+ 账户", "neutral", "login", "l：登录 " .. (login.NAME[provider] or "") .. " 账户（可添加多个）"))
	table.insert(head, button("⚙", if st.settings then "accent" else "neutral", "settings", ",：布局、排序、状态栏等设置"))
	table.insert(head, button("?", if st.help then "accent" else "neutral", "help", "按键"))
	table.insert(main, ui.node("row", { gap = "sm", key = "head" }, head))

	if st.flow then
		table.insert(main, login_card(st.flow, fit))
	end
	local edit = edit_card(st)
	if edit then
		table.insert(main, edit :: Node)
	end
	if st.settings then
		table.insert(main, settings_card())
	end
	if st.help then
		table.insert(main, help_card())
	end

	local summary = summary_card(entries, now, fit)
	if summary then
		table.insert(main, summary :: Node)
	end

	local layout = M.layout(#entries)
	if layout == "compact" and #entries > 0 then
		local rows: { Node } = {}
		for i, e in entries do
			table.insert(rows, compact_row(e, i == st.sel, now, fit))
		end
		table.insert(main, with(ui.card({ ui.span("账户", "strong"), ui.span(" · j/k 选择，详情见下方", "muted") }, rows), { key = "list" }))
		local e = entries[st.sel]
		if e then
			table.insert(main, account_card(e, { mark = false, active = true, confirm = st.confirm == e.account.id, now = now, fit = fit }))
		end
	elseif #entries > 0 then
		local grid = cols >= GRID_COLS and #entries > 1
		local card_fit = if grid then fit_of(cols // 2 - 1) else fit
		local cards: { Node } = {}
		for i, e in entries do
			local card = account_card(e, { mark = i == st.sel and #entries > 1, active = i == st.sel, confirm = st.confirm == e.account.id, now = now, fit = card_fit })
			if grid then
				card = with(card, { grow = 1, min = { w = "58ch" } })
			end
			table.insert(cards, card)
		end
		if grid then
			table.insert(main, ui.node("row", { gap = "sm", wrap = true, key = "grid" }, cards))
		else
			for _, c in cards do
				table.insert(main, c)
			end
		end
	end

	local dups, hidden = 0, 0
	for _, e in s.entries do
		if e.account.provider == provider then
			if e.duplicate_of then
				dups += 1
			elseif poller.pref(e).hidden then
				hidden += 1
			end
		end
	end
	local notes: { Span } = {}
	if dups > 0 then
		table.insert(notes, ui.span(string.format("另有 %d 个来源指向同一账户，已合并", dups), "dim"))
	end
	if hidden > 0 and not s.settings.show_hidden then
		if #notes > 0 then
			table.insert(notes, ui.span(" · ", "dim"))
		end
		table.insert(notes, ui.span(string.format("%d 个账户已隐藏（a 显示）", hidden), "dim"))
	end
	if #notes > 0 then
		table.insert(main, line(notes, { key = "notes" }))
	end
	if #entries == 0 and not s.ticking and not st.flow then
		local empty = if hidden > 0
			then { "账户都已隐藏", "按 a 列出已隐藏的账户，选中后按 h 取消隐藏。" }
			elseif provider == "gpt"
			then { "还没有 GPT 账户", "按 l 登录 ChatGPT 账户；用 Codex CLI（codex login）或在 omp 中登录后也会自动读取。" }
			else { "还没有 Claude 账户", "按 l 登录 Pro / Max 账户；已登录 Claude Code 时会自动读取。" }
		table.insert(main, with(ui.card({ ui.span(empty[1], "strong") }, {
			ui.node("text", { spans = { ui.span(empty[2], "muted") } }),
		}), { key = "empty" }))
	end

	return { main = ui.col(main) }
end

return M
