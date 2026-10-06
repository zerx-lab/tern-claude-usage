-- Pure modules: hashing/PKCE, ISO time, usage payload normalization, pasted-code parsing.

local fake = require("./fake_tern")
local env = fake.new()
__fresh(env)

local crypto = require("../lib/crypto")
local time = require("../lib/time")
local usage = require("../lib/usage")
local oauth = require("../lib/oauth")

local function eq(a: any, b: any, what: string)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", what, tostring(b), tostring(a)), 2)
	end
end

-- SHA-256 across padding boundaries (55/56/64/119 bytes) and a multi-block input.
local vectors = {
	{ "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
	{ "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
	{ string.rep("a", 55), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
	{ string.rep("a", 56), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
	{ string.rep("a", 64), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
	{ string.rep("a", 119), "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb" },
}
local all = {}
for i = 0, 255 do
	all[i + 1] = string.char(i)
end
table.insert(vectors, { string.rep(table.concat(all), 5), "d414b085826eb06778483ba35564dc849e643359f69ed9747878ba6e54985bed" })
for _, v in vectors do
	eq(crypto.hex(crypto.sha256(v[1])), v[2], "sha256 of " .. #v[1] .. " bytes")
end

-- RFC 7636 appendix B.
eq(crypto.base64url(crypto.sha256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "pkce S256")
eq(crypto.base64url(string.char(0xfb, 0xff, 0xfe, 0x01)), "-__-AQ", "base64url unpadded")
eq(crypto.unhex(" 0a ff\n10 "), "\10\255\16", "unhex skips whitespace")

local p = oauth.pkce(string.rep("\1", 64))
eq(#p.verifier, 64, "verifier length")
eq(p.challenge, crypto.base64url(crypto.sha256(p.verifier)), "challenge")
eq(p.state, string.rep("01", 16), "state hex")
local url = oauth.authorize_url(p, oauth.LOOPBACK_REDIRECT)
assert(string.find(url, "redirect_uri=http%%3A%%2F%%2Flocalhost%%3A54545%%2Fcallback"), url)
assert(string.find(url, "scope=user%%3Aprofile%%20user%%3Ainference"), url)
assert(string.find(url, "code_challenge_method=S256", 1, true), url)

-- ISO timestamps: fractional seconds, offsets, Z.
eq(time.parse_iso("2026-10-03T04:10:00.135558+00:00"), 1791000600.135558, "iso micro")
eq(time.parse_iso("2026-11-05T07:59:00+00:00"), 1793865540, "iso")
eq(time.parse_iso("2026-10-07T20:00:00+08:00"), 1791374400, "iso offset")
eq(time.parse_iso("2024-02-29T23:59:59Z"), 1709251199, "iso leap Z")
eq(time.parse_iso("nope"), nil, "iso garbage")
eq(time.parse_iso(nil), nil, "iso nil")
eq(time.duration(2 * 86400 + 3 * 3600 + 59), "2天3小时", "duration days")
eq(time.duration(3 * 3600 + 12 * 60), "3小时12分", "duration hours")
eq(time.short(3 * 3600 + 5 * 60), "3h05m", "short")

-- The real payload Claude Code cached (Pro account, nulls dropped by the decoder).
local real = env.tern.json.decode([[{
 "five_hour": {"utilization":3,"resets_at":"2026-10-03T04:10:00.135558+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},
 "seven_day": {"utilization":0,"resets_at":"2026-10-07T20:00:00.135579+00:00","limit_dollars":null},
 "seven_day_oauth_apps": null, "seven_day_opus": null, "seven_day_sonnet": null,
 "iguana_necktie": {"utilization":0,"resets_at":"2026-11-05T07:59:00+00:00","limit_dollars":100,"used_dollars":0,"remaining_dollars":100,"locked_reason":null},
 "extra_usage": {"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null,"currency":null,"decimal_places":null,"disabled_reason":null,"user_disabled":true},
 "limits": [
  {"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"2026-10-03T04:10:00.135558+00:00","scope":null,"is_active":true},
  {"kind":"weekly_all","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-10-07T20:00:00.135579+00:00","scope":null,"is_active":false}
 ],
 "spend": {"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"percent":0,"severity":"normal","enabled":false,"disabled_reason":null},
 "member_dashboard_available": false
}]])
local u = usage.parse(real)
assert(u, "real payload parses")
eq(#u.windows, 3, "real windows (5h, 7d, iguana_necktie)")
eq(u.windows[1].id, "5h", "5h first")
eq(u.windows[1].pct, 3, "5h pct")
eq(u.windows[1].resets_at, 1791000600.135558, "5h reset")
eq(u.windows[1].active, true, "5h active")
eq(u.windows[2].id, "7d", "7d second")
eq(u.windows[2].duration, usage.WEEK, "7d duration")
eq(u.windows[3].id, "bucket:iguana_necktie", "codename bucket")
eq(u.windows[3].dollars.limit, 100, "codename limit")
eq(u.extra.enabled, false, "spend disabled")
eq(u.extra.reason, "user_disabled", "reason from extra_usage when spend has none")

-- Per-model weekly caps only in limits[]; legacy buckets gone; spend enabled with a cap.
local scoped = usage.parse({
	limits = {
		{ kind = "session", percent = 40, resets_at = "2026-10-03T04:10:00Z" },
		{ kind = "weekly_all", percent = 77, resets_at = "2026-10-07T20:00:00Z" },
		{ kind = "weekly_scoped", percent = 100, resets_at = "2026-10-07T20:00:00Z", is_active = true, scope = { model = { display_name = "Opus" } } },
	},
	spend = { enabled = true, used = { amount_minor = 1234, exponent = 2, currency = "USD" }, limit = { amount_minor = 5000, exponent = 2, currency = "USD" } },
})
assert(scoped)
eq(#scoped.windows, 3, "scoped windows")
eq(scoped.windows[1].pct, 40, "session from limits")
eq(scoped.windows[2].pct, 77, "weekly from limits")
eq(scoped.windows[3].label, "7 天 · Opus", "scoped label")
eq(scoped.windows[3].active, true, "scoped active")
eq(scoped.extra.used, 12.34, "spend used")
eq(scoped.extra.limit, 50, "spend limit")
eq(math.floor(scoped.extra.pct * 100 + 0.5), 2468, "spend pct derived")

-- A legacy per-model bucket and a scoped limit for the same model show once.
local both = usage.parse({
	five_hour = { utilization = 1 },
	seven_day_opus = { utilization = 20, resets_at = "2026-10-07T20:00:00Z" },
	limits = { { kind = "weekly_scoped", percent = 20, scope = { model = { display_name = "Opus" } } } },
})
assert(both)
eq(#both.windows, 2, "opus deduped")

-- Legacy extra_usage in cents.
local legacy = usage.parse({ five_hour = { utilization = 5 }, extra_usage = { is_enabled = true, used_credits = 250, monthly_limit = 1000 } })
assert(legacy)
eq(legacy.extra.used, 2.5, "legacy used")
eq(legacy.extra.pct, 25, "legacy pct")
eq(usage.parse({ hello = 1 }), nil, "not a usage body")

-- Pace: 50% used after 1 h of a 5 h window → exhausts in 1 h, before the reset.
local now = 1000000
local w = { id = "5h", label = "", kind = "session", pct = 50, resets_at = now + 4 * 3600, duration = 5 * 3600 }
local pace = usage.pace(w, now)
assert(pace)
eq(pace.elapsed, 0.2, "elapsed fraction")
eq(math.floor(pace.exhaust_in :: number + 0.5), 3600, "exhaust in")
eq(math.floor(pace.delta + 0.5), 30, "ahead of pace")
local slow = usage.pace({ id = "7d", label = "", kind = "weekly", pct = 10, resets_at = now + 3.5 * 86400, duration = usage.WEEK }, now)
assert(slow)
eq(slow.exhaust_in, nil, "slow use lasts")
eq(math.floor(slow.projected :: number + 0.5), 20, "projection")
eq(usage.pace({ id = "x", label = "", kind = "session", pct = 0, resets_at = nil, duration = 5 * 3600 }, now), nil, "no reset no pace")

eq(usage.plan("default_claude_max_20x", nil, nil), "Max 20x", "tier plan")
eq(usage.plan(nil, "max", nil), "Max", "subscription plan")
eq(usage.plan(nil, nil, "claude_pro"), "Pro", "org type plan")

-- Pasted codes.
local c, s = oauth.parse_pasted("  abc123#st4te \n")
eq(c, "abc123", "code#state code")
eq(s, "st4te", "code#state state")
c, s = oauth.parse_pasted("http://localhost:54545/callback?code=xy%2Fz&state=qq")
eq(c, "xy/z", "url code decoded")
eq(s, "qq", "url state")
c, s = oauth.parse_pasted("https://platform.claude.com/oauth/code/callback?error=access_denied")
eq(c, nil, "url without code")
c = oauth.parse_pasted("bare-code_1")
eq(c, "bare-code_1", "bare code")
c = oauth.parse_pasted("two words")
eq(c, nil, "garbage")
local rc, rs = oauth.parse_callback_request("GET /callback?code=K1&state=S1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
eq(rc, "K1", "callback code")
eq(rs, "S1", "callback state")
local _, _, rerr = oauth.parse_callback_request("GET /callback?error=access_denied HTTP/1.1\r\n")
eq(rerr, "access_denied", "callback error")

print("pure: all passed")
