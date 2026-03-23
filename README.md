# LunaWolves

Gilden-Addon fuer **The Last Luna Wolves** (World of Warcraft Retail).

## Features

### DKP-Punkteverwaltung
- Punkte vergeben/abziehen mit Grund und History
- Automatische DKP-Vergabe bei Bosskills
- Lifetime-Punkte-Tracking
- Multi-Officer-Synchronisation ueber Addon-Messages
- Kontextmenue per Rechtsklick auf Spieler

### Raid-Einladungssystem
- Raid-Events erstellen mit Titel und optionalem Datum
- Gildenmitglieder erhalten ein Popup zur Anmeldung
- Angemeldete Spieler koennen per Klick eingeladen werden
- Klassen- und Spezialisierungs-Anzeige

### Allgemein
- Minimap-Icon mit Gilden-Logo (verschiebbar)
- Options-Panel unter ESC > Optionen > Addons
- Modularer Aufbau fuer einfache Erweiterbarkeit

## Installation

1. Den `LunaWolves`-Ordner nach `World of Warcraft/_retail_/Interface/AddOns/` kopieren
2. WoW starten oder `/reload` im Chat eingeben
3. Alle Gildenmitglieder muessen das Addon installiert haben, damit Sync und Raid-Einladungen funktionieren

## Befehle

| Befehl | Beschreibung |
|---|---|
| `/lw` | Hilfe anzeigen |
| `/lw dkp` | DKP-Fenster oeffnen |
| `/lw dkp show [Name]` | DKP eines Spielers anzeigen |
| `/lw dkp add Name Anzahl Grund` | Punkte vergeben |
| `/lw dkp sub Name Anzahl Grund` | Punkte abziehen |
| `/lw dkp sync` | Sync erzwingen |
| `/lw dkp history [Name]` | History anzeigen |
| `/lw raid` | Raid-Verwaltung oeffnen |
| `/lw raid create Titel` | Raid-Event erstellen |
| `/lw raid close` | Anmeldungen schliessen |
| `/lw ranks` | Gildenraenge anzeigen |
| `/lw officer <rang>` | Officer-Rang-Schwelle setzen |

## Berechtigungen

DKP-Aenderungen und Raid-Events koennen nur von Officeren durchgefuehrt werden. Standardmaessig gelten Rang 0 (Gildenmeister) und 1 als Officer. Die Schwelle kann mit `/lw officer <rang>` angepasst werden -- `/lw ranks` zeigt alle Raenge.

## Projektstruktur

```
LunaWolves/
  Core.lua              -- Kern: Events, Slash-Commands, Minimap, Options
  Modules/
    DKP.lua             -- DKP-Punkteverwaltung
    RaidInvite.lua      -- Raid-Einladungssystem
  icon.tga              -- Minimap-Icon (Gilden-Logo)
  LunaWolves.toc        -- Addon-Manifest
```

## Lizenz

[MIT](LICENSE)
