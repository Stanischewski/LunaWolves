-- Core.lua
-- LunaWolves Gilden-Addon -- Kern-Framework
-- Modul-System, Event-Bus, Addon-Kommunikation, Berechtigungen

-- ============================================================
-- Globaler Namespace
-- ============================================================

LunaWolves = {}
LunaWolves.modules = {}
LunaWolves.callbacks = {}
LunaWolves.guildRanks = {}      -- ["Spielername"] = rankIndex
LunaWolves.playerName = nil
LunaWolves.playerRealm = nil

local ADDON_PREFIX = "LunaWolves"
local SEND_QUEUE = {}
local SEND_TIMER = nil
local CHUNK_SIZE = 230           -- Platz für Header lassen
local CHUNK_BUFFERS = {}         -- Empfangspuffer für Chunked-Nachrichten

-- ============================================================
-- Hilfsfunktionen
-- ============================================================

-- Chat-Ausgabe mit Addon-Prefix
function LunaWolves:Print(...)
    local msg = table.concat({...}, " ")
    DEFAULT_CHAT_FRAME:AddMessage("|cff8888ff[LunaWolves]|r " .. msg)
end

-- Kurze Spielernamen ohne Realm (für lokalen Server)
local function StripRealm(name)
    if not name then return nil end
    local short = strsplit("-", name)
    return short
end

-- ============================================================
-- 1. Modul-Registrierung
-- ============================================================

function LunaWolves:RegisterModule(name, module)
    module._name = name
    self.modules[name] = module
    if module.OnInitialize then
        module:OnInitialize()
    end
end

function LunaWolves:GetModule(name)
    return self.modules[name]
end

-- ============================================================
-- 2. Interner Event-Bus
-- ============================================================

function LunaWolves:RegisterCallback(event, module, func)
    if not self.callbacks[event] then
        self.callbacks[event] = {}
    end
    table.insert(self.callbacks[event], { module = module, func = func })
end

function LunaWolves:FireCallback(event, ...)
    if not self.callbacks[event] then return end
    for _, entry in ipairs(self.callbacks[event]) do
        entry.func(entry.module, ...)
    end
end

-- ============================================================
-- 3. Addon-Kommunikation
-- ============================================================

-- Nachricht senden (mit automatischem Chunking und Queue)
function LunaWolves:SendMessage(channel, moduleName, command, payload, target)
    local msg = moduleName .. ":" .. command .. ":" .. (payload or "")

    if #msg <= 240 then
        self:QueueSend(msg, channel, target)
    else
        -- Chunking: Nachrichten in Teile aufteilen
        local msgId = tostring(GetTime()) .. math.random(1000, 9999)
        local data = moduleName .. ":" .. command .. ":" .. (payload or "")
        local parts = {}
        for i = 1, #data, CHUNK_SIZE do
            table.insert(parts, data:sub(i, i + CHUNK_SIZE - 1))
        end
        for i, part in ipairs(parts) do
            local chunked = "CHUNK:" .. msgId .. ":" .. i .. "/" .. #parts .. ":" .. part
            self:QueueSend(chunked, channel, target)
        end
    end
end

-- Send-Queue: Rate-Limiting (max 10 Nachrichten/Sek pro Prefix)
function LunaWolves:QueueSend(msg, channel, target)
    table.insert(SEND_QUEUE, { msg = msg, channel = channel, target = target })
    if not SEND_TIMER then
        self:ProcessSendQueue()
    end
end

function LunaWolves:ProcessSendQueue()
    if #SEND_QUEUE == 0 then
        SEND_TIMER = nil
        return
    end
    local item = table.remove(SEND_QUEUE, 1)
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, item.msg, item.channel, item.target)
    SEND_TIMER = C_Timer.After(0.1, function()
        LunaWolves:ProcessSendQueue()
    end)
end

-- Eingehende Nachrichten verarbeiten
local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end

    -- Eigene Nachrichten ignorieren
    local senderShort = StripRealm(sender)
    if senderShort == LunaWolves.playerName then return end

    -- Chunked-Nachricht?
    if message:sub(1, 6) == "CHUNK:" then
        LunaWolves:HandleChunk(message, sender, channel)
        return
    end

    -- Normales Routing: MODULE:COMMAND:payload
    local moduleName, command, payload = strsplit(":", message, 3)

    -- Core-Nachrichten direkt verarbeiten
    if moduleName == "CORE" then
        LunaWolves:OnCoreMessage(command, payload or "", senderShort, channel)
        return
    end

    local mod = LunaWolves.modules[moduleName]
    if mod and mod.OnMessage then
        mod:OnMessage(command, payload or "", senderShort, channel)
    end
end

-- Core-Nachrichten verarbeiten
function LunaWolves:OnCoreMessage(command, payload, sender, channel)
    if command == "THRESHOLD" then
        -- Nur von Officers akzeptieren
        if not self:IsOfficer(sender) then return end
        local threshold = tonumber(payload)
        if threshold then
            LunaWolvesDB.officerRankThreshold = threshold
            self:Print("Officer-Schwelle von " .. sender .. " aktualisiert: Rang <= " .. threshold)
        end
    end
end

-- Chunked-Nachrichten zusammensetzen
function LunaWolves:HandleChunk(message, sender, channel)
    -- Format: CHUNK:msgId:seqNum/total:data
    local _, msgId, seqInfo, data = strsplit(":", message, 4)
    local seqNum, total = strsplit("/", seqInfo)
    seqNum = tonumber(seqNum)
    total = tonumber(total)

    local bufKey = sender .. "-" .. msgId
    if not CHUNK_BUFFERS[bufKey] then
        CHUNK_BUFFERS[bufKey] = { parts = {}, total = total, time = GetTime() }
    end

    local buf = CHUNK_BUFFERS[bufKey]
    buf.parts[seqNum] = data

    -- Alle Teile empfangen?
    local count = 0
    for _ in pairs(buf.parts) do count = count + 1 end
    if count == total then
        -- Zusammensetzen und als normale Nachricht verarbeiten
        local full = ""
        for i = 1, total do
            full = full .. (buf.parts[i] or "")
        end
        CHUNK_BUFFERS[bufKey] = nil

        local senderShort = StripRealm(sender)
        local moduleName, command, payload = strsplit(":", full, 3)
        local mod = self.modules[moduleName]
        if mod and mod.OnMessage then
            mod:OnMessage(command, payload or "", senderShort, channel)
        end
    end
end

-- Alte Chunk-Buffer aufräumen (alle 30 Sekunden)
local function CleanupChunkBuffers()
    local now = GetTime()
    for key, buf in pairs(CHUNK_BUFFERS) do
        if now - buf.time > 10 then
            CHUNK_BUFFERS[key] = nil
        end
    end
    C_Timer.After(30, CleanupChunkBuffers)
end

-- ============================================================
-- 4. Berechtigungssystem
-- ============================================================

function LunaWolves:IsOfficer(playerName)
    if not playerName then playerName = self.playerName end
    local rank = self.guildRanks[playerName]
    local threshold = LunaWolvesDB.officerRankThreshold or 1
    return rank ~= nil and rank <= threshold
end

-- Gildenränge cachen
function LunaWolves:ScanGuildRoster()
    if not IsInGuild() then return end
    local numMembers = GetNumGuildMembers()
    wipe(self.guildRanks)
    for i = 1, numMembers do
        local name, _, rankIndex = GetGuildRosterInfo(i)
        if name then
            local short = StripRealm(name)
            self.guildRanks[short] = rankIndex
        end
    end
end

-- ============================================================
-- 5. Slash-Kommando
-- ============================================================

SLASH_LUNAWOLVES1 = "/lw"
SLASH_LUNAWOLVES2 = "/lunawolves"
SlashCmdList["LUNAWOLVES"] = function(input)
    local cmd, rest = strsplit(" ", input or "", 2)
    cmd = (cmd or ""):lower()

    if cmd == "dkp" then
        local mod = LunaWolves:GetModule("DKP")
        if mod and mod.HandleSlash then
            mod:HandleSlash(rest)
        end
    elseif cmd == "raid" then
        local mod = LunaWolves:GetModule("RAID")
        if mod and mod.HandleSlash then
            mod:HandleSlash(rest)
        end
    elseif cmd == "officer" then
        -- Officer-Rang-Schwelle setzen (nur Officers!)
        local threshold = tonumber(rest)
        if threshold then
            if not LunaWolves:IsOfficer() then
                LunaWolves:Print("Nur Officers können die Schwelle ändern.")
                return
            end
            LunaWolvesDB.officerRankThreshold = threshold
            LunaWolves:Print("Officer-Rang-Schwelle auf " .. threshold .. " gesetzt.")
            LunaWolves:Print("Ränge 0 bis " .. threshold .. " gelten jetzt als Officer.")
            -- An andere Officers broadcasten
            LunaWolves:SendMessage("GUILD", "CORE", "THRESHOLD", tostring(threshold))
        else
            LunaWolves:Print("Aktuell: Rang <= " .. (LunaWolvesDB.officerRankThreshold or 1) .. " = Officer")
            LunaWolves:Print("Ändern: /lw officer <rang>")
            LunaWolves:Print("Nutze /lw ranks um alle Gildenränge zu sehen.")
        end
    elseif cmd == "ranks" then
        -- Alle Gildenränge mit Namen auflisten
        if not IsInGuild() then
            LunaWolves:Print("Du bist in keiner Gilde.")
            return
        end
        local threshold = LunaWolvesDB.officerRankThreshold or 1
        LunaWolves:Print("--- Gildenränge ---")
        for i = 0, GuildControlGetNumRanks() - 1 do
            local rankName = GuildControlGetRankName(i)
            local marker = ""
            if i <= threshold then
                marker = " |cff00ff00<< Officer|r"
            end
            LunaWolves:Print("  " .. i .. " = " .. rankName .. marker)
        end
        LunaWolves:Print("Schwelle ändern: /lw officer <rang>")
    else
        LunaWolves:Print("--- LunaWolves Hilfe ---")
        LunaWolves:Print("/lw dkp -- DKP-Verwaltung öffnen")
        LunaWolves:Print("/lw dkp show [Name] -- DKP anzeigen")
        LunaWolves:Print("/lw dkp add Name Anzahl Grund -- Punkte vergeben")
        LunaWolves:Print("/lw dkp sub Name Anzahl Grund -- Punkte abziehen")
        LunaWolves:Print("/lw dkp history [Name] -- History-Fenster öffnen")
        LunaWolves:Print("/lw dkp delete Name -- Spieler aus DKP löschen")
        LunaWolves:Print("/lw dkp on -- DKP-Session starten (nur im Schlachtzug)")
        LunaWolves:Print("/lw dkp off -- DKP-Session beenden")
        LunaWolves:Print("/lw dkp status -- Session-Status anzeigen")
        LunaWolves:Print("/lw dkp sync -- Sync erzwingen")
        LunaWolves:Print("/lw raid -- Gruppen-Suche öffnen")
        LunaWolves:Print("/lw raid create [Titel] -- Gruppe erstellen (Dialog oder direkt)")
        LunaWolves:Print("/lw raid close -- Eigene Gruppe schließen")
        LunaWolves:Print("/lw raid refresh -- Liste aktualisieren")
        LunaWolves:Print("/lw ranks -- Gildenränge anzeigen")
        LunaWolves:Print("/lw officer <rang> -- Officer-Rang-Schwelle setzen")
    end
end

-- ============================================================
-- 6. Minimap-Button
-- ============================================================

local ICON_TEXTURE = "Interface\\AddOns\\LunaWolves\\icon"

local function CreateMinimapButton()
    local btn = CreateFrame("Button", "LunaWolves_MinimapBtn", Minimap)
    btn:SetSize(33, 33)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetClampedToScreen(true)
    btn:SetMovable(true)
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Icon-Textur (Gilden-Logo)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON_TEXTURE)
    icon:SetSize(25, 25)
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)

    -- Runder Rand (Minimap-Stil)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(56, 56)
    border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    -- Highlight beim Hover
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture(ICON_TEXTURE)
    highlight:SetSize(25, 25)
    highlight:SetPoint("CENTER", btn, "CENTER", 0, 0)
    highlight:SetAlpha(0.3)

    -- Position auf dem Minimap-Rand berechnen
    local function UpdatePosition(angle)
        local rad = math.rad(angle)
        local radius = LunaWolvesDB.minimapRadius or 100
        local x = math.cos(rad) * radius
        local y = math.sin(rad) * radius
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    -- Dragging um die Minimap
    local isDragging = false
    btn:SetScript("OnDragStart", function(self)
        isDragging = true
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            local angle = math.deg(math.atan2(cy - my, cx - mx))
            LunaWolvesDB.minimapAngle = angle
            UpdatePosition(angle)
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        isDragging = false
        self:SetScript("OnUpdate", nil)
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff8888ffLunaWolves|r", 1, 1, 1)
        GameTooltip:AddLine("Linksklick: DKP öffnen", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Rechtsklick: Gruppen-Suche", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Klick-Aktionen
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            local dkp = LunaWolves:GetModule("DKP")
            if dkp and dkp.ToggleUI then
                dkp:ToggleUI()
            end
        elseif button == "RightButton" then
            local raid = LunaWolves:GetModule("RAID")
            if raid and raid.ShowGroupList then
                raid:ShowGroupList()
            end
        end
    end)

    -- Gespeicherte Position laden
    local angle = LunaWolvesDB.minimapAngle or 225
    UpdatePosition(angle)

    return btn
end

-- ============================================================
-- 7. Options-Panel (ESC > Optionen > Addons)
-- ============================================================

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame", "LunaWolvesOptionsPanel")
    panel.name = "LunaWolves"

    -- Titel
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cff8888ffLunaWolves|r")

    -- Beschreibung
    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetWidth(550)
    desc:SetJustifyH("LEFT")
    desc:SetText(
        "Gilden-Addon für 'The Last Luna Wolves'.\n\n" ..
        "Features:\n" ..
        "  - DKP-Punkteverwaltung mit automatischer Vergabe bei Bosskills\n" ..
        "  - Multi-Officer-Synchronisation\n" ..
        "  - Raid-Einladungssystem mit Benachrichtigungen\n\n" ..
        "Befehle: /lw für eine Liste aller Kommandos."
    )

    -- Trennlinie
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    divider:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    divider:SetColorTexture(0.5, 0.5, 0.5, 0.3)

    -- Checkbox: Minimap-Icon anzeigen
    local yOffset = -16
    local minimapCheck = CreateFrame("CheckButton", "LunaWolves_Opt_Minimap", panel, "InterfaceOptionsCheckButtonTemplate")
    minimapCheck:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, yOffset)
    minimapCheck.Text:SetText("Minimap-Icon anzeigen")
    minimapCheck:SetChecked(not LunaWolvesDB.hideMinimapIcon)
    minimapCheck:SetScript("OnClick", function(self)
        LunaWolvesDB.hideMinimapIcon = not self:GetChecked()
        if LunaWolves.minimapBtn then
            if LunaWolvesDB.hideMinimapIcon then
                LunaWolves.minimapBtn:Hide()
            else
                LunaWolves.minimapBtn:Show()
            end
        end
    end)

    -- Checkbox-Beschreibung
    local minimapDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    minimapDesc:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 26, -2)
    minimapDesc:SetText("|cff999999Das LunaWolves-Icon am Minimap-Rand ein-/ausblenden.|r")

    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
end

-- ============================================================
-- 8. Event-Handler (Kern)
-- ============================================================

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("PLAYER_LOGIN")
coreFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
coreFrame:RegisterEvent("CHAT_MSG_ADDON")

coreFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- SavedVariables initialisieren
        LunaWolvesDB = LunaWolvesDB or {}
        LunaWolvesDB.officerRankThreshold = LunaWolvesDB.officerRankThreshold or 1

        -- Spielernamen cachen
        LunaWolves.playerName = UnitName("player")
        LunaWolves.playerRealm = GetRealmName()

        -- Addon-Prefix registrieren
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

        -- Gildenränge scannen
        if IsInGuild() then
            C_GuildInfo.GuildRoster()  -- Fordert GUILD_ROSTER_UPDATE an
        end

        -- Chunk-Buffer-Cleanup starten
        C_Timer.After(30, CleanupChunkBuffers)

        -- Minimap-Button erstellen
        LunaWolves.minimapBtn = CreateMinimapButton()
        if LunaWolvesDB.hideMinimapIcon then
            LunaWolves.minimapBtn:Hide()
        end

        -- Options-Panel registrieren
        CreateOptionsPanel()

        -- Alle Module aktivieren
        for name, mod in pairs(LunaWolves.modules) do
            if mod.OnEnable then
                mod:OnEnable()
            end
        end

        LunaWolves:Print("v1.0.7 geladen. /lw für Hilfe.")

    elseif event == "GUILD_ROSTER_UPDATE" then
        LunaWolves:ScanGuildRoster()

    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    end
end)
