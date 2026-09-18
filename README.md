# PowerShell-Skripte fuer Windows Server 2025

Dieses Repository enthaelt PowerShell-Skripte zur Automatisierung der Bereitstellung und Haertung von Windows Server 2025, insbesondere fuer die Erstellung eines Domain Controllers.

---

## 📁 Skripte

### 1. [VM_Basic.ps1](./VM_Basic.ps1)
**Zweck:** Grundlegende Optimierung und Haertung eines nackten Windows Servers.

#### Funktionen:
- **Schritt 1: Initialisierung**
  - **Lokalen Administrator umbenennen** und **Zufaelliges Admin-Passwort setzen** (Sicherheitsmassnahme: verhindert Anmeldung waehrend des gesamten Setups)
  - Statische IP-Konfiguration (wird in Azure uebersprungen)
  - RDP-Zugriff ermoeglichen
  - Erstellt eine geplante Aufgabe fuer den automatischen Neustart

- **Schritt 2: Server optimieren**
  - Powerplan auf "Hoechstleistung" setzen
  - Zeitsynchronisation (NTP) konfigurieren
  - Deutsche Lokalisierung (Sprache, Region, Tastatur)
  - **Deaktivierung von unnoetigen Diensten** (Sicherheit & Performance):
    - `Spooler` (Druckwarteschlange – PrintNightmare-Sicherheitsrisiko)
    - `DiagTrack` (Telemetrie – Datenschutzrisiko)
    - `dmwappushservice` (WAP-Push-Nachrichten – Teil der Telemetrie)
    - `RemoteRegistry` (Remoteregistrierung – Privilege Escalation Risiko)
    - `WSearch` (Windows Search – I/O-Last und Angriffsflaeche)
    - `SysMain` (SuperFetch – Speicherverschwendung auf Servern)
    - `lfsvc` (Standortdienst – Sicherheitsrisiko im Rechenzentrum)
    - `lmhosts` (NetBIOS-Hilfsdienst – Anfaellig fuer Spoofing/Angriffe)
    - `XboxGipSvc` (Xbox-Dienste – Unnoetig auf Servern)
    - `XblAuthManager` (Xbox-Authentifizierung – Unnoetig auf Servern)
  - SMB1 deaktivieren (Sicherheitsrisiko)
  - Windows Defender Ausschluesse fuer AD-Verzeichnisse
  - Temp-Bereinigung

- **Schritt 3: Aufraeumen**
  - **Admin-Passwort auf gewuenschten Wert setzen** (letzter Schritt)
  - Plante Aufgabe entfernen
  - Fortschrittsdatei loeschen

---

### 2. [Create_AD.ps1](./Create_AD.ps1)
**Zweck:** Hochstufen des Servers zum Domain Controller und Befuellen der Domaene mit Tiering-Struktur und GPOs.

#### Sicherheitsmassnahme:
Das Administrator-Konto (SID-500) wird **zu Beginn** mit einem zufaelligen Kennwort gesichert, damit **waehrend des gesamten Setups keine Anmeldung am DC moeglich** ist. Erst im letzten Schritt (`Step-Cleanup`) wird das gewuenschte Kennwort gesetzt (Parameter `-AdminPassword`).

#### Funktionen:
- **Schritt 1: Domain Controller hochstufen**
  - **Sicherheitsmassnahme: Zufaelliges Admin-Kennwort setzen** (Login gesperrt)
  - **Pruefung auf ausstehende Neustarts** (maximal 1 Neustart vor der Rolleninstallation):
    1. Pruefe zu Beginn ob Neustarts ausstehen
    2. Falls JA: **Sofortiger Neustart** → `Step-PromoteCheck`
    3. Pruefe nach Neustart erneut
    4. Falls JA: **Bereinigung der Flags** (`Clear-PendingReboot`)
    5. **Fahre mit der AD-Rolleninstallation fort** (keine Endlosschleife)
  - `RemoteRegistry` temporaer aktivieren (erforderlich fuer AD-Promotion)
  - AD DS und DNS Rollen installieren
  - Neue Gesamtstruktur erstellen (`Install-ADDSForest`)
  - **Nach der Promotion: Domain-Admin mit zufaelligem Kennwort sichern**
  - `RemoteRegistry` nach der Promotion wieder deaktivieren

- **Schritt 1b: Neustart-Pruefung (`Step-PromoteCheck`)**
  - **Zufaelliges Admin-Kennwort setzen** (falls nach Neustart noetig)
  - Prueft nach dem Neustart erneut auf ausstehende Neustarts
  - Falls ja: **Bereinigung der Flags** (`Clear-PendingReboot`)
  - **Fuehrt direkt die Rolleninstallation aus** (kein erneuter Aufruf von `Step-Promote`)

- **Schritt 2: Domain Controller haerten**
  - OSConfig DC-Security-Baseline anwenden (Windows Server 2025)

- **Schritt 3: Domaene mit Tiering-Struktur befuellen**
  - **Tiering-Struktur OUs** (alle OUs direkt am Domain-Root):
    ```
    Domain Root (DC=dev,DC=lab)
    ├── Tier0
    │   ├── T0-Admins (Benutzer)
    │   ├── T0-Servers (DCs, PKI)
    │   ├── T0-Service Accounts
    │   └── T0-Gruppen
    ├── Tier1
    │   ├── T1-Admins (Server-Admins, Helpdesk Level 2)
    │   ├── T1-Servers (SQL, Exchange, etc.)
    │   ├── T1-Service Accounts
    │   └── T1-Gruppen
    └── Tier2
        ├── T2-Users (Normale Mitarbeiter)
        ├── T2-Admins (Helpdesk Level 1)
        ├── T2-Clients (Windows Laptops/PCs)
        ├── T2-Service Accounts
        └── T2-Gruppen
    ```
  - **Sicherheitsgruppen erstellen:**
    - T0-Admins (Tier 0 Administratoren)
    - T1-Admins (Tier 1 Administratoren)
    - T2-Admins (Tier 2 Administratoren)
    - T2-Users (Tier 2 Benutzer)
  - **Administrator (SID-500) in T0-Admins aufnehmen** (verhindert, dass ihn die Logon-Restriktionen aussperren)
  - **GPOs mit Zugriffsbeschraenkungen:**
    - **Tier0-Admin-Zugriff:**
      - T0-Admins duerfen sich nur an T0-Servern anmelden
      - T0-Admins sind lokale Admins auf T0-Servern
      - Alle Admins duerfen kein RDP nutzen
    - **Tier1-Admin-Zugriff:**
      - T1-Admins duerfen sich nur an T1-Servern anmelden
      - T1-Admins sind lokale Admins auf T1-Servern
      - Alle Admins duerfen kein RDP nutzen
    - **Tier2-Zugriff-Kontrolle:**
      - T2-Admins/T2-Users duerfen sich nur an T2-Clients anmelden
      - T2-Admins sind lokale Admins auf T2-Clients
      - T2-Users haben Standard-Benutzerrechte
      - Alle Admins duerfen kein RDP nutzen

- **Schritt 4: Aufraeumen**
  - **Admin-Kennwort auf gewuenschten Wert setzen** (`-AdminPassword`, Login wieder moeglich)
  - Plante Aufgabe entfernen
  - Gruppenrichtlinien aktualisieren

---

### 3. [Create_DemoData.ps1](./Create_DemoData.ps1)
**Zweck:** Befuellt die Domaene mit Musterbenutzern, Gruppen und Computerkonten.

#### Funktionen:
- **Sicherheitsgruppen erstellen** (in T2-Gruppen):
  - GG_IT_Admin, GG_Helpdesk, GG_Mitarbeiter, GG_Finanzen, GG_Entwicklung, GG_ServerAdmin
- **Musterbenutzer anlegen** (in T2-Users):
  - 25 Demo-Benutzer (Demo.User01 bis Demo.User25)
  - Zuordnung zu Abteilungen (IT, Helpdesk, Finanzen, Entwicklung, Vertrieb, HR)
- **Service-Accounts erstellen** (in T2-Service Accounts):
  - svc_backup, svc_monitoring, svc_join, svc_print
- **Computerkonten anlegen:**
  - 10 Client-Computer (CL-WS001 bis CL-WS010) in T2-Clients OU
  - 5 Server-Computer (SRV-APP01 bis SRV-APP05) in T1-Servers OU

---

## 🔄 Ablauf

### 1. VM_Basic.ps1 ausfuehren
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\VM_Basic.ps1 -StaticIP "192.168.10.10" -DefaultGateway "192.168.10.1" -DnsServer "127.0.0.1" -LocalAdminName "LokalAdmin" -LocalAdminPwd "P@ssw0rd!2025"
```
- **Achtung:** `RemoteRegistry` wird deaktiviert. Fuer die AD-Promotion wird dieser Dienst im `Create_AD.ps1` temporaer wieder aktiviert.

### 2. Create_AD.ps1 ausfuehren
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Create_AD.ps1 -DomainName "corp.example.com" -NetBiosName "CORP" -DsrmPassword "P@ssw0rd!2025" -AdminPassword "P@ssw0rd!2025"
```

### 3. (Optional) Create_DemoData.ps1 ausfuehren
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Create_DemoData.ps1 -DomainName "corp.example.com" -NetBiosName "CORP" -DemoUserCount 25
```

---

## ⚙️ Voraussetzungen

- **Windows Server 2025** (Desktop Experience oder Server Core)
- **Ausfuehrung als SYSTEM** (z. B. ueber geplante Aufgabe mit `RunLevel Highest`)
- **PowerShell 5.1 oder hoeher**
- **Fuer `Create_AD.ps1`:**
  - Vorheriger Durchlauf von `VM_Basic.ps1`
  - Modul `Microsoft.OSConfig` muss installiert sein (fuer DC-Haertung)

---

## 📌 Wichtige Hinweise

### Dienst `RemoteRegistry`
- Wird in **`VM_Basic.ps1` deaktiviert** (Sicherheitsmassnahme).
- Wird in **`Create_AD.ps1` temporaer aktiviert** (erforderlich fuer AD-Promotion).
- Wird nach der Promotion **wieder deaktiviert**.

### Neustart-Logik in `Create_AD.ps1`
- **Maximal 1 Neustart** vor der Rolleninstallation.
- **Ablauf:**
  1. Pruefe zu Beginn ob Neustarts ausstehen → **Falls JA: Neustart**
  2. Pruefe nach Neustart erneut → **Falls JA: Clearing der Flags**
  3. **Fahre mit der AD-Rolleninstallation fort** (keine Endlosschleife).

### Tiering-Struktur
Die Domaene wird mit einer 3-stufigen Sicherheitsarchitektur (Tiering-Modell) eingerichtet:

| **Tier** | **Beschreibung** | **Zugangsbeschraenkung** | **Berechtigung** |
|----------|----------------|------------------------|------------------|
| Tier 0 | Hochsensible Systeme (DCs, PKI) | Nur T0-Admins | Admin-Rechte |
| Tier 1 | Server-Systeme (SQL, Exchange) | Nur T1-Admins | Admin-Rechte |
| Tier 2 | Client-Systeme (Arbeitsstationen) | T2-Admins & T2-Users | Admins: Admin, Users: Standard |

### RDP-Beschraenkungen
- **Alle Administratoren** (T0, T1, T2) duerfen **kein RDP** nutzen
- Dies gilt fuer lokale Anmeldung und Remote-Desktop
- Erzwungen durch GPOs mit `DenyLogOnThroughRemoteDesktopServices`

### Deaktivierte Dienste
Die folgende Liste von Diensten wird in `VM_Basic.ps1` deaktiviert, um Sicherheit und Performance zu verbessern:

| **Dienstname**          | **Anzeigename**               | **Empfehlung** | **Grund** |
|-------------------------|-------------------------------|----------------|-----------|
| Spooler                 | Druckwarteschlange            | Deaktivieren   | Historisch anfaellig fuer kritische Sicherheitsluecken (PrintNightmare) |
| DiagTrack               | Benutzererfahrungen und Telemetrie | Deaktivieren | Sendet Telemetrie- und Diagnosedaten an Microsoft |
| dmwappushservice        | WAP-Push-Nachrichtendienst    | Deaktivieren   | Gehoert zur Telemetrie-Infrastruktur; auf Servern nutzlos |
| RemoteRegistry          | Remoteregistrierung           | Deaktivieren*  | Erlaubt Remotebenutzern das Aendern der Registrierung (Privilege Escalation Risiko) |
| WSearch                 | Windows Search                | Deaktivieren   | Indizierungsdienst; I/O-Last und Angriffsflaeche |
| SysMain                 | SysMain (SuperFetch)          | Deaktivieren   | Optimiert Caching fuer Desktops; auf Servern Speicherverschwendung |
| lfsvc                   | Standortdienst               | Deaktivieren   | Ermittelt geografischen Standort; Sicherheitsrisiko im Rechenzentrum |
| lmhosts                 | TCP/IP-NetBIOS-Hilfsdienst    | Deaktivieren   | Unterstuetzt NetBIOS ueber TCP/IP; anfaellig fuer Spoofing/Angriffe |
| XboxGipSvc              | Xbox-Dienste                 | Deaktivieren   | Gaming-Komponenten; auf Servern unnoetig |
| XblAuthManager          | Xbox-Authentifizierung        | Deaktivieren   | Gaming-Komponenten; auf Servern unnoetig |

*RemoteRegistry muss fuer die AD-Promotion temporaer aktiviert werden (wird in `Create_AD.ps1` automatisch gehandhabt).

---

## 🔍 Fehlerbehebung

### Problem: "The request to add or remove features on the specified server failed. The operation cannot be completed, because the server that you specified requires a restart"
- **Loesung:** Das Skript erkennt ausstehende Neustarts automatisch und fuehrt diese durch. Falls das Problem weiterhin besteht:
  - Manuell pruefen, ob ein Neustart aussteht (z. B. ueber `Get-WindowsFeature` oder Registry-Eintraege).
  - Server manuell neu starten und `Create_AD.ps1` erneut ausfuehren.

### Problem: Demo-Daten können nicht angelegt werden
- **Ursache:** Die OUs oder Gruppen existieren noch nicht.
- **Loesung:** `Create_AD.ps1` muss zuerst ausgefuehrt werden, da es die benoetigte OU-Struktur erstellt.

---

## 📜 Changelog

### [Latest](https://github.com/micha-09/powershell-scripts/commit/main)
- **Create_AD.ps1:**
  - **Neue Sicherheitsmassnahme:** Admin-Konto (SID-500) wird waehrend des Setups mit zufaelligem Kennwort gesperrt, erst am Ende wird das gewuenschte Kennwort gesetzt (`-AdminPassword` Parameter)
  - **OU-Struktur angepasst:** Jeder Tier erhaelt eigene 'Service Accounts'- und 'Gruppen'-OUs (T0/T1/T2); globale OUs (Gruppen, ServiceAccounts, Benutzer) entfernt; Tiering-Gruppen liegen in den jeweiligen T*-Gruppen-OUs
  - **Splatting-Refactoring:** `Install-ADDSForest` nutzt jetzt Parameter-Hashtables statt Backtick-Notation (robuster, lesbarer)
  - Korrigierte Neustart-Logik: Maximal 1 Neustart vor der Rolleninstallation
  - `Step-PromoteCheck` fuehrt direkt die Rolleninstallation aus (keine Endlosschleife mehr)
  - Robustere Pruefung auf ausstehende Neustarts (CBS, Windows Update, DISM, etc.)
  - **Neue Tiering-Struktur:** 3-stufiges Sicherheitsmodell (Tier0, Tier1, Tier2)
  - **GPOs mit Zugriffsbeschraenkungen:**
    - User Rights Assignment fuer lokale Anmeldung
    - DenyLogOnThroughRemoteDesktopServices fuer alle Admins
    - RestrictedGroups fuer lokale Administratoren

- **VM_Basic.ps1:**
  - Aktualisierte Liste der zu deaktivierenden Dienste (gemaess Sicherheitsanforderungen)
  - Hinweis zu `RemoteRegistry` (wird fuer AD-Promotion temporaer aktiviert)

- **Create_DemoData.ps1:**
  - Neue Datei: Demo-Daten in separate Datei ausgegliedert
  - Computerkonten werden in den korrekten Tiering-OUs angelegt
  - Erstellt benoetigte OUs falls nicht vorhanden

---

## 📄 Lizenz

Dieses Projekt steht unter der **MIT-Lizenz**. Siehe [LICENSE](./LICENSE) fuer weitere Informationen.
