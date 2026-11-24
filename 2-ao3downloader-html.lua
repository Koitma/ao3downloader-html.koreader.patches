--[[
    AO3 Downloader: HTML downloads as a user patch (survives plugin updates)
    Version 0.1.0

    Install: copy this file to  koreader/patches/2-ao3downloader-html.lua  and restart KOReader.
    Remove:  delete the file. Nothing in the plugin folder is modified.

    What it adds to the AO3 downloader plugin:
      * "Download format" HTML/EPUB (default HTML) and "HTML folder" in a new "HTML configuration" menu entry
      * "View HTML downloads": its own list, backed by its own history file
        (<koreader>/fanfic/fanfic_history_html.json). The EPUB history is never written by HTML downloads.
      * HTML mode: Download / Update / browse / "Download work by ID" use HTML.
        "Update" on an EPUB work never touches the EPUB: if the work has no HTML copy it offers to
        download one, if it has one it offers to update that copy.
      * HTML menu has "Download as EPUB" (works again once AO3 serves EPUB; goes to the EPUB history)
      * No chapter tracking / "Open at chapter" for HTML works; manual "Mark as read/unread" instead.

    Hooks used: PluginLoader:loadPlugins (to run after the plugin is loaded), FanficMenu:show,
    the plugin class methods DownloadFanfic / UpdateFanfic, downloaded_fanfics.update/checkIfStored,
    fanfic_reader:onPageUpdate and AO3_downloader_client (adds downloadHtml).
    If the plugin renames those modules/methods in a future version, the patch does nothing and logs a warning.
]]

local PluginLoader = require("pluginloader")
local DataStorage = require("datastorage")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local util = require("util")

local LOGTAG = "AO3Downloader HTML patch: "
local KEY_FORMAT = "ao3html_download_format" -- "html" | "epub"
local KEY_FOLDER = "ao3html_folder"

------------------------------------------------------------------------------------------------
-- Separate history for HTML works
------------------------------------------------------------------------------------------------
local HtmlHistory = {}
do
    local json = require("dkjson")
    local history_file = DataStorage:getDataDir() .. "/fanfic/fanfic_history_html.json"
    local fanfics = {}

    local function deepcopy(orig, copies)
        copies = copies or {}
        if type(orig) ~= "table" then return orig end
        if copies[orig] then return copies[orig] end
        local copy = {}
        copies[orig] = copy
        for k, v in next, orig, nil do
            copy[deepcopy(k, copies)] = deepcopy(v, copies)
        end
        return copy
    end

    local function asTable(field)
        if type(field) == "string" then return { field } end
        if type(field) == "table" then return field end
        return {}
    end

    local function normalize(f)
        f.id = tostring(f.id)
        f.format = "html"
        f.fandoms = asTable(f.fandoms)
        f.relationships = asTable(f.relationships)
        f.characters = asTable(f.characters)
        f.tags = asTable(f.tags)
        f.warnings = asTable(f.warnings)
    end

    function HtmlHistory.save()
        util.makePath(DataStorage:getDataDir() .. "/fanfic")
        local file, err = io.open(history_file, "w")
        if not file then
            logger.err(LOGTAG .. "cannot save history:", err)
            return
        end
        file:write(json.encode(fanfics, { indent = true }))
        file:close()
    end

    function HtmlHistory.load()
        local file = io.open(history_file, "r")
        if not file then return end
        local content = file:read("*a")
        file:close()
        local history, __, err = json.decode(content)
        if type(history) ~= "table" then
            logger.err(LOGTAG .. "cannot load history:", err)
            return
        end
        for __, f in pairs(history) do normalize(f) end
        fanfics = history
    end

    function HtmlHistory.getAll() return deepcopy(fanfics) end
    function HtmlHistory.checkIfStored(id) return fanfics[tostring(id)] end

    function HtmlHistory.update(fanfic, not_save)
        normalize(fanfic)
        fanfics[fanfic.id] = fanfic
        if not not_save then HtmlHistory.save() end
    end

    function HtmlHistory.delete(id)
        if not fanfics[tostring(id)] then return false end
        fanfics[tostring(id)] = nil
        HtmlHistory.save()
        return true
    end

    function HtmlHistory.setWorkRead(id, is_read)
        local f = fanfics[tostring(id)]
        if not f then return end
        f.read = is_read and true or false
        HtmlHistory.save()
    end
end

------------------------------------------------------------------------------------------------
-- Everything that needs the plugin's modules runs once, after the plugin has been loaded
------------------------------------------------------------------------------------------------
local applied = false

local function apply()
    if applied then return end
    local FanficMenu = package.loaded["fanfic_menu"]
    local EpubHistory = package.loaded["downloaded_fanfics"]
    local Client = package.loaded["AO3_downloader_client"]
    local Config = package.loaded["fanfic_config"]
    if not (FanficMenu and EpubHistory and Client and Config) then return end
    applied = true

    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local ButtonDialog = require("ui/widget/buttondialog")
    local TextViewer = require("ui/widget/textviewer")
    local BD = require("ui/bidi")
    local socketutil = require("socketutil")
    local https = require("ssl.https")

    HtmlHistory.load()

    -- cached: the plugin's Config rewrites its settings file on every read
    local format_cache = Config:readSetting(KEY_FORMAT) or "html"
    local function getFormat() return format_cache end
    local function setFormat(value)
        format_cache = value
        Config:saveSetting(KEY_FORMAT, value)
    end
    local function htmlFolder()
        local f = Config:readSetting(KEY_FOLDER)
        if f and f ~= "" then return f end
        return (Config:readSetting("fanfic_folder_path") or "") .. "/HTML"
    end

    --------------------------------------------------------------------------------------------
    -- Client: HTML download (temp file, status + content check, atomic replace)
    --------------------------------------------------------------------------------------------
    function Client:downloadHtml(url, filepath)
        local function fail(msg) return { success = false, error = msg, error_message = msg } end
        if not url or not url:match("^https?://") then
            return fail(T("Invalid or missing URL for HTML download: %1", tostring(url)))
        end

        -- same cookies the plugin uses (needed for restricted works)
        local cookie_header = ""
        local cookies = Config:readSetting("cookies")
        local domain = url:match("^(https?://[^/]+)")
        if type(cookies) == "table" and cookies[domain] then
            local parts = {}
            for __, c in pairs(cookies[domain]) do
                table.insert(parts, c.name .. "=" .. c.value)
            end
            cookie_header = table.concat(parts, "; ")
        end

        local tmp = filepath .. ".part"
        local status
        for attempt = 1, 3 do
            local file, err = io.open(tmp, "wb")
            if not file then
                return fail(T("Failed to open file for writing. Error: %1", tostring(err)))
            end
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local ok, response, st = pcall(https.request, {
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "Mozilla/5.0 (platform; rv:gecko-version) Gecko/gecko-trail Firefox/firefox-version",
                    ["Accept"] = "text/html,application/xhtml+xml",
                    ["Accept-Language"] = "en-US,en;q=0.5",
                    ["Cookie"] = cookie_header,
                },
                sink = socketutil.file_sink(file),
                protocol = "tlsv1_3",
                options = "all",
            })
            socketutil:reset_timeout()
            pcall(file.close, file)
            status = ok and st or nil
            if ok and response == 1 and status == 200 then break end
            if status == 429 or status == 404 or status == 403 then break end -- retrying will not help
        end

        if status ~= 200 then
            os.remove(tmp)
            if status == 429 then
                return fail(_("AO3 is rate limiting requests (429), try again in a few minutes"))
            end
            return fail(T("AO3 answered with status %1", tostring(status or "no response")))
        end

        local check = io.open(tmp, "rb")
        local head = check and check:read(2048) or ""
        if check then check:close() end
        head = head:lower()
        if not (head:find("<html", 1, true) or head:find("<!doctype", 1, true)) then
            os.remove(tmp)
            return fail("Downloaded file is not HTML")
        end

        os.remove(filepath)
        local renamed, rename_err = os.rename(tmp, filepath)
        if not renamed then
            os.remove(tmp)
            return fail(T("Failed to save file: %1", tostring(rename_err)))
        end
        return { success = true, filepath = filepath }
    end

    --------------------------------------------------------------------------------------------
    -- Class methods (installed once, from the plugin instance's class)
    --------------------------------------------------------------------------------------------
    local COPY_FIELDS = {
        "title", "author", "chapters", "summary", "fandoms", "tags", "relationships", "characters",
        "warnings", "hits", "kudos", "bookmarks", "comments", "rating", "category", "iswip",
        "updated", "published", "wordcount",
    }
    local LIVE_FIELDS = { "markedForLater", "subscriptionID", "bookmarkID", "bookmarkContent" }

    local function errText(r) return r.error_message or r.error or "Unknown error" end

    local function htmlLink(id)
        local domain = Config:readSetting("AO3_domain") or "https://archiveofourown.org"
        return domain .. "/downloads/" .. tostring(id) .. "/" .. tostring(id) .. ".html"
    end

    local function mergeMetadata(fanfic, meta)
        for __, key in ipairs(COPY_FIELDS) do
            if meta[key] ~= nil then fanfic[key] = meta[key] end
        end
        for __, key in ipairs(LIVE_FIELDS) do fanfic[key] = meta[key] end
        local old = fanfic.chapter_data or {}
        if type(meta.chapterData) == "table" then
            for idx, chapter in pairs(meta.chapterData) do
                chapter.read = old[idx] and old[idx].read or false
            end
            fanfic.chapter_data = meta.chapterData
        end
        fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S")
    end

    local class_patched = false
    local function patchClass(instance)
        if class_patched then return end
        local mt = getmetatable(instance)
        local cls = mt and mt.__index
        if type(cls) ~= "table" or type(cls.DownloadFanfic) ~= "function" or type(cls.UpdateFanfic) ~= "function" then
            logger.warn(LOGTAG .. "plugin class not recognised, HTML support not installed")
            return
        end
        class_patched = true

        local orig_download, orig_update = cls.DownloadFanfic, cls.UpdateFanfic
        local forced_epub = false

        -- opts.read: carry the work-level "read" flag over (used when the source is an EPUB record)
        function cls:DownloadFanficHTML(id, opts)
            opts = opts or {}
            local function fail(msg)
                UIManager:show(InfoMessage:new({ text = msg }))
            end
            local NetworkMgr = require("ui/network/manager")
            if not NetworkMgr:isConnected() then
                NetworkMgr:runWhenConnected(function() self:DownloadFanficHTML(id, opts) end)
                return
            end
            local r = Client:getWorkMetadata(id)
            if not r.success then
                return fail(_("Error: failed to fetch work metadata: ") .. errText(r))
            end
            local meta = r.work_metadata
            os.execute("sleep " .. math.random(1, 3))

            local folder = htmlFolder()
            util.makePath(folder)
            local path = folder .. "/" .. cls.GenerateFileName(meta) .. ".html"
            local d = Client:downloadHtml(htmlLink(id), path)
            if not d.success then
                return fail(_("Error: failed to download HTML, ") .. errText(d))
            end

            local fanfic = { id = tostring(id), path = d.filepath }
            mergeMetadata(fanfic, meta)
            if fanfic.chapter_data then
                for __, chapter in pairs(fanfic.chapter_data) do chapter.read = false end
            end
            if opts.read then fanfic.read = true end
            HtmlHistory.update(fanfic)

            UIManager:show(ConfirmBox:new({
                text = T(_("File saved to:\n%1\nWould you like to read the downloaded work now?"), BD.filepath(fanfic.path)),
                ok_text = _("Read now"),
                ok_callback = function() self:onOpenFanficReader(fanfic.path, fanfic) end,
            }))
        end

        function cls:UpdateFanficHTML(fanfic)
            local NetworkMgr = require("ui/network/manager")
            if not NetworkMgr:isConnected() then
                NetworkMgr:runWhenConnected(function() self:UpdateFanficHTML(fanfic) end)
                return
            end
            local r = Client:getWorkMetadata(fanfic.id)
            if not r.success then
                UIManager:show(InfoMessage:new({ text = _("Error: failed to fetch updated metadata: ") .. errText(r) }))
                return
            end
            os.execute("sleep " .. math.random(2, 5))

            -- old file is replaced only after a verified successful download
            local d = Client:downloadHtml(htmlLink(fanfic.id), fanfic.path)
            if not d.success then
                UIManager:show(InfoMessage:new({ text = _("Error: failed to download updated HTML, ") .. errText(d) }))
                return
            end
            mergeMetadata(fanfic, r.work_metadata)
            HtmlHistory.update(fanfic)
            UIManager:show(InfoMessage:new({ text = T(_("Fanfic '%1' has been updated successfully."), fanfic.title) }))
        end

        -- the original EPUB download, reachable while in HTML mode (HTML menu button)
        function cls:DownloadFanficEpub(id)
            local NetworkMgr = require("ui/network/manager")
            if not NetworkMgr:isConnected() then
                NetworkMgr:runWhenConnected(function() self:DownloadFanficEpub(id) end)
                return
            end
            forced_epub = true
            local ok, err = pcall(orig_download, self, id)
            forced_epub = false
            if not ok then logger.err(LOGTAG .. tostring(err)) end
        end

        cls.DownloadFanfic = function(self, id, ...)
            if forced_epub or getFormat() ~= "html" then
                return orig_download(self, id, ...)
            end
            return self:DownloadFanficHTML(id)
        end

        cls.UpdateFanfic = function(self, fanfic, ...)
            if fanfic and fanfic.format == "html" then
                return self:UpdateFanficHTML(fanfic)
            end
            if getFormat() == "html" then
                -- EPUB works are never updated while in HTML mode. Offer the HTML copy instead.
                local title = fanfic.title or fanfic.id
                local html_record = HtmlHistory.checkIfStored(fanfic.id)
                local dialog
                local function ask(text, action)
                    dialog = ButtonDialog:new({
                        title = text,
                        buttons = { {
                            { text = _("No"), callback = function() UIManager:close(dialog) end },
                            {
                                text = _("Yes"),
                                callback = function()
                                    UIManager:close(dialog)
                                    UIManager:show(InfoMessage:new({ text = _("Downloading work may take some time…"), timeout = 1 }))
                                    UIManager:scheduleIn(1, action)
                                end,
                            },
                        } },
                    })
                    UIManager:show(dialog)
                end
                if html_record then
                    ask(T(_("An HTML copy of '%1' already exists. Update it?"), title),
                        function() self:UpdateFanficHTML(html_record) end)
                else
                    ask(T(_("'%1' has no HTML copy yet. Download it?"), title),
                        function() self:DownloadFanficHTML(fanfic.id, { read = fanfic.read }) end)
                end
                return
            end
            return orig_update(self, fanfic, ...)
        end
    end

    --------------------------------------------------------------------------------------------
    -- HTML works list (no chapter tracking, no "Open at chapter")
    --------------------------------------------------------------------------------------------
    local function fandomsOf(f)
        if type(f.fandoms) == "table" and #f.fandoms > 0 then return f.fandoms end
        return { _("Unknown Fandom") }
    end

    local function statusPrefix(f)
        if not f.read then return "  " end
        local count, total = tostring(f.chapters or ""):match("([^/]+)/([^/]+)")
        local complete = count ~= nil and tonumber(count) ~= nil and tonumber(count) == tonumber(total)
        return complete and "✓" or "="
    end

    local function joinOr(list, fallback)
        if type(list) == "table" and #list > 0 then return table.concat(list, ", ") end
        return fallback
    end

    local function groupByFandom()
        local groups, last = {}, {}
        for __, f in pairs(HtmlHistory.getAll()) do
            for ___, fandom in ipairs(fandomsOf(f)) do
                groups[fandom] = groups[fandom] or {}
                table.insert(groups[fandom], f)
                local accessed = f.last_accessed or "0000-00-00 00:00:00"
                if not last[fandom] or accessed > last[fandom] then last[fandom] = accessed end
            end
        end
        return groups, last
    end

    local function showHtmlWorks(fanfic_obj, menu)
        local showWorkDialog

        local function workItems(fandom)
            local works = (groupByFandom())[fandom] or {}
            table.sort(works, function(a, b) return (a.last_accessed or "") > (b.last_accessed or "") end)
            local items = {}
            for __, f in ipairs(works) do
                table.insert(items, {
                    text = T("%1 (%2) %3 by %4", statusPrefix(f), f.chapters or "?", f.title or "Untitled",
                        (f.author and f.author ~= "") and f.author or "anonymous"),
                    id = f.id,
                    callback = function() showWorkDialog(f, fandom) end,
                })
            end
            return items
        end

        local function fandomItems()
            local groups, last = groupByFandom()
            local names = {}
            for fandom in pairs(groups) do table.insert(names, fandom) end
            if #names == 0 then return nil end
            table.sort(names, function(a, b) return last[a] > last[b] end)
            local items = {}
            for __, fandom in ipairs(names) do
                table.insert(items, {
                    text = T("(%1) %2", #groups[fandom], fandom),
                    callback = function()
                        menu:GoDownInMenu(T(_("HTML works in '%1'"), fandom), workItems(fandom))
                    end,
                    hold_callback = function() UIManager:show(InfoMessage:new({ text = fandom })) end,
                })
            end
            return items
        end

        local function afterDelete()
            menu:onReturn()
            local items = fandomItems()
            if items then
                menu:switchItemTable(nil, items)
                menu:updateItems()
            else
                menu:onReturn()
                UIManager:show(InfoMessage:new({ text = _("No HTML works left.") }))
            end
        end

        showWorkDialog = function(fanfic, fandom)
            local dialog
            dialog = ButtonDialog:new({
                title = T(_("Options for '%1'"), fanfic.title or "?"),
                buttons = {
                    {
                        {
                            text = _("Open"),
                            callback = function()
                                fanfic.last_accessed = os.date("%Y-%m-%d %H:%M:%S")
                                HtmlHistory.update(fanfic)
                                UIManager:close(dialog)
                                fanfic_obj:onOpenFanficReader(fanfic.path, fanfic)
                            end,
                        },
                        {
                            text = _("Update"),
                            callback = function()
                                UIManager:close(dialog)
                                UIManager:show(InfoMessage:new({ text = _("Downloading work may take some time…"), timeout = 1 }))
                                UIManager:scheduleIn(1, function() fanfic_obj:UpdateFanficHTML(fanfic) end)
                            end,
                        },
                    },
                    {
                        {
                            text = fanfic.read and _("Mark as unread") or _("Mark as read"),
                            callback = function()
                                HtmlHistory.setWorkRead(fanfic.id, not fanfic.read)
                                UIManager:close(dialog)
                                menu:switchItemTable(nil, workItems(fandom))
                                menu:updateItems()
                            end,
                        },
                        {
                            -- AO3 is HTML-only right now; this works again once EPUB downloads return
                            text = _("Download as EPUB"),
                            callback = function()
                                UIManager:close(dialog)
                                UIManager:show(InfoMessage:new({ text = _("Downloading work may take some time…"), timeout = 1 }))
                                UIManager:scheduleIn(1, function() fanfic_obj:DownloadFanficEpub(fanfic.id) end)
                            end,
                        },
                    },
                    {
                        {
                            text = _("View Details"),
                            callback = function()
                                local details = string.format(
                                    "Fandoms: %s\n\nStatus: %s\nChapters: %s\nPublished: %s\nUpdated: %s\nAuthor: %s\n\nSummary:\n%s\n\nRating: %s\nCategory: %s\n\nWarnings:\n%s\n\nRelationships:\n%s\n\nCharacters:\n%s\n\nOther Tags:\n%s\n\nBookmarked: %s\nMarked for Later: %s\nSubscribed: %s\n\nWords: %s\nHits: %s\nKudos: %s\nBookmarks: %s\nComments: %s\n\nFile:\n%s",
                                    joinOr(fanfic.fandoms, "No fandoms available"),
                                    fanfic.iswip or "Unknown", fanfic.chapters or "Unknown",
                                    fanfic.published or "Unknown", fanfic.updated or "Unknown",
                                    fanfic.author or "Unknown", fanfic.summary or "No summary available",
                                    fanfic.rating or "Unknown", fanfic.category or "Unknown",
                                    joinOr(fanfic.warnings, "No warnings available"),
                                    joinOr(fanfic.relationships, "No relationships available"),
                                    joinOr(fanfic.characters, "No characters available"),
                                    joinOr(fanfic.tags, "No tags available"),
                                    fanfic.bookmarkID and ("Yes (" .. tostring(fanfic.bookmarkID) .. ")") or "No",
                                    fanfic.markedForLater and "Yes" or "No",
                                    fanfic.subscriptionID and ("Yes (" .. tostring(fanfic.subscriptionID) .. ")") or "No",
                                    fanfic.wordcount or "Unknown", fanfic.hits or "0", fanfic.kudos or "0",
                                    fanfic.bookmarks or "0", fanfic.comments or "0", fanfic.path or "?")
                                UIManager:show(TextViewer:new({ title = fanfic.title, text = details }))
                                UIManager:close(dialog)
                            end,
                        },
                        {
                            text = _("Delete"),
                            callback = function()
                                UIManager:close(dialog)
                                local confirm
                                confirm = ButtonDialog:new({
                                    title = T(_("Are you sure you want to delete '%1'?"), fanfic.title or "?"),
                                    buttons = { {
                                        { text = _("Cancel"), callback = function() UIManager:close(confirm) end },
                                        {
                                            text = _("Delete"),
                                            callback = function()
                                                UIManager:close(confirm)
                                                local file_path = fanfic.path
                                                HtmlHistory.delete(fanfic.id)
                                                local ok, err = util.removeFile(file_path)
                                                if not ok then
                                                    UIManager:show(InfoMessage:new({
                                                        text = T(_("Failed to delete file for '%1': %2, record has still been removed"),
                                                            fanfic.title or "?", tostring(err)),
                                                    }))
                                                end
                                                afterDelete()
                                            end,
                                        },
                                    } },
                                })
                                UIManager:show(confirm)
                            end,
                        },
                    },
                    { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
                },
            })
            UIManager:show(dialog)
        end

        local items = fandomItems()
        if not items then
            UIManager:show(InfoMessage:new({ text = _("No HTML works downloaded yet.") }))
            return
        end
        menu:GoDownInMenu(_("Downloaded Works (HTML) by Fandom"), items)
    end

    --------------------------------------------------------------------------------------------
    -- HTML configuration submenu
    --------------------------------------------------------------------------------------------
    local function showHtmlSettings(menu)
        local function settingItems()
            return {
                {
                    text = T(_("Download format: %1"), getFormat() == "html" and "HTML" or "EPUB"),
                    callback = function()
                        local dialog
                        local function choose(value)
                            return function()
                                setFormat(value)
                                UIManager:close(dialog)
                                menu:switchItemTable(nil, settingItems())
                                menu:updateItems()
                            end
                        end
                        dialog = ButtonDialog:new({
                            title = _("Download format"),
                            buttons = {
                                { { text = "HTML", callback = choose("html") } },
                                { { text = "EPUB", callback = choose("epub") } },
                            },
                        })
                        UIManager:show(dialog)
                    end,
                },
                {
                    text = T(_("HTML folder: %1"), htmlFolder()),
                    callback = function()
                        local filemanagerutil = require("apps/filemanager/filemanagerutil")
                        pcall(util.makePath, htmlFolder())
                        filemanagerutil.showChooseDialog(_("Current HTML folder:"), function(path)
                            Config:saveSetting(KEY_FOLDER, path)
                            menu:switchItemTable(nil, settingItems())
                            menu:updateItems()
                        end, htmlFolder(), filemanagerutil.getDefaultDir())
                    end,
                },
            }
        end
        menu:GoDownInMenu(_("HTML configuration"), settingItems())
    end

    --------------------------------------------------------------------------------------------
    -- Hook: main menu entries + class patching
    --------------------------------------------------------------------------------------------
    local orig_show = FanficMenu.show
    FanficMenu.show = function(self, fanfic, ...)
        patchClass(fanfic)
        local widget = orig_show(self, fanfic, ...)
        local ok, err = pcall(function()
            local items = widget.item_table
            local pos = #items
            for i, item in ipairs(items) do
                if type(item.text) == "string" and item.text:find("View downloaded fanfics", 1, true) then
                    pos = i
                    break
                end
            end
            table.insert(items, pos + 1, {
                text = "\u{f1c9} View HTML downloads",
                callback = function() showHtmlWorks(fanfic, widget) end,
            })
            table.insert(items, pos + 2, {
                text = "HTML configuration",
                callback = function() showHtmlSettings(widget) end,
            })
            widget:switchItemTable(nil, items)
        end)
        if not ok then logger.err(LOGTAG .. "could not add menu entries: " .. tostring(err)) end
        return widget
    end

    --------------------------------------------------------------------------------------------
    -- Hook: keep HTML records out of the EPUB history; browser sees the right history
    --------------------------------------------------------------------------------------------
    local orig_update = EpubHistory.update
    EpubHistory.update = function(fanfic, not_save)
        if type(fanfic) == "table" and fanfic.format == "html" then
            return HtmlHistory.update(fanfic, not_save)
        end
        return orig_update(fanfic, not_save)
    end

    local orig_check = EpubHistory.checkIfStored
    EpubHistory.checkIfStored = function(id, ...)
        if getFormat() == "html" then
            local info = debug.getinfo(2, "S")
            if info and info.source and info.source:find("fanficbrowser", 1, true) then
                return HtmlHistory.checkIfStored(id)
            end
        end
        return orig_check(id, ...)
    end

    --------------------------------------------------------------------------------------------
    -- Hook: reader - no chapter tracking for HTML works
    --------------------------------------------------------------------------------------------
    local FanficReader = package.loaded["fanfic_reader"]
    if FanficReader and type(FanficReader.onPageUpdate) == "function" then
        local orig_page_update = FanficReader.onPageUpdate
        FanficReader.onPageUpdate = function(self, pageno, ...)
            if self.current_fanfic and self.current_fanfic.format == "html" then return end
            return orig_page_update(self, pageno, ...)
        end
    else
        logger.warn(LOGTAG .. "fanfic_reader not recognised; chapter tracking not disabled for HTML works")
    end

    logger.info(LOGTAG .. "installed")
end

-- run right after the plugin has been loaded
if not pcall(apply) then logger.warn(LOGTAG .. "early apply failed") end
if not applied then
    local orig_load = PluginLoader.loadPlugins
    PluginLoader.loadPlugins = function(self, ...)
        local a, b, c = orig_load(self, ...)
        local ok, err = pcall(apply)
        if not ok then logger.err(LOGTAG .. tostring(err)) end
        return a, b, c
    end
end
