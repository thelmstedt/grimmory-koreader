local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local JSON = require("json")
local _ = require("gettext")
local T = ffiutil.template

local ok_https, https = pcall(require, "ssl.https")
local data_dir = DataStorage:getFullDataDir()
local state_dir = data_dir .. "/settings/grimmory"
local state_path = state_dir .. "/state.json"

local Grimmory = WidgetContainer:extend{
    name = "Grimmory",
    is_doc_only = false,
}

local function trim_slash(value)
    if not value then return "" end
    return value:gsub("/+$", "")
end

local function safe_path(value)
    value = tostring(value or ""):gsub("\\", "/")
    local parts = {}
    for part in value:gmatch("[^/]+") do
        if part ~= "." and part ~= ".." and part ~= "" then
            table.insert(parts, (part:gsub("%c", "_")))
        end
    end
    return table.concat(parts, "/")
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

local function file_size(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

function Grimmory:init()
    self.server_url = G_reader_settings:readSetting("grimmory_server_url") or ""
    self.username = G_reader_settings:readSetting("grimmory_username") or ""
    self.auth_key = G_reader_settings:readSetting("grimmory_auth_key") or ""
    self.sync_dir = G_reader_settings:readSetting("grimmory_sync_dir")
        or (G_reader_settings:readSetting("home_dir") or data_dir) .. "/Grimmory"
    self.autostart = G_reader_settings:isTrue("grimmory_autostart")
    self.state = self:readState()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    if self.autostart then
        self:runSync()
    end
end

function Grimmory:isConfigured()
    return self.server_url ~= "" and self.username ~= "" and self.auth_key ~= ""
end

function Grimmory:request(url, sink, headers)
    local transport = http
    if url:match("^https://") then
        if not ok_https then
            return nil, "HTTPS is not available in this KOReader build"
        end
        transport = https
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, response_headers, status = socket.skip(1, transport.request({
        url = url,
        method = "GET",
        sink = sink,
        headers = headers or {},
    }))
    socketutil:reset_timeout()

    if code ~= 200 then
        return nil, status or code
    end
    return response_headers or {}, nil
end

function Grimmory:syncUrl()
    return trim_slash(self.server_url) .. "/api/koreader/v1/library/sync"
end

function Grimmory:getHeader(headers, name)
    if not headers then return nil end
    local wanted = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == wanted then
            return value
        end
    end
    return nil
end

function Grimmory:getSyncPage(sync_token)
    local chunks = {}
    local headers = {
        ["x-auth-user"] = self.username,
        ["x-auth-key"] = self.auth_key,
    }
    if sync_token and sync_token ~= "" then
        headers["x-booklore-synctoken"] = sync_token
    end

    local _, err = self:request(self:syncUrl(), ltn12.sink.table(chunks), headers)
    if err then return nil, err end

    local ok, result = pcall(JSON.decode, table.concat(chunks))
    if not ok then
        return nil, _("Invalid Grimmory response")
    end

    return {
        added = result.added or result.Added or {},
        changed = result.changed or result.Changed or {},
        removed = result.removed or result.Removed or {},
        syncToken = result.syncToken or result.SyncToken,
        continueSync = result.continueSync or result.ContinueSync or false,
    }, nil
end

function Grimmory:readState()
    local file = io.open(state_path, "r")
    if not file then
        return { files = {} }
    end

    local raw = file:read("a")
    file:close()

    local ok, state = pcall(JSON.decode, raw)
    if not ok or type(state) ~= "table" then
        return { files = {} }
    end
    state.files = state.files or {}
    return state
end

function Grimmory:writeState()
    util.makePath(state_dir)
    local tmp = state_path .. ".tmp"
    local file = io.open(tmp, "w")
    if not file then return end

    file:write(JSON.encode(self.state or { files = {} }))
    file:close()
    os.remove(state_path)
    os.rename(tmp, state_path)
end

function Grimmory:fileStateKey(book)
    return tostring(book.id or book.url or book.title)
end

function Grimmory:extensionForFormat(format)
    format = tostring(format or ""):lower()
    if format == "pdf" then return ".pdf" end
    if format == "cbx" then return ".cbz" end
    if format == "fb2" then return ".fb2" end
    if format == "mobi" then return ".mobi" end
    if format == "azw3" then return ".azw3" end
    return ".epub"
end

function Grimmory:safeFileName(book)
    local title = tostring(book.title or book.id or "book")
    title = title:gsub("[/\\:*?\"<>|%c]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then title = "book" end
    return title .. " [" .. tostring(book.id or "unknown") .. "]" .. self:extensionForFormat(book.format)
end

function Grimmory:targetPath(book)
    if book.relativePath and book.relativePath ~= "" then
        return self.sync_dir .. "/" .. safe_path(book.relativePath)
    end
    return self.sync_dir .. "/" .. safe_path(self:safeFileName(book))
end

-- A book is current only when we have previously recorded it with the same
-- server-side content hash and the on-disk file is intact (matches the size we
-- recorded at download time). Size is never compared against the server value,
-- which is KB-rounded; the hash is the source of truth for content identity.
function Grimmory:isBookCurrent(book, target)
    local previous = self.state.files[self:fileStateKey(book)]
    if not previous or not previous.hash or not book.hash then
        return false
    end
    if previous.hash ~= book.hash then
        return false
    end

    local function intact(path)
        local size = file_size(path)
        return size ~= nil and (not previous.size or size == previous.size)
    end

    if intact(target) then
        return true
    end

    -- Same content, but the server path changed (e.g. renamed/moved library):
    -- relocate the existing file instead of re-downloading identical bytes.
    if previous.path and previous.path ~= target and intact(previous.path) then
        util.makePath(dirname(target))
        os.remove(target)
        os.rename(previous.path, target)
        return file_size(target) ~= nil
    end

    return false
end

function Grimmory:rememberBook(book, target)
    self.state.files[self:fileStateKey(book)] = {
        path = target,
        size = file_size(target) or book.size,
        hash = book.hash,
        title = book.title,
        syncedAt = os.time(),
    }
end

function Grimmory:downloadBook(book)
    local target = self:targetPath(book)
    if not book.url then return false, _("Missing download URL") end
    if self:isBookCurrent(book, target) then
        self:rememberBook(book, target)
        return false
    end

    util.makePath(dirname(target))

    local tmp = target .. ".grimmory-download"
    local file = io.open(tmp, "wb")
    if not file then
        return false, T(_("Cannot write %1"), target)
    end

    local _, err = self:request(book.url, ltn12.sink.file(file), {
        ["x-auth-user"] = self.username,
        ["x-auth-key"] = self.auth_key,
    })
    if err then
        os.remove(tmp)
        return false, err
    end

    local previous = self.state.files[self:fileStateKey(book)]
    if previous and previous.path and previous.path ~= target then
        os.remove(previous.path)
    end
    os.remove(target)
    os.rename(tmp, target)
    self:rememberBook(book, target)
    return true
end

function Grimmory:normalizeBook(item, removed)
    local id = item.fileId or item.FileId or item.bookId or item.BookId
    local path = item.downloadUrl or item.DownloadUrl
    local url = nil
    if path and path:match("^https?://") then
        url = path
    elseif path then
        url = trim_slash(self.server_url) .. path
    end
    return {
        id = id,
        title = item.title or item.Title or item.fileName or item.FileName or id,
        url = url,
        size = item.fileSizeBytes or item.FileSizeBytes,
        format = item.bookType or item.BookType,
        relativePath = item.relativePath or item.RelativePath,
        hash = item.hash or item.Hash,
        removed = removed,
    }
end

function Grimmory:removeBook(book)
    local previous = self.state.files[self:fileStateKey(book)]
    if previous and previous.path then
        os.remove(previous.path)
    end
    self.state.files[self:fileStateKey(book)] = nil
end

-- Run a sync once the network is connected, inside a Trapper coroutine so
-- progress can be shown and the user can cancel between books. We use
-- runWhenConnected (not runWhenOnline): a Grimmory server is typically
-- self-hosted on the LAN, so requiring internet hostname resolution would
-- needlessly drop the sync on offline/captive networks.
function Grimmory:runSync()
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            self:syncLibrary()
        end)
    end)
end

function Grimmory:syncLibrary()
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Configure Grimmory server, user, and auth key first."),
        })
        return
    end

    local downloaded = 0
    local skipped = 0
    local failed = 0
    local removed = 0

    -- The sync token is only advanced once the whole run completes, so it always
    -- records a finished state (never a half-served snapshot). An interruption
    -- therefore restarts against the last completed point; the server rebuilds a
    -- fresh delta and already-present files are skipped by hash, so nothing is
    -- re-downloaded and nothing is lost. File records are persisted after every
    -- page so completed downloads survive an interruption.
    local sync_token = self.state.syncToken
    local cancelled = false

    local function processDownload(item)
        local book = self:normalizeBook(item, false)
        if not book or not book.id then return true end
        if not Trapper:info(T(_("Grimmory sync…\nDownloaded: %1  Up to date: %2  Removed: %3\n\n%4"),
                downloaded, skipped, removed, book.title or "")) then
            cancelled = true
            return false
        end
        local ok, download_err = self:downloadBook(book)
        if ok then
            downloaded = downloaded + 1
        elseif download_err then
            failed = failed + 1
            logger.warn("[Grimmory] Download failed:", book.title, download_err)
        else
            skipped = skipped + 1
        end
        return true
    end

    while true do
        local page, err = self:getSyncPage(sync_token)
        if err then
            self:writeState()
            Trapper:clear()
            logger.warn("[Grimmory] sync failed:", err)
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Grimmory sync failed: %1"), err),
            })
            return
        end

        for _, item in ipairs(page.removed) do
            local book = self:normalizeBook(item, true)
            if book and book.id then
                self:removeBook(book)
                removed = removed + 1
            end
        end

        for _, item in ipairs(page.added) do
            if not processDownload(item) then break end
        end
        if not cancelled then
            for _, item in ipairs(page.changed) do
                if not processDownload(item) then break end
            end
        end

        -- Persist downloaded file records for this page; keep the token unchanged.
        self:writeState()

        if cancelled then
            Trapper:clear()
            UIManager:show(InfoMessage:new{
                text = T(_("Grimmory sync cancelled.\nDownloaded: %1  Up to date: %2  Removed: %3"),
                    downloaded, skipped, removed),
            })
            return
        end

        if failed > 0 then
            Trapper:clear()
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Grimmory sync stopped after %1 failed downloads."), failed),
            })
            return
        end

        if not page.continueSync then
            self.state.syncToken = page.syncToken
            break
        end
        sync_token = page.syncToken
    end

    self:writeState()
    Trapper:clear()

    UIManager:show(InfoMessage:new{
        timeout = 8,
        text = T(_("Grimmory sync complete.\nDownloaded: %1\nUp to date: %2\nRemoved: %3"),
            downloaded, skipped, removed),
    })
end

function Grimmory:showSettingDialog(title, setting_key, current_value, on_save, password)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = current_value or "",
        input_type = "string",
        text_type = password and "password" or nil,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText() or ""
                        G_reader_settings:saveSetting(setting_key, value)
                        on_save(value)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Grimmory:addToMainMenu(menu_items)
    menu_items.grimmory = {
        text = _("Grimmory"),
        sub_item_table = {
            {
                text = _("Sync library now"),
                keep_menu_open = true,
                enabled_func = function() return self:isConfigured() end,
                callback = function()
                    self:runSync()
                end,
            },
            {
                text_func = function()
                    return T(_("Server: %1"), self.server_url ~= "" and self.server_url or _("Not set"))
                end,
                keep_menu_open = true,
                callback = function()
                    self:showSettingDialog(_("Grimmory server URL"), "grimmory_server_url", self.server_url, function(value)
                        self.server_url = trim_slash(value)
                        G_reader_settings:saveSetting("grimmory_server_url", self.server_url)
                    end)
                end,
            },
            {
                text_func = function()
                    return T(_("User: %1"), self.username ~= "" and self.username or _("Not set"))
                end,
                keep_menu_open = true,
                callback = function()
                    self:showSettingDialog(_("Grimmory KoReader user"), "grimmory_username", self.username, function(value)
                        self.username = value
                        self.state.syncToken = nil
                        self:writeState()
                    end)
                end,
            },
            {
                text = _("Auth key"),
                keep_menu_open = true,
                callback = function()
                    self:showSettingDialog(_("Grimmory KoReader auth key"), "grimmory_auth_key", self.auth_key, function(value)
                        self.auth_key = value
                        self.state.syncToken = nil
                        self:writeState()
                    end, true)
                end,
            },
            {
                text_func = function()
                    return T(_("Sync folder: %1"), self.sync_dir)
                end,
                keep_menu_open = true,
                callback = function()
                    self:showSettingDialog(_("Grimmory sync folder"), "grimmory_sync_dir", self.sync_dir, function(value)
                        self.sync_dir = value
                    end)
                end,
            },
            {
                text = _("Sync with KOReader start"),
                checked_func = function() return self.autostart end,
                callback = function()
                    self.autostart = not self.autostart
                    G_reader_settings:flipNilOrFalse("grimmory_autostart")
                end,
            },
        },
    }
end

function Grimmory:onDispatcherRegisterActions()
    Dispatcher:registerAction("sync_grimmory_library", {
        category = "none",
        event = "SyncGrimmoryLibrary",
        title = _("Sync Grimmory library"),
        general = true,
    })
end

function Grimmory:onSyncGrimmoryLibrary()
    self:runSync()
end

require("insert_menu")

return Grimmory
