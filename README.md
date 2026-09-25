# Sku für WoW Forever

Das **Sku**-Addon (Screenreader-Addon für blinde und sehbehinderte WoW-Spieler),
angepasst für **WoW Forever** (Blizzards neuer Classic-Client, intern „Camelot",
Interface 16001). Basis ist Sku 43.8.

Original: <https://github.com/Sku75/Sku-WoW-Addon-TBC> (Sku75).
Lizenz: GPL v3, siehe `LICENSE.txt`. Alle Änderungen stehen unter derselben Lizenz.

## Installation

Der Ordner `Sku` in diesem Repository ist das **komplette Addon**. Einfach
kopieren und einfügen:

1. Den Ordner `Sku` in den Forever-AddOn-Ordner kopieren, zum Beispiel
   `World of Warcraft/_classic_beta_/Interface/AddOns/`. Ein vorhandener
   `Sku`-Ordner wird dabei ersetzt.
2. Die Zusatz-Addons von Sku (`SkuAudioData_en`, `SkuAudioData_fast_de`,
   `SkuBeaconSoundsets`, `SkuCustomBeaconsAdditional`, `SkuCustomBeaconsEssential`)
   sind **nicht** enthalten. Sie sind unverändert und kommen aus der originalen
   Sku-Auslieferung.
3. Im Spiel nach jedem Login einmal **Shift-F1** drücken (Menü kurz auf und zu),
   sonst bleiben andere Sku-Tasten beim ersten Versuch stumm.

## Was gegenüber dem Original geändert wurde

WoW Forever hat viele alte Funktionen entfernt oder umbenannt und schützt
Gesundheits- und Ressourcenwerte („geheime Werte"), sodass Addons nicht damit
rechnen können. Die Anpassungen:

- **Kompatibilitäts-Bausteine** in `Core.lua` (alte Funktionen wie `GetSpellInfo`,
  `UnitAura`, `UnitBuff`, `GetCoinText`, `BetterDate`, Zauberbuch- und
  Pickup-Funktionen auf die neuen `C_*`-Schnittstellen abgebildet).
- **Sprachausgabe** (`SkuVoice`) mit festen Rückfallwerten, damit sie spricht.
- **Menüs neu aufgebaut aus den Schnittstellen**, weil die alten Fensterelemente fehlen:
  Tasche, Aktionsleisten mit Zauberbuch, Händler (Waren, Rückkauf, Reparieren), Lehrer,
  Questbuch (Vorlesen von Titel, Ziel, Text, Belohnungen), Monitor-Menü.
- **Tooltips** über `C_TooltipInfo` und Ersatzwege statt der entfernten Tooltip-Methoden;
  Blizzards Beta-Hinweis („Open Issue Report") wird herausgefiltert.
- **Übersichtsseite** (Strg-Shift-Runter): abgesichert gegen geheime Werte und fehlende
  Funktionen.
- **Chat**: Nachlesen, Nachrichtentypen; die auf Forever gesperrte Kampflog-Registrierung
  wird nicht mehr versucht.
- **Einstellungen** bleiben nach dem Login erhalten (stabiler Charakterschlüssel, weil der
  Name beim Laden auf Forever schwankt).
- **Blizzard Ansagen**: neuer Eintrag unter Einstellungen mit Blizzards
  Audiounterstützung (Bildschirmleser und Kampfansagen).
- **Nicht möglich auf Forever**: Heilmonitor für Gruppe, Schlachtzug und Ressourcen
  (Blizzards Schutz gegen Auswertung von Gesundheit und Ressourcen).

## Stand

In Arbeit, getestet mit einem Magier im Startgebiet. Bekannte offene Punkte:
Fertigkeiten-Anzeige (keine Waffenstufen mehr auf Forever), Auswahl-Belohnungen im
Questbuch, einzelne Fehler bei geheimen Werten im Kampf.

## Geänderte Dateien (gegenüber Sku 43.8)

`Core.lua`, `Sku.toc`, `SkuUtil.lua`, `Libs/AceEvent-3.0/AceEvent-3.0.lua`,
`Libs/SkuVoice-1.0/SkuVoice-1.0.lua`, `SkuAuras/Core.lua`, `SkuChat/Core.lua`,
`SkuChat/Options.lua`, `SkuCore/Core.lua`, `SkuCore/LocalMenu.lua`, `SkuCore/Options.lua`,
`SkuCore/aqCombat.lua`, `SkuCore/gameOptions.lua`, `SkuCore/equipmentSets.lua`,
`SkuCore/alIntegration.lua`, `SkuCore/auctionHouse.lua`, `SkuCore/JunkAndRepair.lua`,
`SkuCore/pawnIntegration.lua`, `SkuMob/Core.lua`, `SkuNav/specialNavigationTasks.lua`,
`SkuQuest/Core.lua`, `SkuQuest/Options.lua`, `SkuZOptions/Core.lua`,
`SkuZOptions/Options.lua`, `SkuZOptions/SkuMenu.lua`, `SkuZOptions/utilities.lua`.
Entfernt: `SkuCore/aq.lua` (Heilmonitor, auf Forever nicht möglich).
