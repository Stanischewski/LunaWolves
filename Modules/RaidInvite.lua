-- Modules/RaidInvite.lua
-- LunaWolves Raid-Einladungsmodul: Events erstellen, Anmeldungen, Einladungen

local RAID = {}

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

-- ============================================================
-- Initialisierung
-- ============================================================

function RAID:OnInitialize()
    -- Wird beim RegisterModule aufgerufen
end

function RAID:OnEnable()
    LunaWolvesDB.RaidInvite = LunaWolvesDB.RaidInvite or {}

    -- Aktives Event (als Raidleiter)
    self.activeEvent = nil
    -- Empfangenes Event (als Mitglied)
    self.receivedEvent = nil
    -- Anmeldungen fuer aktives Event
    self.signups = {}

    -- UI vorbereiten
    self:CreatePopupUI()
    self:CreateManagerUI()
end

-- ============================================================
-- Nachrichtenverarbeitung
-- ============================================================

function RAID:OnMessage(command, payload, sender, channel)
    if command == "OPEN" then
        self:HandleOpen(payload, sender)
    elseif command == "JOIN" then
        self:HandleJoin(payload, sender)
    elseif command == "LEAVE" then
        self:HandleLeave(payload, sender)
    elseif command == "CLOSE" then
        self:HandleClose(payload, sender)
    end
end

-- ============================================================
-- Raid-Event erstellen (Raidleiter)
-- ============================================================

function RAID:CreateEvent(title)
    if not LunaWolves:IsOfficer() then
        LunaWolves:Print("Nur Officers koennen Raid-Events erstellen.")
        return
    end

    if not title or title == "" then
        LunaWolves:Print("Syntax: /lw raid create <Titel>")
        return
    end

    local eventId = LunaWolves.playerName .. "-" .. time() .. "-" .. math.random(1000, 9999)

    self.activeEvent = {
        id = eventId,
        title = title,
        leader = LunaWolves.playerName,
        timestamp = time(),
    }
    wipe(self.signups)

    -- An Gilde broadcasten
    local payload = table.concat({ eventId, title, LunaWolves.playerName, tostring(time()) }, ";")
    LunaWolves:SendMessage("GUILD", "RAID", "OPEN", payload)

    LunaWolves:Print("Raid-Event erstellt: " .. title)
    LunaWolves:Print("Warte auf Anmeldungen...")

    -- Manager-UI oeffnen
    self:RefreshManager()
    self.managerFrame:Show()
end

-- ============================================================
-- Eingehende Events verarbeiten
-- ============================================================

-- Mitglied empfaengt OPEN
function RAID:HandleOpen(payload, sender)
    local eventId, title, leader, ts = strsplit(";", payload)

    -- Bin ich selbst der Leader? Dann ignorieren
    if leader == LunaWolves.playerName then return end

    self.receivedEvent = {
        id = eventId,
        title = title,
        leader = leader,
        timestamp = tonumber(ts) or time(),
    }

    -- Popup anzeigen
    self:ShowPopup(title, leader)
    LunaWolves:Print("Raid-Einladung von " .. leader .. ": " .. title)
end

-- Raidleiter empfaengt JOIN
function RAID:HandleJoin(payload, sender)
    local eventId, playerName, class, spec = strsplit(";", payload)

    -- Nur verarbeiten wenn wir ein aktives Event haben
    if not self.activeEvent or self.activeEvent.id ~= eventId then return end

    -- Duplikat pruefen
    for _, signup in ipairs(self.signups) do
        if signup.name == playerName then return end
    end

    table.insert(self.signups, {
        name = playerName,
        class = class or "UNKNOWN",
        spec = spec or "",
        selected = true,  -- Standard: ausgewaehlt
    })

    LunaWolves:Print(playerName .. " (" .. (spec or "") .. " " .. (class or "") .. ") hat sich angemeldet.")

    -- Manager-UI aktualisieren
    if self.managerFrame and self.managerFrame:IsShown() then
        self:RefreshManager()
    end
end

-- Raidleiter empfaengt LEAVE
function RAID:HandleLeave(payload, sender)
    local eventId, playerName = strsplit(";", payload)
    if not self.activeEvent or self.activeEvent.id ~= eventId then return end

    for i, signup in ipairs(self.signups) do
        if signup.name == playerName then
            table.remove(self.signups, i)
            LunaWolves:Print(playerName .. " hat sich abgemeldet.")
            break
        end
    end

    if self.managerFrame and self.managerFrame:IsShown() then
        self:RefreshManager()
    end
end

-- Mitglied empfaengt CLOSE
function RAID:HandleClose(payload, sender)
    local eventId = strsplit(";", payload)
    if self.receivedEvent and self.receivedEvent.id == eventId then
        self.receivedEvent = nil
        if self.popupFrame then
            self.popupFrame:Hide()
        end
        LunaWolves:Print("Raid-Anmeldung wurde geschlossen.")
    end
end

-- ============================================================
-- Mitglied: Beitreten / Ablehnen
-- ============================================================

function RAID:JoinEvent()
    if not self.receivedEvent then return end

    local _, classFile = UnitClass("player")
    local specIndex = GetSpecialization()
    local specName = specIndex and select(2, GetSpecializationInfo(specIndex)) or ""

    local payload = table.concat({
        self.receivedEvent.id,
        LunaWolves.playerName,
        classFile or "UNKNOWN",
        specName,
    }, ";")
    LunaWolves:SendMessage("GUILD", "RAID", "JOIN", payload)

    LunaWolves:Print("Du hast dich fuer '" .. self.receivedEvent.title .. "' angemeldet.")
    if self.popupFrame then
        self.popupFrame:Hide()
    end
end

function RAID:LeaveEvent()
    if not self.receivedEvent then return end

    local payload = table.concat({
        self.receivedEvent.id,
        LunaWolves.playerName,
    }, ";")
    LunaWolves:SendMessage("GUILD", "RAID", "LEAVE", payload)

    LunaWolves:Print("Du hast dich abgemeldet.")
    if self.popupFrame then
        self.popupFrame:Hide()
    end
end

-- ============================================================
-- Raidleiter: Event schliessen
-- ============================================================

function RAID:CloseEvent()
    if not self.activeEvent then
        LunaWolves:Print("Kein aktives Raid-Event.")
        return
    end

    LunaWolves:SendMessage("GUILD", "RAID", "CLOSE", self.activeEvent.id)
    LunaWolves:Print("Raid-Event '" .. self.activeEvent.title .. "' geschlossen.")
    self.activeEvent = nil
    wipe(self.signups)

    if self.managerFrame then
        self.managerFrame:Hide()
    end
end

-- ============================================================
-- Raidleiter: Ausgewaehlte Spieler einladen
-- ============================================================

function RAID:InviteSelected()
    local count = 0
    for _, signup in ipairs(self.signups) do
        if signup.selected then
            C_PartyInfo.InviteUnit(signup.name)
            count = count + 1
        end
    end
    if count > 0 then
        LunaWolves:Print(count .. " Spieler eingeladen.")
    else
        LunaWolves:Print("Keine Spieler ausgewaehlt.")
    end
end

-- ============================================================
-- Slash-Kommandos
-- ============================================================

function RAID:HandleSlash(input)
    local cmd, rest = strsplit(" ", input or "", 2)
    cmd = (cmd or ""):lower()

    if cmd == "create" then
        self:CreateEvent(rest)
    elseif cmd == "close" then
        self:CloseEvent()
    elseif cmd == "list" then
        if not self.activeEvent then
            LunaWolves:Print("Kein aktives Raid-Event.")
            return
        end
        LunaWolves:Print("--- Anmeldungen fuer " .. self.activeEvent.title .. " ---")
        if #self.signups == 0 then
            LunaWolves:Print("Noch keine Anmeldungen.")
        else
            for i, s in ipairs(self.signups) do
                LunaWolves:Print(i .. ". " .. s.name .. " (" .. s.spec .. " " .. s.class .. ")")
            end
        end
    else
        -- Kein Subkommando: Manager-UI oeffnen/togglen
        if self.activeEvent then
            if self.managerFrame:IsShown() then
                self.managerFrame:Hide()
            else
                self:RefreshManager()
                self.managerFrame:Show()
            end
        else
            LunaWolves:Print("Kein aktives Raid-Event. Erstelle eins mit: /lw raid create <Titel>")
        end
    end
end

-- ============================================================
-- UI: Popup fuer Gildenmitglieder
-- ============================================================

function RAID:CreatePopupUI()
    if self.popupFrame then return end

    local f = CreateFrame("Frame", "LunaWolves_RaidPopup", UIParent, "BackdropTemplate")
    f:SetSize(320, 120)
    f:SetPoint("TOP", UIParent, "TOP", 0, -100)
    f:SetFrameStrata("DIALOG")
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
    f:SetBackdropColor(0.1, 0.1, 0.2, 0.95)
    f:SetBackdropBorderColor(0.3, 0.3, 0.8, 1)
    f:Hide()
    self.popupFrame = f

    -- Titel
    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -12)
    f.titleText:SetTextColor(0.5, 0.5, 1)

    -- Info-Text
    f.infoText = f:CreateFontString(nil, "OVERLAY")
    f.infoText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    f.infoText:SetPoint("TOP", f, "TOP", 0, -35)
    f.infoText:SetTextColor(1, 1, 1)

    -- Beitreten-Button
    local joinBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    joinBtn:SetSize(110, 28)
    joinBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 30, 15)
    joinBtn:SetText("Beitreten")
    joinBtn:SetScript("OnClick", function()
        RAID:JoinEvent()
    end)

    -- Ablehnen-Button
    local declineBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    declineBtn:SetSize(110, 28)
    declineBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 15)
    declineBtn:SetText("Ablehnen")
    declineBtn:SetScript("OnClick", function()
        f:Hide()
    end)

    -- Auto-Hide Timer
    f.hideTimer = nil
end

function RAID:ShowPopup(title, leader)
    local f = self.popupFrame
    f.titleText:SetText("|cff8888ffRaid-Einladung|r")
    f.infoText:SetText(title .. "\nRaidleiter: " .. leader)
    f:Show()

    -- Auto-Hide nach 5 Minuten
    if f.hideTimer then
        f.hideTimer:Cancel()
    end
    f.hideTimer = C_Timer.NewTimer(300, function()
        f:Hide()
    end)

    -- Sound abspielen
    PlaySound(SOUNDKIT.READY_CHECK)
end

-- ============================================================
-- UI: Manager-Frame fuer Raidleiter
-- ============================================================

function RAID:CreateManagerUI()
    if self.managerFrame then return end

    local ROW_HEIGHT = 22
    local MAX_ROWS = 20

    local f = CreateFrame("Frame", "LunaWolves_RaidManager", UIParent, "BackdropTemplate")
    f:SetSize(350, ROW_HEIGHT * MAX_ROWS + 110)
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
    self.managerFrame = f

    -- Titel
    f.titleText = f:CreateFontString(nil, "OVERLAY")
    f.titleText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    f.titleText:SetPoint("TOP", f, "TOP", 0, -10)

    -- Schliessen-Button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)

    -- Anmeldungen-Header
    local header = f:CreateFontString(nil, "OVERLAY")
    header:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -35)
    header:SetText("Anmeldungen:")
    header:SetTextColor(0.8, 0.8, 0.4)

    -- Anzahl-Anzeige
    f.countText = f:CreateFontString(nil, "OVERLAY")
    f.countText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    f.countText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -35)
    f.countText:SetTextColor(0.7, 0.7, 0.7)

    -- Zeilen fuer Anmeldungen
    f.rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("CheckButton", nil, f)
        row:SetSize(300, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -50 - ((i - 1) * ROW_HEIGHT))

        -- Checkbox
        local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        cb:SetPoint("LEFT", row, "LEFT", 0, 0)
        cb:SetScript("OnClick", function(self)
            if row.signupIndex then
                RAID.signups[row.signupIndex].selected = self:GetChecked()
            end
        end)
        row.checkbox = cb

        -- Name
        row.nameText = row:CreateFontString(nil, "OVERLAY")
        row.nameText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.nameText:SetPoint("LEFT", cb, "RIGHT", 5, 0)
        row.nameText:SetWidth(120)
        row.nameText:SetJustifyH("LEFT")

        -- Klasse/Spec
        row.classText = row:CreateFontString(nil, "OVERLAY")
        row.classText:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
        row.classText:SetPoint("LEFT", row.nameText, "RIGHT", 10, 0)
        row.classText:SetWidth(150)
        row.classText:SetJustifyH("LEFT")

        row.signupIndex = nil
        row:Hide()
        f.rows[i] = row
    end

    -- Einladen-Button
    local inviteBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    inviteBtn:SetSize(110, 26)
    inviteBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 10)
    inviteBtn:SetText("Einladen")
    inviteBtn:SetScript("OnClick", function()
        RAID:InviteSelected()
    end)

    -- Schliessen-Button (Event beenden)
    local closeEventBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeEventBtn:SetSize(140, 26)
    closeEventBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 10)
    closeEventBtn:SetText("Event schliessen")
    closeEventBtn:SetScript("OnClick", function()
        RAID:CloseEvent()
    end)

    -- Alle auswaehlen / keine auswaehlen
    local selectAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    selectAllBtn:SetSize(110, 22)
    selectAllBtn:SetPoint("BOTTOM", inviteBtn, "TOP", 0, 5)
    selectAllBtn:SetText("Alle waehlen")
    selectAllBtn:SetScript("OnClick", function()
        local allSelected = true
        for _, s in ipairs(RAID.signups) do
            if not s.selected then allSelected = false; break end
        end
        for _, s in ipairs(RAID.signups) do
            s.selected = not allSelected
        end
        RAID:RefreshManager()
    end)

    -- ESC schliesst
    table.insert(UISpecialFrames, "LunaWolves_RaidManager")
end

function RAID:RefreshManager()
    local f = self.managerFrame
    if not f then return end

    if self.activeEvent then
        f.titleText:SetText("|cff8888ffRaid:|r " .. self.activeEvent.title)
    else
        f.titleText:SetText("|cff8888ffRaid-Manager|r")
    end

    f.countText:SetText(#self.signups .. " Anmeldung" .. (#self.signups ~= 1 and "en" or ""))

    for i = 1, #f.rows do
        local row = f.rows[i]
        if i <= #self.signups then
            local signup = self.signups[i]
            row.signupIndex = i
            row.checkbox:SetChecked(signup.selected)

            -- Name mit Klassenfarbe
            local color = CLASS_COLORS[signup.class]
            if color then
                row.nameText:SetTextColor(color.r, color.g, color.b)
            else
                row.nameText:SetTextColor(1, 1, 1)
            end
            row.nameText:SetText(signup.name)

            -- Klasse und Spec
            local classSpec = signup.spec
            if signup.class and signup.class ~= "UNKNOWN" then
                classSpec = classSpec .. " " .. signup.class
            end
            row.classText:SetText(classSpec)
            if color then
                row.classText:SetTextColor(color.r, color.g, color.b, 0.7)
            else
                row.classText:SetTextColor(0.7, 0.7, 0.7)
            end

            row:Show()
        else
            row.signupIndex = nil
            row:Hide()
        end
    end
end

-- ============================================================
-- Modul registrieren
-- ============================================================

LunaWolves:RegisterModule("RAID", RAID)
