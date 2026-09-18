<#
.SYNOPSIS
    Allgemeiner Teil: nackten Windows Server optimieren und haerten.

.DESCRIPTION
    Das Skript wird als SYSTEM ausgefuehrt und durchlaeuft mehrere Schritte, die durch geplante
    Aufgaben (Scheduled Tasks) und Neustarts voneinander getrennt sind:

      Schritt 1: Initialisierung   (geplante Aufgabe anlegen, ggf. statische IP setzen, Basis-Konfig)
      Schritt 2: Server optimieren  (Powerplan, Dienste, Updates, Zeitzone, deutsche Lokalisierung, etc.)
      Schritt 3: Aufraeumen        (geplante Aufgabe entfernen, Fortschrittsdatei loeschen)

    Nach Abschluss steht ein fertig optimierter Server bereit, der anschliessend
    z.B. mit Create_AD.ps1 zum Domain Controller hochgestuft wird (Haertung dort).

    Das Setzen einer statischen IP wird auf in Azure erstellten Maschinen automatisch
    uebersprungen (Erkennung ueber den Azure Guest Agent Dienst).

    Voraussetzungen:
      - Ausfuehrung als SYSTEM (z.B. ueber geplante Aufgabe mit RunLevel Highest)
      - Windows Server 2025 (Desktop Experience oder Server Core)
      - Statische IP / DNS konfigurierbar (wird vom Skript gesetzt, falls gewuenscht und NICHT in Azure)

.PARAMETER StaticIP
    Statische IP-Adresse, die der primaeren NIC zugewiesen wird. Leer fuer DHCP. Wird in Azure ignoriert.

.PARAMETER DefaultGateway
    Standardgateway fuer die statische Konfiguration. Leer fuer DHCP. Wird in Azure ignoriert.

.PARAMETER DnsServer
    DNS-Server fuer die statische Konfiguration. Wird in Azure ignoriert.

.PARAMETER LocalAdminName
    Neuer Name des lokalen Administrator-Kontos (SID-500).

.PARAMETER LocalAdminPwd
    Kennwort fuer den lokalen Administrator.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\VM_Basic.ps1 -StaticIP "192.168.10.10" -DefaultGateway "192.168.10.1"
#>

[CmdletBinding()]
param (
    [string]$StaticIP         = "192.168.10.10",
    [string]$DefaultGateway   = "192.168.10.1",
    [string]$DnsServer        = "127.0.0.1",
    [string]$LocalAdminName   = "LokalAdmin",
    [string]$LocalAdminPwd    = "Fenster2020!!"
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# --- Globale Konfiguration -------------------------------------------------
$scriptPath    = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
$progressFile  = "C:\Temp\VM_Basic_progress.txt"
$scriptLog     = "C:\Temp\VM_Basic_$(Get-Date -Format 'yyyyMMdd').log"
$taskName      = "RunVM_BasicAfterRestart"

# --- Hilfsfunktionen --------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Write-Host $line
    Add-Content -Path $scriptLog -Value $line -ErrorAction SilentlyContinue
}

# Hilfsfunktion: fuehrt einen Befehl mit -Verbose aus und protokolliert die
# Verbose-Ausgabe zusaetzlich ins Log. Akzeptiert einen Skriptblock und dessen Parameter.
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
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -StaticIP `"$StaticIP`" -DefaultGateway `"$DefaultGateway`" -DnsServer `"$DnsServer`" -LocalAdminName `"$LocalAdminName`" -LocalAdminPwd `"$LocalAdminPwd`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
}

function Remove-ScheduledTask {
    Write-Log "Entferne geplante Aufgabe '$taskName'."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

# --- Azure-Erkennung ------------------------------------------------------
function Test-IsAzureVM {
    # Pruefe gezielt den Dienst des Azure Guest Agents
    $AzureAgent = Get-Service -Name "WindowsAzureGuestAgent" -ErrorAction SilentlyContinue
    if ($AzureAgent) {
        Write-Log "Umgebung: Microsoft Azure Cloud (Agent-Status: $($AzureAgent.Status))."
        return $true
    }
    Write-Log "Umgebung: On-Premise (kein Azure Guest Agent gefunden)."
    return $false
}

# --- Lokalisierung auf Deutsch (System, Welcome Screen, Default User) -----
function Set-GermanLocalization {
    Write-Log "Konfiguriere deutsche Lokalisierung / regionale Einstellungen."

    Set-Culture de-DE
    Set-WinHomeLocation -GeoId 94
    Set-WinUserLanguageList -LanguageList de-DE -Force
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
    
    Write-Log "Deutsche Lokalisierung gesetzt (Region, Tastatur, UI-Sprache)."
}

# --- Lokalisierung fuer existierendes Admin-Konto beim Anmelden (einmalig) --
# Legt einen Scheduled Task an, der Set-GermanLocalization bei der Anmeldung von
# $LocalAdminName ausfuehrt und sich danach selbst loescht (einmalig).
function Register-LocalizationUserTask {
    $userTaskName = "ApplyGermanLocalization_$LocalAdminName"
    Write-Log "Lege einmaligen Anmelde-Task '$userTaskName' fuer Benutzer '$LocalAdminName' an."

    # Inline-Skript: Lokalisierung anwenden, dann den Task selbst entfernen.
    $inlineScript = @"
try {
    Set-Culture de-DE -Verbose
    Set-WinHomeLocation -GeoId 94 -Verbose
    Set-WinUserLanguageList -LanguageList de-DE -Force -Verbose
    Add-Content -Path 'C:\Temp\VM_Basic_$(Get-Date -Format 'yyyyMMdd').log' -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Lokalisierung fuer Benutzer '$LocalAdminName' angewendet (Anmelde-Task)."
} catch {
    Add-Content -Path 'C:\Temp\VM_Basic_$(Get-Date -Format 'yyyyMMdd').log' -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Fehler bei Lokalisierung fuer '$LocalAdminName': `$_"
} finally {
    Unregister-ScheduledTask -TaskName '$userTaskName' -Confirm:`$false -ErrorAction SilentlyContinue
    Add-Content -Path 'C:\Temp\VM_Basic_$(Get-Date -Format 'yyyyMMdd').log' -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Anmelde-Task '$userTaskName' entfernt."
    Add-Content -Path 'C:\Temp\VM_Basic_$(Get-Date -Format 'yyyyMMdd').log' -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Starte Neustart nach Lokalisierung."
    shutdown /r /t 5
}
"@

    $encodedCmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inlineScript))
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCmd"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$LocalAdminName"
    $principal = New-ScheduledTaskPrincipal -UserId $LocalAdminName -LogonType Interactive -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd
    Register-ScheduledTask -TaskName $userTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
    Write-Log "Einmaliger Anmelde-Task '$userTaskName' registriert fuer '$LocalAdminName' (loescht sich selbst nach Ausfuehrung)."
}

function Set-StaticIPConfig {
    if ([string]::IsNullOrWhiteSpace($StaticIP)) {
        Write-Log "Keine statische IP konfiguriert - verwende bestehende (DHCP) Konfiguration."
        return
    }

    # Statische IP darf auf in Azure erstellten Maschinen NICHT gesetzt werden.
    if (Test-IsAzureVM) {
        Write-Log "Statische IP-Konfiguration in Azure uebersprungen (Azure uebernimmt die Netzwerkkonfiguration)."
        return
    }

    $nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $nic) { Write-Log "Keine aktive Netzwerkkarte gefunden - ueberspringe IP-Konfiguration."; return }
    $ifIndex = $nic.ifIndex
    $prefix  = (Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixLength } | Select-Object -First 1).PrefixLength
    if (-not $prefix) { $prefix = 24 }
    Write-Log "Setze statische IP $StaticIP/$prefix an Interface '$($nic.Name)' (Index $ifIndex)."

    # 1) Adapter komplett auf DHCP zuruecksetzen (loescht alte statische IPs/Gateways/DNS)
    Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue

    # 2) Neue statische IP und Gateway zuweisen
    $newIpArgs = @{
        InterfaceIndex = $ifIndex
        IPAddress      = $StaticIP
        PrefixLength   = $prefix
    }
    if (-not [string]::IsNullOrWhiteSpace($DefaultGateway)) { $newIpArgs['DefaultGateway'] = $DefaultGateway }
    New-NetIPAddress @newIpArgs -ErrorAction Stop

    # 3) Neue statische DNS-Server zuweisen
    if (-not [string]::IsNullOrWhiteSpace($DnsServer)) {
        Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses @($DnsServer)
    }
}

# --- Schritt 1: Initialisierung --------------------------------------------
function Step-Init {
    Write-Log "Schritt 1: Initialisierung."
    New-Item -ItemType Directory -Path "C:\Temp" -Force
    Add-Content -Path $scriptLog -Value "---- Neue Skriptausfuehrung gestartet $(Get-Date) ----"
    Set-StaticIPConfig
    # Ermoeglichen spaeterer RDP-Verwaltung
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

    # Lokalisierung fuer das bereits existierende Admin-Benutzerkonto ($LocalAdminName)
    # nachtraeglich beim naechsten Anmelden aktivieren (einmaliger Task, der sich selbst loescht).
    Register-LocalizationUserTask

    # Ueberfluessige Dienste deaktivieren (Sicherheit & Performance Optimierung)
    # Hinweis: RemoteRegistry wird hier deaktiviert, muss aber fuer AD-Promotion im Create_AD.ps1
    # temporaer wieder aktiviert werden (vor dem promote) und nach dem Setup wieder deaktiviert werden.
    $servicesToDisable = @(
        "Spooler",
        "DiagTrack",
        "dmwappushservice",
        "RemoteRegistry",
        "WSearch",
        "SysMain",
        "lfsvc",
        "lmhosts",
        "XboxGipSvc",
        "XblAuthManager"
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

    # Unnoetige Protokollbindungen (LLTD/RSPNDR) deaktivieren
    Disable-NetAdapterBinding -Name "*" -ComponentID "ms_rspndr","ms_lltdio" -ErrorAction SilentlyContinue
    Write-Log "Unnoetige Protokollbindungen (LLTD/RSPNDR) deaktiviert."

    # SMB1 deaktivieren (Sicherheit)
    try {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
        Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue
        Write-Log "SMB1 deaktiviert."
    } catch { Write-Log "SMB1 Deaktivierung fehlgeschlagen: $_" }

    # Windows Defender Echtzeitschutz aktiv lassen, aber Ausschluesse fuer AD
    try {
        Add-MpPreference -ExclusionPath "C:\Windows\NTDS","C:\Windows\SYSVOL","C:\Windows\System32\ntds.dit" -ErrorAction SilentlyContinue
        Write-Log "Defender-Ausschluesse fuer AD-Verzeichnisse gesetzt."
    } catch { Write-Log "Defender-Ausschluesse nicht gesetzt: $_" }

    # Temp bereinigen
    Get-ChildItem "C:\Windows\Temp","$env:TEMP" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

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
    Invoke-Reboot -NextStepName "Abschluss"
}

# --- Schritt 3: Aufraeumen -------------------------------------------------
function Step-Cleanup {
    Write-Log "Schritt 3: Aufraeumen - Server ist optimiert."
    Remove-ScheduledTask
    Remove-Item -Path $progressFile -Force -ErrorAction SilentlyContinue
    Write-Log "Skript abgeschlossen. Server ist einsatzbereit (z.B. fuer Create_AD.ps1)."
}

# --- Hauptsteuerung --------------------------------------------------------
try {
    $current = if (Test-Path $progressFile) { (Get-Content $progressFile -Raw).Trim() } else { "" }

    switch ($current) {
        ""            { Step-Init }
        "step1finish" { Step-Optimize }
        "step2finish" { Step-Cleanup }
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
