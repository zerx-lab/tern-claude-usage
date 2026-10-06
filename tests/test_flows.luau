-- Host and window halves against a scripted runtime: refresh, 401 retry, 429 backoff, Claude Code
-- write-back, duplicate accounts, both login paths, the block view and the status segment.

local fake = require("./fake_tern")
local crypto = require("../lib/crypto")

local NOW_MS = os.time() * 1000

local function eq(a: any, b: any, what: string)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", what, tostring(b), tostring(a)), 2)
	end
end

local function payload(session: number, weekly: number): string
	return string.format(
		[[{"five_hour":{"utilization":%d,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":%d,"resets_at":"2030-01-05T00:00:00Z"},"limits":[{"kind":"weekly_scoped","percent":12,"resets_at":"2030-01-05T00:00:00Z","scope":{"model":{"display_name":"Opus"}}}],"spend":{"enabled":true,"used":{"amount_minor":500,"exponent":2,"currency":"USD"},"limit":{"amount_minor":2000,"exponent":2,"currency":"USD"}}}]],
		session,
		weekly
	)
end

local function ok(body: string, headers: any?): any
	return { status = 200, headers = headers or {}, body = body, timed_out = false }
end

local function status(code: number, body: string?, headers: any?): any
	return { status = code, headers = headers or {}, body = body or "{}", timed_out = false }
end

local TOKEN_OK = [[{"access_token":"sk-new","refresh_token":"rt-new","expires_in":28800,"account":{"uuid":"acc-1","email_address":"me@example.com"},"organization":{"uuid":"org-1","name":"Me Org"}}]]
local PROFILE = [[{"account":{"uuid":"acc-1","email":"me@example.com"},"organization":{"uuid":"org-1","name":"Me Org","rate_limit_tier":"default_claude_max_5x"}}]]

-- Every node is a table with a string kind and well-formed children; returns the visible text.
local function walk(node: any, out: { string })
	assert(type(node) == "table" and type(node.k) == "string", "bad node")
	local p = node.p or {}
	for _, key in { "spans", "head", "label", "total" } do
		local s = p[key]
		if type(s) == "table" then
			for _, span in s do
				table.insert(out, if type(span) == "table" then span.t else span)
			end
		elseif type(s) == "string" then
			table.insert(out, s)
		end
	end
	if type(p.text) == "string" then
		table.insert(out, p.text)
	end
	for _, c in node.c or {} do
		walk(c, out)
	end
end

local function render(env: any, st: any, cx: any): string
	local def = env.blocks.usage
	local v = def.view(st, cx)
	local out = {}
	walk(v.main, out)
	if v.dock then
		walk(v.dock, out)
	end
	return table.concat(out, " ")
end

local function base_process(argv: { string }, _opts: any): any
	if argv[1] == "chmod" then
		return { status = 0, stdout = "", stderr = "", timed_out = false }
	end
	if argv[1] == "security" then
		return { status = 44, stdout = "", stderr = "not found", timed_out = false }
	end
	return { status = 127, stdout = "", stderr = "nope", timed_out = false }
end

local function own_account(expires: number): string
	return string.format(
		[[{"accounts":[{"id":"own:a","added_at":1,"tokens":{"access":"sk-old","refresh":"rt-old","expires":%d,"account_uuid":"acc-1","org_uuid":"org-1","email":"me@example.com"}}]}]],
		expires
	)
end

local function count(list: { any }, pred: (any) -> boolean): number
	local n = 0
	for _, v in list do
		if pred(v) then
			n += 1
		end
	end
	return n
end

local function is_usage(c: any): boolean
	return string.find(c.url, "/api/oauth/usage", 1, true) ~= nil
end

local function is_token(c: any): boolean
	return string.find(c.url, "/v1/oauth/token", 1, true) ~= nil
end

-- ── own account: expired token is refreshed, then usage and profile are read ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS - 1000)
	env.process = base_process
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "platform.claude.com/v1/oauth/token", 1, true) then
			local body = env.tern.json.decode(opts.body)
			eq(body.grant_type, "refresh_token", "grant")
			eq(body.refresh_token, "rt-old", "old refresh token sent")
			eq(opts.headers["anthropic-beta"], "oauth-2025-04-20", "refresh beta header")
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			eq(opts.headers.Authorization, "Bearer sk-new", "usage uses refreshed token")
			return ok(payload(42, 18))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()

	local stored = env.tern.json.decode(env.files["/data/accounts.json"])
	eq(stored.accounts[1].tokens.refresh, "rt-new", "rotated refresh token persisted")
	eq(stored.accounts[1].tokens.access, "sk-new", "new access token persisted")
	eq(count(env.calls.process, function(c)
		return c.argv[1] == "chmod" and c.argv[3] == "/data/accounts.json"
	end) >= 1, true, "accounts file chmod 600")

	local s = env.kv.status
	eq(#s.accounts, 1, "status rows")
	eq(s.accounts[1].session.pct, 42, "status session pct")
	eq(s.accounts[1].weekly.pct, 18, "status weekly pct")
	eq(s.accounts[1].plan, "Max 5x", "plan from profile")

	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local text = render(env, st, cx)
	for _, want in { "me@example.com", "Max 5x", "5h", "42%", "7d", "18%", "7d Opus", "12%", "额外", "$5.00", "/ $20.00" } do
		assert(string.find(text, want, 1, true), "view shows " .. want .. " in: " .. text)
	end
	-- A narrow pane drops the source, pace extras and history but keeps every window.
	cx.cols = 40
	local narrow = render(env, st, cx)
	assert(not string.find(narrow, "插件登录", 1, true), "narrow drops source: " .. narrow)
	for _, want in { "5h", "42%", "7d Opus", "额外" } do
		assert(string.find(narrow, want, 1, true), "narrow shows " .. want)
	end
	cx.cols = 100
	eq(env.blocks.usage.title(st), "Claude 5h 42% · 7d 18%", "title")

	-- The window segment reads the same summary.
	require("../window")
	local segs = env.status_fn({ pane = 1, cwd = "", program = "", title = "" })
	assert(segs and string.find(segs[1].text, "5h 42%", 1, true) and string.find(segs[1].text, "7d 18%", 1, true), "status segment")
	eq(segs[1].command, "plugin.claude-usage.open", "segment opens block")

	-- 's' hides the segment.
	env.blocks.usage.key(st, { name = "s", ctrl = false, alt = false, shift = false, meta = false }, cx)
	env.drain()
	env.advance(16000)
	eq(env.status_fn({ pane = 1, cwd = "", program = "", title = "" }), nil, "segment off")
	print("own refresh: ok")
end

-- ── 401 once: refresh and retry; 429: back off, keep data, force ignores backoff ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS + 3600 * 1000)
	env.process = base_process
	local usage_answers = { status(401), ok(payload(10, 5)) }
	env.fetch = function(url: string, _opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			return table.remove(usage_answers, 1) or status(429, '{"error":{"type":"rate_limit_error","message":"slow down"}}', { ["retry-after"] = "120" })
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	eq(count(env.calls.fetch, is_token), 1, "one refresh after 401")
	eq(count(env.calls.fetch, is_usage), 2, "usage retried once")

	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	env.drain()
	-- A block opened within the interval reuses the fresh data.
	eq(count(env.calls.fetch, is_usage), 2, "no refetch on open")
	env.advance(61000)
	eq(count(env.calls.fetch, is_usage), 3, "polled at the interval")
	local text = render(env, st, cx)
	assert(string.find(text, "429", 1, true), "429 shown: " .. text)
	assert(string.find(text, "10%", 1, true), "old data kept: " .. text)
	env.advance(61000)
	eq(count(env.calls.fetch, is_usage), 3, "backoff skips the next tick")
	env.blocks.usage.key(st, { name = "r", ctrl = false, alt = false, shift = false, meta = false }, cx)
	env.drain()
	eq(count(env.calls.fetch, is_usage), 4, "r forces a fetch")
	print("401/429: ok")
end

-- ── Claude Code: expired keychain login is refreshed and written back ──
do
	local env = fake.new()
	__fresh(env)
	local doc = string.format(
		[[{"claudeAiOauth":{"accessToken":"cc-old","refreshToken":"cc-rt-old","expiresAt":%d,"scopes":["user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x","refreshTokenExpiresAt":123},"mcpOAuth":{"keep":"me"}}]],
		NOW_MS - 5000
	)
	local written: string? = nil
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "security" and argv[2] == "find-generic-password" and argv[5] == "-w" then
			eq(argv[4], "Claude Code-credentials", "keychain service")
			return { status = 0, stdout = written or doc, stderr = "", timed_out = false }
		elseif argv[1] == "security" and argv[2] == "find-generic-password" then
			return { status = 0, stdout = '    "acct"<blob>="zero"\n    "svce"<blob>="Claude Code-credentials"\n', stderr = "", timed_out = false }
		elseif argv[1] == "security" and argv[2] == "-i" then
			local acct, hex = string.match(opts.stdin, '^add%-generic%-password %-U %-a "([^"]+)" %-s "Claude Code%-credentials" %-X (%x+)\n$')
			eq(acct, "zero", "write-back uses the item's account")
			written = crypto.unhex(hex :: string)
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			eq(env.tern.json.decode(opts.body).refresh_token, "cc-rt-old", "Claude Code refresh token")
			return ok([[{"access_token":"cc-new","refresh_token":"cc-rt-new","expires_in":28800}]])
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			eq(opts.headers.Authorization, "Bearer cc-new", "usage with refreshed Claude Code token")
			return ok(payload(7, 3))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	assert(written, "keychain written back")
	local saved = env.tern.json.decode(written :: string)
	eq(saved.claudeAiOauth.accessToken, "cc-new", "write-back access")
	eq(saved.claudeAiOauth.refreshToken, "cc-rt-new", "write-back refresh")
	eq(saved.claudeAiOauth.subscriptionType, "max", "other fields kept")
	eq(saved.claudeAiOauth.refreshTokenExpiresAt, 123, "unknown fields kept")
	eq(saved.mcpOAuth.keep, "me", "sibling keys kept")
	eq(env.kv.status.accounts[1].plan, "Max 5x", "live profile tier wins over the keychain's login-time tier")
	eq(env.kv.status.accounts[1].session.pct, 7, "Claude Code usage")

	-- Next tick: the written token is current, so no second refresh.
	env.advance(301000)
	eq(count(env.calls.fetch, is_token), 1, "no second refresh")
	print("claude code write-back: ok")
end

-- ── Claude Code's own fresh cache is used instead of a request ──
do
	local env = fake.new()
	__fresh(env)
	local doc = string.format([[{"claudeAiOauth":{"accessToken":"cc","refreshToken":"rt","expiresAt":%d}}]], NOW_MS + 3600000)
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "security" and argv[5] == "-w" then
			return { status = 0, stdout = doc, stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	env.files["/home/test/.claude.json"] = string.format(
		[[{"oauthAccount":{"accountUuid":"acc-9","emailAddress":"cc@example.com","organizationRateLimitTier":"default_claude_ai"},"cachedUsageUtilization":{"fetchedAtMs":%d,"accountUuid":"acc-9","utilization":%s}}]],
		NOW_MS - 5000,
		payload(55, 30)
	)
	env.fetch = function(url: string, _opts: any): any
		error("no request expected: " .. url)
	end
	require("../host")
	env.drain()
	local row = env.kv.status.accounts[1]
	eq(row.label, "cc@example.com", "label from oauthAccount")
	eq(row.plan, "Pro", "plan from oauthAccount")
	eq(row.session.pct, 55, "cached usage adopted")
	print("claude code cache: ok")
end

-- ── the same account from two sources shows once ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS + 3600000)
	local doc = string.format([[{"claudeAiOauth":{"accessToken":"cc","refreshToken":"rt","expiresAt":%d}}]], NOW_MS + 3600000)
	env.files["/home/test/.claude.json"] = [[{"oauthAccount":{"accountUuid":"acc-1","organizationUuid":"org-1","emailAddress":"me@example.com"}}]]
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "security" and argv[5] == "-w" then
			return { status = 0, stdout = doc, stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	env.fetch = function(url: string, _opts: any): any
		if string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(1, 1))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	env.advance(301000)
	eq(#env.kv.status.accounts, 1, "deduplicated")
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	assert(string.find(render(env, st, cx), "另有 1 个来源指向同一账户", 1, true), "duplicate note")
	print("dedupe: ok")
end

-- ── login through the loopback listener ──
do
	local env = fake.new()
	__fresh(env)
	local opened: string? = nil
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "od" then
			return { status = 0, stdout = string.rep("ab ", 64), stderr = "", timed_out = false }
		elseif argv[1] == "nc" then
			eq(argv[3], "54545", "listener port")
			assert(string.find(opts.stdin, "HTTP/1.1 200 OK", 1, true), "listener answers")
			return "pending"
		elseif argv[1] == "open" then
			opened = argv[2]
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	local exchanged: any = nil
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			exchanged = env.tern.json.decode(opts.body)
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(20, 10))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, { "login" }, nil)
	env.advance(500)
	assert(opened and string.find(opened :: string, "^https://claude%.ai/oauth/authorize%?"), "browser opened: " .. tostring(opened))
	assert(string.find(opened :: string, "redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback", 1, true), "loopback redirect")
	assert(string.find(render(env, st, cx), "自动完成", 1, true), "listening hint")
	local state = string.match(opened :: string, "[?&]state=([%x]+)")
	env.pending.nc({ status = 0, stdout = "GET /callback?code=THE-CODE&state=" .. state .. " HTTP/1.1\r\nHost: localhost\r\n\r\n", stderr = "", timed_out = false })
	env.drain()
	assert(exchanged, "code exchanged")
	eq(exchanged.grant_type, "authorization_code", "exchange grant")
	eq(exchanged.code, "THE-CODE", "exchange code")
	eq(exchanged.state, state, "exchange state")
	eq(exchanged.redirect_uri, "http://localhost:54545/callback", "exchange redirect")
	eq(exchanged.client_id, "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "client id")
	local challenge = string.match(opened :: string, "code_challenge=([%w%-_]+)")
	eq(crypto.base64url(crypto.sha256(exchanged.code_verifier)), challenge, "verifier matches challenge")
	eq(st.flow, nil, "flow closed")
	eq(env.toasts[#env.toasts].level, "success", "success toast")
	local stored = env.tern.json.decode(env.files["/data/accounts.json"])
	eq(stored.accounts[1].tokens.email, "me@example.com", "account stored")
	eq(env.kv.status.accounts[1].session.pct, 20, "new account polled")
	print("login loopback: ok")
end

-- ── login by pasting code#state when the port is taken ──
do
	local env = fake.new()
	__fresh(env)
	local opened: string? = nil
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "od" then
			return { status = 0, stdout = string.rep("cd ", 64), stderr = "", timed_out = false }
		elseif argv[1] == "nc" then
			return { status = 1, stdout = "", stderr = "Address already in use", timed_out = false }
		elseif argv[1] == "open" then
			opened = argv[2]
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	local exchanged: any = nil
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			exchanged = env.tern.json.decode(opts.body)
			if string.find(url, "platform.claude.com", 1, true) then
				return { status = 0, headers = {}, body = "", error = "connection refused", timed_out = false }
			end
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(20, 10))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local function key(name: string, text: string?)
		return env.blocks.usage.key(st, { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }, cx)
	end
	key("l")
	env.advance(500)
	assert(opened and string.find(opened :: string, "redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback", 1, true), "manual redirect")
	assert(string.find(render(env, st, cx), "code#state", 1, true), "paste hint")
	local state = string.match(opened :: string, "[?&]state=([%x]+)")
	-- A wrong state is refused without a request.
	key("paste", "CODE#deadbeef")
	env.drain()
	eq(exchanged, nil, "wrong state not exchanged")
	assert(string.find(render(env, st, cx), "state 不匹配", 1, true), "state error shown")
	key("paste", " CODE2#" .. state .. "\n")
	env.drain()
	assert(exchanged, "pasted code exchanged")
	eq(exchanged.code, "CODE2", "pasted code")
	eq(exchanged.redirect_uri, "https://platform.claude.com/oauth/code/callback", "manual redirect in exchange")
	eq(count(env.calls.fetch, is_token), 2, "token endpoint fallback")
	eq(st.flow, nil, "flow done")
	eq(#env.kv.status.accounts, 1, "account added")
	print("login paste: ok")
end

-- ── removing an own account needs confirmation ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS + 3600000)
	env.process = base_process
	env.fetch = function(url: string, _opts: any): any
		if string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(1, 1))
		end
		return ok(PROFILE)
	end
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local function key(name: string)
		return env.blocks.usage.key(st, { name = name, ctrl = false, alt = false, shift = false, meta = false }, cx)
	end
	key("x")
	assert(string.find(render(env, st, cx), "移除此登录", 1, true), "confirm shown")
	key("enter")
	eq(#env.tern.json.decode(env.files["/data/accounts.json"]).accounts, 0, "removed")
	eq(key("q"), false, "unused key returns false")
	print("remove: ok")
end
