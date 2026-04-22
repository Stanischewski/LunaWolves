-- Modules/RaidInvite.lua
-- LunaWolves Gruppen-/Raid-Suchsystem: Jeder Gildler kann Gruppen erstellen,
-- andere koennen anfragen oder (bei Auto-Accept) direkt beitreten.

local RAID = {}

local SOLID = "Interface\\Buttons\\WHITE8X8"
local GROUP_TIMEOUT = 30 * 60    -- Gruppen nach 30 min Inaktivitaet verwerfen
local LIST_AUTO_REFRESH = 5      -- Auto-Refresh der Liste alle 5 Sekunden

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

-- Hilfsfunktion: Klassenfarbe als Hex
local function ClassColorCode(classFile)
    local c = CLASS_COLORS[classFile]
    if not c then return "|cffffffff" end
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

-- ============================================================
-- Initialisierung
-- ============================================================

function RAID:OnInitialize()
end

function RAID:OnEnable()
    LunaWolvesDB.RaidInvite = LunaWolvesDB.RaidInvite or {}

    -- Aktive Gruppen: [groupId] = { id, creator, creatorClass, type, title, autoAccept, timestamp, members = {} }
    self.activeGroups = {}
    -- Meine eigene Gruppe (ich bin Ersteller)
    self.myGroupId = nil
    -- Eingehende Anfragen (nur wenn ich Ersteller mit manueller Annahme bin)
    -- [player] = { groupId, class, spec, timestamp }
    self.pendingRequests = {}

    -- UI vorbereiten
    self:CreateListUI()
    self:CreateCreateUI()
    self:CreateManagerUI()
    self:CreateRequestUI()

    -- Beim Login (leicht verzoegert) die Liste aller aktiven Gruppen abfragen
    C_Timer.After(3, function()
        if IsInGuild() then
            LunaWolves:SendMessage("GUILD", "RAID", "LISTREQ", "")
        end
    end)

    -- Regelmaessiger Cleanup alter Gruppen
    C_Timer.NewTicker(60, function()
        RAID:PruneGroups()
    end)
end

-- ============================================================
-- Nachrichtenverarbeitung
-- ============================================================

function RAID:OnMessage(command, payload, sender, channel)
    if command == "ANNOUNCE" then
        self:HandleAnnounce(payload, sender)
    elseif command == "LISTREQ" then
        self:HandleListReq(payload, sender)
    elseif command == "REQUEST" then
        self:HandleRequest(payload, sender)
    elseif command == "ACCEPT" then
        self:HandleAccept(payload, sender)
    elseif command == "REJECT" then
        self:HandleReject(payload, sender)
    elseif command == "CLOSE" then
        self:HandleClose(payload, sender)
    end
end

-- ============================================================
-- Gruppe erstellen / schliessen
-- ============================================================

function RAID:CreateGroup(groupType, title, autoAccept)
    if not IsInGuild() then
        LunaWolves:Print("Du bist in keiner Gilde.")
        return
    end
    if not title or title == "" then
        LunaWolves:Print("Titel darf nicht leer sein.")
        return
    end
    if groupType ~= "PARTY" and groupType ~= "RAID" then
        groupType = "PARTY"
    end

    -- Bestehende eigene Gruppe zuerst schliessen
    if self.myGroupId then
        self:CloseMyGroup(true)
    end

    local _, classFile = UnitClass("player")
    local groupId = LunaWolves.playerName .. "-" .. time() .. "-" .. math.random(1000, 9999)

    local group = {
        id = groupId,
        creator = LunaWolves.playerName,
        creatorClass = classFile or "UNKNOWN",
        type = groupType,
        title = title,
        autoAccept = autoAccept and true or false,
        timestamp = time(),
        members = {},  -- [name] = { class, spec, timestamp }
    }
    self.activeGroups[groupId] = group
    self.myGroupId = groupId

    self:BroadcastAnnounce(group)
    LunaWolves:Print("Gruppe erstellt: " .. title .. " (" ..
        (groupType == "RAID" and "Schlachtzug" or "5-Spieler") ..
        (autoAccept and ", Auto-Annahme" or "") .. ")")

    self:RefreshManager()
    self.managerFrame:Show()
    self:RefreshList()
end

function RAID:BroadcastAnnounce(group)
    local payload = table.concat({
        group.id,
        group.creator,
        group.creatorClass,
        group.type,
        group.title,
        group.autoAccept and "1" or "0",
        tostring(group.timestamp),
    }, ";")
    LunaWolves:SendMessage("GUILD", "RAID", "ANNOUNCE", payload)
end

function RAID:CloseMyGroup(silent)
    if not self.myGroupId then
        if not silent then
            LunaWolves:Print("Du hast keine aktive Gruppe.")
        end
        return
    end
    local groupId = self.myGroupId
    LunaWolves:SendMessage("GUILD", "RAID", "CLOSE", groupId)
    self.activeGroups[groupId] = nil
    self.myGroupId = nil
    wipe(self.pendingRequests)
    if not silent then
        LunaWolves:Print("Deine Gruppe wurde geschlossen.")
    end
    if self.managerFrame then self.managerFrame:Hide() end
    self:RefreshList()
end

-- ============================================================
-- Gruppen-Announcements verarbeiten
-- ============================================================

function RAID:HandleAnnounce(payload, sender)
    local id, creator, class, gtype, title, autoAccept, ts = strsplit(";", payload)
    if not id or not creator then return end

    -- Creator muss mit Sender uebereinstimmen (Anti-Spoof light)
    if creator ~= sender then return end

    -- Meine eigene Gruppe nicht doppelt hinzufuegen
    if creator == LunaWolves.playerName then return end

    local existing = self.activeGroups[id]
    self.activeGroups[id] = {
        id = id,
        creator = creator,
        creatorClass = class or "UNKNOWN",
        type = gtype == "RAID" and "RAID" or "PARTY",
        title = title or "Gruppe",
        autoAccept = autoAccept == "1",
        timestamp = tonumber(ts) or time(),
        members = existing and existing.members or {},
    }

    self:RefreshList()
end

function RAID:HandleListReq(payload, sender)
    -- Nur antworten wenn ich eine aktive Gruppe habe
    if not self.myGroupId then return end
    local group = self.activeGroups[self.myGroupId]
    if not group then return end
    -- Leicht verzoegerte Antwort um Spam zu vermeiden
    C_Timer.After(math.random() * 2, function()
        if self.activeGroups[self.myGroupId] then
            self:BroadcastAnnounce(self.activeGroups[self.myGroupId])
        end
    end)
end

function RAID:HandleClose(payload, sender)
    local id = strsplit(";", payload)
    if not id then return end
    local group = self.activeGroups[id]
    if not group then return end
    -- Nur Ersteller darf schliessen
    if group.creator ~= sender then return end
    self.activeGroups[id] = nil
    -- Hatte ich diese Gruppe angefragt? Infos aufraeumen
    self:RefreshList()
end

-- ============================================================
-- Anfragen / Annahme / Ablehnung
-- ============================================================

-- Ich will einer Gruppe beitreten
function RAID:RequestJoin(groupId)
    local group = self.activeGroups[groupId]
    if not group then
        LunaWolves:Print("Gruppe nicht mehr verfuegbar.")
        return
    end
    if group.creator == LunaWolves.playerName then
        LunaWolves:Print("Das ist deine eigene Gruppe.")
        return
    end

    local _, classFile = UnitClass("player")
    local specIndex = GetSpecialization and GetSpecialization()
    local specName = ""
    if specIndex and GetSpecializationInfo then
        specName = select(2, GetSpecializationInfo(specIndex)) or ""
    end

    local payload = table.concat({
        groupId,
        LunaWolves.playerName,
        classFile or "UNKNOWN",
        specName,
    }, ";")
    -- Whisper an den Ersteller (kein Gildenchat-Spam)
    LunaWolves:SendMessage("WHISPER", "RAID", "REQUEST", payload, group.creator)

    if group.autoAccept then
        LunaWolves:Print("Beitrittsanfrage an " .. group.creator .. " gesendet (Auto-Annahme).")
    else
        LunaWolves:Print("Beitrittsanfrage an " .. group.creator .. " gesendet.")
    end
end

-- Ersteller empfaengt eine Anfrage
function RAID:HandleRequest(payload, sender)
    local groupId, player, class, spec = strsplit(";", payload)
    if not groupId or not player then return end

    -- Nur verarbeiten wenn es meine Gruppe ist
    if groupId ~= self.myGroupId then return end
    local group = self.activeGroups[groupId]
    if not group then return end

    -- Doppelanfrage: Bereits Mitglied? Dann direkt wieder ACCEPT senden
    if group.members[player] then
        LunaWolves:SendMessage("WHISPER", "RAID", "ACCEPT", groupId, player)
        C_PartyInfo.InviteUnit(player)
        return
    end

    if group.autoAccept then
        self:AcceptRequest(player, class, spec)
    else
        -- In Pending-Liste aufnehmen und Popup anzeigen
        self.pendingRequests[player] = {
            groupId = groupId,
            class = class or "UNKNOWN",
            spec = spec or "",
            timestamp = time(),
        }
        self:ShowRequestPopup(player, class, spec)
        LunaWolves:Print(player .. " moechte deiner Gruppe beitreten.")
        self:RefreshManager()
    end
end

-- Ersteller nimmt eine Anfrage an (Auto oder manuell)
function RAID:AcceptRequest(player, class, spec)
    if not self.myGroupId then return end
    local group = self.activeGroups[self.myGroupId]
    if not group then return end

    -- Falls aus Pending: Daten von dort holen
    local pending = self.pendingRequests[player]
    if pending then
        class = class or pending.class
        spec = spec or pending.spec
        self.pendingRequests[player] = nil
    end

    group.members[player] = {
        class = class or "UNKNOWN",
        spec = spec or "",
        timestamp = time(),
    }

    LunaWolves:SendMessage("WHISPER", "RAID", "ACCEPT", group.id, player)
    C_PartyInfo.InviteUnit(player)

    LunaWolves:Print(player .. " angenommen und eingeladen.")
    self:RefreshManager()
end

function RAID:RejectRequest(player)
    if not self.myGroupId then return end
    local pending = self.pendingRequests[player]
    if not pending then return end
    LunaWolves:SendMessage("WHISPER", "RAID", "REJECT", pending.groupId .. ";voll", player)
    self.pendingRequests[player] = nil
    LunaWolves:Print(player .. " abgelehnt.")
    self:RefreshManager()
end

-- Ich als Anfragender empfange ACCEPT
function RAID:HandleAccept(payload, sender)
    local groupId = strsplit(";", payload)
    local group = self.activeGroups[groupId]
    local title = group and group.title or "Gruppe"
    LunaWolves:Print(sender .. " hat dich in '" .. title .. "' aufgenommen.")
    -- Die Einladung kommt automatisch via InviteUnit beim Sender
end

-- Ich als Anfragender empfange REJECT
function RAID:HandleReject(payload, sender)
    local groupId, reason = strsplit(";", payload)
    local group = self.activeGroups[groupId]
    local title = group and group.title or "Gruppe"
    LunaWolves:Print(sender .. " hat deine Anfrage fuer '" .. title .. "' abgelehnt" ..
        (reason and reason ~= "" and (" (" .. reason .. ")") or "") .. ".")
end

-- ============================================================
-- Cleanup
-- ============================================================

function RAID:PruneGroups()
    local now = time()
    local changed = false
    for id, group in pairs(self.activeGroups) do
        if (now - group.timestamp) > GROUP_TIMEOUT then
            self.activeGroups[id] = nil
            if self.myGroupId == id then
                self.myGroupId = nil
            end
            changed = true
        end
    end
    if changed then self:RefreshList() end
end

-- ============================================================
-- Slash-Kommandos
-- ============================================================

function RAID:HandleSlash(input)
    local cmd, rest = strsplit(" ", input or "", 2)
    cmd = (cmd or ""):lower()

    if cmd == "create" then
        -- Mit Titel direkt anlegen (als PARTY, kein Auto-Accept)
        if rest and rest ~= "" then
            self:CreateGroup("PARTY", rest, false)
        else
            self:ShowCreateDialog()
        end
    elseif cmd == "close" then
        self:CloseMyGroup(false)
    elseif cmd == "list" then
        self:ShowGroupList()
    elseif cmd == "refresh" then
        LunaWolves:SendMessage("GUILD", "RAID", "LISTREQ", "")
        LunaWolves:Print("Gruppen-Liste wird aktualisiert...")
    else
        -- Ohne Subkommando: Gruppen-Liste anzeigen
        self:ShowGroupList()
    end
end

-- ============================================================
-- UI: Gruppen-Liste
-- ============================================================

local function StyleFrame(f, r, g, b)
    f:SetBackdrop({
        bgFile = SOLID,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.1, 0.1, 0.15, 0.95)
    f:SetBackdropBorderColor(r or 0.4, g or 0.4, b or 0.6, 1)
end

function RAID:CreateListUI()
    if self.listFrame then return end

    local ROW_HEIGHT = 28
    local MAX_ROWS = 10

    local f = CreateFrame("Frame", "LunaWolves_GroupList", UIParent, "BackdropTemplate")
    f:SetSize(460, ROW_HEIGHT * MAX_ROWS + 110)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    StyleFrame(f)
    f:Hide()
    self.listFrame = f

    -- Titel
    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -10)
    f.titleText:SetText("|cff8888ffGilden-Gruppensuche|r")

    -- Schliessen
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Header
    local h1 = f:CreateFontString(nil, "OVERLAY")
    h1:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    h1:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -38)
    h1:SetText("Ersteller")
    h1:SetTextColor(0.8, 0.8, 0.4)

    local h2 = f:CreateFontString(nil, "OVERLAY")
    h2:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    h2:SetPoint("TOPLEFT", f, "TOPLEFT", 140, -38)
    h2:SetText("Typ")
    h2:SetTextColor(0.8, 0.8, 0.4)

    local h3 = f:CreateFontString(nil, "OVERLAY")
    h3:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    h3:SetPoint("TOPLEFT", f, "TOPLEFT", 195, -38)
    h3:SetText("Titel")
    h3:SetTextColor(0.8, 0.8, 0.4)

    local h4 = f:CreateFontString(nil, "OVERLAY")
    h4:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    h4:SetPoint("TOPLEFT", f, "TOPLEFT", 310, -38)
    h4:SetText("Slots")
    h4:SetTextColor(0.8, 0.8, 0.4)

    -- Zeilen
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(420, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -52 - ((i - 1) * ROW_HEIGHT))

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(row)
        bg:SetColorTexture(0.2, 0.2, 0.3, 0.3)
        row.bg = bg

        row.creatorText = row:CreateFontString(nil, "OVERLAY")
        row.creatorText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.creatorText:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.creatorText:SetWidth(120)
        row.creatorText:SetJustifyH("LEFT")

        row.typeText = row:CreateFontString(nil, "OVERLAY")
        row.typeText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.typeText:SetPoint("LEFT", row, "LEFT", 125, 0)
        row.typeText:SetWidth(55)
        row.typeText:SetJustifyH("LEFT")

        row.titleText = row:CreateFontString(nil, "OVERLAY")
        row.titleText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.titleText:SetPoint("LEFT", row, "LEFT", 180, 0)
        row.titleText:SetWidth(115)
        row.titleText:SetJustifyH("LEFT")

        row.slotsText = row:CreateFontString(nil, "OVERLAY")
        row.slotsText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.slotsText:SetPoint("LEFT", row, "LEFT", 295, 0)
        row.slotsText:SetWidth(55)
        row.slotsText:SetJustifyH("LEFT")
        row.slotsText:SetTextColor(0.7, 0.7, 0.7)

        -- Aktions-Button
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(75, 22)
        btn:SetPoint("RIGHT", row, "RIGHT", -3, 0)
        row.actionBtn = btn

        row:Hide()
        f.rows[i] = row
    end

    -- Unten: Buttons
    local createBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    createBtn:SetSize(140, 26)
    createBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 12)
    createBtn:SetText("Neue Gruppe")
    createBtn:SetScript("OnClick", function()
        RAID:ShowCreateDialog()
    end)

    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(110, 26)
    refreshBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
    refreshBtn:SetText("Aktualisieren")
    refreshBtn:SetScript("OnClick", function()
        LunaWolves:SendMessage("GUILD", "RAID", "LISTREQ", "")
    end)

    local closeBtn2 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn2:SetSize(110, 26)
    closeBtn2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 12)
    closeBtn2:SetText("Schliessen")
    closeBtn2:SetScript("OnClick", function()
        f:Hide()
    end)

    -- Auto-Refresh via OnUpdate (throttled)
    f.refreshTimer = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.refreshTimer = (self.refreshTimer or 0) + elapsed
        if self.refreshTimer >= LIST_AUTO_REFRESH then
            self.refreshTimer = 0
            RAID:RefreshList()
        end
    end)

    -- ESC schliesst
    table.insert(UISpecialFrames, "LunaWolves_GroupList")
end

function RAID:ShowGroupList()
    if not self.listFrame then self:CreateListUI() end
    -- Vorher aktualisieren: einmal LISTREQ broadcasten
    if IsInGuild() then
        LunaWolves:SendMessage("GUILD", "RAID", "LISTREQ", "")
    end
    self:RefreshList()
    self.listFrame:Show()
end

function RAID:RefreshList()
    local f = self.listFrame
    if not f or not f:IsShown() then return end

    -- Sortierte Liste erzeugen
    local list = {}
    for _, g in pairs(self.activeGroups) do
        table.insert(list, g)
    end
    table.sort(list, function(a, b) return a.timestamp > b.timestamp end)

    for i, row in ipairs(f.rows) do
        local g = list[i]
        if g then
            -- Ersteller (Klassenfarbe)
            row.creatorText:SetText(ClassColorCode(g.creatorClass) .. g.creator .. "|r")

            -- Typ
            if g.type == "RAID" then
                row.typeText:SetText("|cffff8800Raid|r")
            else
                row.typeText:SetText("|cff88ff88Gruppe|r")
            end

            -- Titel
            row.titleText:SetText(g.title or "")
            row.titleText:SetTextColor(1, 1, 1)

            -- Slots
            local memberCount = 0
            for _ in pairs(g.members) do memberCount = memberCount + 1 end
            -- +1 weil Ersteller auch zaehlt
            local total = memberCount + 1
            local max = g.type == "RAID" and 40 or 5
            row.slotsText:SetText(total .. "/" .. max .. (g.autoAccept and " |cff88ff88A|r" or ""))

            -- Action-Button: Eigene Gruppe -> Verwalten; sonst Beitreten/Anfragen
            row.actionBtn:SetScript("OnClick", nil)
            if g.creator == LunaWolves.playerName then
                row.actionBtn:SetText("Verwalten")
                row.actionBtn:Enable()
                row.actionBtn:SetScript("OnClick", function()
                    RAID:RefreshManager()
                    RAID.managerFrame:Show()
                end)
                row.bg:SetColorTexture(0.2, 0.3, 0.2, 0.5)
            else
                if g.autoAccept then
                    row.actionBtn:SetText("Beitreten")
                else
                    row.actionBtn:SetText("Anfragen")
                end
                row.actionBtn:Enable()
                local groupId = g.id
                row.actionBtn:SetScript("OnClick", function()
                    RAID:RequestJoin(groupId)
                end)
                row.bg:SetColorTexture(0.2, 0.2, 0.3, 0.3)
            end

            row:Show()
        else
            row:Hide()
        end
    end

    -- Leer-Hinweis
    if #list == 0 then
        if not f.emptyText then
            f.emptyText = f:CreateFontString(nil, "OVERLAY")
            f.emptyText:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
            f.emptyText:SetPoint("CENTER", f, "CENTER", 0, 0)
            f.emptyText:SetTextColor(0.6, 0.6, 0.6)
        end
        f.emptyText:SetText("Keine aktiven Gruppen.\nErstelle selbst eine!")
        f.emptyText:Show()
    elseif f.emptyText then
        f.emptyText:Hide()
    end
end

-- ============================================================
-- UI: Erstell-Dialog
-- ============================================================

function RAID:CreateCreateUI()
    if self.createFrame then return end

    local f = CreateFrame("Frame", "LunaWolves_GroupCreate", UIParent, "BackdropTemplate")
    f:SetSize(360, 300)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    StyleFrame(f, 0.5, 0.5, 0.8)
    f:Hide()
    self.createFrame = f

    -- Titel
    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    title:SetPoint("TOP", f, "TOP", 0, -12)
    title:SetText("|cff8888ffNeue Gruppe erstellen|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Typ-Auswahl
    local typeLabel = f:CreateFontString(nil, "OVERLAY")
    typeLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    typeLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -45)
    typeLabel:SetText("Typ:")
    typeLabel:SetTextColor(0.8, 0.8, 0.4)

    local partyRadio = CreateFrame("CheckButton", nil, f, "UIRadioButtonTemplate")
    partyRadio:SetPoint("TOPLEFT", typeLabel, "BOTTOMLEFT", 0, -5)
    partyRadio.text = partyRadio:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    partyRadio.text:SetPoint("LEFT", partyRadio, "RIGHT", 2, 0)
    partyRadio.text:SetText("5-Spieler-Gruppe")
    partyRadio:SetChecked(true)

    local raidRadio = CreateFrame("CheckButton", nil, f, "UIRadioButtonTemplate")
    raidRadio:SetPoint("TOPLEFT", partyRadio, "BOTTOMLEFT", 0, -2)
    raidRadio.text = raidRadio:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    raidRadio.text:SetPoint("LEFT", raidRadio, "RIGHT", 2, 0)
    raidRadio.text:SetText("Schlachtzug (>5 Spieler)")

    partyRadio:SetScript("OnClick", function()
        partyRadio:SetChecked(true)
        raidRadio:SetChecked(false)
    end)
    raidRadio:SetScript("OnClick", function()
        raidRadio:SetChecked(true)
        partyRadio:SetChecked(false)
    end)
    f.partyRadio = partyRadio
    f.raidRadio = raidRadio

    -- Titel-Eingabe
    local titleLabel = f:CreateFontString(nil, "OVERLAY")
    titleLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    titleLabel:SetPoint("TOPLEFT", raidRadio, "BOTTOMLEFT", 0, -15)
    titleLabel:SetText("Titel:")
    titleLabel:SetTextColor(0.8, 0.8, 0.4)

    local titleEdit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    titleEdit:SetSize(280, 24)
    titleEdit:SetPoint("TOPLEFT", titleLabel, "BOTTOMLEFT", 8, -5)
    titleEdit:SetAutoFocus(false)
    titleEdit:SetMaxLetters(40)
    titleEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    titleEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.titleEdit = titleEdit

    -- Preset-Buttons
    local presets = { "Raid", "M+", "PvP", "Delve" }
    local prev = nil
    for i, preset in ipairs(presets) do
        local pBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        pBtn:SetSize(60, 20)
        if prev then
            pBtn:SetPoint("LEFT", prev, "RIGHT", 5, 0)
        else
            pBtn:SetPoint("TOPLEFT", titleEdit, "BOTTOMLEFT", -5, -5)
        end
        pBtn:SetText(preset)
        pBtn:SetScript("OnClick", function()
            titleEdit:SetText(preset)
        end)
        prev = pBtn
    end

    -- Auto-Accept-Checkbox
    local autoCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    autoCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -190)
    autoCheck.text = autoCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoCheck.text:SetPoint("LEFT", autoCheck, "RIGHT", 2, 0)
    autoCheck.text:SetText("Anfragen automatisch annehmen")
    f.autoCheck = autoCheck

    local autoDesc = f:CreateFontString(nil, "OVERLAY")
    autoDesc:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    autoDesc:SetPoint("TOPLEFT", autoCheck, "BOTTOMLEFT", 26, -2)
    autoDesc:SetText("|cff999999Neue Spieler werden sofort eingeladen.|r")

    -- Erstellen-Button
    local okBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    okBtn:SetSize(110, 26)
    okBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 15)
    okBtn:SetText("Erstellen")
    okBtn:SetScript("OnClick", function()
        local title = titleEdit:GetText()
        local groupType = raidRadio:GetChecked() and "RAID" or "PARTY"
        local autoAccept = autoCheck:GetChecked() and true or false
        if not title or title == "" then
            LunaWolves:Print("Bitte einen Titel eingeben.")
            return
        end
        RAID:CreateGroup(groupType, title, autoAccept)
        f:Hide()
    end)

    -- Abbrechen
    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(110, 26)
    cancelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 15)
    cancelBtn:SetText("Abbrechen")
    cancelBtn:SetScript("OnClick", function() f:Hide() end)

    table.insert(UISpecialFrames, "LunaWolves_GroupCreate")
end

function RAID:ShowCreateDialog()
    if not self.createFrame then self:CreateCreateUI() end
    local f = self.createFrame
    -- Standardwerte zuruecksetzen
    f.partyRadio:SetChecked(true)
    f.raidRadio:SetChecked(false)
    f.autoCheck:SetChecked(false)
    f.titleEdit:SetText("")
    f:Show()
    f.titleEdit:SetFocus()
end

-- ============================================================
-- UI: Manager-Fenster (fuer Ersteller)
-- ============================================================

function RAID:CreateManagerUI()
    if self.managerFrame then return end

    local ROW_HEIGHT = 22
    local MAX_ROWS = 15

    local f = CreateFrame("Frame", "LunaWolves_GroupManager", UIParent, "BackdropTemplate")
    f:SetSize(400, ROW_HEIGHT * MAX_ROWS + 140)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    StyleFrame(f, 0.5, 0.6, 0.4)
    f:Hide()
    self.managerFrame = f

    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -10)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Auto-Accept-Toggle (live aenderbar)
    local autoCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    autoCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -35)
    autoCheck.text = autoCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoCheck.text:SetPoint("LEFT", autoCheck, "RIGHT", 2, 0)
    autoCheck.text:SetText("Auto-Annahme aktiv")
    autoCheck:SetScript("OnClick", function(self)
        if RAID.myGroupId and RAID.activeGroups[RAID.myGroupId] then
            RAID.activeGroups[RAID.myGroupId].autoAccept = self:GetChecked() and true or false
            RAID:BroadcastAnnounce(RAID.activeGroups[RAID.myGroupId])
            -- Bei Aktivieren: alle pending Anfragen automatisch annehmen
            if self:GetChecked() then
                local toAccept = {}
                for player, req in pairs(RAID.pendingRequests) do
                    table.insert(toAccept, { player = player, class = req.class, spec = req.spec })
                end
                for _, r in ipairs(toAccept) do
                    RAID:AcceptRequest(r.player, r.class, r.spec)
                end
            end
            RAID:RefreshManager()
            RAID:RefreshList()
        end
    end)
    f.autoCheck = autoCheck

    f.countText = f:CreateFontString(nil, "OVERLAY")
    f.countText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    f.countText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -35)
    f.countText:SetTextColor(0.7, 0.7, 0.7)

    -- Zeilen
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(360, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -62 - ((i - 1) * ROW_HEIGHT))

        row.nameText = row:CreateFontString(nil, "OVERLAY")
        row.nameText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.nameText:SetPoint("LEFT", row, "LEFT", 5, 0)
        row.nameText:SetWidth(130)
        row.nameText:SetJustifyH("LEFT")

        row.specText = row:CreateFontString(nil, "OVERLAY")
        row.specText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.specText:SetPoint("LEFT", row.nameText, "RIGHT", 5, 0)
        row.specText:SetWidth(110)
        row.specText:SetJustifyH("LEFT")

        row.statusText = row:CreateFontString(nil, "OVERLAY")
        row.statusText:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
        row.statusText:SetPoint("LEFT", row.specText, "RIGHT", 0, 0)
        row.statusText:SetWidth(50)
        row.statusText:SetJustifyH("LEFT")

        local acceptBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        acceptBtn:SetSize(28, 20)
        acceptBtn:SetPoint("RIGHT", row, "RIGHT", -35, 0)
        acceptBtn:SetText("✓")
        row.acceptBtn = acceptBtn

        local rejectBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        rejectBtn:SetSize(28, 20)
        rejectBtn:SetPoint("RIGHT", row, "RIGHT", -3, 0)
        rejectBtn:SetText("✗")
        row.rejectBtn = rejectBtn

        row:Hide()
        f.rows[i] = row
    end

    -- Unten: Buttons
    local inviteAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    inviteAllBtn:SetSize(130, 26)
    inviteAllBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 12)
    inviteAllBtn:SetText("Alle einladen")
    inviteAllBtn:SetScript("OnClick", function()
        if not RAID.myGroupId then return end
        local group = RAID.activeGroups[RAID.myGroupId]
        if not group then return end
        local count = 0
        for name, _ in pairs(group.members) do
            C_PartyInfo.InviteUnit(name)
            count = count + 1
        end
        LunaWolves:Print(count .. " Mitglied" .. (count ~= 1 and "er" or "") .. " erneut eingeladen.")
    end)

    local closeGroupBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeGroupBtn:SetSize(140, 26)
    closeGroupBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 12)
    closeGroupBtn:SetText("Gruppe schliessen")
    closeGroupBtn:SetScript("OnClick", function()
        RAID:CloseMyGroup(false)
    end)

    table.insert(UISpecialFrames, "LunaWolves_GroupManager")
end

function RAID:RefreshManager()
    local f = self.managerFrame
    if not f then return end

    local group = self.myGroupId and self.activeGroups[self.myGroupId] or nil
    if not group then
        f.titleText:SetText("|cff8888ffGruppen-Manager|r")
        for _, row in ipairs(f.rows) do row:Hide() end
        f.countText:SetText("")
        return
    end

    f.titleText:SetText("|cff8888ff" .. group.title .. "|r |cff999999(" ..
        (group.type == "RAID" and "Schlachtzug" or "Gruppe") .. ")|r")
    f.autoCheck:SetChecked(group.autoAccept)

    -- Kombinierte Liste: Mitglieder + offene Anfragen
    local entries = {}
    for name, info in pairs(group.members) do
        table.insert(entries, {
            name = name, class = info.class, spec = info.spec,
            status = "MEMBER",
        })
    end
    for name, req in pairs(self.pendingRequests) do
        if req.groupId == group.id then
            table.insert(entries, {
                name = name, class = req.class, spec = req.spec,
                status = "PENDING",
            })
        end
    end
    -- Pending zuerst
    table.sort(entries, function(a, b)
        if a.status ~= b.status then return a.status == "PENDING" end
        return a.name < b.name
    end)

    local memberCount = 0
    for _ in pairs(group.members) do memberCount = memberCount + 1 end
    local pendingCount = 0
    for _ in pairs(self.pendingRequests) do pendingCount = pendingCount + 1 end
    f.countText:SetText(memberCount .. " Mitglieder, " .. pendingCount .. " Anfragen")

    for i, row in ipairs(f.rows) do
        local e = entries[i]
        if e then
            -- Name mit Klassenfarbe
            local color = CLASS_COLORS[e.class]
            if color then
                row.nameText:SetTextColor(color.r, color.g, color.b)
            else
                row.nameText:SetTextColor(1, 1, 1)
            end
            row.nameText:SetText(e.name)

            row.specText:SetText(e.spec or "")
            if color then
                row.specText:SetTextColor(color.r, color.g, color.b, 0.7)
            else
                row.specText:SetTextColor(0.7, 0.7, 0.7)
            end

            if e.status == "PENDING" then
                row.statusText:SetText("|cffffaa00wartet|r")
                row.acceptBtn:Show()
                row.rejectBtn:Show()
                local playerName = e.name
                local class = e.class
                local spec = e.spec
                row.acceptBtn:SetScript("OnClick", function()
                    RAID:AcceptRequest(playerName, class, spec)
                end)
                row.rejectBtn:SetScript("OnClick", function()
                    RAID:RejectRequest(playerName)
                end)
            else
                row.statusText:SetText("|cff88ff88in Gruppe|r")
                row.acceptBtn:Hide()
                row.rejectBtn:Hide()
            end

            row:Show()
        else
            row:Hide()
        end
    end
end

-- ============================================================
-- UI: Anfrage-Popup (nur bei manueller Annahme)
-- ============================================================

function RAID:CreateRequestUI()
    if self.requestPopup then return end

    local f = CreateFrame("Frame", "LunaWolves_GroupRequest", UIParent, "BackdropTemplate")
    f:SetSize(320, 110)
    f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    StyleFrame(f, 0.3, 0.3, 0.8)
    f:Hide()
    self.requestPopup = f

    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -10)
    f.titleText:SetText("|cff8888ffBeitrittsanfrage|r")

    f.infoText = f:CreateFontString(nil, "OVERLAY")
    f.infoText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    f.infoText:SetPoint("TOP", f, "TOP", 0, -32)

    local acceptBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    acceptBtn:SetSize(100, 26)
    acceptBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 30, 12)
    acceptBtn:SetText("Annehmen")
    f.acceptBtn = acceptBtn

    local rejectBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    rejectBtn:SetSize(100, 26)
    rejectBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 12)
    rejectBtn:SetText("Ablehnen")
    f.rejectBtn = rejectBtn
end

function RAID:ShowRequestPopup(player, class, spec)
    if not self.requestPopup then self:CreateRequestUI() end
    local f = self.requestPopup

    local color = ClassColorCode(class)
    local specPart = (spec and spec ~= "" and (spec .. " ") or "")
    f.infoText:SetText(color .. player .. "|r\n" .. specPart .. (class or ""))

    f.acceptBtn:SetScript("OnClick", function()
        RAID:AcceptRequest(player, class, spec)
        f:Hide()
    end)
    f.rejectBtn:SetScript("OnClick", function()
        RAID:RejectRequest(player)
        f:Hide()
    end)

    f:Show()
    PlaySound(SOUNDKIT.READY_CHECK)

    -- Auto-Hide nach 60 Sekunden
    if f.hideTimer then f.hideTimer:Cancel() end
    f.hideTimer = C_Timer.NewTimer(60, function() f:Hide() end)
end

-- ============================================================
-- Modul registrieren
-- ============================================================

LunaWolves:RegisterModule("RAID", RAID)
