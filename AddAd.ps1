<#
.SYNOPSIS
    Vollautomatisierter Aufbau eines fertig gehaerteten Domain Controllers auf einem nackten Windows Server.

.DESCRIPTION
    Das Skript wird als SYSTEM ausgefuehrt und durchlaeuft mehrere Schritte, die durch geplante
    Aufgaben (Scheduled Tasks) und Neustarts voneinander getrennt sind:

      Schritt 1: Initialisierung   (geplante Aufgabe anlegen, statische IP setzen, Basis-Konfig)
      Schritt 2: Server optimieren  (Powerplan, Dienste, Updates, Zeitzone, etc.)
      Schritt 3: Haerten            (OSConfig Security Baseline fuer Domain Controller, Windows Server 2025)
      Schritt 4: DC hochstufen      (AD DS + DNS installieren, Forest erstellen)
      Schritt 5: Domäne befüllen    (OUs, Gruppen, Benutzer, Computer als Musterdaten)
      Schritt 6: Aufraeumen         (geplante Aufgabe entfernen, Fortschrittsdatei loeschen)

    Nach Abschluss steht ein fertiger, gehaerteter Domain Controller bereit.

    Voraussetzungen:
      - Ausfuehrung als SYSTEM (z.B. ueber geplante Aufgabe mit RunLevel Highest)
      - Windows Server 2025 (Desktop Experience oder Server Core) - Haertung erfolgt rein ueber OSConfig
      - PowerShell-Modul 'Microsoft.OSConfig' muss VOR der Skriptausfuehrung auf dem Server installiert sein
        (Skript bricht in Schritt 3 ab, falls das Modul fehlt)
      - Statische IP / DNS konfigurierbar (wird vom Skript gesetzt, falls gewuenscht)

.PARAMETER DomainName
    FQDN der neuen Gesamtstruktur (z.B. corp.example.com).

.PARAMETER NetBiosName
    NetBIOS-Domaenenname (z.B. CORP).

.PARAMETER DsrmPassword
    Kennwort fuer den Verzeichnisdienst-Wiederherstellungsmodus (DSRM).

.PARAMETER StaticIP
    Statische IP-Adresse, die der primären NIC zugewiesen wird. Leer fuer DHCP.

.PARAMETER DefaultGateway
    Standardgateway fuer die statische Konfiguration. Leer fuer DHCP.

.PARAMETER DnsServer
    DNS-Server fuer die statische Konfiguration (meist die eigene IP nach Promotion).

.PARAMETER DemoUserCount
    Anzahl der Musterbenutzer, die in Schritt 5 angelegt werden.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\AddAd.ps1 -DomainName "corp.example.com" -NetBiosName "CORP" -DsrmPassword "P@ssw0rd!23"
#>

[CmdletBinding()]
param (
    [string]$DomainName      = "corp.example.com",
    [string]$NetBiosName      = "CORP",
    [string]$DsrmPassword     = "P@ssw0rd!2025",
    [string]$StaticIP         = "10.0.0.4",
    [string]$DefaultGateway   = "10.0.0.1",
    [string]$DnsServer        = "127.0.0.1",
    [int]   $DemoUserCount    = 25,
    [string]$LocalAdminName   = "LokalAdmin",
    [string]$LocalAdminPwd    = "P@ssw0rd!2025"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# --- Globale Konfiguration -------------------------------------------------
$scriptPath    = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
$progressFile  = "C:\Temp\AddAd_progress.txt"
$scriptLog     = "C:\Temp\AddAd_$(Get-Date -Format 'yyyyMMdd').log"
$taskName      = "RunAddAdAfterRestart"


# --- Hilfsfunktionen --------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Write-Host $line
    Add-Content -Path $scriptLog -Value $line -ErrorAction SilentlyContinue
}

function Save-Progress {
    param([string]$Step)
    $Step | Out-File -FilePath $progressFile -Force
    Write-Log "Fortschritt gespeichert: $Step"
}

function Invoke-Reboot {
    param([string]$NextStepName)
    Write-Log "Starte Neustart (naechster Schritt: $NextStepName)..."
    Restart-Computer -Force
}

function Create-ScheduledTask {
    Write-Log "Erzeuge geplante Aufgabe '$taskName' fuer den Autostart nach Neustart."
    $action    = New-ScheduledTaskAction    -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -DomainName `"$DomainName`" -NetBiosName `"$NetBiosName`" -DsrmPassword `"$DsrmPassword`" -StaticIP `"$StaticIP`" -DefaultGateway `"$DefaultGateway`" -DnsServer `"$DnsServer`" -DemoUserCount $DemoUserCount -LocalAdminName `"$LocalAdminName`" -LocalAdminPwd `"$LocalAdminPwd`""
    $trigger   = New-ScheduledTaskTrigger   -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Remove-ScheduledTask {
    Write-Log "Entferne geplante Aufgabe '$taskName'."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

# --- Lokalisierung auf Deutsch (System, Welcome Screen, Default User) -----
function Set-GermanLocalization {
    Write-Log "Konfiguriere deutsche Lokalisierung / regionale Einstellungen."

    # Region und Formate auf Deutsch (Deutschland) setzen
    Set-Culture de-DE
    Set-WinHomeLocation -GeoId 94

    # Tastaturlayout auf Deutsch (Standard) setzen
    Set-WinUserLanguageList -LanguageList de-DE -Force

    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true

    Write-Log "Deutsche Lokalisierung gesetzt (Region, Tastatur, UI-Sprache, Welcome Screen, Default User)."
}

function Set-StaticIPConfig {
    if ([string]::IsNullOrWhiteSpace($StaticIP)) {
        Write-Log "Keine statische IP konfiguriert - verwende bestehende (DHCP) Konfiguration."
        return
    }
    $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $nic) { Write-Log "Keine aktive Netzwerkkarte gefunden - ueberspringe IP-Konfiguration."; return }
    $prefix = (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixLength }).PrefixLength
    if (-not $prefix) { $prefix = 24 }
    Write-Log "Setze statische IP $StaticIP/$prefix an Interface '$($nic.Name)'."
    $ifIndex = $nic.ifIndex
    Remove-NetIPAddress   -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute      -InterfaceIndex $ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress     -InterfaceIndex $ifIndex -IPAddress $StaticIP -PrefixLength $prefix -DefaultGateway $DefaultGateway | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @($DnsServer) | Out-Null
}

# --- Schritt 1: Initialisierung --------------------------------------------
function Step-Init {
    Write-Log "Schritt 1: Initialisierung."
    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
    Add-Content -Path $scriptLog -Value "---- Neue Skriptausfuehrung gestartet $(Get-Date) ----"
    Set-StaticIPConfig
    # Ermoeglichen spaeterer RDP-Verwaltung (optional, niedrigste Privilegien)
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -ErrorAction SilentlyContinue
    Create-ScheduledTask
    Save-Progress -Step "step1finish"
    Invoke-Reboot -NextStepName "Optimierung"
}

# --- Schritt 2: Server optimieren ------------------------------------------
function Step-Optimize {
    Write-Log "Schritt 2: Server optimieren."

    # Powerplan auf Hoechstleistung (fuer DC-Betrieb deterministisch)
    try {
        $hp = powercfg /list | Select-String "Hoechstleistung|High performance|Ultimate"
        if (-not $hp) { powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null }
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        powercfg -setactive SCHEME_MIN 2>$null
        Write-Log "Powerplan auf Hoechstleistung gesetzt."
    } catch { Write-Log "Powerplan konnte nicht gesetzt werden: $_" }

    # Zeitsynchronisation
    try {
        Set-TimeZone -Id "W. Europe Standard Time" -ErrorAction SilentlyContinue
        w32tm /config /manualpeerlist:"time.windows.com,0x1" /syncfromflags:manual /update 2>$null | Out-Null
        Write-Log "Zeitzone und NTP konfiguriert."
    } catch { Write-Log "Zeitkonfiguration fehlgeschlagen: $_" }

    # Deutsche Lokalisierung / regionale Einstellungen fuer alle Benutzer, zukuenftige
    # Benutzer und den Welcome Screen (auf englischen Server-OS).
    Set-GermanLocalization

    # Ueberfluessige Dienste deaktivieren (Beispiele, die auf einem DC nicht benoetigt werden)
    $servicesToDisable = @(
        "DiagTrack",            # Telemetrie
        "dmwappushservice",     # Telemetrie
        "SysMain",              # Superfetch (auf Server nicht relevant)
        "WSearch",              # Windows Search (auf DC ressourcenlastig)
        "PrintSpooler",         # Druckerdienst (nur falls kein Printserver)
        "RemoteRegistry",      # Remote-Registry reduzieren
        "lfsvc"                 # Standortdienst
    )
    foreach ($svc in $servicesToDisable) {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s) {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Log "Dienst deaktiviert: $svc"
            }
        } catch { Write-Log "Dienst $svc konnte nicht deaktiviert werden: $_" }
    }

    # Windows Update auf "Benachrichtigung" (kein automatischer Neustart waehrend Domaenenbetrieb)
    try {
        $wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
        if (-not (Test-Path $wuKey)) { New-Item -Path $wuKey -Force | Out-Null }
        Set-ItemProperty -Path $wuKey -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
        Set-ItemProperty -Path $wuKey -Name "AUOptions" -Value 2 -Type DWord
        Write-Log "Windows Update konfiguriert (kein automatischer Reboot)."
    } catch { Write-Log "Windows Update Konfiguration fehlgeschlagen: $_" }

    # IPv6 nicht deaktivieren - DC/DNS benoetigt ggfs. IPv6; nur RAS deaktivieren
    Disable-NetAdapterBinding -Name "*" -ComponentID "ms_rspndr","ms_lltdio" -ErrorAction SilentlyContinue
    Write-Log "Unnoetige Protokollbindungen (LLTD/RSPNDR) deaktiviert."

    # SMB1 deaktivieren (Sicherheit)
    try {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
        Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue
        Write-Log "SMB1 deaktiviert."
    } catch { Write-Log "SMB1 Deaktivierung fehlgeschlagen: $_" }

    # Windows Defender Echtzeitschutz aktiv lassen (auf DC empfohlen), aber Ausschluesse fuer AD
    try {
        Add-MpPreference -ExclusionPath "C:\Windows\NTDS","C:\Windows\SYSVOL","C:\Windows\System32\ntds.dit" -ErrorAction SilentlyContinue
        Write-Log "Defender-Ausschluesse fuer AD-Verzeichnisse gesetzt."
    } catch { Write-Log "Defender-Ausschluesse nicht gesetzt: $_" }

    # Temp bereinigen
    Get-ChildItem "C:\Windows\Temp","$env:TEMP" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Lokaler Administrator umbenennen und Kennwort setzen (falls vorhanden)
    try {
        $admin = Get-LocalUser | Where-Object { $_.SID -like "S-1-5-21-*-500" }
        if ($admin) {
            Rename-LocalUser -Name $admin.Name -NewName $LocalAdminName -ErrorAction SilentlyContinue
            Set-LocalUser -Name $LocalAdminName -Password (ConvertTo-SecureString $LocalAdminPwd -AsPlainText -Force) -ErrorAction SilentlyContinue
            Enable-LocalUser -Name $LocalAdminName -ErrorAction SilentlyContinue
            Write-Log "Lokaler Administrator umbenannt/aktiviert: $LocalAdminName"
        }
    } catch { Write-Log "Lokaler Administrator nicht angepasst: $_" }

    Save-Progress -Step "step2finish"
    Invoke-Reboot -NextStepName "Haertung"
}

# --- Schritt 3: Haerten (OSConfig, Windows Server 2025) -------------------
function Step-Harden {
    Write-Log "Schritt 3: Haerten ueber OSConfig (Windows Server 2025)."

    # OSConfig: Voraussetzung ist das vorab installierte Modul 'Microsoft.OSConfig'.
    # Es wird NICHT durch dieses Skript installiert - fehlt es, wird Schritt 3 abgebrochen,
    # damit der DC nicht ohne Haertung weiter hochgestuft wird.
    if (-not (Get-Module -ListAvailable -Name Microsoft.OSConfig)) {
        Write-Log "ABBRUCH: Modul 'Microsoft.OSConfig' ist nicht installiert. Es muss vor der Skriptausfuehrung auf dem Server installiert sein."
        throw "Voraussetzung nicht erfuellt: Microsoft.OSConfig Modul fehlt. Installation vorab erforderlich."
    }
    Write-Log "OSConfig-Modul gefunden. Importiere..."
    Import-Module Microsoft.OSConfig -ErrorAction Stop

    # DC-Security-Baseline als Desired Configuration anwenden.
    # Windows Server 2025 stellt DSC-basierte Security Baselines bereit; der Scenario-Pfad
    # "SecurityBaseline/WindowsServer/2025/DomainController" haertet den Server passend fuer einen DC.
    try {
        Write-Log "Wende OSConfig DC-Security-Baseline an (Scenario SecurityBaseline/WindowsServer/2025/DomainController)..."
        Set-OSConfigDesiredConfiguration -Scenario "SecurityBaseline/WindowsServer/2025/DomainController" -Default -ErrorAction Stop
        Write-Log "OSConfig DC-Security-Baseline erfolgreich angewendet."
    } catch {
        Write-Log "OSConfig-Baseline konnte nicht angewendet werden: $_"
        throw $_
    }

    Save-Progress -Step "step3finish"
    Invoke-Reboot -NextStepName "Domain Controller Promotion"
}

# --- Schritt 4: Domain Controller hochstufen -------------------------------
function Step-Promote {
    Write-Log "Schritt 4: Server zum Domain Controller hochstufen."

    # AD DS und DNS Rollen installieren
    Write-Log "Installiere Windows-Features AD-Domain-Services und DNS..."
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null

    # Pruefen, ob bereits DC ist
    $isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
    if ($isDC) {
        Write-Log "Server ist bereits Domain Controller - Promotion uebersprungen."
    } else {
        $secureDsrm = ConvertTo-SecureString $DsrmPassword -AsPlainText -Force
        Write-Log "Erstelle neue Gesamtstruktur '$DomainName' (NetBIOS $NetBiosName)..."
        Install-ADDSForest `
            -DomainName $DomainName `
            -DomainNetbiosName $NetBiosName `
            -SafeModeAdministratorPassword $secureDsrm `
            -InstallDNS `
            -NoRebootOnCompletion `
            -Force `
            -ErrorAction Stop | Out-Null
        Write-Log "Neue Gesamtstruktur erstellt."
    }

    Save-Progress -Step "step4finish"
    Invoke-Reboot -NextStepName "Promotion abschliessen & Musterdaten"
}

# --- Schritt 5: Domaene mit Musterdaten befüllen ----------------------------
function Step-Populate {
    Write-Log "Schritt 5: Musterdaten in die Domaene laden."

    # AD-Module sicherstellen
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log "ActiveDirectory Modul fehlt - installiere RSAT."
        Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction SilentlyContinue | Out-Null
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    # Warte, bis der DC nach dem Reboot voll verfuegbar ist
    $retries = 0
    while (-not (Get-Service -Name NTDS -ErrorAction SilentlyContinue) -and $retries -lt 30) {
        Start-Sleep -Seconds 10; $retries++
    }
    Start-Sleep -Seconds 15

    $domainDN = "DC=" + ($DomainName -split '\.' -join ",DC=")
    $baseDN   = $domainDN
    $adServer = $env:COMPUTERNAME

    # UPN-Suffix setzen
    try {
        Set-ADForest -Identity $NetBiosName -UPNSuffixes @{ Replace = $DomainName } -Server $adServer -ErrorAction SilentlyContinue
    } catch { Write-Log "UPN-Suffix nicht gesetzt: $_" }

    # OUs anlegen
    $ouList = @(
        @{ Name = "Unternehmen";       Path = $baseDN },
        @{ Name = "Benutzer";          Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Administratoren";   Path = "OU=Benutzer,OU=Unternehmen,$baseDN" },
        @{ Name = "ServiceAccounts";  Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Gruppen";           Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Server";            Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Clients";           Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Computer";          Path = "OU=Unternehmen,$baseDN" }
    )
    foreach ($ou in $ouList) {
        try {
            if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($ou.Name)'" -SearchBase $ou.Path -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -Server $adServer -ErrorAction Stop
                Write-Log "OU angelegt: $($ou.Name) ($($ou.Path))"
            }
        } catch { Write-Log "OU '$($ou.Name)' nicht angelegt: $_" }
    }

    # Sicherheitsgruppen anlegen
    $groups = @(
        @{ Name = "GG_IT_Admin";       Desc = "IT Administratoren";       Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "GG_Helpdesk";       Desc = "Helpdesk-Mitarbeiter";     Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "GG_Mitarbeiter";    Desc = "Alle Mitarbeiter";         Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "GG_Finanzen";       Desc = "Finanzabteilung";          Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "GG_Entwicklung";    Desc = "Entwickler";               Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "GG_ServerAdmin";    Desc = "Server-Administratoren";    Path = "OU=Gruppen,OU=Unternehmen,$baseDN" }
    )
    foreach ($g in $groups) {
        try {
            if (-not (Get-ADGroup -Identity $g.Name -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $g.Name -GroupCategory Security -GroupScope Global -Description $g.Desc -Path $g.Path -Server $adServer -ErrorAction Stop
                Write-Log "Gruppe angelegt: $($g.Name)"
            }
        } catch { Write-Log "Gruppe '$($g.Name)' nicht angelegt: $_" }
    }

    # Musterbenutzer anlegen
    $depts = @("IT","Helpdesk","Finanzen","Entwicklung","Vertrieb","HR")
    $securePwd = ConvertTo-SecureString "P@ssw0rd!2025" -AsPlainText -Force
    $userOU = "OU=Benutzer,OU=Unternehmen,$baseDN"
    for ($i = 1; $i -le $DemoUserCount; $i++) {
        $dept   = $depts[(($i - 1) % $depts.Count)]
        $fn     = "Demo"
        $ln     = "User{0:D2}" -f $i
        $uname  = "$fn.$ln"
        $upn    = "$uname@$DomainName"
        try {
            if (-not (Get-ADUser -Identity $uname -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADUser `
                    -Name $uname `
                    -GivenName $fn `
                    -Surname $ln `
                    -DisplayName "$fn $ln" `
                    -SamAccountName $uname `
                    -UserPrincipalName $upn `
                    -Path $userOU `
                    -AccountPassword $securePwd `
                    -Enabled $true `
                    -Department $dept `
                    -Server $adServer `
                    -ErrorAction Stop | Out-Null
                # Mitgliedschaft nach Abteilung
                $grp = switch ($dept) {
                    "IT"          { "GG_IT_Admin" }
                    "Helpdesk"    { "GG_Helpdesk" }
                    "Finanzen"    { "GG_Finanzen" }
                    "Entwicklung" { "GG_Entwicklung" }
                    default       { "GG_Mitarbeiter" }
                }
                Add-ADGroupMember -Identity $grp -Members $uname -Server $adServer -ErrorAction SilentlyContinue
                Add-ADGroupMember -Identity "GG_Mitarbeiter" -Members $uname -Server $adServer -ErrorAction SilentlyContinue
                Write-Log "Benutzer angelegt: $uname ($dept -> $grp)"
            }
        } catch { Write-Log "Benutzer '$uname' nicht angelegt: $_" }
    }

    # Service-Accounts (gMSA-geeignete Konten als Muster)
    $svcOU = "OU=ServiceAccounts,OU=Unternehmen,$baseDN"
    $svcAccounts = @("svc_backup","svc_monitoring","svc_join","svc_print")
    foreach ($svc in $svcAccounts) {
        try {
            if (-not (Get-ADUser -Identity $svc -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADUser `
                    -Name $svc `
                    -SamAccountName $svc `
                    -UserPrincipalName "$svc@$DomainName" `
                    -Path $svcOU `
                    -AccountPassword $securePwd `
                    -Enabled $true `
                    -Description "Service-Konto (Muster)" `
                    -Server $adServer | Out-Null
                Write-Log "Service-Konto angelegt: $svc"
            }
        } catch { Write-Log "Service-Konto '$svc' nicht angelegt: $_" }
    }

    # Muster-Computerkonten (Clients) anlegen
    $clientOU = "OU=Clients,OU=Unternehmen,$baseDN"
    for ($i = 1; $i -le 10; $i++) {
        $cname = "CL-WS{0:D3}" -f $i
        try {
            if (-not (Get-ADComputer -Identity $cname -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADComputer -Name $cname -Path $clientOU -Description "Muster-Client $i" -Server $adServer -ErrorAction Stop | Out-Null
                Write-Log "Computerkonto angelegt: $cname"
            }
        } catch { Write-Log "Computerkonto '$cname' nicht angelegt: $_" }
    }

    # Muster-Serverkonten
    $serverOU = "OU=Server,OU=Unternehmen,$baseDN"
    for ($i = 1; $i -le 5; $i++) {
        $cname = "SRV-APP{0:D2}" -f $i
        try {
            if (-not (Get-ADComputer -Identity $cname -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADComputer -Name $cname -Path $serverOU -Description "Muster-Server $i" -Server $adServer -ErrorAction Stop | Out-Null
                Write-Log "Server-Konto angelegt: $cname"
            }
        } catch { Write-Log "Server-Konto '$cname' nicht angelegt: $_" }
    }

    # GPO fuer Password-Richtlinie als additional hardening
    try {
        $gpoName = "Domaenen-Passwortrichtlinie"
        if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
            New-GPO -Name $gpoName | Out-Null
            Set-GPRegistryValue -Name $gpoName -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PasswordPolicy" -ValueName "MinimumPasswordLength" -Type DWord -Value 14 -ErrorAction SilentlyContinue
            New-GPLink -Name $gpoName -Target $baseDN -LinkEnabled Yes | Out-Null
            Write-Log "GPO '$gpoName' erstellt und verlinkt."
        }
    } catch { Write-Log "GPO nicht erstellt: $_" }

    Write-Log "Musterdaten erfolgreich in die Domaene geladen."
    Save-Progress -Step "step5finish"
    Invoke-Reboot -NextStepName "Abschluss"
}

# --- Schritt 6: Aufraeumen -------------------------------------------------
function Step-Cleanup {
    Write-Log "Schritt 6: Aufraeumen - Domaene ist fertig."
    Remove-ScheduledTask
    Remove-Item -Path $progressFile -Force -ErrorAction SilentlyContinue
    # Letzte Haertungs-Verifikation nach Abschluss
    try {
        gpupdate /force 2>$null | Out-Null
        Write-Log "Gruppenrichtlinien aktualisiert."
    } catch { }
    Write-Log "Skript abgeschlossen. Domain Controller $NetBiosName ($DomainName) ist einsatzbereit."
}

# --- Hauptsteuerung --------------------------------------------------------
try {
    $current = if (Test-Path $progressFile) { (Get-Content $progressFile -Raw).Trim() } else { "" }

    switch ($current) {
        ""            { Step-Init }
        "step1finish" { Step-Optimize }
        "step2finish" { Step-Harden }
        "step3finish" { Step-Promote }
        "step4finish" { Step-Populate }
        "step5finish" { Step-Cleanup }
        default {
            Write-Log "Unbekannter Fortschrittsstatus '$current'. Breche ab."
            Remove-ScheduledTask
            throw "Ungueltiger Fortschritt: $current"
        }
    }
}
catch {
    Write-Log "Fehler aufgetreten: $($_.Exception.Message)"
    Write-Log "Stack: $($_.ScriptStackTrace)"
    # Bei Fehler nicht automatisch rebooten - Administrator kann Log pruefen
    exit 1
}
