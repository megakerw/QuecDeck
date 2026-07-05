-- Harness for auth.lua: stubs the lighty request environment and runs the
-- real file per case via dofile. Run via host-test-authlua.sh: expects a
-- disposable root environment (CI runner/container), since auth.lua's
-- /tmp/quecdeck and /opt/etc paths are used as-is.

local AUTH = "quecdeck/auth.lua"
local SESSIONS = "/tmp/quecdeck/sessions/"
local HTPASSWD = "/opt/etc/.htpasswd"

local pass, fail = 0, 0
local function t(name, expected, actual)
    if expected == actual then
        pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL: %s\n  expected: %s\n  actual:   %s",
            name, tostring(expected), tostring(actual)))
    end
end

-- Each case gets a fresh lighty stub; auth.lua's top-level return is the
-- status it hands back to mod_magnet (nil/0 = pass request through).
local function run(uri, cookie)
    lighty = {
        env     = { ["request.uri"] = uri },
        request = { Cookie = cookie },
        header  = {},
    }
    local rc = dofile(AUTH)
    return rc or 0, lighty
end

local function write_session(token, fields)
    local f = assert(io.open(SESSIONS .. token, "w"))
    for k, v in pairs(fields) do f:write(k .. "=" .. v .. "\n") end
    f:close()
end

local function read_file(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

os.execute("mkdir -p " .. SESSIONS)
os.execute("mkdir -p /opt/etc")

-- ------------------------------------------------ setup mode (no htpasswd)
os.remove(HTPASSWD)

local rc, L = run("/", nil)
t("setup: root redirects to wizard", 302, rc)
t("setup: wizard location", "/setup.html", L.header["Location"])
rc = run("/setup.html", nil)
t("setup: wizard reachable", 0, rc)
rc = run("/cgi-bin/init_setup", nil)
t("setup: init_setup reachable", 0, rc)
rc = run("/js/setup.js", nil)
t("setup: js exempt", 0, rc)
rc, L = run("/cgi-bin/get_dashboard", nil)
t("setup: other CGI redirected", 302, rc)

-- ------------------------------------------------------------ normal mode
local f = assert(io.open(HTPASSWD, "w")); f:write("admin:x\n"); f:close()

rc, L = run("/setup.html", nil)
t("post-setup: setup.html redirects away", 302, rc)
t("post-setup: location", "/", L.header["Location"])

rc = run("/login.html", nil)
t("exempt: login page", 0, rc)
rc = run("/css/style.css", nil)
t("exempt: css", 0, rc)
rc = run("/cgi-bin/auth_login", nil)
t("exempt: auth_login", 0, rc)

rc, L = run("/index.html", nil)
t("no cookie: redirect", 302, rc)
t("no cookie: next param", "/login.html?next=/index.html", L.header["Location"])

rc = run("/index.html", "session=nosuchtoken123")
t("unknown token: redirect", 302, rc)
rc = run("/index.html", "session=" .. string.rep("a", 129))
t("oversized token: redirect", 302, rc)
rc = run("/../index.html", "session=whatever")
t("traversal path: redirect", 302, rc)

local now = os.time()
write_session("tokA1", { user = "admin", role = "admin",
    created = tostring(now), last_access = tostring(now - 100) })
rc = run("/index.html", "session=tokA1")
t("valid session: passes", 0, rc)
rc = run("/cgi-bin/get_dashboard", "other=x; session=tokA1")
t("valid session: token after other cookie", 0, rc)
local la = tonumber((read_file(SESSIONS .. "tokA1") or ""):match("last_access=(%d+)"))
t("valid session: last_access refreshed", true, la ~= nil and (now - la) < 10)

write_session("tokB2", { user = "admin", role = "admin",
    created = tostring(now), last_access = tostring(now - 3600) })
rc, L = run("/index.html", "session=tokB2")
t("inactivity expiry: redirect", 302, rc)
t("inactivity expiry: expired flag", "/login.html?expired=1&next=/index.html", L.header["Location"])
t("inactivity expiry: file removed", nil, read_file(SESSIONS .. "tokB2"))

write_session("tokC3", { user = "admin", role = "admin",
    created = tostring(now - 30000), last_access = tostring(now) })
rc = run("/index.html", "session=tokC3")
t("absolute expiry: redirect", 302, rc)

-- ---------------------------------------------------------- dev gating
write_session("tokD4", { user = "admin", role = "admin",
    created = tostring(now), last_access = tostring(now) })
rc = run("/cgi-bin/user_atcommand", "session=tokD4")
t("dev endpoint locked: 403", 403, rc)
rc = run("/console/", "session=tokD4")
t("console locked: 403", 403, rc)
rc = run("/cgi-bin/get_dashboard", "session=tokD4")
t("non-dev endpoint: passes while locked", 0, rc)

local df = assert(io.open(SESSIONS .. "tokD4.dev", "w"))
df:write("dev_unlocked=1\n"); df:close()
rc = run("/cgi-bin/user_atcommand", "session=tokD4")
t("dev endpoint unlocked: passes", 0, rc)
rc = run("/console/", "session=tokD4")
t("console unlocked: passes", 0, rc)

-- -------------------------------------------------------------- summary
print("")
print(string.format("auth.lua tests: %d, passed: %d, failed: %d", pass + fail, pass, fail))
os.exit(fail == 0 and 0 or 1)
