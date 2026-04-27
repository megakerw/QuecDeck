-- auth.lua — Session-based authentication for QuecDeck
-- Runs via mod_magnet on every HTTPS request.

local TIMEOUT  = 1800            -- seconds of inactivity before session expires
local MAX_AGE  = 28800           -- 8 hours absolute session lifetime
local SESSIONS = "/tmp/quecdeck/sessions/"
local LOGIN    = "/login.html"

local uri  = lighty.env["request.uri"]
local path = uri:match("^([^?#]*)")

-- Reject any path containing traversal sequences before any exemption check
if path:find("%.%.", 1, true) then
    lighty.header["Location"] = LOGIN
    lighty.header["Cache-Control"] = "no-store"
    lighty.status = 302
    return 302
end

-- Redirect to setup wizard if no admin password has been configured yet.
-- Use a shell test rather than io.open — lighttpd runs as www-data but its
-- only supplementary group is dialout, so htpasswd files are root:dialout 640.
local ret = os.execute("test -s /opt/etc/.htpasswd 2>/dev/null")
local setup_needed = not (ret == true or ret == 0)
if setup_needed then
    if path ~= "/setup.html" and path ~= "/cgi-bin/init_setup"
        and not path:match("^/css/")
        and not path:match("^/js/")
        and not path:match("^/fonts/")
        and path ~= "/favicon.ico"
    then
        lighty.header["Location"] = "/setup.html"
        lighty.header["Cache-Control"] = "no-store"
        lighty.status = 302
        return 302
    end
    return 0
end

-- Setup page is only valid before setup; redirect away once it's done
if path == "/setup.html" then
    lighty.header["Location"] = "/"
    lighty.header["Cache-Control"] = "no-store"
    lighty.status = 302
    return 302
end

-- Paths that do not require an active session
local exempt = {
    ["/login.html"]         = true,
    ["/cgi-bin/auth_login"] = true,
    ["/cgi-bin/auth_logout"]= true,
    ["/favicon.ico"]        = true,
}
if exempt[path]
    or path:match("^/css/")
    or path:match("^/js/")
    or path:match("^/fonts/")
then
    return 0
end

-- Extract session token from Cookie header
local cookie = lighty.request["Cookie"] or ""
local token  = cookie:match("^session=([A-Za-z0-9]+)") or cookie:match("; *session=([A-Za-z0-9]+)")

local function redirect(dest)
    lighty.header["Location"] = dest
    lighty.header["Cache-Control"] = "no-store"
    lighty.status = 302
    return 302
end

local function url_encode(s)
    return s:gsub("[^A-Za-z0-9%%-._~!$&'()*+,;=:@/]", function(c)
        return string.format("%%%02X", c:byte())
    end)
end

local safe_path = url_encode(path)

if not token or not token:match("^[A-Za-z0-9]+$") or #token > 128 then
    return redirect(LOGIN .. "?next=" .. safe_path)
end

-- Read session file
local sf = SESSIONS .. token
local f  = io.open(sf, "r")
if not f then
    return redirect(LOGIN .. "?next=" .. safe_path)
end

local sess = {}
for line in f:lines() do
    local k, v = line:match("^([%w_]+)=(.-)$")
    if k then sess[k] = v end
end
f:close()

-- Check inactivity timeout and absolute session lifetime
local now         = os.time()
local last_access = tonumber(sess.last_access) or 0
local created     = tonumber(sess.created)     or 0

if (now - last_access) > TIMEOUT or (now - created) > MAX_AGE then
    os.remove(sf)
    return redirect(LOGIN .. "?expired=1&next=" .. safe_path)
end

-- Developer CGIs additionally require the session to be unlocked via auth_dev
local requires_dev_unlocked = path:match("^/console")
    or path == "/cgi-bin/user_atcommand" or path == "/cgi-bin/get_atcommand"
    or path == "/cgi-bin/toggle_ttyd"   or path == "/cgi-bin/set_cell_lock"
if requires_dev_unlocked and sess.dev_unlocked ~= "1" then
    lighty.status = 403
    return 403
end

-- Refresh last_access timestamp.
-- Write to a temp file and chmod before renaming so the session file is never
-- transiently world-readable between open() and a post-hoc chmod call.
local tmp = sf .. ".new"
local wf = io.open(tmp, "w")
if wf then
    wf:write("user="        .. (sess.user    or "") .. "\n")
    wf:write("role="        .. (sess.role    or "") .. "\n")
    wf:write("created="     .. (sess.created or tostring(now)) .. "\n")
    wf:write("last_access=" .. tostring(now) .. "\n")
    if sess.dev_unlocked      then wf:write("dev_unlocked="      .. sess.dev_unlocked      .. "\n") end
    if sess.dev_fail_count    then wf:write("dev_fail_count="    .. sess.dev_fail_count    .. "\n") end
    if sess.dev_lockout_until then wf:write("dev_lockout_until=" .. sess.dev_lockout_until .. "\n") end
    wf:close()
    os.execute("chmod 600 " .. tmp)
    os.rename(tmp, sf)
end

-- Opportunistic cleanup: scan for and remove expired session files (~1% of requests)
if math.random(100) == 1 then
    local d = io.popen("find " .. SESSIONS .. " -maxdepth 1 -type f 2>/dev/null")
    if d then
        for fpath in d:lines() do
            local name = fpath:match("([^/]+)$")
            if name and name:match("^[A-Za-z0-9]+$") then
                local cf = io.open(SESSIONS .. name, "r")
                if cf then
                    local la = 0
                    for line in cf:lines() do
                        local k, v = line:match("^([%w_]+)=(.-)$")
                        if k == "last_access" then la = tonumber(v) or 0 end
                    end
                    cf:close()
                    if (now - la) > TIMEOUT then os.remove(SESSIONS .. name) end
                end
            end
        end
        d:close()
    end
end

return 0
