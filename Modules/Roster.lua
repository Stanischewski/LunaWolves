-- Modules/Roster.lua
-- Scannt den Gildenroster bei GUILD_ROSTER_UPDATE und schreibt ihn
-- in LunaWolvesDB.guild / .members fuer den Tauri-Upload-Agent.

local Roster = {}

local SCAN_COOLDOWN = 60   -- Sekunden Mindestabstand zwischen zwei Scans
local lastScanTime  = 0

-- ============================================================
-- Initialisierung
-- ============================================================

function Roster:OnInitialize() end

function Roster:OnEnable()
    LunaWolvesDB.version   = LunaWolvesDB.version   or 1
    LunaWolvesDB.scannedAt = LunaWolvesDB.scannedAt or 0
    LunaWolvesDB.guild     = LunaWolvesDB.guild     or {}
    LunaWolvesDB.members   = LunaWolvesDB.members   or {}

    self.eventFrame = CreateFrame("Frame")
    self.eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
    self.eventFrame:SetScript("OnEvent", function(_, event)
        if event == "GUILD_ROSTER_UPDATE" then
            Roster:DoScan()
        end
    end)

    if IsInGuild() then
        C_GuildInfo.GuildRoster()
    end
end

-- ============================================================
-- Roster-Scan
-- ============================================================

-- Ermittelt den Heimrealm der Gilde aus den Mitgliedernamen.
-- Auf Connected Realms liefert GetGuildInfo() einen leeren guildRealm —
-- Mitglieder vom Gilden-Heimrealm erscheinen dann als "Name-Realm".
local function DetectGuildRealm()
    local realmVotes = {}
    local numMembers = GetNumGuildMembers()
    for i = 1, math.min(numMembers, 20) do
        local name = GetGuildRosterInfo(i)
        if name then
            local _, r = strsplit("-", name)
            if r and r ~= "" then
                realmVotes[r] = (realmVotes[r] or 0) + 1
            end
        end
    end
    local bestRealm, bestCount = nil, 0
    for r, c in pairs(realmVotes) do
        if c > bestCount then
            bestRealm = r
            bestCount = c
        end
    end
    return bestRealm or GetRealmName()
end

function Roster:DoScan()
    if not IsInGuild() then return end

    local now = time()
    if now - lastScanTime < SCAN_COOLDOWN then return end
    lastScanTime = now

    local guildName, _, _, guildRealm = GetGuildInfo("player")
    if not guildName then return end

    -- Auf Connected Realms ist guildRealm leer; Mitgliedernamen scannen
    -- um den Heimrealm der Gilde zuverlässig zu bestimmen.
    local realm = (guildRealm and guildRealm ~= "") and guildRealm or DetectGuildRealm()

    LunaWolvesDB.guild = {
        name    = guildName,
        realm   = realm,
        faction = UnitFactionGroup("player"),
    }

    local playerName  = LunaWolves.playerName
    local playerRealm = LunaWolves.playerRealm or GetRealmName()
    local numMembers  = GetNumGuildMembers()
    local old         = LunaWolvesDB.members or {}
    local new         = {}

    for i = 1, numMembers do
        -- GetGuildRosterInfo: name, rankName, rankIndex, level,
        -- classDisplayName, zone, note, officerNote, isOnline, status,
        -- classFileName, achievementPoints, achievementRank, isMobile, ...
        local name, _, rankIndex, level, _, _, _, _, isOnline, _, classFile =
            GetGuildRosterInfo(i)

        if name and classFile then
            local charName, charRealm = strsplit("-", name)
            if not charRealm or charRealm == "" then
                -- Kein Realm-Suffix = Mitglied ist auf dem Realm des Viewers
                charRealm = GetRealmName()
            end

            local key   = charName .. "-" .. charRealm
            local entry = old[key] or {}

            -- lastSeen aktualisieren wenn online, sonst alten Wert behalten
            local lastSeen = entry.lastSeen
            if isOnline then lastSeen = now end
            lastSeen = lastSeen or now

            -- Item-Level: fuer eigenen Char direkt, fuer andere aus Versions-Daten
            local ilvl = entry.itemLevel
            if charName == playerName and charRealm == playerRealm then
                local _, equipped = GetAverageItemLevel()
                if equipped and equipped > 0 then
                    ilvl = math.floor(equipped)
                end
            else
                -- Versions-Modul broadcasted ilvl von Addon-Nutzern
                local vKey = charName .. "-" .. charRealm
                local verEntry = LunaWolvesDB.Versions and LunaWolvesDB.Versions[vKey]
                if verEntry and (verEntry.itemLevel or 0) > 0 then
                    ilvl = verEntry.itemLevel
                end
            end

            new[key] = {
                name      = charName,
                realm     = charRealm,
                class     = classFile,
                level     = level,
                guildRank = rankIndex,
                online    = isOnline and true or false,
                lastSeen  = lastSeen,
                itemLevel = ilvl,
            }
        end
    end

    LunaWolvesDB.members   = new
    LunaWolvesDB.scannedAt = now
    LunaWolvesDB.version   = 1

    LunaWolves:FireCallback("ROSTER_UPDATED", new)
end

-- ============================================================
-- Slash-Handler  (/lw roster [scan])
-- ============================================================

function Roster:HandleSlash(args)
    local cmd = (args or ""):lower():match("^(%S*)")

    if cmd == "scan" then
        lastScanTime = 0
        C_GuildInfo.GuildRoster()
        LunaWolves:Print("Roster-Scan angefordert...")
        return
    end

    local count = 0
    for _ in pairs(LunaWolvesDB.members or {}) do count = count + 1 end
    local ts  = LunaWolvesDB.scannedAt or 0
    local age = ts > 0 and (time() - ts) or -1
    if age < 0 then
        LunaWolves:Print("Roster: noch kein Scan durchgefuehrt.")
    else
        LunaWolves:Print(string.format("Roster: %d Mitglieder, letzter Scan vor %ds.", count, age))
    end
    LunaWolves:Print("'/lw roster scan' -- Scan sofort erzwingen")
end

-- ============================================================
-- Registrierung
-- ============================================================

LunaWolves:RegisterModule("ROSTER", Roster)
