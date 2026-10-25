--[[--
    StoryKore KOReader Plugin
    Compatible con todos los lectores (Kindle Keyboard / K3, K4, Paperwhite, Oasis, Kobo, Android, etc.)
    Sincroniza de forma inalámbrica estadísticas (statistics.sqlite3) y metadatos (.lua dentro de .sdr) con StoryKore.
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

-- Safe loader helper for UI widgets and utilities
local function safe_require(module_name)
    local ok, mod = pcall(require, module_name)
    if ok and mod then return mod end
    return nil
end

local ConfirmBox = safe_require("ui/widget/confirmbox")
local InfoMessage = safe_require("ui/widget/infomessage")
local InputDialog = safe_require("ui/widget/inputdialog")
local MultiInputDialog = safe_require("ui/widget/multiinputdialog")
local DataStorage = safe_require("datastorage")
local Device = safe_require("device")
local logger = safe_require("logger")

-- Network Manager safe load (different KOReader versions use different paths)
local NetworkMgr = safe_require("ui/network/manager") or safe_require("ui/network/networkmgr")

-- LuaFileSystem safe load
local lfs = safe_require("libs/libkoreader-lfs") or safe_require("lfs")

-- Safe message popup
local function show_message(text, timeout)
    if InfoMessage then
        UIManager:show(InfoMessage:new{
            text = text,
            timeout = timeout or 5,
        })
    end
end

-- Wi-Fi and Network helper functions
local function is_wifi_on()
    if NetworkMgr and NetworkMgr.isWifiOn then
        local ok, val = pcall(function() return NetworkMgr:isWifiOn() end)
        if ok and val ~= nil then return val end
    end
    if Device and Device.isWifiOn then
        local ok, val = pcall(function() return Device:isWifiOn() end)
        if ok and val ~= nil then return val end
    end
    return false
end

local function turn_off_wifi()
    if NetworkMgr and NetworkMgr.turnOffWifi then
        pcall(function() NetworkMgr:turnOffWifi() end)
    elseif Device and Device.turnOffWifi then
        pcall(function() Device:turnOffWifi() end)
    end
end

local function turn_on_wifi_and_run(callback)
    if is_wifi_on() then
        if NetworkMgr and NetworkMgr.runWhenOnline then
            NetworkMgr:runWhenOnline(callback)
        else
            callback()
        end
        return
    end

    local function when_online()
        if NetworkMgr and NetworkMgr.runWhenOnline then
            NetworkMgr:runWhenOnline(callback)
        else
            callback()
        end
    end

    if NetworkMgr and NetworkMgr.turnOnWifi then
        local ok = pcall(function()
            NetworkMgr:turnOnWifi(when_online, false)
        end)
        if not ok then
            when_online()
        end
    elseif Device and Device.turnOnWifi then
        pcall(function() Device:turnOnWifi() end)
        when_online()
    else
        when_online()
    end
end

-- Base64 encoder helper with fast C module detection and high-performance pure-Lua fallback
local function to_base64(data)
    if not data or #data == 0 then return "" end

    -- 1. Try standard LuaSocket mime module
    local ok_mime, mime = pcall(require, "mime")
    if ok_mime and mime and type(mime.b64) == "function" then
        return mime.b64(data)
    end

    -- 2. Try mime.core (used by many embedded KOReader builds)
    local ok_core, core = pcall(require, "mime.core")
    if ok_core and core and type(core.b64) == "function" then
        return core.b64(data)
    end

    -- 3. Fast pure-Lua chunked Base64 (avoids million-iteration gsub string thrashing on e-ink CPUs)
    local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local len = #data
    local out = {}
    local out_idx = 1
    local b1, b2, b3, n
    for i = 1, len - (len % 3), 3 do
        b1, b2, b3 = data:byte(i, i + 2)
        n = b1 * 65536 + b2 * 256 + b3
        out[out_idx] = b64_chars:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1) ..
                      b64_chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1) ..
                      b64_chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) ..
                      b64_chars:sub(n % 64 + 1, n % 64 + 1)
        out_idx = out_idx + 1
    end
    local rem = len % 3
    if rem == 1 then
        b1 = data:byte(len)
        n = b1 * 65536
        out[out_idx] = b64_chars:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1) ..
                       b64_chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1) ..
                       "=="
    elseif rem == 2 then
        b1, b2 = data:byte(len - 1, len)
        n = b1 * 65536 + b2 * 256
        out[out_idx] = b64_chars:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1) ..
                       b64_chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1) ..
                       b64_chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) ..
                       "="
    end
    return table.concat(out)
end

-- JSON encoder/decoder helper
local function json_encode(obj)
    local ok_r, rapidjson = pcall(require, "rapidjson")
    if ok_r and rapidjson and rapidjson.encode then
        return rapidjson.encode(obj)
    end
    local ok_j, j = pcall(require, "json")
    if ok_j and j and j.encode then
        return j.encode(obj)
    end
    local ok_u, util = pcall(require, "util")
    if ok_u and util and util.tableToJSON then
        return util.tableToJSON(obj)
    end
    return "{}"
end

local function json_decode(str)
    local ok_r, rapidjson = pcall(require, "rapidjson")
    if ok_r and rapidjson and rapidjson.decode then
        local ok, res = pcall(rapidjson.decode, str)
        if ok then return res end
    end
    local ok_j, j = pcall(require, "json")
    if ok_j and j and j.decode then
        local ok, res = pcall(j.decode, str)
        if ok then return res end
    end
    return {}
end

-- File helpers
local function read_binary_file(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function read_text_file(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local DEFAULT_SERVER_URL = "https://storykore.onrender.com"

local StoryKore = WidgetContainer:extend{
    name = "storykore",
    is_doc_only = false,
}

function StoryKore:init()
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:loadSettings()
end

function StoryKore:loadSettings()
    local saved = G_reader_settings and G_reader_settings:readSetting("storykore_settings")
    if type(saved) == "table" then
        self.settings = saved
    else
        self.settings = {}
    end
    local s_url = self.settings.server_url
    if not s_url or s_url == "" or s_url == "https://" or s_url == "http://" then
        self.settings.server_url = DEFAULT_SERVER_URL
    end
    self.settings.username = self.settings.username or ""
    self.settings.password = self.settings.password or ""
    self.settings.token = self.settings.token or ""
    self.settings.last_sync = self.settings.last_sync or ""
    self.settings.custom_docs_dir = self.settings.custom_docs_dir or ""
    if self.settings.auto_manage_wifi == nil then
        self.settings.auto_manage_wifi = false
    end
end

function StoryKore:saveSettings()
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("storykore_settings", self.settings)
    end
end

-- Registra StoryKore en el menú principal
function StoryKore:addToMainMenu(menu_items)
    menu_items.storykore = {
        text = _("StoryKore"),
        sub_item_table = {
            {
                text = _("Sincronizar ahora"),
                callback = function()
                    self:onSyncTap()
                end,
            },
            {
                text = _("Auto Wi-Fi (Ahorro de batería)"),
                checked_func = function()
                    return self.settings.auto_manage_wifi == true
                end,
                help_text = _("Activa Wi-Fi para sincronizar y lo apaga automáticamente al terminar."),
                callback = function(touchmenu_instance)
                    self.settings.auto_manage_wifi = not self.settings.auto_manage_wifi
                    self:saveSettings()
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                    if self.settings.auto_manage_wifi then
                        show_message(_("✓ Auto Wi-Fi activado:\n\nAl sincronizar, el plugin encenderá el Wi-Fi, sincronizará y lo apagará automáticamente para ahorrar batería."), 5)
                    else
                        show_message(_("Auto Wi-Fi desactivado:\n\nEl Wi-Fi se gestionará de forma manual."), 3)
                    end
                end,
            },
            {
                text_func = function()
                    local u = self.settings.username
                    if not u or u == "" then return _("Usuario: (No configurado)") end
                    return _("Usuario: ") .. u
                end,
                callback = function()
                    self:editUsername()
                end,
            },
            {
                text_func = function()
                    local p = self.settings.password
                    if not p or p == "" then return _("Contraseña: (No configurada)") end
                    return _("Contraseña: ••••••••")
                end,
                callback = function()
                    self:editPassword()
                end,
            },
            {
                text = _("Probar conexión"),
                callback = function()
                    self:testConnection()
                end,
            },
            {
                text = _("Estado de sincronización"),
                callback = function()
                    self:showStatusDialog()
                end,
            },
            {
                text = _("Configurar cuenta (Usuario / Clave)"),
                callback = function()
                    self:showSettingsDialog()
                end,
            },
        }
    }
end

-- Modales de edición individual con teclado físico o virtual
function StoryKore:editServerUrl()
    if not InputDialog then return self:showSettingsDialog() end
    local dialog
    dialog = InputDialog:new{
        title = _("URL del Servidor StoryKore"),
        description = _("Ejemplo: https://mi-storykore.onrender.com o http://192.168.1.50:8000"),
        input = self.settings.server_url ~= "" and self.settings.server_url or "https://",
        buttons = {
            {
                {
                    text = _("Cancelar"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Guardar"),
                    is_enter_default = true,
                    callback = function()
                        local val = (dialog:getInputText() or ""):gsub("%s+", ""):gsub("/+$", "")
                        self.settings.server_url = val
                        self.settings.token = ""
                        self:saveSettings()
                        UIManager:close(dialog)
                        show_message(_("URL del servidor guardada."), 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function StoryKore:editUsername()
    if not InputDialog then return self:showSettingsDialog() end
    local dialog
    dialog = InputDialog:new{
        title = _("Usuario o Email"),
        description = _("Tu usuario o correo de StoryKore:"),
        input = self.settings.username or "",
        buttons = {
            {
                {
                    text = _("Cancelar"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Guardar"),
                    is_enter_default = true,
                    callback = function()
                        local val = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        self.settings.username = val
                        self.settings.token = ""
                        self:saveSettings()
                        UIManager:close(dialog)
                        show_message(_("Usuario guardado."), 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function StoryKore:editPassword()
    if not InputDialog then return self:showSettingsDialog() end
    local dialog
    dialog = InputDialog:new{
        title = _("Contraseña"),
        description = _("Tu contraseña de StoryKore:"),
        input = self.settings.password or "",
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Cancelar"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Guardar"),
                    is_enter_default = true,
                    callback = function()
                        local val = dialog:getInputText() or ""
                        self.settings.password = val
                        self.settings.token = ""
                        self:saveSettings()
                        UIManager:close(dialog)
                        show_message(_("Contraseña guardada."), 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function StoryKore:showSettingsDialog()
    if not MultiInputDialog then
        return self:editUsername()
    end
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Cuenta de StoryKore"),
        fields = {
            {
                description = _("Usuario o email:"),
                text = self.settings.username or "",
                hint = "usuario o email",
            },
            {
                description = _("Contraseña:"),
                text = self.settings.password or "",
                hint = "contraseña",
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancelar"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Guardar"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFieldsText()
                        local user = (fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        local pass = fields[2] or ""

                        self.settings.server_url = DEFAULT_SERVER_URL
                        self.settings.username = user
                        self.settings.password = pass
                        self.settings.token = ""
                        self:saveSettings()

                        UIManager:close(dialog)
                        show_message(_("Cuenta guardada correctamente."), 3)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShow then dialog:onShow() end
end

-- Network request with lazy loading of network modules
function StoryKore:httpRequest(req)
    local ok_http, http = pcall(require, "socket.http")
    if not ok_http then
        return nil, "Módulo socket.http no disponible en este dispositivo."
    end
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_ltn12 then
        return nil, "Módulo ltn12 no disponible."
    end
    local socketutil = safe_require("socketutil")

    local url = req.url
    local is_https = url:match("^https://") ~= nil
    local client = (is_https and ok_https and https) or http
    local response_body = {}

    local headers = req.headers or {}
    if req.body then
        headers["Content-Length"] = tostring(#req.body)
    end

    local request_param = {
        url = url,
        method = req.method or "GET",
        headers = headers,
        source = req.body and ltn12.source.string(req.body) or nil,
        sink = ltn12.sink.table(response_body),
    }

    if socketutil and socketutil.set_timeout then
        pcall(function() socketutil:set_timeout(120, 300) end)
    end
    local ok, res, code, resp_headers = pcall(client.request, request_param)
    if socketutil and socketutil.reset_timeout then
        pcall(function() socketutil:reset_timeout() end)
    end

    if not ok then
        return nil, "Fallo al conectar: " .. tostring(res)
    end

    -- En la interfaz de tabla de LuaSocket:
    -- Si la petición tiene éxito a nivel de red: res == 1 y code contiene el código HTTP (ej: 200, 401, 500)
    -- Si falla a nivel de socket/red: res es nil y code contiene el error (ej: "timeout", "closed", "wantread")
    if res ~= 1 then
        if code == "wantread" or code == "timeout" then
            return nil, "El servidor tardó en responder (tiempo de espera agotado). Vuelve a intentar la sincronización ahora que el servidor está activo."
        end
        return nil, "Fallo de conexión: " .. tostring(code or res or "desconocido")
    end

    local status_code = tonumber(code) or code
    local body_str = table.concat(response_body)
    return status_code, body_str, resp_headers
end

function StoryKore:authenticate()
    if not self.settings.username or self.settings.username == "" or
       not self.settings.password or self.settings.password == "" then
        return nil, _("Usuario o contraseña no configurados.")
    end

    local base_url = (self.settings.server_url or ""):gsub("/+$", "")
    local login_url = base_url .. "/api/auth/login"

    local req_body = json_encode({
        username_or_email = self.settings.username,
        password = self.settings.password,
    })

    local code, body = self:httpRequest({
        url = login_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        body = req_body,
    })

    if not code then
        return nil, body
    end

    if code == 200 then
        local data = json_decode(body)
        if data and data.access_token then
            self.settings.token = data.access_token
            self:saveSettings()
            return data.access_token
        end
        return nil, _("Respuesta inválida recibida del servidor.")
    else
        local data = json_decode(body)
        local detail = (data and data.detail) or (_("Error HTTP ") .. tostring(code))
        return nil, detail
    end
end

function StoryKore:runOnline(callback)
    if NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(callback)
    else
        callback()
    end
end

function StoryKore:testConnection()
    if not self.settings.username or self.settings.username == "" or
       not self.settings.password or self.settings.password == "" then
        if ConfirmBox then
            UIManager:show(ConfirmBox:new{
                text = _("Por favor, ingresa primero tu usuario y contraseña de StoryKore.\n\n¿Deseas configurarlos ahora?"),
                ok_text = _("Configurar"),
                cancel_text = _("Cancelar"),
                ok_callback = function()
                    self:showSettingsDialog()
                end,
            })
        else
            self:showSettingsDialog()
        end
        return
    end

    local auto_wifi = self.settings.auto_manage_wifi == true
    local connecting_info = nil
    if auto_wifi and not is_wifi_on() then
        connecting_info = InfoMessage and InfoMessage:new{
            text = _("StoryKore\n\n📶 Activando Wi-Fi...\nPor favor, espera."),
        }
        if connecting_info then UIManager:show(connecting_info) end
    end

    local function run_test()
        if connecting_info then
            UIManager:close(connecting_info)
            connecting_info = nil
        end

        local info = InfoMessage and InfoMessage:new{
            text = _("Conectando con StoryKore...\nComprobando autenticación..."),
        }
        if info then UIManager:show(info) end

        UIManager:nextTick(function()
            local token, err = self:authenticate()
            if info then UIManager:close(info) end

            local wifi_status_text = ""
            if auto_wifi then
                turn_off_wifi()
                wifi_status_text = _("\n\n📶 Wi-Fi desconectado automáticamente.")
            end

            if token then
                show_message(_("✓ ¡Conexión con StoryKore exitosa!\n\nUsuario autenticado correctamente.") .. wifi_status_text, 5)
            else
                if ConfirmBox then
                    UIManager:show(ConfirmBox:new{
                        text = _("No se pudo conectar con StoryKore:\n\n") .. (err or _("Error desconocido")) .. wifi_status_text .. _("\n\n¿Deseas revisar usuario y contraseña?"),
                        ok_text = _("Revisar"),
                        cancel_text = _("Cerrar"),
                        ok_callback = function()
                            self:showSettingsDialog()
                        end,
                    })
                else
                    show_message(_("Error de conexión:\n") .. (err or "") .. wifi_status_text, 6)
                end
            end
        end)
    end

    if auto_wifi then
        turn_on_wifi_and_run(run_test)
    else
        self:runOnline(run_test)
    end
end

function StoryKore:getDocumentsDir()
    if not lfs then return "/mnt/us/documents" end
    local custom = self.settings.custom_docs_dir
    if custom and custom ~= "" and lfs.attributes(custom, "mode") == "directory" then
        return custom
    end

    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home and lfs.attributes(home, "mode") == "directory" then
        return home
    end

    if Device and Device.home_dir and lfs.attributes(Device.home_dir, "mode") == "directory" then
        return Device.home_dir
    end

    local data_dir = DataStorage and DataStorage:getDataDir() or ""
    local candidates = {
        "/mnt/us/documents",
        "/mnt/onboard",
        "/sdcard/books",
        "/sdcard/koreader",
        data_dir .. "/../documents",
        data_dir,
    }
    for _, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") == "directory" then
            return path
        end
    end

    return data_dir
end

function StoryKore:getStatisticsDb()
    if not lfs then return nil, nil end
    local settings_dir = DataStorage and DataStorage:getSettingsDir() or ""
    local data_dir = DataStorage and DataStorage:getDataDir() or ""
    local candidates = {
        settings_dir .. "/statistics.sqlite3",
        data_dir .. "/settings/statistics.sqlite3",
        "/mnt/us/koreader/settings/statistics.sqlite3",
        "/mnt/us/extensions/koreader/settings/statistics.sqlite3",
        "/mnt/onboard/.koreader/settings/statistics.sqlite3",
    }

    for _, path in ipairs(candidates) do
        local mode = lfs.attributes(path, "mode")
        if mode == "file" then
            local data = read_binary_file(path)
            if data and #data > 0 then
                return to_base64(data), path
            end
        end
    end

    return nil, nil
end

function StoryKore:scanLuaFiles(base_dir)
    local lua_files = {}
    if not lfs then return lua_files end
    local seen = {}

    local function scan_folder(dir, depth)
        if depth > 8 then return end
        local mode = lfs.attributes(dir, "mode")
        if mode ~= "directory" then return end

        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." and not entry:match("^%..+") and
               entry ~= "System Volume Information" and entry ~= "$RECYCLE.BIN" then
                local full_path = dir .. "/" .. entry
                local attr = lfs.attributes(full_path)
                if attr and attr.mode == "directory" then
                    if entry:match("%.sdr$") then
                        for sdr_item in lfs.dir(full_path) do
                            if sdr_item:match("%.lua$") then
                                local lua_path = full_path .. "/" .. sdr_item
                                if not seen[lua_path] then
                                    seen[lua_path] = true
                                    local content = read_text_file(lua_path)
                                    if content and #content > 0 then
                                        local rel_path = lua_path
                                        if lua_path:sub(1, #base_dir) == base_dir then
                                            rel_path = lua_path:sub(#base_dir + 1):gsub("^/+", "")
                                        end
                                        table.insert(lua_files, {
                                            path = rel_path,
                                            content = content,
                                        })
                                    end
                                end
                            end
                        end
                    else
                        scan_folder(full_path, depth + 1)
                    end
                end
            end
        end
    end

    scan_folder(base_dir, 0)
    return lua_files
end

function StoryKore:doSync()
    local token = self.settings.token
    if not token or token == "" then
        local new_token, err = self:authenticate()
        if not new_token then
            return nil, _("Error de inicio de sesión: ") .. (err or _("Verifica usuario y contraseña."))
        end
        token = new_token
    end

    local stats_b64, stats_path = self:getStatisticsDb()
    local docs_dir = self:getDocumentsDir()
    local lua_files = self:scanLuaFiles(docs_dir)

    if not stats_b64 and #lua_files == 0 then
        return nil, _("No se encontraron datos de KOReader para sincronizar.\n\n" ..
                      "Ruta examinada: ") .. tostring(docs_dir) .. _("\nVerifica que tengas libros leídos o estadísticas.")
    end

    local payload = {
        statistics_db = stats_b64,
        lua_files = lua_files,
        auto_enrich = true,
    }
    local payload_json = json_encode(payload)

    local base_url = (self.settings.server_url or ""):gsub("/+$", "")
    local sync_url = base_url .. "/api/sync/koreader"

    local function send_request(auth_token)
        return self:httpRequest({
            url = sync_url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Accept"] = "application/json",
                ["Authorization"] = "Bearer " .. auth_token,
            },
            body = payload_json,
        })
    end

    local code, body = send_request(token)

    if code == 401 then
        local new_token, auth_err = self:authenticate()
        if new_token then
            token = new_token
            code, body = send_request(token)
        else
            return nil, _("Tu sesión en StoryKore ha expirado. ") .. (auth_err or "")
        end
    end

    if not code then
        return nil, _("Fallo de red al conectar con StoryKore:\n") .. tostring(body)
    end

    if code == 200 then
        local data = json_decode(body)
        if data and data.success then
            return data
        else
            return nil, _("El servidor respondió con éxito pero el formato de datos fue inesperado.")
        end
    else
        local data = json_decode(body)
        local err_detail = (data and data.detail) or (_("Error HTTP ") .. tostring(code))
        return nil, err_detail
    end
end

function StoryKore:onSyncTap()
    if not self.settings.username or self.settings.username == "" or
       not self.settings.password or self.settings.password == "" then
        if ConfirmBox then
            UIManager:show(ConfirmBox:new{
                text = _("Debes configurar primero tu cuenta de StoryKore (usuario y contraseña).\n\n¿Deseas configurarla ahora?"),
                ok_text = _("Configurar"),
                cancel_text = _("Cancelar"),
                ok_callback = function()
                    self:showSettingsDialog()
                end,
            })
        else
            self:showSettingsDialog()
        end
        return
    end

    local auto_wifi = self.settings.auto_manage_wifi == true
    local connecting_info = nil
    if auto_wifi and not is_wifi_on() then
        connecting_info = InfoMessage and InfoMessage:new{
            text = _("StoryKore Sync\n\n📶 Activando Wi-Fi automáticamente...\nConectando a la red, espera un momento."),
        }
        if connecting_info then UIManager:show(connecting_info) end
    end

    local function run_sync()
        if connecting_info then
            UIManager:close(connecting_info)
            connecting_info = nil
        end

        local info = InfoMessage and InfoMessage:new{
            text = _("StoryKore Sync\n\nRecopilando estadísticas y notas de lectura...\nSubiendo datos a StoryKore..."),
        }
        if info then UIManager:show(info) end

        UIManager:nextTick(function()
            local result, err_msg = self:doSync()
            if info then UIManager:close(info) end

            local wifi_status_text = ""
            if auto_wifi then
                turn_off_wifi()
                wifi_status_text = _("\n\n📶 Wi-Fi desconectado automáticamente para ahorrar batería.")
            end

            if result then
                local b_imp = result.books_imported or 0
                local b_upd = result.books_updated or 0
                local hl_imp = result.highlights_imported or 0
                local sess_imp = result.sessions_imported or 0

                local now_str = os.date("%Y-%m-%d %H:%M:%S")
                self.settings.last_sync = now_str
                self:saveSettings()

                local msg = string.format(
                    _("✓ Sincronización completada con éxito\n\n" ..
                      "• Libros nuevos importados: %d\n" ..
                      "• Libros actualizados: %d\n" ..
                      "• Notas y subrayados: %d\n" ..
                      "• Sesiones de lectura: %d\n\n" ..
                      "Fecha: %s%s"),
                    b_imp, b_upd, hl_imp, sess_imp, now_str, wifi_status_text
                )
                show_message(msg, 10)
            else
                if ConfirmBox then
                    UIManager:show(ConfirmBox:new{
                        text = _("Error en la sincronización con StoryKore:\n\n") .. (err_msg or _("Error desconocido")) .. wifi_status_text .. _("\n\n¿Deseas revisar tu usuario y contraseña?"),
                        ok_text = _("Revisar"),
                        cancel_text = _("Cerrar"),
                        ok_callback = function()
                            self:showSettingsDialog()
                        end,
                    })
                else
                    show_message(_("Error de sincronización:\n") .. (err_msg or "") .. wifi_status_text, 8)
                end
            end
        end)
    end

    if auto_wifi then
        turn_on_wifi_and_run(run_sync)
    else
        self:runOnline(run_sync)
    end
end

function StoryKore:showStatusDialog()
    local docs_dir = self:getDocumentsDir()
    local has_stats = self:getStatisticsDb() ~= nil
    local lua_count = #self:scanLuaFiles(docs_dir)

    local text = string.format(
        _("Estado de StoryKore Sync:\n\n" ..
          "• Servidor: StoryKore Cloud\n" ..
          "• Usuario: %s\n" ..
          "• Auto Wi-Fi: %s\n" ..
          "• Base de estadísticas: %s\n" ..
          "• Metadatos .lua encontrados: %d\n" ..
          "• Carpeta de biblioteca: %s\n" ..
          "• Última sincronización: %s"),
        self.settings.username ~= "" and self.settings.username or _("(No configurado)"),
        self.settings.auto_manage_wifi and _("Activado (Conectar -> Sincronizar -> Apagar)") or _("Desactivado (Manual)"),
        has_stats and _("Detectada (statistics.sqlite3)") or _("No encontrada"),
        lua_count,
        docs_dir,
        self.settings.last_sync ~= "" and self.settings.last_sync or _("Nunca")
    )
    show_message(text, 10)
end

return StoryKore
