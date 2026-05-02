-- Modules/Versions.lua
-- LunaWolves Versionsübersicht: Wer hat das Addon, welche Version,
-- optional Battle.net-Tag um Chars derselben Person zu erkennen.

local VER = {}

local SOLID = "Interface\\Buttons\\WHITE8X8"

-- Klassenfarben (gleich wie in DKP.lua)
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

local STALE_AFTER = 30 * 24 * 60 * 60   -- 30 Tage: ältere Einträge verwerfen

-- ============================================================
-- Hilfsfunktionen
-- ============================================================

-- Voller Spielername mit normalisiertem Realm
local function GetFullName()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then
        realm = (GetRealmName() or ""):gsub("[%s%-]", "")
    end
    return LunaWolves.playerName .. "-" .. realm
end

local function ShortName(fullName)
    if not fullName then return "" end
    local short = strsplit("-", fullName)
    return short or fullName
end

local function RealmOf(fullName)
    if not fullName then return "" end
    local _, realm = strsplit("-", fullName, 2)
    return realm or ""
end

-- Eigene Addon-Version aus TOC
local function GetMyVersion()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata("LunaWolves", "Version") or "?"
    elseif GetAddOnMetadata then
        return GetAddOnMetadata("LunaWolves", "Version") or "?"
    end
    return "?"
end

-- Eigenen Battle.net-Tag (sofern Sharing aktiv ist und BN verbunden)
local function GetMyBattleTag()
    if not LunaWolvesDB or LunaWolvesDB.shareBattleTag == false then
        return ""
    end
    if not BNGetInfo then return "" end
    local ok, _, battleTag = pcall(BNGetInfo)
    if ok and battleTag and battleTag ~= "" then
        return battleTag
    end
    return ""
end

-- Semver-Vergleich: returns -1 / 0 / 1
local function ParseVersion(v)
    if not v then return 0, 0, 0 end
    local maj, min, pat = v:match("(%d+)%.(%d+)%.(%d+)")
    return tonumber(maj) or 0, tonumber(min) or 0, tonumber(pat) or 0
end
local function CompareVersions(a, b)
    local a1, a2, a3 = ParseVersion(a)
    local b1, b2, b3 = ParseVersion(b)
    if a1 ~= b1 then return a1 < b1 and -1 or 1 end
    if a2 ~= b2 then return a2 < b2 and -1 or 1 end
    if a3 ~= b3 then return a3 < b3 and -1 or 1 end
    return 0
end

-- ============================================================
-- Initialisierung
-- ============================================================

function VER:OnInitialize()
end

function VER:OnEnable()
    LunaWolvesDB.Versions = LunaWolvesDB.Versions or {}
    -- shareBattleTag default true (Opt-Out, kein Opt-In)
    if LunaWolvesDB.shareBattleTag == nil then
        LunaWolvesDB.shareBattleTag = true
    end

    self.versions = LunaWolvesDB.Versions
    self.expandedTags = {}  -- [battleTag] = true wenn ausgeklappt (session-only)

    -- Alte Einträge aufräumen (älter als 30 Tage)
    self:PruneStale()

    -- Eigenen Eintrag direkt setzen
    self:UpdateSelf()

    -- UI vorbereiten (lazy)
    self.listFrame = nil

    -- 5 Sekunden nach Login HELLO an Gilde senden
    C_Timer.After(5, function()
        if IsInGuild() then
            VER:BroadcastHello()
        end
    end)
end

function VER:UpdateSelf()
    local _, classFile = UnitClass("player")
    local fullName = GetFullName()
    self.versions[fullName] = {
        version    = GetMyVersion(),
        battleTag  = GetMyBattleTag(),
        classFile  = classFile or "UNKNOWN",
        lastSeen   = time(),
    }
end

-- ============================================================
-- Nachrichtenverarbeitung
-- ============================================================

function VER:OnMessage(command, payload, sender, channel)
    if command == "HELLO" then
        self:HandleHello(payload, sender)
    elseif command == "LISTREQ" then
        self:HandleListReq(payload, sender)
    end
end

-- HELLO senden: version;battleTag;classFile;fullName
function VER:BroadcastHello()
    self:UpdateSelf()
    local me = self.versions[GetFullName()]
    if not me then return end
    local payload = table.concat({
        me.version or "?",
        me.battleTag or "",
        me.classFile or "UNKNOWN",
        GetFullName(),
    }, ";")
    LunaWolves:SendMessage("GUILD", "VER", "HELLO", payload)
end

function VER:HandleHello(payload, sender)
    local version, battleTag, classFile, fullName = strsplit(";", payload)
    if not version or not fullName then return end

    -- Sender muss zum fullName passen (Anti-Spoof light)
    if ShortName(fullName) ~= sender then return end

    -- Eigenen Eintrag nicht überschreiben (ist immer aktuell)
    if fullName == GetFullName() then return end

    self.versions[fullName] = {
        version    = version,
        battleTag  = battleTag or "",
        classFile  = (classFile and classFile ~= "") and classFile or "UNKNOWN",
        lastSeen   = time(),
    }

    -- UI live aktualisieren wenn offen
    if self.listFrame and self.listFrame:IsShown() then
        self:RefreshList()
    end
end

function VER:HandleListReq(payload, sender)
    -- Mit zufälliger Verzögerung antworten, um Spam-Bursts zu vermeiden
    C_Timer.After(math.random() * 3, function()
        VER:BroadcastHello()
    end)
end

-- ============================================================
-- Cleanup
-- ============================================================

function VER:PruneStale()
    local now = time()
    for name, info in pairs(self.versions) do
        if not info.lastSeen or (now - info.lastSeen) > STALE_AFTER then
            self.versions[name] = nil
        end
    end
end

-- ============================================================
-- Slash-Kommandos
-- ============================================================

function VER:HandleSlash(input)
    local cmd = (input or ""):lower():match("^(%S*)")

    if cmd == "refresh" then
        LunaWolves:SendMessage("GUILD", "VER", "LISTREQ", "")
        LunaWolves:Print("Versionsliste wird aktualisiert...")
    elseif cmd == "share" then
        -- Toggle Battle.net-Sharing
        LunaWolvesDB.shareBattleTag = not LunaWolvesDB.shareBattleTag
        LunaWolves:Print("Battle.net-Tag teilen: " ..
            (LunaWolvesDB.shareBattleTag and "|cff00ff00an|r" or "|cffff8800aus|r"))
        VER:BroadcastHello()
    else
        self:ShowList()
    end
end

-- ============================================================
-- UI: Versionsliste
-- ============================================================

function VER:CreateListUI()
    if self.listFrame then return end

    local ROW_HEIGHT = 22
    local MAX_ROWS = 18

    local f = CreateFrame("Frame", "LunaWolves_VersionList", UIParent, "BackdropTemplate")
    f:SetSize(540, ROW_HEIGHT * MAX_ROWS + 130)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = SOLID,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
    f:SetBackdropBorderColor(0.4, 0.4, 0.6, 1)
    f:Hide()
    self.listFrame = f

    -- Titel (gleicher Stil wie DKP-Fenster: "LunaWolves" blau, Modulname weiß)
    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -10)
    f.titleText:SetText("|cff8888ffLunaWolves|r Versionsübersicht")

    -- Schließen-Button (X)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Header (gleicher Font/Position wie DKP-Fenster)
    -- Realm steht jetzt grau hinter dem Namen (wie DKP), BattleTag wird intern
    -- für Gruppierung verwendet aber nicht mehr angezeigt.
    local headerY = -35
    local headers = {
        { "Spieler",    20  },
        { "Version",    290 },
        { "Chars",      380 },
        { "Aktivität",  450 },
    }
    for _, h in ipairs(headers) do
        local fs = f:CreateFontString(nil, "OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", h[2], headerY)
        fs:SetText(h[1])
        fs:SetTextColor(0.8, 0.8, 0.4)
    end

    -- Trennlinie unter den Headern (wie beim DKP)
    local headerSep = f:CreateTexture(nil, "ARTWORK")
    headerSep:SetTexture(SOLID)
    headerSep:SetVertexColor(0.4, 0.4, 0.6, 0.5)
    headerSep:SetSize(510, 1)
    headerSep:SetPoint("TOPLEFT", f, "TOPLEFT", 15, headerY - 15)

    -- Zeilen (Buttons, damit klickbar für Gruppen-Toggle)
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(510, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 15, headerY - 20 - ((i - 1) * ROW_HEIGHT))
        row:RegisterForClicks("LeftButtonUp")

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        bg:SetColorTexture(0.2, 0.2, 0.3, 0.2)
        row.bg = bg

        -- Ausklapp-Pfeil (▶/▼) am linken Rand, nur sichtbar bei Gruppen-Leadern
        row.arrow = row:CreateFontString(nil, "OVERLAY")
        row.arrow:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        row.arrow:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.arrow:SetWidth(12)
        row.arrow:SetJustifyH("CENTER")
        row.arrow:SetTextColor(0.7, 0.7, 1)

        local function makeText(xOff, width)
            local fs = row:CreateFontString(nil, "OVERLAY")
            fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
            fs:SetPoint("LEFT", row, "LEFT", xOff, 0)
            fs:SetWidth(width)
            fs:SetJustifyH("LEFT")
            return fs
        end
        row.nameText     = makeText(20,  260)  -- Char + Realm-Suffix in einem
        row.versionText  = makeText(275, 80)
        row.charsText    = makeText(365, 60)
        row.activityText = makeText(430, 60)

        row:Hide()
        f.rows[i] = row
    end

    -- ------------------------------------------------------------
    -- Unterer Bereich (1:1 wie DKP-Fenster):
    --   y=63: "Mehr Einträge"-Hinweis (nur bei Overflow)
    --   y=38..60: Buttons (Höhe 22)
    --   y=34:  Trennlinie zwischen Buttons und Status
    --   y=13:  Info-/Status-Reihe auf voller Breite
    -- ------------------------------------------------------------

    -- "Mehr Einträge"-Hinweis (nur bei Overflow): zwischen Liste und Buttons
    f.moreText = f:CreateFontString(nil, "OVERLAY")
    f.moreText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    f.moreText:SetPoint("BOTTOM", f, "BOTTOM", 0, 63)
    f.moreText:SetTextColor(0.6, 0.6, 0.6)
    f.moreText:Hide()

    -- Buttons-Reihe (y=38, Höhe 22 — wie DKP)
    local toggleAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    toggleAllBtn:SetSize(130, 22)
    toggleAllBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 15, 38)
    toggleAllBtn:SetText("Alle ausklappen")
    f.toggleAllBtn = toggleAllBtn
    toggleAllBtn:SetScript("OnClick", function()
        VER:ToggleAll()
    end)

    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(110, 22)
    refreshBtn:SetPoint("LEFT", toggleAllBtn, "RIGHT", 5, 0)
    refreshBtn:SetText("Aktualisieren")
    refreshBtn:SetScript("OnClick", function()
        LunaWolves:SendMessage("GUILD", "VER", "LISTREQ", "")
    end)

    local closeBtn2 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn2:SetSize(110, 22)
    closeBtn2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 38)
    closeBtn2:SetText("Schließen")
    closeBtn2:SetScript("OnClick", function() f:Hide() end)

    -- Trennlinie ZWISCHEN Buttons und Info-Reihe (y=34, wie DKP)
    local btnSep = f:CreateTexture(nil, "ARTWORK")
    btnSep:SetTexture(SOLID)
    btnSep:SetVertexColor(0.4, 0.4, 0.6, 0.4)
    btnSep:SetSize(510, 1)
    btnSep:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 34)

    -- Info-/Status-Reihe (y=13, volle Breite — wie DKP-Statuslabel)
    f.infoText = f:CreateFontString(nil, "OVERLAY")
    f.infoText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    f.infoText:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  15, 13)
    f.infoText:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 13)
    f.infoText:SetJustifyH("LEFT")
    f.infoText:SetTextColor(1, 1, 1)

    table.insert(UISpecialFrames, "LunaWolves_VersionList")
end

function VER:ShowList()
    if not self.listFrame then self:CreateListUI() end
    -- LISTREQ einmalig: alle melden sich
    if IsInGuild() then
        LunaWolves:SendMessage("GUILD", "VER", "LISTREQ", "")
    end
    self:RefreshList()
    self.listFrame:Show()
end

-- "vor X Min/h/Tag" — relative Zeit kompakt
local function FormatActivity(ts)
    if not ts then return "-" end
    local diff = time() - ts
    if diff < 60 then return "jetzt" end
    if diff < 3600 then return math.floor(diff / 60) .. "m" end
    if diff < 86400 then return math.floor(diff / 3600) .. "h" end
    return math.floor(diff / 86400) .. "d"
end

-- Eintrag aus self.versions in Anzeigeformat bringen
local function MakeEntry(fullName, info)
    return {
        fullName  = fullName,
        version   = info.version or "?",
        battleTag = info.battleTag or "",
        classFile = info.classFile or "UNKNOWN",
        lastSeen  = info.lastSeen or 0,
    }
end

-- Baut die Anzeigeliste auf:
--  - Pro BattleTag mit >=2 Chars: ein "leader" (aktivster Char) + bei expanded[tag] alle weiteren als "sub"
--  - Pro BattleTag mit 1 Char: einzelner Eintrag (kein Pfeil)
--  - "(privat)"-Einträge ohne BattleTag: einzeln
function VER:BuildDisplayList()
    local groupedByTag = {}
    local privates     = {}

    for fullName, info in pairs(self.versions) do
        local e = MakeEntry(fullName, info)
        if e.battleTag ~= "" then
            local g = groupedByTag[e.battleTag]
            if not g then
                g = { battleTag = e.battleTag, chars = {} }
                groupedByTag[e.battleTag] = g
            end
            table.insert(g.chars, e)
        else
            table.insert(privates, e)
        end
    end

    -- Gruppen vorbereiten: aktivster Char zuerst
    local groupArr = {}
    local groupCount = 0
    for _, g in pairs(groupedByTag) do
        groupCount = groupCount + 1
        table.sort(g.chars, function(a, b) return a.lastSeen > b.lastSeen end)
        g.latestActivity = g.chars[1].lastSeen
        table.insert(groupArr, g)
    end
    -- Gruppen sortieren: aktivste zuerst
    table.sort(groupArr, function(a, b) return a.latestActivity > b.latestActivity end)

    -- Privat-Einträge nach Aktivität sortieren
    table.sort(privates, function(a, b) return a.lastSeen > b.lastSeen end)

    -- Flache Anzeige-Liste bauen
    local display = {}

    for _, g in ipairs(groupArr) do
        local leader = g.chars[1]
        local size = #g.chars
        local isExpanded = self.expandedTags[g.battleTag] == true

        -- Leader-Zeile mit Gruppen-Info
        table.insert(display, {
            entry        = leader,
            isGroupLeader = size > 1,
            groupSize    = size,
            isExpanded   = isExpanded,
            isSub        = false,
            battleTag    = g.battleTag,
        })

        -- Sub-Zeilen wenn ausgeklappt
        if isExpanded and size > 1 then
            for i = 2, size do
                table.insert(display, {
                    entry      = g.chars[i],
                    isSub      = true,
                    battleTag  = g.battleTag,
                })
            end
        end
    end

    for _, p in ipairs(privates) do
        table.insert(display, { entry = p, isSub = false })
    end

    return display, groupCount, groupArr
end

function VER:RefreshList()
    local f = self.listFrame
    if not f then return end

    -- Höchste Version bestimmen (für Update-Markierung)
    local maxVersion = "0.0.0"
    local totalEntries = 0
    for _, info in pairs(self.versions) do
        totalEntries = totalEntries + 1
        if info.version and CompareVersions(info.version, maxVersion) > 0 then
            maxVersion = info.version
        end
    end

    local display, groupCount, groupArr = self:BuildDisplayList()

    -- "Alle aus/zuklappen"-Button-Label aktualisieren
    if f.toggleAllBtn then
        local anyExpanded = false
        for _, g in ipairs(groupArr) do
            if self.expandedTags[g.battleTag] then anyExpanded = true; break end
        end
        f.toggleAllBtn:SetText(anyExpanded and "Alle zuklappen" or "Alle ausklappen")
        f.toggleAllBtn:SetEnabled(groupCount > 0)
    end

    -- Zeilen befüllen
    for i, row in ipairs(f.rows) do
        local d = display[i]
        if d then
            local e = d.entry

            -- Name + Realm-Suffix grau hintendran (wie DKP), Sub-Zeilen mit Einzug
            local indent = d.isSub and "  └ " or ""
            local myRealm = RealmOf(GetFullName())
            local charRealm = RealmOf(e.fullName)
            local realmSuffix = (charRealm ~= "" and charRealm ~= myRealm)
                and ("|cff777777-" .. charRealm .. "|r") or ""
            local color = CLASS_COLORS[e.classFile]
            local nameStr
            if color then
                nameStr = string.format("|cff%02x%02x%02x%s|r",
                    color.r * 255, color.g * 255, color.b * 255, ShortName(e.fullName))
            else
                nameStr = ShortName(e.fullName)
            end
            row.nameText:SetText(indent .. nameStr .. realmSuffix)

            -- Version: aktuell = grün, älter = rot
            local cmp = CompareVersions(e.version, maxVersion)
            local versionColor = "|cff88ff88"
            if cmp < 0 then versionColor = "|cffff6666" end
            row.versionText:SetText(versionColor .. "v" .. e.version .. "|r")

            -- Chars-Spalte: nur bei Gruppen-Leadern Anzahl, sonst leer
            if d.isGroupLeader then
                row.charsText:SetText("|cffaaaaff" .. d.groupSize .. "|r")
            else
                row.charsText:SetText("")
            end

            -- Aktivität
            row.activityText:SetText(FormatActivity(e.lastSeen))
            row.activityText:SetTextColor(0.6, 0.6, 0.6)

            -- Aus-/Einklapp-Indikator nur bei Gruppen-Leadern
            -- (ASCII +/-, da FRIZQT__.TTF keine Unicode-Dreiecke rendert)
            if d.isGroupLeader then
                row.arrow:SetText(d.isExpanded and "-" or "+")
            else
                row.arrow:SetText("")
            end

            -- Hintergrund
            if d.isGroupLeader then
                row.bg:SetColorTexture(0.25, 0.3, 0.45, 0.4)
            elseif d.isSub then
                row.bg:SetColorTexture(0.18, 0.2, 0.32, 0.5)
            else
                row.bg:SetColorTexture(0.2, 0.2, 0.3, 0.2)
            end

            -- Klick-Verhalten: nur Leader togglen Gruppe
            row:SetScript("OnClick", nil)
            if d.isGroupLeader then
                local tag = d.battleTag
                row:SetScript("OnClick", function()
                    self.expandedTags[tag] = not self.expandedTags[tag]
                    self:RefreshList()
                end)
            end

            row:Show()
        else
            row:Hide()
            row:SetScript("OnClick", nil)
        end
    end

    -- "Mehr Einträge" Hinweis wenn Liste länger als MAX_ROWS
    local maxRows = #f.rows
    if #display > maxRows then
        f.moreText:SetText("|cff888888… und " .. (#display - maxRows) .. " weitere Einträge (zuklappen oder Fenster größer machen)|r")
        f.moreText:Show()
    else
        f.moreText:Hide()
    end

    -- Info-Zeile
    local me = self.versions[GetFullName()]
    local myVer = me and me.version or "?"
    local shareStatus = LunaWolvesDB.shareBattleTag and "|cff88ff88geteilt|r" or "|cffff8800privat|r"
    f.infoText:SetText("Eigene Version: |cff88ff88v" .. myVer ..
        "|r  •  Höchste: |cffffaa00v" .. maxVersion ..
        "|r  •  BattleTag: " .. shareStatus ..
        "  •  " .. totalEntries .. " Chars / " .. groupCount .. " Personen")
end

-- Alle Gruppen aus-/zuklappen (Toggle: wenn irgendeine offen ist → alle zu, sonst alle auf)
function VER:ToggleAll()
    local _, _, groupArr = self:BuildDisplayList()
    local anyExpanded = false
    for _, g in ipairs(groupArr) do
        if self.expandedTags[g.battleTag] then anyExpanded = true; break end
    end
    if anyExpanded then
        wipe(self.expandedTags)
    else
        for _, g in ipairs(groupArr) do
            if #g.chars > 1 then
                self.expandedTags[g.battleTag] = true
            end
        end
    end
    self:RefreshList()
end

-- ============================================================
-- Modul registrieren
-- ============================================================

LunaWolves:RegisterModule("VER", VER)
