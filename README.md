# WoW Forever – Anpassungen für Sku

Änderungen am **Sku**-Addon (Screenreader-Addon für blinde und sehbehinderte
WoW-Spieler), damit es auf **WoW Forever** läuft (Blizzards neuer Classic-Client,
intern „Camelot", Interface 16001).

Dieses Repository enthält **nur die geänderten Dateien** von Sku 43.8, nicht das
ganze Addon.

Original: <https://github.com/Sku75/Sku-WoW-Addon-TBC> (Sku75).
Lizenz: GPL v3, siehe `LICENSE.txt`. Alle Änderungen stehen unter derselben Lizenz.

## Installation

1. Das originale Sku-Addon (Version 43.8) installieren.
2. Den Ordner `Sku` aus diesem Repository über den installierten Ordner
   `Interface/AddOns/Sku` kopieren, vorhandene Dateien überschreiben.
3. Die Datei `SkuCore/aq.lua` löschen (der Heilmonitor ist auf Forever nicht
   möglich, siehe unten). Die Zeile dazu in `Sku.toc` ist bereits auskommentiert.
4. Im Spiel nach jedem Login einmal **Shift-F1** drücken (Menü kurz auf und zu),
   sonst bleiben andere Sku-Tasten beim ersten Versuch stumm.

## Was sich geändert hat

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
