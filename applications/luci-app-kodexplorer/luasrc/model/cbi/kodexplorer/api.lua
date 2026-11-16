local fs = require "nixio.fs"
local sys = require "luci.sys"
local uci = require"luci.model.uci".cursor()
local util = require "luci.util"
local i18n = require "luci.i18n"

module("luci.model.cbi.kodexplorer.api", package.seeall)

local appname = "kodexplorer"
local api_url = "https://api.github.com/repos/kalcaddle/kodbox/releases/latest"

local wget = "/usr/bin/wget"
local wget_args = { "--no-check-certificate", "-q", "-T", "30" }
local command_timeout = 300

local function _unpack(t, i)
    i = i or 1
    if t[i] ~= nil then return t[i], _unpack(t, i + 1) end
end

local function exec(cmd, args, writer, timeout)
    local os = require "os"
    local nixio = require "nixio"

    local fdi, fdo = nixio.pipe()
    local pid = nixio.fork()

    if pid > 0 then
        fdo:close()

        if writer or timeout then
            local starttime = os.time()
            while true do
                if timeout and os.difftime(os.time(), starttime) >= timeout then
                    nixio.kill(pid, nixio.const.SIGTERM)
                    return 1
                end

                if writer then
                    local buffer = fdi:read(2048)
                    if buffer and #buffer > 0 then
                        writer(buffer)
                    end
                end

                local wpid, stat, code = nixio.waitpid(pid, "nohang")

                if wpid and stat == "exited" then return code end

                if not writer and timeout then nixio.nanosleep(1) end
            end
        else
            local wpid, stat, code = nixio.waitpid(pid)
            return wpid and stat == "exited" and code
        end
    elseif pid == 0 then
        nixio.dup(fdo, nixio.stdout)
        fdi:close()
        fdo:close()
        nixio.exece(cmd, args, nil)
        nixio.stdout:close()
        os.exit(1)
    end
end

function get_project_directory()
    return uci:get(appname, "@global[0]", "project_directory") or "/tmp/kodcloud"
end

function get_version()
    local version = get_project_directory() .. "/config/version.php"
    return sys.exec(string.format("echo -n $(cat %s 2>/dev/null | grep \"'KOD_VERSION'\" | cut -d \"'\" -f 4)", version))
end

local function get_api_json(url)
    local jsonc = require "luci.jsonc"
    local json_content = sys.exec("curl -sL -k -A 'Mozilla/5.0' --connect-timeout 15 -m 30 '" .. url .. "' 2>/dev/null || " .. wget .. " --no-check-certificate -U 'Mozilla/5.0' -q -T 30 -O- '" .. url .. "' 2>/dev/null")
    if json_content == "" then return {} end
    return jsonc.parse(json_content) or {}
end

function to_check()
    local raw = get_api_json(api_url)
    if not raw or not raw.tag_name then
        return { code = 0 }
    end

    local ver = raw.tag_name:gsub("^v", "")
        ver = ver:match("^(%d+%.%d+)") or ver
    local dl_url = ""

    if raw.assets and #raw.assets > 0 then
        for _, asset in ipairs(raw.assets) do
            if asset.name and asset.name:match("%.zip$") then
                dl_url = asset.browser_download_url
                break
            end
        end
    end

    if dl_url == "" then
        dl_url = "https://github.com/kalcaddle/kodbox/archive/refs/tags/" .. raw.tag_name .. ".zip"
    end

    return {
        code = 1,
        data = {
            server = {
                version = ver,
                link = dl_url
            }
        }
    }
end

function to_download(url)
    if not url or url == "" then
        return {code = 1, error = i18n.translate("Download url is required.")}
    end

    local proj_dir = get_project_directory()
    sys.call("mkdir -p " .. proj_dir)
    sys.call("/bin/rm -f " .. proj_dir .. "/kodcloud_download.*")

    local tmp_file = util.trim(util.exec("mktemp -u -p " .. proj_dir .. " kodcloud_download.XXXXXX"))

    local result = (sys.call(string.format("curl -sL -k -A 'Mozilla/5.0' --connect-timeout 15 -m 300 -o '%s' '%s' || %s --no-check-certificate -U 'Mozilla/5.0' -q -T 300 -O '%s' '%s'", tmp_file, url, wget, tmp_file, url)) == 0)

    if not result or not fs.access(tmp_file) or (fs.stat(tmp_file, "size") or 0) < 1024 then
        exec("/bin/rm", {"-f", tmp_file})
        return {
            code = 1,
            error = i18n.translatef("File download failed or timed out: %s", url)
        }
    end

    return {code = 0, file = tmp_file}
end

function to_extract(file)
    if not file or file == "" or not fs.access(file) then
        return {code = 1, error = i18n.translate("File path required.")}
    end

    local proj_dir = get_project_directory()
    sys.call("mkdir -p " .. proj_dir)
    sys.call("/bin/rm -rf " .. proj_dir .. "/kodcloud_extract.*")
    local tmp_dir = util.trim(util.exec("mktemp -d -p " .. proj_dir .. " kodcloud_extract.XXXXXX"))

    local output = {}
    exec("/usr/bin/unzip", {"-o", file, "-d", tmp_dir}, function(chunk) output[#output + 1] = chunk end)

    exec("/bin/rm", {"-f", file})

    return {code = 0, file = tmp_dir}
end

function to_move(file)
    if not file or file == "" or not fs.access(file) then
        sys.call("/bin/rm -rf " .. get_project_directory() .. "/kodcloud_extract.*")
        return {code = 1, error = i18n.translate("Client file is required.")}
    end

    local client_file = get_project_directory()
    sys.call("mkdir -p " .. client_file)

    local sub_dir = util.trim(util.exec("find " .. file .. " -mindepth 1 -maxdepth 1 -type d"))
    if sub_dir ~= "" and not fs.access(file .. "/index.php") and fs.access(sub_dir .. "/index.php") then
        sys.call("cp -Rf " .. sub_dir .. "/* " .. client_file .. "/")
    else
        sys.call("cp -Rf " .. file .. "/* " .. client_file .. "/")
    end

    sys.call("chmod -Rf 777 " .. client_file)
    sys.call("/bin/rm -rf " .. get_project_directory() .. "/kodcloud_extract.*")

        sys.call("chmod +x /etc/init.d/kodexplorer && /etc/init.d/kodexplorer enable >/dev/null 2>&1")
    sys.call("/etc/init.d/kodexplorer restart >/dev/null 2>&1 &")

    return {code = 0}
end