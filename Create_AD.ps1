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
    [string]$DsrmPassword     = "Fenster2020",
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

    # 5. Pruefe Dism / Image-State (fuer Server 2025)
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

    # Kein Neustart ausstehend - fahre direkt mit der Promotion fort
    Write-Log "Kein ausstehender Neustart - fahre mit Promotion fort."
    
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

# --- Schritt 2: Tiering-Struktur und GPOs erstellen -----------------------
function Step-Populate {
    Write-Log "Schritt 2: Tiering-Struktur und GPOs erstellen."

    # AD-Module sicherstellen
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log "ActiveDirectory Modul fehlt - installiere RSAT."
        Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction SilentlyContinue
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    $domainDN = "DC=" + ($DomainName -split '\.' -join ",DC=")
    $baseDN   = $domainDN
    $adServer = $env:COMPUTERNAME

    # UPN-Suffix setzen
    try {
        Set-ADForest -Identity $NetBiosName -UPNSuffixes @{ Replace = $DomainName } -Server $adServer -ErrorAction SilentlyContinue
    } catch { Write-Log "UPN-Suffix nicht gesetzt: $_" }

    # Tiering-Struktur OUs anlegen
    Write-Log "Erstelle Tiering-Struktur OUs..."
    $tieringOUs = @(
        @{ Name = "Unternehmen";       Path = $baseDN },
        @{ Name = "Tier0";             Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "T0-Admins";         Path = "OU=Tier0,OU=Unternehmen,$baseDN" },
        @{ Name = "T0-Servers";        Path = "OU=Tier0,OU=Unternehmen,$baseDN" },
        @{ Name = "Tier1";             Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "T1-Admins";         Path = "OU=Tier1,OU=Unternehmen,$baseDN" },
        @{ Name = "T1-Servers";        Path = "OU=Tier1,OU=Unternehmen,$baseDN" },
        @{ Name = "Tier2";             Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "T2-Users";          Path = "OU=Tier2,OU=Unternehmen,$baseDN" },
        @{ Name = "T2-Admins";         Path = "OU=Tier2,OU=Unternehmen,$baseDN" },
        @{ Name = "T2-Clients";        Path = "OU=Tier2,OU=Unternehmen,$baseDN" },
        @{ Name = "Gruppen";           Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "ServiceAccounts";  Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Benutzer";          Path = "OU=Unternehmen,$baseDN" }
    )
    foreach ($ou in $tieringOUs) {
        try {
            if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($ou.Name)'" -SearchBase $ou.Path -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -Server $adServer -ErrorAction Stop
                Write-Log "OU angelegt: $($ou.Name) ($($ou.Path))"
            }
        } catch { Write-Log "OU '$($ou.Name)' nicht angelegt: $_" }
    }

    # Sicherheitsgruppen fuer Tiering anlegen
    Write-Log "Erstelle Sicherheitsgruppen fuer Tiering..."
    $tieringGroups = @(
        @{ Name = "T0-Admins";         Desc = "Tier 0 Administratoren (DC, PKI)";          Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "T1-Admins";         Desc = "Tier 1 Administratoren (SQL, Exchange)";    Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "T2-Admins";         Desc = "Tier 2 Administratoren (Helpdesk Level 1)";  Path = "OU=Gruppen,OU=Unternehmen,$baseDN" },
        @{ Name = "T2-Users";          Desc = "Tier 2 Benutzer (Normale Mitarbeiter)";      Path = "OU=Gruppen,OU=Unternehmen,$baseDN" }
    )
    foreach ($g in $tieringGroups) {
        try {
            if (-not (Get-ADGroup -Identity $g.Name -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $g.Name -GroupCategory Security -GroupScope Global -Description $g.Desc -Path $g.Path -Server $adServer -ErrorAction Stop
                Write-Log "Gruppe angelegt: $($g.Name)"
            }
        } catch { Write-Log "Gruppe '$($g.Name)' nicht angelegt: $_" }
    }

    # Funktion zum Erhalten der SID einer Gruppe
    function Get-GroupSID {
        param([string]$GroupName)
        try {
            $group = Get-ADGroup -Identity $GroupName -Server $adServer -Properties SID -ErrorAction SilentlyContinue
            if ($group) {
                return $group.SID.Value
            }
        } catch { Write-Log "SID fuer Gruppe '$GroupName' nicht abgerufen: $_" }
        return ""
    }

    # GPOs fuer Tiering-Struktur erstellen
    Write-Log "Erstelle GPOs fuer Tiering-Enforcement..."
    
    # GPO: T0-Admins duerfen sich nur an T0-Servern anmelden und sind dort Admin
    $gpoT0 = "Tier0-Admin-Zugriff"
    if (-not (Get-GPO -Name $gpoT0 -ErrorAction SilentlyContinue)) {
        Write-Log "Erstelle GPO: $gpoT0"
        $newGPO = New-GPO -Name $gpoT0
        
        # User Rights Assignment: Deny log on locally fuer alle außer T0-Admins
        Set-GPRegistryValue -Name $gpoT0 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "DenyLogOnLocally" -Type MultiString -Value @("T1-Admins", "T1-Server-Admins", "T2-Admins", "T2-Users", "T2-Client-Admins") -ErrorAction SilentlyContinue
        
        # User Rights Assignment: Allow log on locally fuer T0-Admins
        Set-GPRegistryValue -Name $gpoT0 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "AllowLogOnLocally" -Type MultiString -Value @("T0-Admins") -ErrorAction SilentlyContinue
        
        # User Rights Assignment: Deny Remote Desktop Services fuer alle (Admins duerfen kein RDP nutzen)
        Set-GPRegistryValue -Name $gpoT0 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "DenyLogOnThroughRemoteDesktopServices" -Type MultiString -Value @("T0-Admins", "T1-Admins", "T2-Admins", "T2-Users", "T1-Server-Admins", "T2-Client-Admins") -ErrorAction SilentlyContinue
        
        # Restricted Groups: T0-Admins als Mitglieder der lokalen Administratoren
        Set-GPRegistryValue -Name $gpoT0 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Group Policy\RestrictedGroups\Administrators" -ValueName "Members" -Type MultiString -Value @("T0-Admins") -ErrorAction SilentlyContinue
        
        # Verknupfen mit T0-Servers OU
        New-GPLink -Name $gpoT0 -Target "OU=T0-Servers,OU=Tier0,OU=Unternehmen,$baseDN" -LinkEnabled Yes
        Write-Log "GPO '$gpoT0' erstellt und mit T0-Servers verknupft."
    }

    # GPO: T1-Admins duerfen sich nur an T1-Servern anmelden und sind dort Admin
    $gpoT1 = "Tier1-Admin-Zugriff"
    if (-not (Get-GPO -Name $gpoT1 -ErrorAction SilentlyContinue)) {
        Write-Log "Erstelle GPO: $gpoT1"
        $newGPO = New-GPO -Name $gpoT1
        
        # User Rights Assignment: Deny log on locally fuer alle außer T1-Admins
        Set-GPRegistryValue -Name $gpoT1 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "DenyLogOnLocally" -Type MultiString -Value @("T0-Admins", "T0-Server-Admins", "T2-Admins", "T2-Users", "T2-Client-Admins") -ErrorAction SilentlyContinue
        
        # User Rights Assignment: Allow log on locally fuer T1-Admins
        Set-GPRegistryValue -Name $gpoT1 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "AllowLogOnLocally" -Type MultiString -Value @("T1-Admins") -ErrorAction SilentlyContinue
        
        # User Rights Assignment: Deny Remote Desktop Services fuer alle (Admins duerfen kein RDP nutzen)
        Set-GPRegistryValue -Name $gpoT1 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "DenyLogOnThroughRemoteDesktopServices" -Type MultiString -Value @("T0-Admins", "T1-Admins", "T2-Admins", "T2-Users", "T0-Server-Admins", "T2-Client-Admins") -ErrorAction SilentlyContinue
        
        # Restricted Groups: T1-Admins als Mitglieder der lokalen Administratoren
        Set-GPRegistryValue -Name $gpoT1 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Group Policy\RestrictedGroups\Administrators" -ValueName "Members" -Type MultiString -Value @("T1-Admins") -ErrorAction SilentlyContinue
        
        # Verknupfen mit T1-Servers OU
        New-GPLink -Name $gpoT1 -Target "OU=T1-Servers,OU=Tier1,OU=Unternehmen,$baseDN" -LinkEnabled Yes
        Write-Log "GPO '$gpoT1' erstellt und mit T1-Servers verknupft."
    }

    # GPO: T2-Admins/T2-Users duerfen sich nur an T2-Clients anmelden
    $gpoT2 = "Tier2-Zugriff-Kontrolle"
    if (-not (Get-GPO -Name $gpoT2 -ErrorAction SilentlyContinue)) {
        Write-Log "Erstelle GPO: $gpoT2"
        $newGPO = New-GPO -Name $gpoT2
        
        # User Rights Assignment: Deny log on locally fuer alle außer T2-Admins und T2-Users
        Set-GPRegistryValue -Name $gpoT2 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "DenyLogOnLocally" -Type MultiString -Value @("T0-Admins", "T0-Server-Admins", "T1-Admins", "T1-Server-Admins") -ErrorAction SilentlyContinue
        
        # User Rights Assignment: Allow log on locally fuer T2-Admins und T2-Users
        Set-GPRegistryValue -Name $gpoT2 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "AllowLogOnLocally" -Type MultiString -Value @("T2-Admins", "T2-Users") -ErrorAction SilentlyContinue
        
        # User Rights Assignment: Deny Remote Desktop Services fuer alle (Admins duerfen kein RDP nutzen)
        Set-GPRegistryValue -Name $gpoT2 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "DenyLogOnThroughRemoteDesktopServices" -Type MultiString -Value @("T0-Admins", "T1-Admins", "T2-Admins", "T2-Users", "T0-Server-Admins", "T1-Server-Admins") -ErrorAction SilentlyContinue
        
        # Restricted Groups: T2-Admins als Mitglieder der lokalen Administratoren
        Set-GPRegistryValue -Name $gpoT2 -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Group Policy\RestrictedGroups\Administrators" -ValueName "Members" -Type MultiString -Value @("T2-Admins") -ErrorAction SilentlyContinue
        
        # Verknupfen mit T2-Clients OU
        New-GPLink -Name $gpoT2 -Target "OU=T2-Clients,OU=Tier2,OU=Unternehmen,$baseDN" -LinkEnabled Yes
        Write-Log "GPO '$gpoT2' erstellt und mit T2-Clients verknupft."
    }

    # GPO fuer Passwortrichtlinie
    try {
        $gpoName = "Domaenen-Passwortrichtlinie"
        if (-not (Get-GPO -Name $gpoName -ErrorAction SilentlyContinue)) {
            New-GPO -Name $gpoName
            Set-GPRegistryValue -Name $gpoName -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PasswordPolicy" -ValueName "MinimumPasswordLength" -Type DWord -Value 14 -ErrorAction SilentlyContinue
            New-GPLink -Name $gpoName -Target $baseDN -LinkEnabled Yes
            Write-Log "GPO '$gpoName' erstellt und verlinkt."
        }
    } catch { Write-Log "GPO nicht erstellt: $_" }

    Write-Log "Tiering-Struktur und GPOs erfolgreich erstellt."
    Save-Progress -Step "step2finish"
    Invoke-Reboot -NextStepName "Abschluss"
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
