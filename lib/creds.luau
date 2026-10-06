--!strict
-- Where OAuth tokens come from:
--   own          accounts this plugin logged in; stored in <data>/accounts.json (mode 600); refreshed here.
--   claude-code  Claude Code's login (macOS Keychain "Claude Code-credentials", else
--                <config>/.credentials.json); refreshed only once expired, and the rotated pair
--                is written back so Claude Code stays logged in.
--   omp          omp's ~/.omp/agent/agent.db rows; read-only (refreshing would log omp out).

local crypto = require("./crypto")

type Tokens = {
	access: string,
	refresh: string?,
	expires: number?,
	scopes: { string }?,
	account_uuid: string?,
	email: string?,
	org_uuid: string?,
	org_name: string?,
}

local M = {}

export type Account = {
	id: string,
	-- "own" | "claude-code" | "omp"
	kind: string,
	tokens: Tokens?,
	-- Tier or subscription hints the source already knows.
	tier: string?,
	subscription: string?,
	-- Why the source can't be used (`omp` disabled row, unreadable keychain, …).
	problem: string?,
	-- claude-code: where its login lives, "keychain" or "file".
	store: string?,
	added_at: number?,
}

local function home(): string
	return tern.getenv("HOME") or ""
end

local function claude_dir(): string
	local dir = tern.getenv("CLAUDE_CONFIG_DIR")
	if dir and dir ~= "" then
		return dir
	end
	return home() .. "/.claude"
end

local function read_json(path: string): any
	if not tern.fs.exists(path) then
		return nil
	end
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return nil
	end
	local ok2, value = pcall(tern.json.decode, text)
	return if ok2 then value else nil
end

-- ── own accounts ────────────────────────────────────────────────────────────

local function own_path(): string
	return tern.plugin.data .. "/accounts.json"
end

function M.own_list(): { Account }
	local doc = read_json(own_path())
	local out: { Account } = {}
	if type(doc) ~= "table" or type(doc.accounts) ~= "table" then
		return out
	end
	for _, a in doc.accounts do
		if type(a) == "table" and type(a.id) == "string" and type(a.tokens) == "table" and type(a.tokens.access) == "string" then
			table.insert(out, { id = a.id, kind = "own", tokens = a.tokens, tier = a.tier, added_at = a.added_at })
		end
	end
	return out
end

local function own_write(list: { Account })
	local rows = {}
	for i, a in list do
		rows[i] = { id = a.id, tokens = a.tokens, tier = a.tier, added_at = a.added_at }
	end
	local path = own_path()
	tern.fs.write(path, tern.json.encode({ accounts = tern.json.array(rows) }, true))
	pcall(tern.process.run, { "chmod", "600", path }, {}, function(_r) end)
end

-- Adds or replaces (same account and organization) a logged-in account; returns its id.
function M.own_upsert(tokens: Tokens): string
	local list = M.own_list()
	for _, a in list do
		local t = a.tokens :: Tokens
		if t.account_uuid and t.account_uuid == tokens.account_uuid and t.org_uuid == tokens.org_uuid then
			a.tokens = tokens
			own_write(list)
			return a.id
		end
	end
	local id = "own:" .. crypto.hex(crypto.sha256((tokens.account_uuid or tokens.access) .. "|" .. (tokens.org_uuid or ""))):sub(1, 12)
	table.insert(list, { id = id, kind = "own", tokens = tokens, added_at = os.time() })
	own_write(list)
	return id
end

function M.own_update(id: string, tokens: Tokens)
	local list = M.own_list()
	for _, a in list do
		if a.id == id then
			a.tokens = tokens
		end
	end
	own_write(list)
end

function M.own_remove(id: string)
	local list = M.own_list()
	local kept = {}
	for _, a in list do
		if a.id ~= id then
			table.insert(kept, a)
		end
	end
	own_write(kept)
end

-- ── Claude Code ─────────────────────────────────────────────────────────────

-- Keychain service: the default config dir uses the bare name; a CLAUDE_CONFIG_DIR adds the
-- first 8 hex digits of its SHA-256.
local function keychain_service(): string
	local dir = tern.getenv("CLAUDE_CONFIG_DIR")
	if dir and dir ~= "" then
		return "Claude Code-credentials-" .. string.sub(crypto.hex(crypto.sha256(dir)), 1, 8)
	end
	return "Claude Code-credentials"
end

local function from_claude_doc(doc: any, store: string): Account?
	if type(doc) ~= "table" or type(doc.claudeAiOauth) ~= "table" then
		return nil
	end
	local o = doc.claudeAiOauth
	if type(o.accessToken) ~= "string" then
		return nil
	end
	return {
		id = "claude-code",
		kind = "claude-code",
		store = store,
		tokens = {
			access = o.accessToken,
			refresh = o.refreshToken,
			expires = o.expiresAt,
			scopes = o.scopes,
		},
		tier = o.rateLimitTier,
		subscription = o.subscriptionType,
	}
end

-- Reads Claude Code's login. `cb(account?, raw_doc?)`; nil when Claude Code isn't logged in here.
function M.claude_code_load(cb: (Account?, any) -> ())
	local function from_file()
		local doc = read_json(claude_dir() .. "/.credentials.json")
		cb(from_claude_doc(doc, "file"), doc)
	end
	if tern.runtime.os ~= "macos" then
		from_file()
		return
	end
	local ok = pcall(tern.process.run, { "security", "find-generic-password", "-s", keychain_service(), "-w" }, { timeout_ms = 10000 }, function(r)
		if r.status == 0 then
			local okj, doc = pcall(tern.json.decode, r.stdout)
			if okj then
				local acc = from_claude_doc(doc, "keychain")
				if acc then
					cb(acc, doc)
					return
				end
			end
		end
		from_file()
	end)
	if not ok then
		from_file()
	end
end

-- Writes refreshed tokens back into the store `account` was read from, keeping every other field.
function M.claude_code_save(account: Account, doc: any, tokens: Tokens, cb: (string?) -> ())
	local o = if type(doc) == "table" and type(doc.claudeAiOauth) == "table" then doc.claudeAiOauth else {}
	o.accessToken = tokens.access
	o.refreshToken = tokens.refresh
	o.expiresAt = tokens.expires
	local out = if type(doc) == "table" then doc else {}
	out.claudeAiOauth = o
	local text = tern.json.encode(out)
	if account.store ~= "keychain" then
		local ok, err = pcall(tern.fs.write, claude_dir() .. "/.credentials.json", text)
		cb(if ok then nil else tostring(err))
		return
	end
	local service = keychain_service()
	-- `add -U` updates only the item with the same account name, so look that name up first.
	local ok, err = pcall(tern.process.run, { "security", "find-generic-password", "-s", service }, { timeout_ms = 10000 }, function(found)
		local acct = string.match(found.stdout, '"acct"<blob>="([^"]*)"') or tern.getenv("USER") or "user"
		local line = string.format('add-generic-password -U -a "%s" -s "%s" -X %s\n', acct, service, crypto.hex(text))
		local ok2, err2 = pcall(tern.process.run, { "security", "-i" }, { stdin = line, timeout_ms = 10000 }, function(r)
			local failed = r.status ~= 0 or string.find(r.stdout .. r.stderr, "rror") ~= nil
			cb(if failed then "写回钥匙串失败: " .. r.stdout .. r.stderr else nil)
		end)
		if not ok2 then
			cb(tostring(err2))
		end
	end)
	if not ok then
		cb(tostring(err))
	end
end

-- Claude Code's own cached `/api/oauth/usage` payload and account metadata from ~/.claude.json
-- (no network). `{fetched_at = epoch s, account_uuid, usage = raw payload, account = oauthAccount}`.
function M.claude_code_cache(): any
	local dir = tern.getenv("CLAUDE_CONFIG_DIR")
	local path = if dir and dir ~= "" then dir .. "/.claude.json" else home() .. "/.claude.json"
	local doc = read_json(path)
	if type(doc) ~= "table" then
		return nil
	end
	local c = doc.cachedUsageUtilization
	local out: { [string]: any } = { account = doc.oauthAccount }
	if type(c) == "table" and type(c.utilization) == "table" and type(c.fetchedAtMs) == "number" then
		out.fetched_at = c.fetchedAtMs / 1000
		out.account_uuid = c.accountUuid
		out.usage = c.utilization
	end
	return out
end

-- ── omp ─────────────────────────────────────────────────────────────────────

-- omp's Anthropic OAuth rows. `cb(accounts)`; empty when omp or sqlite3 is missing.
function M.omp_load(cb: ({ Account }) -> ())
	local db = home() .. "/.omp/agent/agent.db"
	if not tern.fs.exists(db) then
		cb({})
		return
	end
	local sql = "select id, data, disabled_cause from auth_credentials where provider = 'anthropic' and credential_type = 'oauth' order by id"
	local ok = pcall(tern.process.run, { "sqlite3", "-readonly", "-json", db, sql }, { timeout_ms = 10000 }, function(r)
		local out: { Account } = {}
		if r.status == 0 then
			local okj, rows = pcall(tern.json.decode, if r.stdout == "" then "[]" else r.stdout)
			if okj and type(rows) == "table" then
				for _, row in rows do
					local okd, data = pcall(tern.json.decode, row.data or "")
					if okd and type(data) == "table" and type(data.access) == "string" then
						table.insert(out, {
							id = "omp:" .. tostring(row.id),
							kind = "omp",
							tokens = {
								access = data.access,
								refresh = data.refresh,
								expires = data.expires,
								account_uuid = data.accountId,
								email = data.email,
								org_uuid = data.orgId,
								org_name = data.orgName,
							},
							problem = if type(row.disabled_cause) == "string" and row.disabled_cause ~= "" then row.disabled_cause else nil,
						})
					end
				end
			end
		end
		cb(out)
	end)
	if not ok then
		cb({})
	end
end

-- 64 bytes from the OS (`od` over /dev/urandom), falling back to a clock-seeded PRNG.
function M.random_bytes(cb: (string) -> ())
	local ok = pcall(tern.process.run, { "od", "-An", "-tx1", "-N64", "/dev/urandom" }, { timeout_ms = 5000 }, function(r)
		local bytes = if r.status == 0 then crypto.unhex(r.stdout) else ""
		cb(if #bytes >= 64 then bytes else crypto.weak_random_bytes(64))
	end)
	if not ok then
		cb(crypto.weak_random_bytes(64))
	end
end

return M
