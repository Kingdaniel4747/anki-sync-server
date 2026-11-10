# Anki Sync Server Enhanced

Ein Docker-Container synchronisiert Anki auf Handy und Laptop. Im Dashboard legst du Sync-Benutzer an, änderst Passwörter, planst Backups und siehst die Logs.

## Auf dem Docker-Server starten

Lege die **docker-compose.yml** und eine **.env** in denselben Ordner. Setze beim ersten Start deinen eigenen Admin-Namen und ein Passwort mit mindestens 12 Zeichen. Für Zugriff im LAN trägst du als Bind-Adresse die private IP des Docker-Hosts ein.

~~~dotenv
DASHBOARD_AUTH='MEIN_NAME:MEIN_LANGES_PASSWORT'
SYNC_BIND_IP=192.168.1.20
DASHBOARD_BIND_IP=192.168.1.20
~~~

Ersetze **192.168.1.20** durch die LAN-IP deines Servers. Ohne diese Einträge sind die beiden Ports nur über den Docker-Host selbst erreichbar. Lege die Verzeichnisse an, beschränke den Zugriff auf die **.env** und starte den Container.

~~~sh
(umask 077; mkdir -p ./data ./backups ./config)
chmod 600 .env
docker compose pull
docker compose up -d
~~~

Öffne **http://SERVER-IP:8081** für das Dashboard. Für Anki im LAN verwendest du **http://SERVER-IP:8080/**. Die Angaben gelten für die mitgelieferten Standardports. Auf einem Server mit **8022** für das Dashboard und **8011** für Sync behältst du diese Host-Ports in der Compose-Datei oder in der **.env** bei.

Das Admin-Konto meldet sich im Dashboard und in Anki mit demselben Zugang an. Unter **Users → + Add user** legst du getrennte Anki-Konten für andere Personen an. **Edit** ändert das jeweilige Passwort. Beim Admin gilt die Änderung für beide Zugänge. Verwende auf den Geräten derselben Person dasselbe Sync-Konto. Der Container speichert die Konten und Zeitpläne in **./config**.

## Öffentlicher Sync über Nginx Proxy Manager

Die beiden Ports bleiben getrennt. Nginx Proxy Manager übernimmt HTTPS und leitet nur den öffentlichen Sync-Host an Anki weiter.

1. Lege einen DNS-Eintrag wie **anki.example.com** für deinen Proxy an.
2. Erstelle im Proxy Manager einen **Proxy Host** für **anki.example.com**. Wähle **http** als Schema, die **LAN-IP des Docker-Hosts** als Ziel und als Forward Port den **Sync-Port**, etwa **8080** oder bei deiner bisherigen Belegung **8011**.
3. Wähle im Tab **SSL** ein Zertifikat, aktiviere **Force SSL** und speichere. In Anki verwendest du **https://anki.example.com/** als eigenen Sync-Server.
4. Lass den Dashboard-Port im LAN. Wenn du das Dashboard ebenfalls über den Proxy betreiben möchtest, verwende dafür einen separaten Proxy Host mit seinem eigenen Port und einem HTTPS-Zertifikat. Setze dafür **DASHBOARD_COOKIE_SECURE=true**.

Öffentlich erreichbar sollen nur die Proxy-Ports für HTTP und HTTPS sein. Leite die Anki- und Dashboard-Ports am Router nicht ins Internet weiter. Bei einem direkt ans Internet angeschlossenen Host beschränke den Zugriff auf diese Ports auf das private Netz oder auf den Proxy. Verwendest du **DASHBOARD_COOKIE_SECURE=true**, melde dich im Dashboard über dessen HTTPS-Adresse an.

Falls größere Sync-Uploads am Proxy mit HTTP 413 scheitern, setze beim Sync-Host unter **Advanced** etwa **client_max_body_size 128m;**. Anki verwendet standardmäßig ein Upload-Limit von 100 MiB. Für Sync bleibt die Anki-Anmeldung zuständig. Eine zusätzliche HTTP-Basic-Auth vor der Sync-Domain kann die Anmeldung in den Anki-Apps stören. [Anki-Server-Dokumentation](https://docs.ankiweb.net/manual/sync-server) · [Nginx Proxy Manager](https://nginxproxymanager.com/guide/) · [Nginx-Uploadlimit](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size)

## Lokale und externe Backups

Im Tab **Backups** stellst du automatische Sicherungen täglich, wöchentlich oder per eigenem Zeitplan ein. Dort legst du auch Zeitzone und Aufbewahrungsdauer fest. Mit **Create backup now** startest du jederzeit ein manuelles Backup. Der Tab zeigt den nächsten und den letzten Lauf. Fehler findest du unter **Logs → Backup**.

Anki-Daten bleiben standardmäßig in **./data** neben der Compose-Datei. Die Archive landen standardmäßig in **./backups**. Für Backups auf einem anderen Server bindest du dort eine NFS- oder SMB-Freigabe auf dem **Docker-Host** ein. Verwende einen eigenen Unterordner auf der Freigabe und trage dessen absoluten Pfad in der **.env** ein.

~~~dotenv
BACKUP_DIR=/mnt/backup-server/anki
~~~

Lege **anki** auf der eingehängten Freigabe an. Docker bricht beim Start ab, wenn der eingetragene Pfad fehlt. Der Backup-Prozess braucht Schreib- und Löschrechte für seine Archive. Er ändert die Besitzer der externen Freigabe nicht. Passe bei Bedarf deren Berechtigungen an **PUID** und **PGID** an. Während eines Backups wird vorübergehend lokaler Speicher für eine Kopie der Anki-Daten benötigt. Das fertige Archiv landet direkt im eingestellten Zielordner.

Die Archive enthalten die Sammlungen und Medien. Sichere auch **./config** separat. Dort liegen die Konten, Passworthashes und der Zeitplan. Wenn dein Backup-Server eigene Snapshots unterstützt, können diese auch ältere oder im Dashboard gelöschte Archive aufbewahren.

### Wiederherstellen

Stoppe den Container, entpacke ein eigenes Backup in einen **neuen leeren Ordner** wie **./data-restored** und setze **DATA_DIR=./data-restored** in der **.env**. Starte mit **docker compose up -d** und prüfe die Sammlung. Für die ursprünglichen Benutzer und Einstellungen verwende den vorhandenen oder separat gesicherten Konfigurationsordner. Du kannst bei Bedarf wieder auf den bisherigen Datenordner zurückschalten.

## .env-Referenz

Die Pfade beziehen sich auf den Docker-Host. Relative Pfade beginnen mit **./** und werden neben der Compose-Datei aufgelöst. Alle drei Zielordner müssen vor dem Start existieren.

| Variable | Standard | Zweck |
| --- | --- | --- |
| ANKI_IMAGE | ghcr.io/kingdaniel4747/anki-sync-server:latest | Container-Image. Bei einem eigenen GitHub-Repository anpassen. |
| DASHBOARD_AUTH | leer | Initialer Admin-Zugang als Benutzername:Passwort. Bei einem bestehenden Admin bleibt der gespeicherte Zugang maßgeblich. |
| SYNC_BIND_IP | 127.0.0.1 | Host-IP für Anki. Für LAN oder Proxy die private Server-IP eintragen. |
| SYNC_HTTP_PORT | 8080 | Host-Port für Anki. |
| DASHBOARD_BIND_IP | 127.0.0.1 | Host-IP für das Dashboard. Für Zugriff vom eigenen Rechner die private Server-IP eintragen. |
| DASHBOARD_HTTP_PORT | 8081 | Host-Port für das Dashboard. |
| DASHBOARD_COOKIE_SECURE | false | Bei Dashboard-Zugriff ausschließlich über HTTPS auf true setzen. |
| DATA_DIR | ./data | Lokaler Ordner mit Anki-Daten. |
| BACKUP_DIR | ./backups | Lokaler Ordner oder eingebundener Pfad zur externen Freigabe. |
| CONFIG_DIR | ./config | Lokaler Ordner mit Konten, Zeitplan und Einstellungen. |
| TZ | UTC | Zeitzone der Container-Logs und Vorgabe für eine neue Backup-Konfiguration, etwa Europe/Berlin. Im Dashboard ist die Backup-Zeitzone separat einstellbar. |
| PUID | 1000 | Linux-Benutzer-ID für Sync, Dashboard und Backups. |
| PGID | 1000 | Linux-Gruppen-ID für Sync, Dashboard und Backups. |

Die schlanke Compose-Datei enthält keine automatische Neustartregel. Nach einem Neustart des Docker-Hosts kannst du sie mit **docker compose up -d** wieder starten. [Docker-Bind-Mounts](https://docs.docker.com/engine/storage/bind-mounts/) · [Docker-Portfreigaben](https://docs.docker.com/engine/network/port-publishing/)

## Von einer älteren Compose-Datei wechseln

Wenn du bereits Bind-Mounts verwendest, trage die **bestehenden Pfade** als **DATA_DIR**, **BACKUP_DIR** und **CONFIG_DIR** ein. Behalte Projektname und Host-Ports bei.

Wenn du Docker-Volumes wie **anki-sync-test_data** benutzt hast, stoppe zuerst die alte Instanz. Kopiere die Inhalte, bevor du die neue Compose-Datei startest. Damit bleiben auch der bisherige Admin und der Zeitplan erhalten. Die tatsächlichen Namen findest du mit **docker volume ls**. Für die bisherige Standarddatei beginnen sie mit **anki-sync-server_anki_**. Die folgende Kopie ist für das Testprojekt mit **anki-sync-test_data**, **anki-sync-test_backups** und **anki-sync-test_config** gedacht. Ersetze bei Bedarf die Namen und Zielpfade. Führe die Befehle neben der Compose-Datei aus, sobald der alte Container gestoppt ist.

~~~sh
(umask 077; mkdir -p ./data ./backups ./config)
IMAGE=ghcr.io/kingdaniel4747/anki-sync-server:latest
copy_volume() {
    docker volume inspect "$1" >/dev/null || return 1
    docker run --rm \
        --mount "type=volume,source=$1,target=/old,readonly" \
        --mount "type=bind,source=$2,target=/new" \
        --entrypoint /bin/sh "$IMAGE" -ec \
        'test -z "$(ls -A /new)" || { echo "Target must be empty" >&2; exit 1; }; cp -a /old/. /new/'
}
copy_volume anki-sync-test_data "$PWD/data" &&
copy_volume anki-sync-test_backups "$PWD/backups" &&
copy_volume anki-sync-test_config "$PWD/config"
~~~

Prüfe die Kopien und starte dann die neue Compose-Datei. Die alten Volumes dienen als Rückfallkopie. Wenn deine alte Konfiguration im Container selbst HTTPS bereitgestellt hat, richte den Sync-Proxy vor dem Umstieg ein.

## Eigene Version bauen und veröffentlichen

Zum lokalen Testen aus dem Projektordner erst **docker build --pull -t anki-sync-server:local .** ausführen und anschließend mit **ANKI_IMAGE=anki-sync-server:local docker compose up -d** starten. Die gleiche **.env** und die oben beschriebenen Ordner gelten auch für diesen Test.

Für eine eigene Veröffentlichung erstelle ein neues, leeres Repository unter deinem GitHub-Konto. Verknüpfe es als **origin** und pushe nach **main**. Der vorhandene Workflow veröffentlicht ein Image als **ghcr.io/dein-name/dein-repo:latest**. Standard ist AMD64. Für ARM64 setze im Repository unter **Settings → Secrets and variables → Actions → Variables** die Variable **DOCKER_RUNNER** auf **ubuntu-24.04-arm**.

Wenn das Image ohne Docker-Anmeldung abrufbar sein soll, stelle das GHCR-Paket auf **Public**. Trage deine Image-Adresse in **ANKI_IMAGE** ein. Nach einem erfolgreichen Build aktualisierst du den Server im Ordner mit der Compose-Datei mit **docker compose pull** und **docker compose up -d**. [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

## Lizenz

AGPL-3.0-or-later. Das Projekt baut auf [Anki Sync Server Enhanced von Christos Longros](https://github.com/chrislongros/anki-sync-server-enhanced) und dem [offiziellen Anki-Sync-Server](https://github.com/ankitects/anki) auf. Siehe [LICENSE](LICENSE).
