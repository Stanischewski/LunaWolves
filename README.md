# LunaWolves

WoW-Addon fuer die Gilde **The Last Luna Wolves**.

## Features

- **DKP-Verwaltung** – Punkte vergeben, abziehen und einsehen direkt im Spiel
- **Raid-Einladungssystem** – Raid-Events erstellen, Mitglieder werden benachrichtigt und koennen per Klick beitreten
- **Minimap-Icon** – Schnellzugriff auf alle Funktionen
- **Multi-Officer-Sync** – DKP-Daten werden automatisch zwischen Officers synchronisiert

## Installation

### Mit WowUp (empfohlen)
1. [WowUp](https://wowup.io/) installieren
2. In WowUp: **Get Addons** > GitHub-URL eingeben: `https://github.com/Stanischewski/LunaWolves`
3. Installieren – fertig! Updates kommen automatisch.

### Manuell
1. Neuestes Release herunterladen: [Releases](https://github.com/Stanischewski/LunaWolves/releases)
2. ZIP entpacken
3. Den Ordner `LunaWolves` nach `World of Warcraft/_retail_/Interface/AddOns/` kopieren
4. WoW neu starten

## Befehle

| Befehl | Beschreibung |
|--------|-------------|
| `/lw` | Hilfe anzeigen |
| `/lw dkp` | DKP-Fenster oeffnen |
| `/lw dkp show [Name]` | DKP eines Spielers anzeigen |
| `/lw dkp add Name Anzahl Grund` | Punkte vergeben |
| `/lw dkp sub Name Anzahl Grund` | Punkte abziehen |
| `/lw dkp history [Name]` | History anzeigen |
| `/lw dkp sync` | Sync erzwingen |
| `/lw raid` | Raid-Verwaltung oeffnen |
| `/lw raid create Titel` | Raid-Event erstellen |
| `/lw raid close` | Anmeldungen schliessen |
| `/lw ranks` | Gildenraenge anzeigen |
| `/lw officer <rang>` | Officer-Rang-Schwelle setzen |

## Lizenz

[MIT](LICENSE)
