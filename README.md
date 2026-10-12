# Sku für WoW Forever

Das **Sku**-Addon (Screenreader-Addon für blinde und sehbehinderte WoW-Spieler),
angepasst für **WoW Forever** (Blizzards neuer Classic-Client, intern „Camelot",
Interface 16001). Basis ist Sku 43.8, die Forever-Version zählt eigenständig als
**1.x** (aktuell **1.8**).

Original: <https://github.com/Sku75/Sku-WoW-Addon-TBC> (Sku75).
Lizenz: GPL v3, siehe `LICENSE.txt`. Alle Änderungen stehen unter derselben Lizenz.

## Installation

Der Ordner `Sku` in diesem Repository ist das **komplette Addon**. Am einfachsten
ist das ZIP der neuesten Version unter
[Releases](https://github.com/gitana83/wow-forever/releases/latest) (`Sku-<Version>.zip`):

1. Den Ordner `Sku` aus dem ZIP in den Forever-AddOn-Ordner kopieren, zum Beispiel
   `World of Warcraft/_classic_beta_/Interface/AddOns/`. Ein vorhandener
   `Sku`-Ordner wird dabei ersetzt.
2. Die Zusatz-Addons von Sku (`SkuAudioData_en`, `SkuAudioData_fast_de`,
   `SkuBeaconSoundsets`, `SkuCustomBeaconsAdditional`, `SkuCustomBeaconsEssential`)
   sind **nicht** enthalten. Sie sind unverändert und kommen aus der originalen
   Sku-Auslieferung.
3. Im Spiel mit `/reload` oder beim nächsten Start ist Sku bereit. Das Menü wird
   nach dem Login still vorbereitet, ein vorheriger Tastendruck ist nicht nötig.

## Was gegenüber dem Original geändert wurde

WoW Forever hat viele alte Funktionen entfernt oder umbenannt, verlagert andere in
neue `C_*`-Schnittstellen und schützt manche Werte („geheime Werte", etwa Gesundheit,
Ressourcen, GUIDs und Namen fremder Einheiten im Kampf und in Instanzen), sodass
Addons nicht damit rechnen können. Außerdem sind einige Funktionen für Addons gesperrt.
Die Anpassungen:

- **Kompatibilitäts-Bausteine** in `Core.lua`: alte Funktionen (`GetSpellInfo`,
  `UnitAura`, `GetCoinText`, Zauberbuch-, Questlog- und Pickup-Funktionen und weitere)
  auf die neuen Schnittstellen abgebildet. Helfer für geheime Werte
  (`Sku.IsSecret`, `Sku.SafeGUID`, `Sku.SafeName`).
- **Menü-Aufbau nach dem Login**, damit Sku-Tasten gleich beim ersten Druck reagieren.
- **Menüs neu aus den Schnittstellen gebaut**, weil die alten Fensterelemente fehlen:
  - Taschen, Bank, Händler (Waren, Rückkauf, Reparieren; Taschen werden bei Bedarf
    nachgeöffnet), Lehrer, Flugmeister.
  - **Auktionshaus** (neues Fenster): Suche, Kategorien, Filter, Favoriten, Kaufen, Bieten,
    Einstellen, eigene Verkäufe, eigene Gebote.
  - **Berufe** (neues Handwerksfenster), **Talente** (Taste N), **Vermächtnis/Erfolge**
    mit Vermächtnisbaum, **Aktionsleisten** mit Zauberbuch und Seitenwechsel auch im Kampf.
  - **Questbuch** (Titel, Ziele, Text, Belohnungen mit Tooltips), Quest-Links im Chat.
  - **Dungeonbrowser** (Anmelden und Gruppensuche), Freunde und Soziales, Gruppenübersicht.
  - **Pet-Menü** (Füttern, Wildtierausbildung, Stall) und Pet-Gesundheit per Taste.
- **Ansagen**: Würfeln um Beute (Bedarf, Gier, Passen, Info per Taste, auch im Laufen),
  Buff-Ansage, Gegnerfarben (gesprochene Farben vor dem Namen für Gegner, die mit dir
  oder deiner Gruppe kämpfen), Folgen-Töne, Schadensmesser über den eingebauten
  Schadensmesser des Spiels.
- **Tooltips** über `C_TooltipInfo` statt der entfernten Tooltip-Methoden; Blizzards
  Beta-Hinweis („Open Issue Report") wird herausgefiltert.
- **Einstellungen** bleiben nach dem Login erhalten (stabiler Charakterschlüssel).
- **Nicht möglich auf Forever**: Heilmonitor für Gruppe, Schlachtzug und Ressourcen
  (Blizzards Schutz gegen Auswertung von Gesundheit und Ressourcen). Das Monitor-Modul
  bleibt dort ausgeschaltet.

## Stand

Version 1.8, in aktiver Weiterentwicklung. Die Menüs sind mit einem Charakter im
Spiel getestet. Noch nicht getestet oder bekannt offen: Würfel-Tasten im Laufen,
Folgen-Ton im Kampf, Schadensmesser im Kampf, Teile der Aktionsleisten im Kampf
(Blizzards Schutz blockiert dort manche Aufrufe).

Änderungen je Version stehen bei den [Releases](https://github.com/gitana83/wow-forever/releases).

## Geänderte und neue Dateien (gegenüber Sku 43.8)

Neu für Forever: `SkuCore/auctionHouseForever.lua`, `SkuCore/professionsForever.lua`,
`SkuCore/achievementsForever.lua`, `SkuCore/actionPageForever.lua`,
`SkuCore/petHealthForever.lua`, `SkuCore/petFeed.lua`, `SkuCore/buffAnnounce.lua`,
`SkuNav/Geo.lua`, `SkuPerfFileStamp.lua`.

Geändert (Auswahl): `Core.lua`, `Sku.toc`, `SkuUtil.lua`, `Libs/SkuVoice-1.0`,
`SkuAuras/Core.lua`, `SkuChat/Core.lua`, `SkuCore/Core.lua`, `SkuCore/LocalMenu.lua`,
`SkuCore/dungeonBrowser.lua`, `SkuCore/friends.lua`, `SkuCore/damageMeter.lua`,
`SkuMob/Core.lua`, `SkuQuest/Core.lua`, `SkuZOptions/Core.lua`. Eine vollständige Liste
ergibt der Vergleich mit Sku 43.8.
