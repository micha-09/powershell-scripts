<#
.SYNOPSIS
    AD-Erstellung: Server zum Domain Controller hochstufen und Domaene mit Musterdaten befuellen.

.DESCRIPTION
    Das Skript wird als SYSTEM ausgefuehrt und durchlaeuft mehrere Schritte, die durch geplante
    Aufgaben (Scheduled Tasks) und Neustarts voneinander getrennt sind. Es setzt voraus, dass
    der Server vorher mit VM_Basic.ps1 optimiert und gehaertet wurde.

      Schritt 1: DC hochstufen  (AD DS + DNS installieren, Forest erstellen)
      Schritt 2: Domaene befuellen (OUs, Gruppen, Benutzer, Computer als Musterdaten)
      Schritt 3: Aufraeumen     (geplante Aufgabe entfernen, Fortschrittsdatei loeschen)

    Nach Abschluss steht ein fertiger, gehaerteter Domain Controller bereit.

    Wo moeglich werden Befehle mit -Verbose ausgefuehrt und die Ausgabe ins Log geschrieben.

    Voraussetzungen:
      - Ausfuehrung als SYSTEM (z.B. ueber geplante Aufgabe mit RunLevel Highest)
      - Vorheriger Durchlauf von VM_Basic.ps1 (Optimierung + Haertung)
      - Windows Server 2025

.PARAMETER DomainName
    FQDN der neuen Gesamtstruktur (z.B. corp.example.com).

.PARAMETER NetBiosName
    NetBIOS-Domaenenname (z.B. CORP).

.PARAMETER DsrmPassword
    Kennwort fuer den Verzeichnisdienst-Wiederherstellungsmodus (DSRM).

.PARAMETER DemoUserCount
    Anzahl der Musterbenutzer, die in Schritt 2 angelegt werden.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Create_AD.ps1 -DomainName "corp.example.com" -NetBiosName "CORP" -DsrmPassword "P@ssw0rd!2025"
#>

[CmdletBinding()]
param (
    [string]$DomainName      = "corp.example.com",
    [string]$NetBiosName      = "CORP",
    [string]$DsrmPassword     = "P@ssw0rd!2025",
    [int]   $DemoUserCount    = 25
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# --- Globale Konfiguration -------------------------------------------------
$scriptPath    = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
$progressFile  = "C:\Temp\Create_AD_progress.txt"
$scriptLog     = "C:\Temp\Create_AD_$(Get-Date -Format 'yyyyMMdd').log"
$taskName      = "RunCreateADAfterRestart"

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
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -DomainName `"$DomainName`" -NetBiosName `"$NetBiosName`" -DsrmPassword `"$DsrmPassword`" -DemoUserCount $DemoUserCount"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
}

function Remove-ScheduledTask {
    Write-Log "Entferne geplante Aufgabe '$taskName'."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

# Prueft, ob ein Neustart des Servers aussteht (Windows Features, Updates, etc.)
function Test-PendingReboot {
    Write-Log "Pruefe, ob ein Neustart aussteht..."
    
    # 1. Pruefe Windows Feature-Installation (CBS/Component-Based Servicing)
    $pendingRebootCBS = $false
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\ServerManager\ServicingParameters"
        if (Test-Path $regPath) {
            $pending = Get-ItemProperty -Path $regPath -Name "PendingReboot" -ErrorAction SilentlyContinue
            if ($pending -and $pending.PendingReboot -eq 1) {
                $pendingRebootCBS = $true
                Write-Log "Ausstehender Neustart erkannt: Windows Features (CBS)."
            }
        }
    } catch { Write-Log "Fehler bei CBS-Reboot-Pruefung: $_" }

    # 2. Pruefe Windows Update / Hotfix (WUA)
    $pendingRebootWUA = $false
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        if (Test-Path $regPath) {
            $pendingRebootWUA = $true
            Write-Log "Ausstehender Neustart erkannt: Windows Update."
        }
    } catch { Write-Log "Fehler bei WUA-Reboot-Pruefung: $_" }

    # 3. Pruefe Component-Based Servicing (CBS) Registry
    $pendingRebootCBS2 = $false
    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
        if (Test-Path $regPath) {
            $pendingRebootCBS2 = $true
            Write-Log "Ausstehender Neustart erkannt: CBS RebootPending."
        }
    } catch { Write-Log "Fehler bei CBS-RebootPending-Pruefung: $_" }

    # 4. Pruefe PendFileRenameOperations (Datei-Operationen, die Neustart erfordern)
    $pendingFileOps = $false
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $pending = Get-ItemProperty -Path $regPath -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
        if ($pending -and $pending.PendingFileRenameOperations) {
            $pendingFileOps = $true
            Write-Log "Ausstehender Neustart erkannt: PendingFileRenameOperations."
        }
    } catch { Write-Log "Fehler bei PendingFileRenameOperations-Pruefung: $_" }

    # 5. Pruefe Dism / Image-State (für Server 2025)
    $pendingDism = $false
    try {
        $result = Dism /Online /Get-Packages | Select-String "Pending"
        if ($result) {
            $pendingDism = $true
            Write-Log "Ausstehender Neustart erkannt: DISM Paket-Operationen."
        }
    } catch { Write-Log "Fehler bei DISM-Pruefung: $_" }

    $needsReboot = $pendingRebootCBS -or $pendingRebootWUA -or $pendingRebootCBS2 -or $pendingFileOps -or $pendingDism
    
    if ($needsReboot) {
        Write-Log "Ausstehender Neustart erkannt! Server muss neu gestartet werden."
    } else {
        Write-Log "Kein ausstehender Neustart erkannt."
    }
    
    return $needsReboot
}

# Versucht, haengende Neustart-Anforderungen zu bereinigen (falls moeglich)
function Clear-PendingReboot {
    Write-Log "Versuche, haengende Neustart-Anforderungen zu bereinigen..."
    
    try {
        # Versuche, PendingFileRenameOperations zurueckzusetzen
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        if (Test-Path $regPath) {
            $pending = Get-ItemProperty -Path $regPath -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
            if ($pending -and $pending.PendingFileRenameOperations) {
                Write-Log "Bereinige PendingFileRenameOperations..."
                Remove-ItemProperty -Path $regPath -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
            }
        }
    } catch { Write-Log "Fehler beim Bereinigen von PendingFileRenameOperations: $_" }

    try {
        # Versuche, CBS-RebootPending zurueckzusetzen
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing"
        if (Test-Path $regPath) {
            Remove-ItemProperty -Path $regPath -Name "RebootPending" -ErrorAction SilentlyContinue
            Write-Log "Bereinige CBS RebootPending..."
        }
    } catch { Write-Log "Fehler beim Bereinigen von CBS RebootPending: $_" }

    try {
        # Versuche, ServerManager-Reboot-Flag zurueckzusetzen
        $regPath = "HKLM:\SOFTWARE\Microsoft\ServerManager\ServicingParameters"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name "PendingReboot" -Value 0 -ErrorAction SilentlyContinue
            Write-Log "Bereinige ServerManager PendingReboot..."
        }
    } catch { Write-Log "Fehler beim Bereinigen von ServerManager PendingReboot: $_" }
}

# --- Schritt 1: Domain Controller hochstufen -------------------------------
function Step-Promote {
    Write-Log "Schritt 1: Server zum Domain Controller hochstufen."

    # Pruefe zu beginn ob neustarts ausstehen, falls ja neustarten
    if (Test-PendingReboot) {
        Write-Log "Ausstehender Neustart erkannt. Fuehre Neustart durch..."
        Save-Progress -Step "step1reboot_check"
        Invoke-Reboot -NextStepName "AD-Promotion (Neustart-Pruefung)"
        return
    }

    # RemoteRegistry temporaer aktivieren (benoetigt fuer AD-Promotion)
    Write-Log "Aktiviere RemoteRegistry-Dienst temporaer fuer AD-Promotion..."
    try {
        $svc = Get-Service -Name "RemoteRegistry" -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name "RemoteRegistry" -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name "RemoteRegistry" -ErrorAction SilentlyContinue
            Write-Log "RemoteRegistry-Dienst aktiviert und gestartet."
        }
    } catch { Write-Log "RemoteRegistry konnte nicht aktiviert werden: $_" }

    # AD DS und DNS Rollen installieren
    Write-Log "Installiere Windows-Features AD-Domain-Services und DNS..."
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools -ErrorAction Stop

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
            -ErrorAction Stop `
           
        Write-Log "Neue Gesamtstruktur erstellt."
    }
    Write-Log "Deaktiviere RemoteRegistry-Dienst wieder nach AD-Promotion..."
    try {
        $svc = Get-Service -Name "RemoteRegistry" -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service -Name "RemoteRegistry" -Force -ErrorAction SilentlyContinue
            Set-Service -Name "RemoteRegistry" -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "RemoteRegistry-Dienst deaktiviert."
        }
    } catch { Write-Log "RemoteRegistry konnte nicht deaktiviert werden: $_" }

    Save-Progress -Step "step1finish"
    Invoke-Reboot -NextStepName "Haertung als Domain Controller"
}

# --- Schritt 1b: Haerten als Domain Controller (OSConfig) ----------------
# Nach der Promotion wird die DC-spezifische Security Baseline angewendet.
function Step-HardenDC {
    Write-Log "Schritt 1b: Haerten als Domain Controller ueber OSConfig (Windows Server 2025)."

    if (-not (Get-Module -ListAvailable -Name Microsoft.OSConfig)) {
        Write-Log "ABBRUCH: Modul 'Microsoft.OSConfig' ist nicht installiert. Es muss vor der Skriptausfuehrung auf dem Server installiert sein."
        throw "Voraussetzung nicht erfuellt: Microsoft.OSConfig Modul fehlt. Installation vorab erforderlich."
    }
    Write-Log "OSConfig-Modul gefunden. Importiere..."
    Import-Module Microsoft.OSConfig -ErrorAction Stop

    try {
        Write-Log "Wende OSConfig DC-Security-Baseline an (Scenario SecurityBaseline/WindowsServer/2025/DomainController)..."
        Set-OSConfigDesiredConfiguration -Scenario SecurityBaseline/WindowsServer/2025/DomainController -Default -ErrorAction Stop
        Write-Log "OSConfig DC-Security-Baseline erfolgreich angewendet."
    } catch {
        Write-Log "OSConfig-Baseline konnte nicht angewendet werden: $_"
        throw $_
    }

    Save-Progress -Step "step1hardenfinish"
    Invoke-Reboot -NextStepName "Musterdaten einspielen"
}

# --- Schritt 2: Domaene mit Musterdaten befuellen --------------------------
function Step-Populate {
    Write-Log "Schritt 2: Musterdaten in die Domaene laden."

    # AD-Module sicherstellen
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log "ActiveDirectory Modul fehlt - installiere RSAT."
        Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction SilentlyContinue
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
                    -ErrorAction Stop `
                   
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
                    -Server $adServer `
                   
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
                New-ADComputer -Name $cname -Path $clientOU -Description "Muster-Client $i" -Server $adServer -ErrorAction Stop
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
                New-ADComputer -Name $cname -Path $serverOU -Description "Muster-Server $i" -Server $adServer -ErrorAction Stop
                Write-Log "Server-Konto angelegt: $cname"
            }
        } catch { Write-Log "Server-Konto '$cname' nicht angelegt: $_" }
    }

    # GPO fuer Password-Richtlinie als additional hardening
    try {
        $gpoName = "Domaenen-Passwortrichtlinie"
        if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
            New-GPO -Name $gpoName
            Set-GPRegistryValue -Name $gpoName -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PasswordPolicy" -ValueName "MinimumPasswordLength" -Type DWord -Value 14 -ErrorAction SilentlyContinue
            New-GPLink -Name $gpoName -Target $baseDN -LinkEnabled Yes
            Write-Log "GPO '$gpoName' erstellt und verlinkt."
        }
    } catch { Write-Log "GPO nicht erstellt: $_" }

    Write-Log "Musterdaten erfolgreich in die Domaene geladen."
    Save-Progress -Step "step2finish"
    Invoke-Reboot -NextStepName "Abschluss"
}

# --- Schritt 3: Aufraeumen -------------------------------------------------
function Step-Cleanup {
    Write-Log "Schritt 3: Aufraeumen - Domaene ist fertig."
    Remove-ScheduledTask
    Remove-Item -Path $progressFile -Force -ErrorAction SilentlyContinue
    # Letzte GPO-Verifikation nach Abschluss
    try {
        gpupdate /force 2>$null | Out-Null
        Write-Log "Gruppenrichtlinien aktualisiert."
    } catch { }
    Write-Log "Skript abgeschlossen. Domain Controller $NetBiosName ($DomainName) ist einsatzbereit."
}

# --- Schritt 1b: AD-Promotion (Rolleninstallation nach Neustart-Pruefung) ---
# Nach Neustart: Pruefe nochmal ob Neustarts ausstehen, falls ja clearing durchfuehren
# und dann direkt mit der Rolleninstallation weitermachen
function Step-PromoteCheck {
    Write-Log "Schritt 1b: Pruefe nach Neustart auf ausstehende Aenderungen..."
    
    # Pruefe nach diesem neustart nochmal ob Neustarts ausstehen, falls ja mache das clearing der pending reboots
    if (Test-PendingReboot) {
        Write-Log "Ausstehender Neustart immer noch erkannt. Bereinige Flags..."
        Clear-PendingReboot
        Start-Sleep -Seconds 5
    }
    
    # Anschliessend direkt mit der Rolleninstallation weitermachen (ohne Step-Promote aufzurufen)
    Write-Log "Fahre mit der Rolleninstallation fort..."
    
    # RemoteRegistry temporaer aktivieren (benoetigt fuer AD-Promotion)
    Write-Log "Aktiviere RemoteRegistry-Dienst temporaer fuer AD-Promotion..."
    try {
        $svc = Get-Service -Name "RemoteRegistry" -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name "RemoteRegistry" -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name "RemoteRegistry" -ErrorAction SilentlyContinue
            Write-Log "RemoteRegistry-Dienst aktiviert und gestartet."
        }
    } catch { Write-Log "RemoteRegistry konnte nicht aktiviert werden: $_" }

    # AD DS und DNS Rollen installieren
    Write-Log "Installiere Windows-Features AD-Domain-Services und DNS..."
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools -ErrorAction Stop

    # Pruefen, ob bereits DC ist
    $isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4
    if ($isDC) {
        Write-Log "Server ist bereits Domain Controller - Promotion uebersprungen."
    } else {
        $secureDsrm = ConvertTo-SecureString $DsrmPassword -AsPlainText -Force
        Write-Log "Erstelle neue Gesamtstruktur '$DomainName' (NetBIOS $NetBiosName)..."
        Install-ADDSForest `\
            -DomainName $DomainName `\
            -DomainNetbiosName $NetBiosName `\
            -SafeModeAdministratorPassword $secureDsrm `\
            -InstallDNS `\
            -NoRebootOnCompletion `\
            -Force `\
            -ErrorAction Stop `\
           
        Write-Log "Neue Gesamtstruktur erstellt."
    }
    Write-Log "Deaktiviere RemoteRegistry-Dienst wieder nach AD-Promotion..."
    try {
        $svc = Get-Service -Name "RemoteRegistry" -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service -Name "RemoteRegistry" -Force -ErrorAction SilentlyContinue
            Set-Service -Name "RemoteRegistry" -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "RemoteRegistry-Dienst deaktiviert."
        }
    } catch { Write-Log "RemoteRegistry konnte nicht deaktiviert werden: $_" }

    Save-Progress -Step "step1finish"
    Invoke-Reboot -NextStepName "Haertung als Domain Controller"
}

# --- Hauptsteuerung --------------------------------------------------------
try {
    $current = if (Test-Path $progressFile) { (Get-Content $progressFile -Raw).Trim() } else { "" }

    switch ($current) {
        ""                     { Create-ScheduledTask; Step-Promote }
        "step1reboot_check"    { Step-PromoteCheck }
        "step1finish"          { Step-HardenDC }
        "step1hardenfinish"    { Step-Populate }
        "step2finish"          { Step-Cleanup }
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
    exit 1
}
