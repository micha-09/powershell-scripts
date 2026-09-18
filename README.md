# PowerShell-Skripte für Windows Server 2025

Dieses Repository enthält PowerShell-Skripte zur Automatisierung der Bereitstellung und Härtung von Windows Server 2025, insbesondere für die Erstellung eines Domain Controllers.

---

## 📁 Skripte

### 1. [VM_Basic.ps1](./VM_Basic.ps1)
**Zweck:** Grundlegende Optimierung und Härtung eines nackten Windows Servers.

#### Funktionen:
- **Schritt 1: Initialisierung**
  - Statische IP-Konfiguration (wird in Azure übersprungen)
  - RDP-Zugriff ermöglichen
  - Erstellt eine geplante Aufgabe für den automatischen Neustart

- **Schritt 2: Server optimieren**
  - Powerplan auf "Hoechstleistung" setzen
  - Zeitsynchronisation (NTP) konfigurieren
  - Deutsche Lokalisierung (Sprache, Region, Tastatur)
  - **Deaktivierung von unnötigen Diensten** (Sicherheit & Performance):
    - `Spooler` (Druckwarteschlange – PrintNightmare-Sicherheitsrisiko)
    - `DiagTrack` (Telemetrie – Datenschutzrisiko)
    - `dmwappushservice` (WAP-Push-Nachrichten – Teil der Telemetrie)
    - `RemoteRegistry` (Remoteregistrierung – Privilege Escalation Risiko)
    - `WSearch` (Windows Search – I/O-Last und Angriffsfläche)
    - `SysMain` (SuperFetch – Speicherverschwendung auf Servern)
    - `lfsvc` (Standortdienst – Sicherheitsrisiko im Rechenzentrum)
    - `lmhosts` (NetBIOS-Hilfsdienst – Anfällig für Spoofing/Angriffe)
    - `XboxGipSvc` (Xbox-Dienste – Unnötig auf Servern)
    - `XblAuthManager` (Xbox-Authentifizierung – Unnötig auf Servern)
  - SMB1 deaktivieren (Sicherheitsrisiko)
  - Windows Defender Ausschlüsse für AD-Verzeichnisse
  - Temp-Bereinigung
  - Lokalen Administrator umbenennen und Passwort setzen

- **Schritt 3: Aufräumen**
  - Plante Aufgabe entfernen
  - Fortschrittsdatei löschen

---

### 2. [Create_AD.ps1](./Create_AD.ps1)
**Zweck:** Hochstufen des Servers zum Domain Controller und Befüllen der Domäne mit Musterdaten.

#### Funktionen:
- **Schritt 1: Domain Controller hochstufen**
  - **Prüfung auf ausstehende Neustarts** (maximal 1 Neustart vor der Rolleninstallation):
    - Falls Neustart aussteht: **Sofortiger Neustart** → `Step-PromoteCheck`
  - `RemoteRegistry` temporär aktivieren (erforderlich für AD-Promotion)
  - AD DS und DNS Rollen installieren
  - Neue Gesamtstruktur erstellen (`Install-ADDSForest`)
  - `RemoteRegistry` nach der Promotion wieder deaktivieren

- **Schritt 1b: Neustart-Prüfung (`Step-PromoteCheck`)**
  - Prüft nach dem Neustart erneut auf ausstehende Neustarts
  - Falls ja: **Bereinigung der Flags** (`Clear-PendingReboot`)
  - **Fährt direkt mit der Rolleninstallation fort** (kein erneuter Aufruf von `Step-Promote`)

- **Schritt 2: Domain Controller härten**
  - OSConfig DC-Security-Baseline anwenden (Windows Server 2025)

- **Schritt 3: Domäne mit Musterdaten befüllen**
  - OUs anlegen (Unternehmen, Benutzer, Gruppen, Server, Clients)
  - Sicherheitsgruppen erstellen (IT_Admin, Helpdesk, Mitarbeiter, etc.)
  - Musterbenutzer anlegen (25 Standardbenutzer)
  - Service-Accounts erstellen
  - Muster-Computerkonten (Clients und Server) anlegen
  - GPO für Passwortrichtlinie erstellen

- **Schritt 4: Aufräumen**
  - Plante Aufgabe entfernen
  - Gruppenrichtlinien aktualisieren

---

## 🔄 Ablauf

### 1. VM_Basic.ps1 ausführen
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\VM_Basic.ps1 -StaticIP "192.168.10.10" -DefaultGateway "192.168.10.1" -DnsServer "127.0.0.1" -LocalAdminName "LokalAdmin" -LocalAdminPwd "P@ssw0rd!2025"
```
- **Achtung:** `RemoteRegistry` wird deaktiviert. Für die AD-Promotion wird dieser Dienst im `Create_AD.ps1` temporär wieder aktiviert.

### 2. Create_AD.ps1 ausführen
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Create_AD.ps1 -DomainName "corp.example.com" -NetBiosName "CORP" -DsrmPassword "P@ssw0rd!2025" -DemoUserCount 25
```

---

## ⚙️ Voraussetzungen

- **Windows Server 2025** (Desktop Experience oder Server Core)
- **Ausführung als SYSTEM** (z. B. über geplante Aufgabe mit `RunLevel Highest`)
- **PowerShell 5.1 oder höher**
- **Für `Create_AD.ps1`:**
  - Vorheriger Durchlauf von `VM_Basic.ps1`
  - Modul `Microsoft.OSConfig` muss installiert sein (für DC-Härtung)

---

## 📌 Wichtige Hinweise

### Dienst `RemoteRegistry`
- Wird in **`VM_Basic.ps1` deaktiviert** (Sicherheitsmaßnahme).
- Wird in **`Create_AD.ps1` temporär aktiviert** (erforderlich für AD-Promotion).
- Wird nach der Promotion **wieder deaktiviert**.

### Neustart-Logik in `Create_AD.ps1`
- **Maximal 1 Neustart** vor der Rolleninstallation.
- **Ablauf:**
  1. Prüfe, ob Neustarts ausstehen → **Falls JA: Neustart**
  2. Prüfe nach Neustart erneut → **Falls JA: Clearing der Flags**
  3. **Fahre mit der AD-Rolleninstallation fort** (keine Endlosschleife).

### Deaktivierte Dienste
Die folgende Liste von Diensten wird in `VM_Basic.ps1` deaktiviert, um Sicherheit und Performance zu verbessern:

| **Dienstname**          | **Anzeigename**               | **Empfehlung** | **Grund** |
|-------------------------|-------------------------------|----------------|-----------|
| Spooler                 | Druckwarteschlange            | Deaktivieren   | Historisch anfällig für kritische Sicherheitslücken (PrintNightmare) |
| DiagTrack               | Benutzererfahrungen und Telemetrie | Deaktivieren | Sendet Telemetrie- und Diagnosedaten an Microsoft |
| dmwappushservice        | WAP-Push-Nachrichtendienst    | Deaktivieren   | Gehört zur Telemetrie-Infrastruktur; auf Servern nutzlos |
| RemoteRegistry          | Remoteregistrierung           | Deaktivieren*  | Erlaubt Remotebenutzern das Ändern der Registrierung (Privilege Escalation Risiko) |
| WSearch                 | Windows Search                | Deaktivieren   | Indizierungsdienst; I/O-Last und Angriffsfläche |
| SysMain                 | SysMain (SuperFetch)          | Deaktivieren   | Optimiert Caching für Desktops; auf Servern Speicherverschwendung |
| lfsvc                   | Standortdienst               | Deaktivieren   | Ermittelt geografischen Standort; Sicherheitsrisiko im Rechenzentrum |
| lmhosts                 | TCP/IP-NetBIOS-Hilfsdienst    | Deaktivieren   | Unterstützt NetBIOS über TCP/IP; anfällig für Spoofing/Angriffe |
| XboxGipSvc              | Xbox-Dienste                 | Deaktivieren   | Gaming-Komponenten; auf Servern unnötig |
| XblAuthManager          | Xbox-Authentifizierung        | Deaktivieren   | Gaming-Komponenten; auf Servern unnötig |

*RemoteRegistry muss für die AD-Promotion temporär aktiviert werden (wird in `Create_AD.ps1` automatisch gehandhabt).

---

## 🔍 Fehlerbehebung

### Problem: "The request to add or remove features on the specified server failed. The operation cannot be completed, because the server that you specified requires a restart"
- **Lösung:** Das Skript erkennt ausstehende Neustarts automatisch und führt diese durch. Falls das Problem weiterhin besteht:
  - Manuell prüfen, ob ein Neustart aussteht (z. B. über `Get-WindowsFeature` oder Registry-Einträge).
  - Server manuell neu starten und `Create_AD.ps1` erneut ausführen.

---

## 📝 Changelog

### [Latest](https://github.com/micha-09/powershell-scripts/commit/main)
- **Create_AD.ps1:**
  - Korrigierte Neustart-Logik: Maximal 1 Neustart vor der Rolleninstallation.
  - `Step-PromoteCheck` führt direkt die Rolleninstallation aus (keine Endlosschleife mehr).
  - Robustere Prüfung auf ausstehende Neustarts (CBS, Windows Update, DISM, etc.).

- **VM_Basic.ps1:**
  - Aktualisierte Liste der zu deaktivierenden Dienste (gemäß Sicherheitsanforderungen).
  - Hinweis zu `RemoteRegistry` (wird für AD-Promotion temporär aktiviert).

---

## 📄 Lizenz

Dieses Projekt steht unter der **MIT-Lizenz**. Siehe [LICENSE](./LICENSE) für weitere Informationen.
