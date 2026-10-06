--!strict
-- One poller per host VM, shared by every open usage block and the status line.
--
-- Each tick re-reads the credential sources (so Claude Code's own refreshes and new logins show
-- up), then fetches `/api/oauth/usage` for each account, one after another. It ticks every
-- `settings.interval` seconds while a usage block is open and every `settings.background`
-- seconds otherwise. A 429 backs that account off (Retry-After, else doubling from one minute)
-- and keeps showing the last good data.

local creds = require("./creds")
local oauth = require("./oauth")
local usage = require("./usage")

local M = {}

export type Sample = { t: number, s: number?, w: number? }

export type Entry = {
	account: creds.Account,
	-- Claude Code's raw credential document, for write-back after a refresh.
	doc: any,
	profile: oauth.Profile?,
	raw: any,
	usage: usage.Usage?,
	-- Epoch seconds the usage data was produced.
	fetched_at: number?,
	-- "api" | "claude-code-cache" | "disk"
	data_source: string?,
	busy: string?,
	error: string?,
	backoff_until: number?,
	backoff_step: number,
	history: { Sample },
	-- Set when another source already shows the same account and organization.
	duplicate_of: string?,
	profile_tried: boolean?,
}

export type Settings = {
	interval: number,
	background: number,
	claude_code: boolean,
	omp: boolean,
	status_line: boolean,
}

local DEFAULTS: Settings = { interval = 60, background = 300, claude_code = true, omp = true, status_line = true }
M.INTERVALS = { 30, 60, 120, 300, 600 }
local HISTORY = 48

local state = {
	entries = {} :: { Entry },
	settings = table.clone(DEFAULTS) :: Settings,
	listeners = {} :: { [number]: BlockCx },
	timer = nil :: TimerHandle?,
	next_at = nil :: number?,
	ticking = false,
	started = false,
	last_tick = nil :: number?,
}
M.state = state

-- ── persistence ─────────────────────────────────────────────────────────────

local function cache_path(): string
	return tern.plugin.data .. "/cache.json"
end

local function load_settings()
	local ok, s = pcall(tern.kv.get, "settings")
	if ok and type(s) == "table" then
		for k, v in s do
			if (DEFAULTS :: any)[k] ~= nil and type(v) == type((DEFAULTS :: any)[k]) then
				(state.settings :: any)[k] = v
			end
		end
	end
end

function M.set_setting(key: string, value: any)
	(state.settings :: any)[key] = value
	pcall(tern.kv.set, "settings", state.settings)
end

local function save_cache()
	local out: { [string]: any } = {}
	for _, e in state.entries do
		if e.raw ~= nil or e.profile ~= nil then
			out[e.account.id] = {
				raw = e.raw,
				fetched_at = e.fetched_at,
				data_source = e.data_source,
				profile = e.profile,
				history = tern.json.array(e.history),
			}
		end
	end
	pcall(tern.fs.write, cache_path(), tern.json.encode(out))
end

local disk_cache: { [string]: any } = {}
local function load_cache()
	if not tern.fs.exists(cache_path()) then
		return
	end
	local ok, text = pcall(tern.fs.read, cache_path())
	if ok then
		local ok2, doc = pcall(tern.json.decode, text)
		if ok2 and type(doc) == "table" then
			disk_cache = doc
		end
	end
end

-- Compact status for the window half's status line, in kv "status".
local function publish()
	local accounts = {}
	for _, e in state.entries do
		if e.duplicate_of or e.account.problem then
			continue
		end
		local row: { [string]: any } = { label = M.label(e), plan = M.plan(e), error = e.error }
		if e.usage then
			for _, w in (e.usage :: usage.Usage).windows do
				if w.id == "5h" or w.id == "7d" then
					row[if w.id == "5h" then "session" else "weekly"] = { pct = w.pct, resets_at = w.resets_at }
				end
			end
			row.fetched_at = e.fetched_at
		end
		table.insert(accounts, row)
	end
	pcall(tern.kv.set, "status", { updated = os.time(), accounts = tern.json.array(accounts), enabled = state.settings.status_line })
end

-- ── listeners ───────────────────────────────────────────────────────────────

local function live_panes(): { [number]: boolean }
	local live: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		live[p.pane] = true
	end
	return live
end

local function has_listeners(): boolean
	local live = live_panes()
	local any = false
	for pane in state.listeners do
		if live[pane] then
			any = true
		else
			state.listeners[pane] = nil
		end
	end
	return any
end

function M.notify()
	local live = live_panes()
	for pane, cx in state.listeners do
		if live[pane] then
			cx:render()
		else
			state.listeners[pane] = nil
		end
	end
end

-- ── labels ──────────────────────────────────────────────────────────────────

function M.label(e: Entry): string
	local p = e.profile
	local t = e.account.tokens
	return (p and p.email) or (t and t.email) or (if e.account.kind == "claude-code" then "Claude Code 账户" else e.account.id)
end

-- The live profile wins over tier hints a credential store saved at login time.
function M.plan(e: Entry): string?
	local p = e.profile
	return usage.plan((p and p.tier) or e.account.tier, e.account.subscription, p and p.org_type)
end

local function identity(e: Entry): string?
	local p, t = e.profile, e.account.tokens
	local acc = (p and p.account_uuid) or (t and t.account_uuid)
	if not acc then
		return nil
	end
	return acc .. "|" .. ((p and p.org_uuid) or (t and t.org_uuid) or "")
end

local function mark_duplicates()
	local seen: { [string]: string } = {}
	for _, e in state.entries do
		e.duplicate_of = nil
		local id = identity(e)
		if id then
			if seen[id] then
				e.duplicate_of = seen[id]
			else
				seen[id] = e.account.id
			end
		end
	end
end

-- ── data ────────────────────────────────────────────────────────────────────

local function record(e: Entry, raw: any, fetched_at: number, source: string)
	local parsed = usage.parse(raw)
	if not parsed then
		e.error = "用量响应格式无法识别"
		return
	end
	e.raw, e.usage, e.fetched_at, e.data_source = raw, parsed, fetched_at, source
	local sample: Sample = { t = fetched_at }
	for _, w in (parsed :: usage.Usage).windows do
		if w.id == "5h" then
			sample.s = w.pct
		elseif w.id == "7d" then
			sample.w = w.pct
		end
	end
	local last = e.history[#e.history]
	if last == nil or fetched_at - last.t >= 1 then
		table.insert(e.history, sample)
		while #e.history > HISTORY do
			table.remove(e.history, 1)
		end
	end
end

local function new_entry(account: creds.Account): Entry
	local e: Entry = { account = account, backoff_step = 0, history = {} }
	local c = disk_cache[account.id]
	if type(c) == "table" then
		e.profile = c.profile
		if type(c.history) == "table" then
			for _, s in c.history do
				if type(s) == "table" and type(s.t) == "number" then
					table.insert(e.history, s)
				end
			end
		end
		if c.raw ~= nil and type(c.fetched_at) == "number" then
			e.raw, e.usage, e.fetched_at, e.data_source = c.raw, usage.parse(c.raw), c.fetched_at, "disk"
		end
	end
	return e
end

local ORDER = { own = 1, ["claude-code"] = 2, omp = 3 }

-- Re-reads every source and merges the accounts into `state.entries`, keeping per-entry state.
function M.reload_accounts(done: () -> ())
	local found: { creds.Account } = creds.own_list()
	local docs: { [string]: any } = {}
	local pending = 2
	local function finish()
		pending -= 1
		if pending > 0 then
			return
		end
		local by_id: { [string]: Entry } = {}
		for _, e in state.entries do
			by_id[e.account.id] = e
		end
		local next_entries: { Entry } = {}
		for _, a in found do
			local e = by_id[a.id] or new_entry(a)
			e.account = a
			if docs[a.id] ~= nil then
				e.doc = docs[a.id]
			end
			table.insert(next_entries, e)
		end
		table.sort(next_entries, function(x, y)
			local ox, oy = ORDER[x.account.kind] or 9, ORDER[y.account.kind] or 9
			if ox ~= oy then
				return ox < oy
			end
			return x.account.id < y.account.id
		end)
		state.entries = next_entries
		mark_duplicates()
		done()
	end
	if state.settings.claude_code then
		creds.claude_code_load(function(acc, doc)
			if acc then
				table.insert(found, acc)
				docs[acc.id] = doc
			end
			finish()
		end)
	else
		finish()
	end
	if state.settings.omp then
		creds.omp_load(function(list)
			for _, a in list do
				table.insert(found, a)
			end
			finish()
		end)
	else
		finish()
	end
end

local function now_ms(): number
	return os.time() * 1000
end

-- Calls `cb(access)` with a usable access token, refreshing it when it's expired (or `force`).
local function ensure_token(e: Entry, force: boolean, cb: (string?, string?) -> ())
	local t = e.account.tokens
	if not t then
		cb(nil, "没有令牌")
		return
	end
	local tokens = t :: oauth.Tokens
	local fresh = tokens.expires == nil or tokens.expires - now_ms() > 60000
	if fresh and not force then
		cb(tokens.access)
		return
	end
	local kind = e.account.kind
	if kind == "omp" then
		cb(nil, "omp 中的登录已过期：在 omp 里重新登录，或在这里用 l 登录")
		return
	end
	e.busy = "refresh"
	M.notify()
	local function do_refresh(current: oauth.Tokens)
		oauth.refresh(current, function(new, err, invalid)
			e.busy = nil
			if not new then
				cb(nil, (if invalid then "登录已失效，需要重新登录" else "刷新令牌失败") .. "（" .. tostring(err) .. "）")
				return
			end
			local fresh_tokens = new :: oauth.Tokens
			e.account.tokens = fresh_tokens
			if kind == "own" then
				creds.own_update(e.account.id, fresh_tokens)
				cb(fresh_tokens.access)
			else
				creds.claude_code_save(e.account, e.doc, fresh_tokens, function(werr)
					if werr then
						tern.log.warn("claude-usage: Claude Code write-back failed", werr)
						e.error = werr
					end
					cb(fresh_tokens.access)
				end)
			end
		end)
	end
	if kind == "claude-code" then
		-- Claude Code may have refreshed on its own since the last read; use that if so.
		creds.claude_code_load(function(acc, doc)
			if acc and acc.tokens then
				local latest = acc.tokens :: oauth.Tokens
				e.account.tokens, e.doc = latest, doc
				if latest.access ~= tokens.access and (latest.expires == nil or latest.expires - now_ms() > 60000) then
					e.busy = nil
					cb(latest.access)
					return
				end
				do_refresh(latest)
			else
				e.busy = nil
				cb(nil, "读取 Claude Code 登录失败")
			end
		end)
	else
		do_refresh(tokens)
	end
end

local function fetch_profile(e: Entry, access: string, done: () -> ())
	if e.profile_tried or (e.profile and e.profile.tier) then
		done()
		return
	end
	e.profile_tried = true
	oauth.get("/profile", access, function(r, body)
		local p = oauth.profile_from(body)
		if p then
			e.profile = p
			mark_duplicates()
		elseif r.status ~= 200 then
			tern.log.warn("claude-usage: profile failed", oauth.describe(r))
		end
		done()
	end)
end

-- Claude Code's own cached usage, when it is newer than ours and belongs to this login.
local function adopt_claude_cache(e: Entry): boolean
	if e.account.kind ~= "claude-code" then
		return false
	end
	local ok, c = pcall(creds.claude_code_cache)
	if not ok or type(c) ~= "table" then
		return false
	end
	local account = c.account
	if type(account) == "table" and e.profile == nil then
		e.profile = {
			email = account.emailAddress,
			name = account.displayName,
			account_uuid = account.accountUuid,
			org_uuid = account.organizationUuid,
			org_name = account.organizationName,
			tier = account.organizationRateLimitTier,
			org_type = account.organizationType,
			billing = account.billingType,
		}
		mark_duplicates()
	end
	if c.usage == nil or type(c.fetched_at) ~= "number" then
		return false
	end
	local who = e.profile and e.profile.account_uuid
	if who and c.account_uuid and c.account_uuid ~= who then
		return false
	end
	if e.fetched_at and c.fetched_at <= (e.fetched_at :: number) then
		return false
	end
	record(e, c.usage, c.fetched_at, "claude-code-cache")
	-- Fresh enough to skip our own request this tick.
	return os.time() - c.fetched_at < state.settings.interval
end

local function backoff(e: Entry, seconds: number?)
	e.backoff_step = math.min(e.backoff_step + 1, 5)
	local wait = seconds or math.min(60 * 2 ^ (e.backoff_step - 1), 900)
	e.backoff_until = os.time() + wait
end

-- Fetches one entry's usage. `force` ignores its backoff.
local function poll_entry(e: Entry, force: boolean, done: () -> ())
	if e.duplicate_of or e.account.problem or e.busy then
		done()
		return
	end
	if not force and e.backoff_until and os.time() < (e.backoff_until :: number) then
		done()
		return
	end
	if adopt_claude_cache(e) then
		e.error = nil
		done()
		return
	end
	local retried = false
	local function run(force_refresh: boolean)
		ensure_token(e, force_refresh, function(access, err)
			if not access then
				e.error = err
				e.busy = nil
				backoff(e, 300)
				done()
				return
			end
			e.busy = "fetch"
			M.notify()
			oauth.get("/usage", access :: string, function(r, body)
				e.busy = nil
				if r.status == 200 and body ~= nil then
					e.error, e.backoff_until, e.backoff_step = nil, nil, 0
					record(e, body, os.time(), "api")
					fetch_profile(e, access :: string, done)
					return
				end
				if r.status == 401 and not retried and e.account.kind ~= "omp" then
					retried = true
					run(true)
					return
				end
				if r.status == 429 then
					backoff(e, oauth.retry_after(r.headers))
					e.error = "请求过于频繁 (429)，暂停到 " .. os.date("%H:%M:%S", e.backoff_until :: number)
				elseif r.status == 401 then
					backoff(e, 300)
					e.error = "令牌无效 (401)：" .. oauth.describe(r)
				else
					backoff(e, nil)
					e.error = oauth.describe(r)
				end
				done()
			end)
		end)
	end
	run(false)
end

-- ── scheduling ──────────────────────────────────────────────────────────────

-- Arms the next tick: `interval` while a block is open, `background` while only the status line
-- needs data, none when neither does (the next block to open polls).
local function schedule()
	if state.timer then
		(state.timer :: TimerHandle):cancel()
		state.timer = nil
	end
	local open = has_listeners()
	if not open and not state.settings.status_line then
		state.next_at = nil
		return
	end
	local wait = if open then state.settings.interval else state.settings.background
	state.next_at = os.time() + wait
	state.timer = tern.timer(wait * 1000, function()
		state.timer = nil
		M.tick(false)
	end)
end

-- Reloads the accounts and polls each in turn; `force` ignores backoffs.
function M.tick(force: boolean)
	if state.ticking then
		return
	end
	state.ticking = true
	M.notify()
	M.reload_accounts(function()
		local i = 0
		local function step()
			i += 1
			local e = state.entries[i]
			if not e then
				state.ticking = false
				state.last_tick = os.time()
				save_cache()
				publish()
				schedule()
				M.notify()
				return
			end
			poll_entry(e, force, function()
				M.notify()
				step()
			end)
		end
		step()
	end)
end

function M.subscribe(cx: BlockCx)
	state.listeners[cx.pane] = cx
	-- A block opening switches to the faster interval; poll now when the data is stale.
	if not state.ticking then
		local stale = state.last_tick == nil or os.time() - (state.last_tick :: number) >= state.settings.interval
		if stale then
			M.tick(false)
		else
			schedule()
		end
	end
end

function M.start()
	if state.started then
		return
	end
	state.started = true
	load_settings()
	load_cache()
	M.tick(false)
end

function M.remove_own(id: string)
	creds.own_remove(id)
	for i, e in state.entries do
		if e.account.id == id then
			table.remove(state.entries, i)
			break
		end
	end
	mark_duplicates()
	save_cache()
	publish()
	M.notify()
end

return M
