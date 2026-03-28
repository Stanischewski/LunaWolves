-- Modules/DKP.lua
-- LunaWolves DKP-Modul: Punkteverwaltung, Sync, Auto-Award, UI

local DKP = {}

-- Klassenfarben (WoW-Standard)
local CLASS_COLORS = {
    WARRIOR     = { r = 0.78, g = 0.61, b = 0.43 },
    PALADIN     = { r = 0.96, g = 0.55, b = 0.73 },
    HUNTER      = { r = 0.67, g = 0.83, b = 0.45 },
    ROGUE       = { r = 1.00, g = 0.96, b = 0.41 },
    PRIEST      = { r = 1.00, g = 1.00, b = 1.00 },
    DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 },
    SHAMAN      = { r = 0.00, g = 0.44, b = 0.87 },
    MAGE        = { r = 0.25, g = 0.78, b = 0.92 },
    WARLOCK     = { r = 0.53, g = 0.53, b = 0.93 },
    MONK        = { r = 0.00, g = 1.00, b = 0.60 },
    DRUID       = { r = 1.00, g = 0.49, b = 0.04 },
    DEMONHUNTER = { r = 0.64, g = 0.19, b = 0.79 },
    EVOKER      = { r = 0.20, g = 0.58, b = 0.50 },
}

local SOLID = "Interface\\Buttons\\WHITE8X8"
local ROW_HEIGHT = 20
local VISIBLE_ROWS = 15
local LIST_WIDTH = 450

-- ============================================================
-- Initialisierung
-- ============================================================

function DKP:OnInitialize()
    -- Wird beim RegisterModule aufgerufen (vor PLAYER_LOGIN)
end

function DKP:OnEnable()
    -- SavedVariables-Struktur sicherstellen
    LunaWolvesDB.DKP = LunaWolvesDB.DKP or {}
    LunaWolvesDB.DKP.points = LunaWolvesDB.DKP.points or {}
    LunaWolvesDB.DKP.history = LunaWolvesDB.DKP.history or {}
    LunaWolvesDB.DKP.pointsPerKill = LunaWolvesDB.DKP.pointsPerKill or 10
    LunaWolvesDB.DKP.lastSyncTimestamp = LunaWolvesDB.DKP.lastSyncTimestamp or 0

    -- WoW-Events registrieren
    self.eventFrame = CreateFrame("Frame")
    self.eventFrame:RegisterEvent("ENCOUNTER_END")
    self.eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "ENCOUNTER_END" then
            DKP:OnEncounterEnd(...)
        end
    end)

    -- UI vorbereiten (versteckt)
    self:CreateUI()

    -- Login-Sync anfordern
    C_Timer.After(5, function()
        if IsInGuild() then
            DKP:RequestSync()
        end
    end)
end

-- ============================================================
-- Kern-Operationen
-- ============================================================

-- Eindeutige ID fuer History-Eintraege
local function GenerateEntryId(officer)
    return officer .. "-" .. time() .. "-" .. math.random(1000, 9999)
end

-- Punkte vergeben
function DKP:Award(player, amount, reason, entryType, officer, entryId, timestamp)
    if not LunaWolves:IsOfficer() and not entryId then
        LunaWolves:Print("Nur Officers koennen DKP vergeben.")
        return false
    end

    amount = tonumber(amount) or 0
    if amount == 0 then return false end

    officer = officer or LunaWolves.playerName
    entryId = entryId or GenerateEntryId(officer)
    timestamp = timestamp or time()
    entryType = entryType or "MANUAL"

    -- Duplikat pruefen
    for _, entry in ipairs(LunaWolvesDB.DKP.history) do
        if entry.id == entryId then
            return false  -- Bereits vorhanden
        end
    end

    -- History-Eintrag erstellen
    local entry = {
        id = entryId,
        player = player,
        delta = amount,
        reason = reason or "",
        type = entryType,
        officer = officer,
        timestamp = timestamp,
    }
    table.insert(LunaWolvesDB.DKP.history, entry)

    -- Punkte-Tabelle aktualisieren
    if not LunaWolvesDB.DKP.points[player] then
        LunaWolvesDB.DKP.points[player] = { current = 0, lifetime = 0 }
    end
    local pts = LunaWolvesDB.DKP.points[player]
    pts.current = pts.current + amount
    if amount > 0 then
        pts.lifetime = pts.lifetime + amount
    end

    -- Event feuern
    LunaWolves:FireCallback("DKP_UPDATED", player, pts.current)

    -- UI aktualisieren
    if self.mainFrame and self.mainFrame:IsShown() then
        self:RefreshList()
    end

    return true, entryId, timestamp
end

-- Punkte abziehen (Ausgabe/Korrektur)
function DKP:Spend(player, amount, reason)
    return self:Award(player, -math.abs(amount), reason, "SPEND")
end

-- Punkte abfragen
function DKP:GetPoints(player)
    local pts = LunaWolvesDB.DKP.points[player]
    if pts then
        return pts.current, pts.lifetime
    end
    return 0, 0
end

-- History abfragen
function DKP:GetHistory(player, limit)
    limit = limit or 20
    local result = {}
    -- Rueckwaerts durch die History (neueste zuerst)
    for i = #LunaWolvesDB.DKP.history, 1, -1 do
        local entry = LunaWolvesDB.DKP.history[i]
        if not player or entry.player == player then
            table.insert(result, entry)
            if #result >= limit then break end
        end
    end
    return result
end

-- ============================================================
-- Auto-Award bei Bosskill
-- ============================================================

function DKP:OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
    if success ~= 1 then return end
    if not IsInRaid() then return end
    if not LunaWolves:IsOfficer() then return end
    if not self:ShouldAutoAward() then return end

    local pointsPerKill = LunaWolvesDB.DKP.pointsPerKill or 10
    local awarded = 0

    for i = 1, GetNumGroupMembers() do
        local name = select(1, GetRaidRosterInfo(i))
        if name then
            local shortName = strsplit("-", name)
            -- Nur Gildenmitglieder erhalten Auto-DKP
            if LunaWolves.guildRanks[shortName] ~= nil then
                local ok, entryId, ts = self:Award(shortName, pointsPerKill,
                    "Bosskill: " .. (encounterName or "Unbekannt"), "BOSS")
                if ok then
                    -- Broadcast an Gilde
                    self:BroadcastUpdate(entryId, shortName, pointsPerKill,
                        "Bosskill: " .. (encounterName or "Unbekannt"), "BOSS", ts)
                    awarded = awarded + 1
                end
            end
        end
    end

    if awarded > 0 then
        LunaWolves:Print(awarded .. " Spieler haben " .. pointsPerKill ..
            " DKP fuer " .. (encounterName or "Bosskill") .. " erhalten.")
    end
end

-- Deterministische Officer-Election: alphabetisch erster Officer im Raid
function DKP:ShouldAutoAward()
    local myName = LunaWolves.playerName
    if not LunaWolves:IsOfficer(myName) then return false end

    local electedOfficer = nil
    for i = 1, GetNumGroupMembers() do
        local name = select(1, GetRaidRosterInfo(i))
        if name then
            local shortName = strsplit("-", name)
            if LunaWolves:IsOfficer(shortName) then
                if not electedOfficer or shortName < electedOfficer then
                    electedOfficer = shortName
                end
            end
        end
    end
    return myName == electedOfficer
end

-- ============================================================
-- Sync-Protokoll
-- ============================================================

-- Einzelnen DKP-Update broadcasten
function DKP:BroadcastUpdate(entryId, player, delta, reason, entryType, timestamp)
    -- Format: id;player;delta;reason;type;officer;timestamp
    local payload = table.concat({
        entryId, player, tostring(delta), reason, entryType,
        LunaWolves.playerName, tostring(timestamp)
    }, ";")
    LunaWolves:SendMessage("GUILD", "DKP", "UPDATE", payload)
end

-- Sync anfordern (beim Login)
function DKP:RequestSync()
    local lastTs = LunaWolvesDB.DKP.lastSyncTimestamp or 0
    LunaWolves:SendMessage("GUILD", "DKP", "SYNCREQ", tostring(lastTs))
end

-- Eingehende Nachrichten verarbeiten
function DKP:OnMessage(command, payload, sender, channel)
    if command == "UPDATE" then
        self:HandleUpdate(payload, sender)
    elseif command == "SYNCREQ" then
        self:HandleSyncRequest(payload, sender)
    elseif command == "SYNCRESP" then
        self:HandleSyncResponse(payload, sender)
    elseif command == "DELETE" then
        self:HandleDelete(payload, sender)
    end
end

function DKP:HandleUpdate(payload, sender)
    -- Sender muss Officer sein
    if not LunaWolves:IsOfficer(sender) then return end

    local id, player, delta, reason, entryType, officer, ts = strsplit(";", payload)
    delta = tonumber(delta) or 0
    ts = tonumber(ts) or time()

    -- In lokale DB einfuegen (Award prueft Duplikate)
    local ok = self:Award(player, delta, reason, entryType, officer, id, ts)
    if ok and ts > (LunaWolvesDB.DKP.lastSyncTimestamp or 0) then
        LunaWolvesDB.DKP.lastSyncTimestamp = ts
    end
end

function DKP:HandleSyncRequest(payload, sender)
    -- Nur Officers antworten
    if not LunaWolves:IsOfficer() then return end

    -- Nur der alphabetisch erste online Officer antwortet (vermeidet Mehrfach-Antworten)
    -- Vereinfacht: Wir antworten immer, der Empfaenger dedupliziert
    local sinceTs = tonumber(payload) or 0
    local entries = {}

    for _, entry in ipairs(LunaWolvesDB.DKP.history) do
        if entry.timestamp > sinceTs then
            table.insert(entries, table.concat({
                entry.id, entry.player, tostring(entry.delta),
                entry.reason, entry.type, entry.officer,
                tostring(entry.timestamp)
            }, ";"))
        end
    end

    if #entries > 0 then
        local payload = table.concat(entries, "|")
        LunaWolves:SendMessage("WHISPER", "DKP", "SYNCRESP", payload, sender)
    end
end

function DKP:HandleSyncResponse(payload, sender)
    if not LunaWolves:IsOfficer(sender) then return end

    local entries = { strsplit("|", payload) }
    local added = 0

    for _, entryStr in ipairs(entries) do
        local id, player, delta, reason, entryType, officer, ts = strsplit(";", entryStr)
        delta = tonumber(delta) or 0
        ts = tonumber(ts) or time()

        local ok = self:Award(player, delta, reason, entryType, officer, id, ts)
        if ok then
            added = added + 1
            if ts > (LunaWolvesDB.DKP.lastSyncTimestamp or 0) then
                LunaWolvesDB.DKP.lastSyncTimestamp = ts
            end
        end
    end

    if added > 0 then
        LunaWolves:Print(added .. " DKP-Eintraege synchronisiert.")
    end
end

-- ============================================================
-- Slash-Kommandos
-- ============================================================

function DKP:HandleSlash(input)
    local cmd, rest = strsplit(" ", input or "", 2)
    cmd = (cmd or ""):lower()

    if cmd == "show" then
        local name = rest or LunaWolves.playerName
        local cur, life = self:GetPoints(name)
        LunaWolves:Print(name .. ": " .. cur .. " DKP (Lifetime: " .. life .. ")")

    elseif cmd == "add" then
        if not LunaWolves:IsOfficer() then
            LunaWolves:Print("Nur Officers koennen DKP vergeben.")
            return
        end
        local name, amount, reason = strmatch(rest or "", "^(%S+)%s+(%d+)%s*(.*)")
        if not name or not amount then
            LunaWolves:Print("Syntax: /lw dkp add Name Anzahl [Grund]")
            return
        end
        amount = tonumber(amount)
        reason = (reason and reason ~= "") and reason or "Manuell"
        local ok, entryId, ts = self:Award(name, amount, reason, "MANUAL")
        if ok then
            self:BroadcastUpdate(entryId, name, amount, reason, "MANUAL", ts)
            LunaWolves:Print(name .. " hat " .. amount .. " DKP erhalten. (" .. reason .. ")")
        end

    elseif cmd == "sub" then
        if not LunaWolves:IsOfficer() then
            LunaWolves:Print("Nur Officers koennen DKP abziehen.")
            return
        end
        local name, amount, reason = strmatch(rest or "", "^(%S+)%s+(%d+)%s*(.*)")
        if not name or not amount then
            LunaWolves:Print("Syntax: /lw dkp sub Name Anzahl [Grund]")
            return
        end
        amount = tonumber(amount)
        reason = (reason and reason ~= "") and reason or "Abzug"
        local ok, entryId, ts = self:Award(name, -amount, reason, "SPEND")
        if ok then
            self:BroadcastUpdate(entryId, name, -amount, reason, "SPEND", ts)
            LunaWolves:Print(name .. ": " .. amount .. " DKP abgezogen. (" .. reason .. ")")
        end

    elseif cmd == "sync" then
        self:RequestSync()
        LunaWolves:Print("Sync angefordert...")

    elseif cmd == "history" then
        local name = rest
        if name and name ~= "" then
            self:ShowHistoryUI(name)
        else
            self:ShowHistoryUI(nil)
        end

    elseif cmd == "delete" then
        if not LunaWolves:IsOfficer() then
            LunaWolves:Print("Nur Officers koennen Spieler loeschen.")
            return
        end
        local name = rest
        if not name or name == "" then
            LunaWolves:Print("Syntax: /lw dkp delete Name")
            return
        end
        if not LunaWolvesDB.DKP.points[name] then
            LunaWolves:Print("Spieler '" .. name .. "' nicht in der DKP-Liste.")
            return
        end
        local cur, life = self:GetPoints(name)
        LunaWolves:Print("|cffff4444Wirklich " .. name .. " loeschen?|r (" .. cur .. " DKP, " .. life .. " Lifetime)")
        LunaWolves:Print("Bestaetigen mit: /lw dkp confirmdelete " .. name)
        self._pendingDelete = name
        -- Timeout: 30 Sekunden
        C_Timer.After(30, function()
            if self._pendingDelete == name then
                self._pendingDelete = nil
            end
        end)

    elseif cmd == "confirmdelete" then
        if not LunaWolves:IsOfficer() then
            LunaWolves:Print("Nur Officers koennen Spieler loeschen.")
            return
        end
        local name = rest
        if not name or name == "" or self._pendingDelete ~= name then
            LunaWolves:Print("Kein ausstehender Loeschvorgang fuer diesen Spieler.")
            LunaWolves:Print("Zuerst: /lw dkp delete Name")
            return
        end
        self._pendingDelete = nil
        -- Spieler aus points entfernen
        LunaWolvesDB.DKP.points[name] = nil
        -- History-Eintraege entfernen
        local removed = 0
        for i = #LunaWolvesDB.DKP.history, 1, -1 do
            if LunaWolvesDB.DKP.history[i].player == name then
                table.remove(LunaWolvesDB.DKP.history, i)
                removed = removed + 1
            end
        end
        LunaWolves:Print("|cff00ff00" .. name .. " geloescht.|r (" .. removed .. " History-Eintraege entfernt)")
        -- Broadcast an andere Officers
        LunaWolves:SendMessage("GUILD", "DKP", "DELETE", name)
        -- UI aktualisieren
        if self.mainFrame and self.mainFrame:IsShown() then
            self:RefreshList()
        end

    elseif cmd == "setboss" then
        -- Punkte pro Bosskill konfigurieren
        local val = tonumber(rest)
        if val then
            LunaWolvesDB.DKP.pointsPerKill = val
            LunaWolves:Print("Punkte pro Bosskill: " .. val)
        else
            LunaWolves:Print("Aktuell: " .. (LunaWolvesDB.DKP.pointsPerKill or 10) ..
                " Punkte pro Bosskill")
            LunaWolves:Print("Aendern: /lw dkp setboss <anzahl>")
        end

    else
        -- Kein Subkommando oder leer: UI oeffnen
        self:ToggleUI()
    end
end

-- ============================================================
-- UI: DKP-Hauptfenster
-- ============================================================

function DKP:CreateUI()
    if self.mainFrame then return end

    -- Hauptfenster
    local f = CreateFrame("Frame", "LunaWolves_DKPFrame", UIParent, "BackdropTemplate")
    f:SetSize(LIST_WIDTH + 40, ROW_HEIGHT * VISIBLE_ROWS + 100)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile = SOLID,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.6, 1)
    f:Hide()
    self.mainFrame = f

    -- Titelleiste
    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("|cff8888ffLunaWolves|r DKP")

    -- Schliessen-Button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Spalten-Header
    local headerY = -35
    local headers = { { "Name", -20 }, { "Klasse", -180 }, { "DKP", -300 }, { "Lifetime", -380 } }
    for _, h in ipairs(headers) do
        local ht = f:CreateFontString(nil, "OVERLAY")
        ht:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        ht:SetTextColor(0.8, 0.8, 0.4)
        ht:SetPoint("TOPLEFT", f, "TOPLEFT", -h[2], headerY)
        ht:SetText(h[1])
    end

    -- Trennlinie
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetTexture(SOLID)
    sep:SetVertexColor(0.4, 0.4, 0.6, 0.5)
    sep:SetSize(LIST_WIDTH, 1)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 20, headerY - 15)

    -- Scroll-Frame
    local scrollFrame = CreateFrame("ScrollFrame", "LunaWolves_DKPScroll", f, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 15, headerY - 20)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -35, 40)
    self.scrollFrame = scrollFrame

    -- Zeilen erstellen
    self.rows = {}
    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(LIST_WIDTH, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 5, -((i - 1) * ROW_HEIGHT))

        -- Hover-Highlight
        local highlight = row:CreateTexture(nil, "BACKGROUND")
        highlight:SetAllPoints()
        highlight:SetTexture(SOLID)
        highlight:SetVertexColor(1, 1, 1, 0.1)
        highlight:Hide()
        row:SetScript("OnEnter", function() highlight:Show() end)
        row:SetScript("OnLeave", function() highlight:Hide() end)

        -- Text-Felder
        row.nameText = row:CreateFontString(nil, "OVERLAY")
        row.nameText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.nameText:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.nameText:SetWidth(150)
        row.nameText:SetJustifyH("LEFT")

        row.classText = row:CreateFontString(nil, "OVERLAY")
        row.classText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.classText:SetPoint("LEFT", row, "LEFT", 165, 0)
        row.classText:SetWidth(110)
        row.classText:SetJustifyH("LEFT")

        row.dkpText = row:CreateFontString(nil, "OVERLAY")
        row.dkpText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.dkpText:SetPoint("LEFT", row, "LEFT", 285, 0)
        row.dkpText:SetWidth(70)
        row.dkpText:SetJustifyH("RIGHT")
        row.dkpText:SetTextColor(0.2, 1, 0.2)

        row.lifetimeText = row:CreateFontString(nil, "OVERLAY")
        row.lifetimeText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.lifetimeText:SetPoint("LEFT", row, "LEFT", 365, 0)
        row.lifetimeText:SetWidth(70)
        row.lifetimeText:SetJustifyH("RIGHT")
        row.lifetimeText:SetTextColor(0.7, 0.7, 0.7)

        row.playerData = nil

        -- Rechtsklick-Menue fuer Officers
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" and row.playerData and LunaWolves:IsOfficer() then
                DKP:ShowContextMenu(row, row.playerData.name)
            end
        end)

        self.rows[i] = row
    end

    -- Scroll-Handler
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function()
            DKP:RefreshList()
        end)
    end)

    -- Sync-Button
    local syncBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    syncBtn:SetSize(80, 22)
    syncBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 10)
    syncBtn:SetText("Sync")
    syncBtn:SetScript("OnClick", function()
        DKP:RequestSync()
        LunaWolves:Print("Sync angefordert...")
    end)

    -- History-Button
    local histBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    histBtn:SetSize(80, 22)
    histBtn:SetPoint("LEFT", syncBtn, "RIGHT", 5, 0)
    histBtn:SetText("History")
    histBtn:SetScript("OnClick", function()
        DKP:ShowHistoryUI(nil)
    end)

    -- ESC schliesst das Fenster
    table.insert(UISpecialFrames, "LunaWolves_DKPFrame")
end

function DKP:ToggleUI()
    if not self.mainFrame then return end
    if self.mainFrame:IsShown() then
        self.mainFrame:Hide()
    else
        self:RefreshList()
        self.mainFrame:Show()
    end
end

-- Sortierte Spielerliste aufbauen
function DKP:GetSortedPlayers()
    local players = {}
    for name, pts in pairs(LunaWolvesDB.DKP.points) do
        table.insert(players, {
            name = name,
            current = pts.current,
            lifetime = pts.lifetime,
        })
    end
    -- Absteigend nach aktuellen DKP sortieren
    table.sort(players, function(a, b) return a.current > b.current end)
    return players
end

function DKP:RefreshList()
    local players = self:GetSortedPlayers()
    local numPlayers = #players

    FauxScrollFrame_Update(self.scrollFrame, numPlayers, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(self.scrollFrame)

    for i = 1, VISIBLE_ROWS do
        local row = self.rows[i]
        local idx = i + offset

        if idx <= numPlayers then
            local p = players[idx]
            row.playerData = p

            row.nameText:SetText(p.name)
            row.dkpText:SetText(tostring(p.current))
            row.lifetimeText:SetText(tostring(p.lifetime))

            -- Klassenfarbe (falls im Gildenroster bekannt)
            local classFile = self:GetPlayerClass(p.name)
            if classFile and CLASS_COLORS[classFile] then
                local c = CLASS_COLORS[classFile]
                row.nameText:SetTextColor(c.r, c.g, c.b)
                row.classText:SetText(classFile)
                row.classText:SetTextColor(c.r, c.g, c.b)
            else
                row.nameText:SetTextColor(1, 1, 1)
                row.classText:SetText("-")
                row.classText:SetTextColor(0.5, 0.5, 0.5)
            end

            row:Show()
        else
            row.playerData = nil
            row:Hide()
        end
    end
end

-- Spielerklasse aus dem Gildenroster ermitteln
function DKP:GetPlayerClass(playerName)
    if not IsInGuild() then return nil end
    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name, _, _, _, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
        if name then
            local short = strsplit("-", name)
            if short == playerName then
                return classFile
            end
        end
    end
    return nil
end

-- ============================================================
-- Delete-Sync
-- ============================================================

function DKP:HandleDelete(payload, sender)
    -- Sender muss Officer sein
    if not LunaWolves:IsOfficer(sender) then return end

    local name = payload
    if not name or name == "" then return end

    -- Spieler lokal entfernen
    LunaWolvesDB.DKP.points[name] = nil
    for i = #LunaWolvesDB.DKP.history, 1, -1 do
        if LunaWolvesDB.DKP.history[i].player == name then
            table.remove(LunaWolvesDB.DKP.history, i)
        end
    end

    LunaWolves:Print(name .. " wurde von " .. sender .. " aus der DKP-Liste entfernt.")

    -- UI aktualisieren
    if self.mainFrame and self.mainFrame:IsShown() then
        self:RefreshList()
    end
end

-- ============================================================
-- UI: History-Fenster
-- ============================================================

local HIST_ROW_HEIGHT = 18
local HIST_VISIBLE_ROWS = 20
local HIST_WIDTH = 580

function DKP:CreateHistoryUI()
    if self.historyFrame then return end

    local f = CreateFrame("Frame", "LunaWolves_HistoryFrame", UIParent, "BackdropTemplate")
    f:SetSize(HIST_WIDTH + 40, HIST_ROW_HEIGHT * HIST_VISIBLE_ROWS + 80)
    f:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile = SOLID,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.6, 1)
    f:Hide()
    self.historyFrame = f

    -- Titelleiste
    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.title:SetPoint("TOP", f, "TOP", 0, -10)

    -- Schliessen-Button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Spalten-Header
    local headerY = -35
    local headers = {
        { "Datum", 15 },
        { "Name", 130 },
        { "DKP", 265 },
        { "Grund", 330 },
        { "Officer", 500 },
    }
    for _, h in ipairs(headers) do
        local ht = f:CreateFontString(nil, "OVERLAY")
        ht:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        ht:SetTextColor(0.8, 0.8, 0.4)
        ht:SetPoint("TOPLEFT", f, "TOPLEFT", h[2], headerY)
        ht:SetText(h[1])
    end

    -- Trennlinie
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetTexture(SOLID)
    sep:SetVertexColor(0.4, 0.4, 0.6, 0.5)
    sep:SetSize(HIST_WIDTH, 1)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 15, headerY - 15)

    -- Scroll-Frame
    local scrollFrame = CreateFrame("ScrollFrame", "LunaWolves_HistoryScroll", f, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, headerY - 20)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -35, 15)
    self.histScrollFrame = scrollFrame

    -- Zeilen erstellen
    self.histRows = {}
    for i = 1, HIST_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(HIST_WIDTH, HIST_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 5, -((i - 1) * HIST_ROW_HEIGHT))

        row.dateText = row:CreateFontString(nil, "OVERLAY")
        row.dateText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        row.dateText:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.dateText:SetWidth(110)
        row.dateText:SetJustifyH("LEFT")
        row.dateText:SetTextColor(0.7, 0.7, 0.7)

        row.nameText = row:CreateFontString(nil, "OVERLAY")
        row.nameText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        row.nameText:SetPoint("LEFT", row, "LEFT", 120, 0)
        row.nameText:SetWidth(125)
        row.nameText:SetJustifyH("LEFT")

        row.dkpText = row:CreateFontString(nil, "OVERLAY")
        row.dkpText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        row.dkpText:SetPoint("LEFT", row, "LEFT", 255, 0)
        row.dkpText:SetWidth(60)
        row.dkpText:SetJustifyH("RIGHT")

        row.reasonText = row:CreateFontString(nil, "OVERLAY")
        row.reasonText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        row.reasonText:SetPoint("LEFT", row, "LEFT", 320, 0)
        row.reasonText:SetWidth(165)
        row.reasonText:SetJustifyH("LEFT")
        row.reasonText:SetTextColor(0.8, 0.8, 0.8)

        row.officerText = row:CreateFontString(nil, "OVERLAY")
        row.officerText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        row.officerText:SetPoint("LEFT", row, "LEFT", 490, 0)
        row.officerText:SetWidth(90)
        row.officerText:SetJustifyH("LEFT")
        row.officerText:SetTextColor(0.6, 0.6, 0.6)

        self.histRows[i] = row
    end

    -- Scroll-Handler
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, HIST_ROW_HEIGHT, function()
            DKP:RefreshHistoryList()
        end)
    end)

    -- ESC schliesst das Fenster
    table.insert(UISpecialFrames, "LunaWolves_HistoryFrame")
end

function DKP:ShowHistoryUI(playerName)
    if not self.historyFrame then
        self:CreateHistoryUI()
    end

    self._historyFilter = playerName
    local titleText = "|cff8888ffDKP History|r"
    if playerName then
        titleText = titleText .. " - " .. playerName
    end
    self.historyFrame.title:SetText(titleText)

    self:RefreshHistoryList()
    self.historyFrame:Show()
end

function DKP:RefreshHistoryList()
    local history = self:GetHistory(self._historyFilter, 200)
    local numEntries = #history

    FauxScrollFrame_Update(self.histScrollFrame, numEntries, HIST_VISIBLE_ROWS, HIST_ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(self.histScrollFrame)

    for i = 1, HIST_VISIBLE_ROWS do
        local row = self.histRows[i]
        local idx = i + offset

        if idx <= numEntries then
            local entry = history[idx]
            local d = date("%d.%m.%Y %H:%M", entry.timestamp)
            local sign = entry.delta >= 0 and "|cff00ff00+" or "|cffff4444"

            row.dateText:SetText(d)
            row.nameText:SetText(entry.player)
            row.dkpText:SetText(sign .. entry.delta .. "|r")
            row.reasonText:SetText(entry.reason)
            row.officerText:SetText(entry.officer)

            -- Klassenfarbe fuer Name
            local classFile = self:GetPlayerClass(entry.player)
            if classFile and CLASS_COLORS[classFile] then
                local c = CLASS_COLORS[classFile]
                row.nameText:SetTextColor(c.r, c.g, c.b)
            else
                row.nameText:SetTextColor(1, 1, 1)
            end

            row:Show()
        else
            row:Hide()
        end
    end
end

-- ============================================================
-- Kontextmenue (Rechtsklick auf Spieler)
-- ============================================================

function DKP:ShowContextMenu(anchor, playerName)
    MenuUtil.CreateContextMenu(anchor, function(ownerRegion, rootDescription)
        rootDescription:CreateTitle(playerName)
        rootDescription:CreateButton("Punkte vergeben", function()
            DKP:ShowInputDialog(playerName, "add")
        end)
        rootDescription:CreateButton("Punkte abziehen", function()
            DKP:ShowInputDialog(playerName, "sub")
        end)
        rootDescription:CreateButton("History anzeigen", function()
            DKP:HandleSlash("history " .. playerName)
        end)
    end)
end

-- ============================================================
-- Eingabe-Dialog (Punkte vergeben/abziehen)
-- ============================================================

function DKP:ShowInputDialog(playerName, action)
    if not self.inputDialog then
        local d = CreateFrame("Frame", "LunaWolves_DKPInput", UIParent, "BackdropTemplate")
        d:SetSize(300, 140)
        d:SetPoint("CENTER")
        d:SetFrameStrata("DIALOG")
        d:SetMovable(true)
        d:EnableMouse(true)
        d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving)
        d:SetScript("OnDragStop", d.StopMovingOrSizing)
        d:SetBackdrop({
            bgFile = SOLID,
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        d:SetBackdropColor(0.15, 0.15, 0.2, 0.95)
        d:SetBackdropBorderColor(0.4, 0.4, 0.6, 1)

        d.title = d:CreateFontString(nil, "OVERLAY")
        d.title:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        d.title:SetPoint("TOP", d, "TOP", 0, -10)

        -- Anzahl
        local amtLabel = d:CreateFontString(nil, "OVERLAY")
        amtLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        amtLabel:SetPoint("TOPLEFT", d, "TOPLEFT", 15, -35)
        amtLabel:SetText("Anzahl:")
        amtLabel:SetTextColor(1, 1, 1)

        d.amountBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        d.amountBox:SetSize(80, 22)
        d.amountBox:SetPoint("LEFT", amtLabel, "RIGHT", 10, 0)
        d.amountBox:SetAutoFocus(false)
        d.amountBox:SetNumeric(true)

        -- Grund
        local reasonLabel = d:CreateFontString(nil, "OVERLAY")
        reasonLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        reasonLabel:SetPoint("TOPLEFT", d, "TOPLEFT", 15, -65)
        reasonLabel:SetText("Grund:")
        reasonLabel:SetTextColor(1, 1, 1)

        d.reasonBox = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        d.reasonBox:SetSize(190, 22)
        d.reasonBox:SetPoint("LEFT", reasonLabel, "RIGHT", 10, 0)
        d.reasonBox:SetAutoFocus(false)

        -- OK-Button
        d.okBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        d.okBtn:SetSize(80, 22)
        d.okBtn:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 40, 10)
        d.okBtn:SetText("OK")

        -- Abbrechen-Button
        d.cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        d.cancelBtn:SetSize(80, 22)
        d.cancelBtn:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -40, 10)
        d.cancelBtn:SetText("Abbrechen")
        d.cancelBtn:SetScript("OnClick", function() d:Hide() end)

        -- ESC schliesst
        d:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:Hide()
                self:SetPropagateKeyboardInput(false)
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)

        self.inputDialog = d
    end

    local d = self.inputDialog
    local isAdd = action == "add"
    d.title:SetText((isAdd and "Punkte vergeben: " or "Punkte abziehen: ") .. playerName)
    d.amountBox:SetText("")
    d.reasonBox:SetText("")
    d.amountBox:SetFocus()

    d.okBtn:SetScript("OnClick", function()
        local amount = tonumber(d.amountBox:GetText()) or 0
        local reason = d.reasonBox:GetText()
        if amount <= 0 then
            LunaWolves:Print("Bitte eine gueltige Anzahl eingeben.")
            return
        end
        reason = (reason and reason ~= "") and reason or (isAdd and "Manuell" or "Abzug")

        if isAdd then
            DKP:HandleSlash("add " .. playerName .. " " .. amount .. " " .. reason)
        else
            DKP:HandleSlash("sub " .. playerName .. " " .. amount .. " " .. reason)
        end
        d:Hide()
    end)

    d:Show()
end

-- ============================================================
-- Modul registrieren
-- ============================================================

LunaWolves:RegisterModule("DKP", DKP)
