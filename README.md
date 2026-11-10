# Anki Sync Server Enhanced

Ein Docker-Container synchronisiert Anki zwischen Handy und Laptop. Im Dashboard verwaltest du getrennte Sync-Konten und planst lokale Backups.

## 1. Lokal bauen und starten

Lege neben der **docker-compose.yml** eine Datei **.env** an und ersetze den Beispielwert durch deinen gewünschten Admin-Namen und dein eigenes langes Passwort.

~~~dotenv
DASHBOARD_AUTH='admin:DEIN_LANGES_PASSWORT'
~~~

Starte im Projektordner mit **docker compose up -d --build**.

1. Öffne das Dashboard im Browser unter **http://SERVER-IP:8081**. Wenn der Container auf deinem eigenen Rechner läuft, verwende **http://localhost:8081**.
2. Melde dich mit dem Namen und Passwort aus der **.env** an. Das Administratorkonto wird beim ersten Start im Konfigurationsvolume gespeichert und ist sofort auch ein Sync-Konto.
3. Trage in Anki **http://SERVER-IP:8080/** als eigenen Sync-Server ein. Verwende auf deinem Handy und Laptop dieselben Admin-Zugangsdaten. Für andere Personen legst du unter **Users → + Add user** getrennte Sync-Konten an.

Die HTTP-Ports sind für den Zugriff im lokalen Netz gedacht. Für öffentlichen Zugriff richte HTTPS ein.

## 2. Backups einstellen

Öffne den Tab **Backups**. Aktiviere **Automatic backups** und wähle täglich, wöchentlich oder einen eigenen Zeitplan. Gib beispielsweise **Europe/Berlin** als Zeitzone und **7** als Aufbewahrungsdauer in Tagen ein. Gespeicherte Änderungen greifen im laufenden Container. Die Seite zeigt den nächsten Termin und das letzte Ergebnis. Ein verpasster Termin wird nach einem Neustart einmal nachgeholt.

Im Tab **Backups** kannst du eine Sicherung sofort anstoßen, herunterladen oder löschen. Der Container legt die Archive im Volume **anki_backups** ab. Die Archive sichern die Anki-Sammlungen und Medien. Für ein vollständiges Server-Backup sicherst du zusätzlich das Volume **anki_config**, das Benutzer, Einstellungen und Zugangsdaten enthält.

Änderungen an Sync-Konten starten den Anki-Prozess kurz neu. Das Admin-Passwort kannst du im Tab **Users** über **Edit** am Administratorkonto für Dashboard und Sync gemeinsam ändern. Das Dashboard bleibt erreichbar. Beim Entfernen eines Kontos bleibt seine Sammlung auf dem Datenträger.

## 3. Über GitHub veröffentlichen und auf dem Server ziehen

Der Projektordner ist ein eigenständiges lokales Git-Repository. Nach deinem Test erstellst du auf GitHub ein **neues, leeres Repository unter deinem eigenen Konto**. Lass die Optionen für README, Lizenz und .gitignore beim Erstellen leer. Die Dateien sind bereits im Projekt vorhanden.

Führe im Projektordner diese Befehle aus und ersetze DEIN-NAME und DEIN-REPO durch die Angaben deines neuen Repositorys.

~~~powershell
git add .
git status --short
git commit -m "Erste Docker-Version"
git remote add origin https://github.com/DEIN-NAME/DEIN-REPO.git
git remote -v
git push -u origin main
~~~

Prüfe vor dem Commit die Dateiliste und vor dem Push die Adresse von origin. [GitHub-Anleitung für ein neues Repository aus lokalem Code](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)

Bei einem Push auf **main** baut GitHub Actions ein Image und veröffentlicht es als **ghcr.io/dein-name/dein-repo:latest**. Standardmäßig wird für **amd64** (Intel und AMD) gebaut. Falls dein Server **arm64** verwendet, setze in den GitHub-Repository-Einstellungen unter **Secrets and variables → Actions → Variables** die Variable **DOCKER_RUNNER** auf **ubuntu-24.04-arm**. Die Serverarchitektur siehst du unter Linux mit **uname -m**.

Stelle das Container-Paket nach dem ersten erfolgreichen Lauf in den GitHub-Paketeinstellungen auf **Public**, wenn der Server es ohne Anmeldung ziehen soll. Lege auf dem Server die **docker-compose.yml** und daneben eine **.env** mit deinem Image-Namen ab.

~~~dotenv
ANKI_IMAGE=ghcr.io/dein-name/dein-repo:latest
DASHBOARD_AUTH='admin:DEIN_LANGES_PASSWORT'
~~~

Start und spätere Updates verwenden dieselben Befehle:

~~~sh
docker compose pull
docker compose up -d --no-build
~~~

**docker compose pull** lädt das Image. **docker compose up** setzt es im laufenden Dienst ein. Die drei Volumes bleiben erhalten. [GitHub-Dokumentation zur Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

## Docker-Einstellungen

| Einstellung in .env | Vorgabe | Zweck |
| --- | --- | --- |
| ANKI_IMAGE | anki-sync-server:local | Lokales Image oder GHCR-Adresse |
| DASHBOARD_AUTH | | Admin-Zugang als Benutzername:Passwort für den ersten Start |
| SYNC_BIND_IP | 0.0.0.0 | Host-Adresse für den Anki-Port |
| SYNC_HTTP_PORT | 8080 | Host-Port für Anki |
| DASHBOARD_BIND_IP | 0.0.0.0 | Host-Adresse für das Dashboard |
| DASHBOARD_HTTP_PORT | 8081 | Host-Port für das Dashboard |
| DASHBOARD_COOKIE_SECURE | false | Bei HTTPS-Zugriff auf das Dashboard auf true setzen |

### Eigene Domains mit HTTPS

Für öffentlichen Zugriff kann der Container selbst TLS für Anki und das Dashboard übernehmen. Verwende dafür zwei DNS-Namen, die auf deinen Server zeigen. Setze in der **.env** zum Beispiel:

~~~dotenv
TLS_ENABLED=true
TLS_DOMAIN=anki.example.com
DASHBOARD_TLS_DOMAIN=anki-admin.example.com
TLS_EMAIL=du@example.com
SYNC_BIND_IP=127.0.0.1
DASHBOARD_BIND_IP=127.0.0.1
~~~

Ergänze in der vorhandenen **docker-compose.yml** unter **ports** die Einträge **"80:80"** und **"443:443"**. Diese Ports müssen am Server erreichbar sein, damit der integrierte Caddy TLS-Zertifikate beziehen kann. Starte anschließend mit **docker compose up -d** neu. In Anki verwendest du **https://anki.example.com/**. Die Administration läuft unter **https://anki-admin.example.com/**. Volume-Mounts und Host-Ports legst du in derselben Compose-Datei fest.

Wenn du bereits einen HTTPS-Reverse-Proxy verwendest, kannst du stattdessen den internen TLS-Modus ausgeschaltet lassen und **DASHBOARD_COOKIE_SECURE=true** setzen.

## Vorhandene Installation übernehmen

Verwende die bisherigen Daten- und Backup-Volumes weiter und ergänze das persistente **/config**-Volume. Ein vorhandenes Administratorkonto und die Backup-Zeiten bleiben beim Update erhalten. Dein Admin-Konto wird beim Update für Anki aktiviert, wenn in **DASHBOARD_AUTH** noch der aktuelle Zugang steht. Andernfalls geschieht das beim nächsten Login im Dashboard. Wenn bereits ein Sync-Konto mit demselben Namen existiert, verwendet es danach das Admin-Passwort. Seine Sammlung bleibt erhalten und Anki muss sich für dieses Konto neu anmelden. Falls du bisher nur den Einmal-Code hattest, setze **DASHBOARD_AUTH** vor dem nächsten Start. Beim ersten Start mit leerem **/config** werden vorhandene **SYNC_USER**-Variablen und Backup-Einstellungen aus der bisherigen Container-Konfiguration übernommen. Anki-Clients mit bisher unverschlüsselten Sync-Passwörtern müssen sich einmal neu anmelden, weil bei der Übernahme neue Passwort-Hashes und Sync-Schlüssel entstehen.

## Lizenz

AGPL-3.0-or-later. Diese Version baut auf [Anki Sync Server Enhanced von Christos Longros](https://github.com/chrislongros/anki-sync-server-enhanced) und dem [offiziellen Anki-Sync-Server](https://github.com/ankitects/anki) auf. Siehe [LICENSE](LICENSE).
