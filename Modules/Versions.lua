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
    f:SetSize(540, ROW_HEIGHT * MAX_ROWS + 110)
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

    -- Titel
    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -10)
    f.titleText:SetText("|cff8888ffLunaWolves Versionsübersicht|r")

    -- Schließen-Button (X)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Header
    local headers = {
        { "Spieler",    20  },
        { "Realm",      170 },
        { "Version",    280 },
        { "BattleTag",  360 },
        { "Aktivität",  475 },
    }
    for _, h in ipairs(headers) do
        local fs = f:CreateFontString(nil, "OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", h[2], -38)
        fs:SetText(h[1])
        fs:SetTextColor(0.8, 0.8, 0.4)
    end

    -- Zeilen
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(510, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -52 - ((i - 1) * ROW_HEIGHT))

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        bg:SetColorTexture(0.2, 0.2, 0.3, 0.2)
        row.bg = bg

        local function makeText(xOff, width)
            local fs = row:CreateFontString(nil, "OVERLAY")
            fs:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
            fs:SetPoint("LEFT", row, "LEFT", xOff, 0)
            fs:SetWidth(width)
            fs:SetJustifyH("LEFT")
            return fs
        end
        row.nameText      = makeText(5,   140)
        row.realmText     = makeText(150, 105)
        row.versionText   = makeText(260, 75)
        row.battleTagText = makeText(340, 120)
        row.activityText  = makeText(455, 60)

        row:Hide()
        f.rows[i] = row
    end

    -- Info-Zeile unten links: eigene Version + Sharing-Status
    f.infoText = f:CreateFontString(nil, "OVERLAY")
    f.infoText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    f.infoText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 14)
    f.infoText:SetTextColor(0.7, 0.7, 0.7)

    -- Refresh-Button
    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(110, 24)
    refreshBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
    refreshBtn:SetText("Aktualisieren")
    refreshBtn:SetScript("OnClick", function()
        LunaWolves:SendMessage("GUILD", "VER", "LISTREQ", "")
    end)

    -- Schließen
    local closeBtn2 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn2:SetSize(110, 24)
    closeBtn2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 12)
    closeBtn2:SetText("Schließen")
    closeBtn2:SetScript("OnClick", function() f:Hide() end)

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

function VER:RefreshList()
    local f = self.listFrame
    if not f then return end

    -- Höchste Version bestimmen (für Update-Markierung)
    local maxVersion = "0.0.0"
    for _, info in pairs(self.versions) do
        if info.version and CompareVersions(info.version, maxVersion) > 0 then
            maxVersion = info.version
        end
    end

    -- Liste in Array umwandeln und sortieren
    -- Sortierung: BattleTag (für Gruppierung visuell) → Name
    local list = {}
    for fullName, info in pairs(self.versions) do
        table.insert(list, {
            fullName  = fullName,
            version   = info.version or "?",
            battleTag = info.battleTag or "",
            classFile = info.classFile or "UNKNOWN",
            lastSeen  = info.lastSeen or 0,
        })
    end
    table.sort(list, function(a, b)
        -- Einträge mit BattleTag zuerst gruppieren
        local aHasTag = a.battleTag ~= ""
        local bHasTag = b.battleTag ~= ""
        if aHasTag ~= bHasTag then return aHasTag end
        if a.battleTag ~= b.battleTag then return a.battleTag < b.battleTag end
        return ShortName(a.fullName) < ShortName(b.fullName)
    end)

    -- BattleTag-Häufigkeit zählen für Gruppen-Markierung
    local tagCount = {}
    for _, e in ipairs(list) do
        if e.battleTag ~= "" then
            tagCount[e.battleTag] = (tagCount[e.battleTag] or 0) + 1
        end
    end

    -- Zeilen befüllen
    for i, row in ipairs(f.rows) do
        local e = list[i]
        if e then
            -- Name (Klassenfarbe)
            local color = CLASS_COLORS[e.classFile]
            if color then
                row.nameText:SetText(string.format("|cff%02x%02x%02x%s|r",
                    color.r * 255, color.g * 255, color.b * 255, ShortName(e.fullName)))
            else
                row.nameText:SetText(ShortName(e.fullName))
            end

            -- Realm
            row.realmText:SetText("|cff999999" .. RealmOf(e.fullName) .. "|r")

            -- Version: aktuell = grün, älter = orange/rot
            local cmp = CompareVersions(e.version, maxVersion)
            local versionColor = "|cff88ff88"
            if cmp < 0 then versionColor = "|cffff6666" end
            row.versionText:SetText(versionColor .. "v" .. e.version .. "|r")

            -- BattleTag (mit Gruppen-Marker wenn mehrere Chars)
            if e.battleTag ~= "" then
                local count = tagCount[e.battleTag] or 1
                local tagSuffix = count > 1 and (" |cffaaaaff(" .. count .. ")|r") or ""
                row.battleTagText:SetText(e.battleTag .. tagSuffix)
                row.battleTagText:SetTextColor(0.7, 0.8, 1)
            else
                row.battleTagText:SetText("|cff666666(privat)|r")
            end

            -- Aktivität
            row.activityText:SetText(FormatActivity(e.lastSeen))
            row.activityText:SetTextColor(0.6, 0.6, 0.6)

            -- Alternierende Hintergründe für Gruppen
            if e.battleTag ~= "" and (tagCount[e.battleTag] or 0) > 1 then
                row.bg:SetColorTexture(0.25, 0.3, 0.4, 0.3)
            else
                row.bg:SetColorTexture(0.2, 0.2, 0.3, 0.2)
            end

            row:Show()
        else
            row:Hide()
        end
    end

    -- Info-Zeile
    local me = self.versions[GetFullName()]
    local myVer = me and me.version or "?"
    local shareStatus = LunaWolvesDB.shareBattleTag and "|cff88ff88geteilt|r" or "|cffff8800privat|r"
    f.infoText:SetText("Eigene Version: |cff88ff88v" .. myVer ..
        "|r  •  Höchste Version: |cffffaa00v" .. maxVersion ..
        "|r  •  BattleTag: " .. shareStatus ..
        "  •  " .. #list .. " Spieler bekannt")
end

-- ============================================================
-- Modul registrieren
-- ============================================================

LunaWolves:RegisterModule("VER", VER)
