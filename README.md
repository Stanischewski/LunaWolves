# LunaWolves

WoW-Addon fuer die Gilde **The Last Luna Wolves**.

## Features

- **DKP-Verwaltung** – Punkte vergeben, abziehen und einsehen direkt im Spiel
- **Raid-Einladungssystem** – Raid-Events erstellen, Mitglieder werden benachrichtigt und koennen per Klick beitreten
- **Minimap-Icon** – Schnellzugriff auf alle Funktionen
- **Multi-Officer-Sync** – DKP-Daten werden automatisch zwischen Officers synchronisiert

## Download

**[⬇ LunaWolves.zip herunterladen](https://github.com/Stanischewski/LunaWolves/releases/latest/download/LunaWolves.zip)**

Der Link zeigt immer auf die neueste Fassung — er bleibt also gueltig, auch
nach dem naechsten Release.

Alle Fassungen mit Aenderungsliste:
[Releases](https://github.com/Stanischewski/LunaWolves/releases)

## Installation

### Manuell
1. [LunaWolves.zip](https://github.com/Stanischewski/LunaWolves/releases/latest/download/LunaWolves.zip) herunterladen
2. ZIP entpacken — darin liegt ein Ordner `LunaWolves`
3. Diesen Ordner nach `World of Warcraft/_retail_/Interface/AddOns/` kopieren
4. WoW neu starten

Danach muss unter `Interface/AddOns/LunaWolves/` die Datei `LunaWolves.toc`
liegen. Liegt dort noch ein Unterordner, wurde eine Ebene zu viel kopiert.

### Mit dem Companion-Agent
Der [Desktop-Agent](https://github.com/Stanischewski/LunaWolvesCompanion)
installiert das Addon und haelt es aktuell — er meldet sich von selbst,
sobald hier ein neues Release erscheint.

### Mit WowUp
1. [WowUp](https://wowup.io/) installieren
2. In WowUp: **Get Addons** > GitHub-URL eingeben: `https://github.com/Stanischewski/LunaWolves`
3. Installieren – Updates kommen dann automatisch.

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
