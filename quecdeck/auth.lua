-- Session-based authentication for QuecDeck
-- Runs via mod_magnet on every HTTPS request.

local TIMEOUT  = 1800            -- seconds of inactivity before session expires
local MAX_AGE  = 28800           -- 8 hours absolute session lifetime
local SESSIONS = "/tmp/quecdeck/sessions/"
local LOGIN    = "/login.html"

local uri  = lighty.env["request.uri"]
local path = uri:match("^([^?#]*)")

local function redirect(dest)
    lighty.header["Location"] = dest
    lighty.header["Cache-Control"] = "no-store"
    lighty.status = 302
    return 302
end

-- Reject any path containing traversal sequences before any exemption check.
-- Percent-encoded dots are rejected too: this runs on the raw URI (magnet
-- attract-raw-url), so "%2e%2e" would not match the literal ".." check yet
-- could decode to a dot-segment later in request handling.
if path:find("%.%.", 1, true) or path:lower():find("%2e", 1, true) then
    return redirect(LOGIN)
end

-- Redirect to setup wizard if no admin password has been configured yet.
-- lighty.c.stat (mod_magnet 1.4.60+; every install's Entware lighttpd is
-- newer) needs no read permission (htpasswd files are root:dialout 640) and
-- no fork. Served from lighttpd's stat cache; ~1s staleness on setup/reset
-- transitions is fine. The shell test keeps auth alive on a build without
-- the API rather than 500ing every request.
local setup_needed
if lighty.c and lighty.c.stat then
    local st = lighty.c.stat("/opt/etc/.htpasswd")
    setup_needed = not (st and st.st_size and st.st_size > 0)
else
    local ret = os.execute("test -s /opt/etc/.htpasswd 2>/dev/null")
    setup_needed = not (ret == true or ret == 0)
end
if setup_needed then
    if path ~= "/setup.html" and path ~= "/cgi-bin/init_setup"
        and not path:match("^/css/")
        and not path:match("^/js/")
        and not path:match("^/fonts/")
        and path ~= "/favicon.ico"
    then
        return redirect("/setup.html")
    end
    return 0
end

-- Setup page is only valid before setup; redirect away once it's done
if path == "/setup.html" then
    return redirect("/")
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

local function url_encode(s)
    return s:gsub("[^A-Za-z0-9%%-._~!$&'()*+,;=:@/]", function(c)
        return string.format("%%%02X", c:byte())
    end)
end

-- Parse a "key=value" session file into a table, or nil if it can't be opened.
local function read_session(p)
    local fh = io.open(p, "r")
    if not fh then return nil end
    local t = {}
    for line in fh:lines() do
        local k, v = line:match("^([%w_]+)=(.-)$")
        if k then t[k] = v end
    end
    fh:close()
    return t
end

local safe_path = url_encode(path)

if not token or not token:match("^[A-Za-z0-9]+$") or #token > 128 then
    return redirect(LOGIN .. "?next=" .. safe_path)
end

-- Read session file
local sf   = SESSIONS .. token
local sess = read_session(sf)
if not sess then
    return redirect(LOGIN .. "?next=" .. safe_path)
end

-- Check inactivity timeout and absolute session lifetime
local now         = os.time()
local last_access = tonumber(sess.last_access) or 0
local created     = tonumber(sess.created)     or 0

if (now - last_access) > TIMEOUT or (now - created) > MAX_AGE then
    os.remove(sf)
    os.remove(sf .. ".dev")
    return redirect(LOGIN .. "?expired=1&next=" .. safe_path)
end

-- Developer CGIs additionally require the session to be unlocked via auth_dev.
-- The dev-unlock flag lives in a separate "<token>.dev" file (written only by
-- auth_dev) so the per-request last_access refresh below can't clobber it.
-- Read it only on dev-gated paths, not on every request.
local requires_dev_unlocked = path:match("^/console")
    or path == "/cgi-bin/user_atcommand"
    or path == "/cgi-bin/toggle_ttyd"   or path == "/cgi-bin/set_cell_lock"
if requires_dev_unlocked then
    local unlocked = false
    local devf = io.open(sf .. ".dev", "r")
    if devf then
        unlocked = devf:read("*a"):match("dev_unlocked=1") ~= nil
        devf:close()
    end
    if not unlocked then
        lighty.status = 403
        return 403
    end
end

-- Refresh last_access via an atomic temp-file + rename. No per-file chmod is
-- needed: the sessions dir is 0700 (auth_login creates it with umask 077), so
-- no other user can traverse into it and the temp file's mode is irrelevant.
-- This drops a shell-fork (os.execute) from every authenticated request.
local tmp = sf .. ".new"
local wf = io.open(tmp, "w")
if wf then
    wf:write("user="        .. (sess.user    or "") .. "\n")
    wf:write("role="        .. (sess.role    or "") .. "\n")
    wf:write("created="     .. (sess.created or tostring(now)) .. "\n")
    wf:write("last_access=" .. tostring(now) .. "\n")
    wf:close()
    os.rename(tmp, sf)
end

-- Opportunistic cleanup: scan for and remove expired session files (~1% of requests)
if math.random(100) == 1 then
    local d = io.popen("find " .. SESSIONS .. " -maxdepth 1 -type f 2>/dev/null")
    if d then
        for fpath in d:lines() do
            local name = fpath:match("([^/]+)$")
            if name and name:match("^[A-Za-z0-9]+$") then
                local s = read_session(SESSIONS .. name)
                if s then
                    local la = tonumber(s.last_access) or 0
                    if (now - la) > TIMEOUT then
                        os.remove(SESSIONS .. name)
                        os.remove(SESSIONS .. name .. ".dev")
                    end
                end
            end
        end
        d:close()
    end
end

return 0
