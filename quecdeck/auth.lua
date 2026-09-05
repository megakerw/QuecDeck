-- Session-based authentication for QuecDeck
-- Runs via mod_magnet on every HTTPS request.

local TIMEOUT  = 1800            -- seconds of inactivity before session expires
local MAX_AGE  = 28800           -- 8 hours absolute session lifetime
local SESSIONS = "/run/quecdeck-web/sessions/"
local LOGIN    = "/login.html"
local DEV_GENERATION = "/opt/etc/.htpasswd_dev.generation"

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
if path:find("..", 1, true) or path:lower():find("%2e", 1, true) then
    return redirect(LOGIN)
end

-- Application paths are literal and contain no escaped bytes or repeated
-- slashes. Every CGI has one flat name. Reject aliases and PATH_INFO before
-- exemptions: lighttpd can otherwise resolve them to a developer-only script
-- after the exact-path authorization check has skipped it.
if path:find("%", 1, true) or path:find("//", 1, true)
    or (path:match("^/cgi%-bin/") and not path:match("^/cgi%-bin/[a-z_]+$")) then
    lighty.status = 403
    return 403
end

-- Redirect to setup wizard if no admin password has been configured yet.
-- lighty.c.stat is available in mod_magnet 1.4.60 and later. Every supported
-- Entware lighttpd is newer. It needs no read permission for the root-owned
-- htpasswd file and avoids a process spawn. About one second of stat-cache
-- staleness during setup or recovery is acceptable. The shell fallback keeps
-- authentication working on an older build instead of returning 500 errors.
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

-- The setup page is valid only before setup. Redirect away once setup is complete.
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

local function file_exists(p)
    local fh = io.open(p, "r")
    if not fh then return false end
    fh:close()
    return true
end

local safe_path = url_encode(path)

if not token or not token:match("^[A-Za-z0-9]+$") or #token > 128 then
    return redirect(LOGIN .. "?next=" .. safe_path)
end

-- Read session file
local sf   = SESSIONS .. token
local revoked = sf .. ".revoked"

-- Logout leaves a short-lived revocation marker. It closes the race where a
-- request reads the session before logout, then refreshes it after logout has
-- deleted it. One check after the atomic refresh covers every ordering without
-- adding locking or a process spawn to authenticated requests.
local function session_revoked()
    local fh = io.open(revoked, "r")
    if not fh then return false end
    fh:close()
    return true
end

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
    os.remove(revoked)
    return redirect(LOGIN .. "?expired=1&next=" .. safe_path)
end

-- Developer CGIs additionally require the session to be unlocked via auth_dev.
-- The dev-unlock flag lives in a separate "<token>.dev" file (written only by
-- auth_dev) so the per-request last_access refresh below can't clobber it.
-- Read it only on dev-gated paths, not on every request.
local requires_dev_unlocked = path == "/cgi-bin/user_atcommand"
    or path == "/cgi-bin/set_cell_lock"
if requires_dev_unlocked then
    local unlocked = false
    local dev = read_session(sf .. ".dev")
    local generation_file = io.open(DEV_GENERATION, "r")
    local generation
    if generation_file then
        generation = generation_file:read("*l")
        generation_file:close()
    end
    if dev and dev.dev_unlocked == "1" and generation
        and generation:match("^[a-f0-9]+$") and #generation == 32
        and dev.generation == generation
    then
        unlocked = true
    end
    if not unlocked then
        os.remove(sf .. ".dev")
        lighty.status = 403
        return 403
    end
end

-- Refresh last_access via an atomic temp-file + rename. No per-file chmod is
-- needed: lighttpd.service sets UMask=0077, so this temp file is created 0600
-- and the rename preserves it. Lua has no chmod, so the unit's mask is what
-- keeps the token file sealed without a shell-fork (os.execute) on every
-- authenticated request. The 0700 sessions dir is the outer layer, not the
-- only one.
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

-- If logout landed before or during the refresh, the marker wins here. If it
-- lands after this check, logout removes the refreshed session itself.
if session_revoked() then
    os.remove(sf)
    os.remove(tmp)
    os.remove(sf .. ".dev")
    return redirect(LOGIN .. "?next=" .. safe_path)
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
                    local cr = tonumber(s.created) or 0
                    if (now - la) > TIMEOUT or (now - cr) > MAX_AGE then
                        os.remove(SESSIONS .. name)
                        os.remove(SESSIONS .. name .. ".dev")
                        os.remove(SESSIONS .. name .. ".revoked")
                    end
                end
            else
                local revoked_token = name and name:match("^([A-Za-z0-9]+)%.revoked$")
                if revoked_token then
                    local revoked_at = 0
                    local rf = io.open(SESSIONS .. name, "r")
                    if rf then
                        revoked_at = tonumber(rf:read("*a")) or 0
                        rf:close()
                    end
                    if (now - revoked_at) > MAX_AGE then
                        os.remove(SESSIONS .. name)
                    end
                else
                    local new_token = name and name:match("^([A-Za-z0-9]+)%.new$")
                    if new_token then
                        local pending = read_session(SESSIONS .. name)
                        local pending_at = pending and tonumber(pending.last_access) or now
                        if (now - pending_at) > TIMEOUT then
                            os.remove(SESSIONS .. name)
                        end
                    else
                        local dev_token = name and name:match("^([A-Za-z0-9]+)%.dev$")
                        if dev_token then
                            local base = SESSIONS .. dev_token
                            if not file_exists(base) and not file_exists(base .. ".new") then
                                os.remove(SESSIONS .. name)
                            end
                        else
                            local dev_tmp_token = name and name:match("^([A-Za-z0-9]+)%.dev%.tmp%.%d+$")
                            if dev_tmp_token then
                                local pending = read_session(SESSIONS .. name)
                                local pending_at = pending and tonumber(pending.created) or now
                                if (now - pending_at) > TIMEOUT then
                                    os.remove(SESSIONS .. name)
                                end
                            else
                                local tmp_token = name and name:match("^([A-Za-z0-9]+)%.revoked%.tmp%.%d+$")
                                if tmp_token then
                                    local tmp_at = now
                                    local tf = io.open(SESSIONS .. name, "r")
                                    if tf then
                                        tmp_at = tonumber(tf:read("*a")) or now
                                        tf:close()
                                    end
                                    if (now - tmp_at) > MAX_AGE then
                                        os.remove(SESSIONS .. name)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        d:close()
    end
end

return 0
