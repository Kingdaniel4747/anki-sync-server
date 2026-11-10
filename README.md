# Anki Sync Server Enhanced

Ein Docker-Container für Anki-Sync, Benutzerverwaltung und geplante Backups.

## Starten

Lege **docker-compose.yml** und **.env** in denselben Ordner auf dem Docker-Host. Setze in der **.env** deinen Admin-Namen und ein eigenes Passwort mit mindestens zwölf Zeichen.

~~~dotenv
DASHBOARD_AUTH='Daniel:DEIN_NEUES_LANGES_PASSWORT'
TZ=Europe/Berlin
~~~

**DASHBOARD_AUTH** richtet den Admin beim ersten Start ein. Wenn schon ein Admin gespeichert ist, gilt dessen aktuelles Passwort. **TZ** bestimmt die Zeitzone der Logs und die Vorgabe für einen neuen Backup-Zeitplan. Unter **Backups** kannst du die Backup-Zeitzone separat ändern.

Die Compose-Datei verwendet diese Pfade direkt:

| Pfad auf dem Docker-Host | Inhalt |
| --- | --- |
| ./data/anki | Sammlungen und Medien |
| ./data/config | Admin, Benutzer und Backup-Zeitplan |
| /mnt/storage/anki | Backup-Archive |

Prüfe mit **findmnt -T /mnt/storage/anki**, dass der Pfad auf deinem eingebundenen Backup-Speicher liegt. Der Ordner muss für den Container-Benutzer mit UID/GID 1000 beschreibbar sein. Die kurze Volume-Schreibweise kann fehlende Ordner auf der lokalen Platte erzeugen. Kontrolliere die Freigabe deshalb vor dem Start.

~~~sh
docker compose pull
docker compose up -d
~~~

- Dashboard im LAN unter **http://SERVER-IP:8083**
- Anki-Sync im LAN unter **http://SERVER-IP:8082/**

Der Admin kann sich mit denselben Daten im Dashboard und in Anki anmelden. Unter **Users → + Add user** legst du getrennte Sync-Konten an. Über **Edit** änderst du Passwörter.

## Eine vorhandene Sammlung auf einen leeren Server laden

Sichere die Anki-Sammlung auf deinem Gerät zuerst. Melde dich mit dem neuen Server und dem passenden Sync-Konto an. Wähle auf dem Gerät mit der vollständigen Sammlung **Hochladen**. Melde dich danach auf den weiteren Geräten für dieses Konto an und wähle bei der Abfrage **Herunterladen**. Dabei ersetzt Anki die lokale Sammlung durch die Kopie vom Server. Jede Person verwendet ein eigenes Sync-Konto. [Anki-Handbuch zur ersten Synchronisation](https://docs.ankiweb.net/syncing.html)

## Backups

Aktiviere im Tab **Backups** die automatischen Backups und stelle Zeit, Zeitzone und Aufbewahrung ein. Wenn du den bisherigen Rhythmus übernehmen möchtest, wähle täglich um **22:00 Uhr**, **Europe/Berlin** und **7 Tage**. Mit **Create backup now** kannst du jederzeit eine Sicherung anstoßen. Während der lokalen Kopie pausiert der Anki-Sync. Beim Packen und Speichern auf dem Backup-Laufwerk läuft der Sync wieder. Unter **Logs → Backup** siehst du den Verlauf.

Der Zielordner steht direkt in der Compose-Datei. Für einen anderen Speicher änderst du den Pfad links von **:/backups**. Sichere **./data/config** separat, wenn du auch Konten und Einstellungen wiederherstellen möchtest. Entpacke bei einer Wiederherstellung dein Archiv in einen neuen Ordner und ändere den Quellpfad links von **:/data**.

## Domain über Nginx Proxy Manager

Lege für die Sync-Domain einen Proxy Host mit Schema **http**, der LAN-IP des Docker-Hosts und Zielport **8082** an. Wähle ein HTTPS-Zertifikat und aktiviere **Force SSL**. In Anki verwendest du dann zum Beispiel **https://anki.example.com/**. Den Dashboard-Port **8083** behältst du im LAN.

Die kurzen Portzeilen binden standardmäßig an alle Host-Adressen. Wenn dein Docker-Host direkt öffentlich erreichbar ist, binde die Ports an seine private IP, etwa mit **"192.168.1.20:8083:8081"**, oder beschränke den Zugriff per Firewall. Nach einem Neustart des Docker-Hosts startest du den Container mit **docker compose up -d**. [Anki-Dokumentation zum öffentlichen Zugriff](https://docs.ankiweb.net/manual/sync-server#public-access) · [Docker-Portfreigaben](https://docs.docker.com/engine/network/port-publishing/)

## Eigenes Image

Der GitHub-Workflow baut beim Push auf **main** und veröffentlicht **ghcr.io/dein-name/dein-repo:latest**. Für ARM64 setze die GitHub-Repository-Variable **DOCKER_RUNNER** auf **ubuntu-24.04-arm**. Passe für dein Image die Zeile **image** in der Compose-Datei an.

Zum lokalen Bauen kannst du **docker build --pull -t anki-sync-server:local .** verwenden und **image: anki-sync-server:local** setzen. Für ein veröffentlichtes Image aktualisierst du den Server mit **docker compose pull** und **docker compose up -d**.

## Lizenz

AGPL-3.0-or-later. Das Projekt baut auf [Anki Sync Server Enhanced von Christos Longros](https://github.com/chrislongros/anki-sync-server-enhanced) und dem [offiziellen Anki-Sync-Server](https://github.com/ankitects/anki) auf. Siehe [LICENSE](LICENSE).
