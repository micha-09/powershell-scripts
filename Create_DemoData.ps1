<#
.SYNOPSIS
    Demo-Daten: Befuellt die Domaene mit Musterbenutzern, Gruppen und Computerkonten.

.DESCRIPTION
    Das Skript wird als SYSTEM oder Domain Admin ausgefuehrt und erstellt Demo-Daten
    in einer bestehenden Active Directory Domaene. Es setzt voraus, dass der Domain Controller
    bereits mit Create_AD.ps1 erstellt wurde und die Grund-OU-Struktur existiert.

    Das Skript erstellt:
      - Sicherheitsgruppen (IT_Admin, Helpdesk, Mitarbeiter, etc.) in OU=Gruppen,OU=Unternehmen
      - Musterbenutzer (25 Standardbenutzer) in OU=Benutzer,OU=Unternehmen
      - Service-Accounts in OU=ServiceAccounts,OU=Unternehmen
      - Muster-Computerkonten (Clients in T2-Clients, Server in T1-Servers)

    Voraussetzungen:
      - Ausfuehrung als SYSTEM oder Domain Admin
      - ActiveDirectory Modul muss verfuegbar sein
      - Domaene muss bereits existieren

.PARAMETER DomainName
    FQDN der Domaene (z.B. corp.example.com).

.PARAMETER NetBiosName
    NetBIOS-Domaenenname (z.B. CORP).

.PARAMETER DemoUserCount
    Anzahl der Musterbenutzer, die angelegt werden.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Create_DemoData.ps1 -DomainName "corp.example.com" -NetBiosName "CORP" -DemoUserCount 25
#>

[CmdletBinding()]
param (
    [string]$DomainName      = "corp.example.com",
    [string]$NetBiosName      = "CORP",
    [int]   $DemoUserCount    = 25
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# --- Globale Konfiguration -------------------------------------------------
$scriptPath    = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
$scriptLog     = "C:\Temp\Create_DemoData_$(Get-Date -Format 'yyyyMMdd').log"

# --- Hilfsfunktionen --------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Message"
    Write-Host $line
    Add-Content -Path $scriptLog -Value $line -ErrorAction SilentlyContinue
}

# --- Hauptfunktion --------------------------------------------------------
try {
    # AD-Module sicherstellen
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log "ActiveDirectory Modul fehlt - installiere RSAT."
        Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction SilentlyContinue
    }
    Import-Module ActiveDirectory -ErrorAction Stop

    $domainDN = "DC=" + ($DomainName -split '\.' -join ",DC=")
    $baseDN   = $domainDN
    $adServer = $env:COMPUTERNAME

    # Warte, bis der DC voll verfuegbar ist
    $retries = 0
    while (-not (Get-Service -Name NTDS -ErrorAction SilentlyContinue) -and $retries -lt 30) {
        Start-Sleep -Seconds 10; $retries++
    }
    Start-Sleep -Seconds 15

    # Benoetigte OUs anlegen, falls sie nicht existieren
    Write-Log "Pruefe und erstelle benoetigte OUs..."
    $requiredOUs = @(
        @{ Name = "Unternehmen";       Path = $baseDN },
        @{ Name = "Gruppen";           Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Benutzer";          Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "ServiceAccounts";  Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "Tier0";             Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "T0-Servers";        Path = "OU=Tier0,OU=Unternehmen,$baseDN" },
        @{ Name = "Tier1";             Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "T1-Servers";        Path = "OU=Tier1,OU=Unternehmen,$baseDN" },
        @{ Name = "Tier2";             Path = "OU=Unternehmen,$baseDN" },
        @{ Name = "T2-Clients";        Path = "OU=Tier2,OU=Unternehmen,$baseDN" }
    )
    foreach ($ou in $requiredOUs) {
        try {
            if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($ou.Name)'" -SearchBase $ou.Path -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -Server $adServer -ErrorAction Stop
                Write-Log "OU angelegt: $($ou.Name) ($($ou.Path))"
            }
        } catch { Write-Log "OU '$($ou.Name)' nicht angelegt: $_" }
    }

    # Sicherheitsgruppen anlegen
    Write-Log "Erstelle Sicherheitsgruppen..."
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
    Write-Log "Erstelle Musterbenutzer..."
    $depts = @("IT","Helpdesk","Finanzen","Entwicklung","Vertrieb","HR")
    $securePwd = ConvertTo-SecureString "Fenster2020!" -AsPlainText -Force
    $userOU = "OU=Benutzer,OU=Unternehmen,$baseDN"
    for ($i = 1; $i -le $DemoUserCount; $i++) {
        $dept   = $depts[(($i - 1) % $depts.Count)]
        $fn     = "Demo"
        $ln     = "User{0:D2}" -f $i
        $uname  = "$fn.$ln"
        $upn    = "$uname@$DomainName"
        try {
            if (-not (Get-ADUser -Identity $uname -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADUser `\
                    -Name $uname `\
                    -GivenName $fn `\
                    -Surname $ln `\
                    -DisplayName "$fn $ln" `\
                    -SamAccountName $uname `\
                    -UserPrincipalName $upn `\
                    -Path $userOU `\
                    -AccountPassword $securePwd `\
                    -Enabled $true `\
                    -Department $dept `\
                    -Server $adServer `\
                    -ErrorAction Stop `\
                   
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
    Write-Log "Erstelle Service-Accounts..."
    $svcOU = "OU=ServiceAccounts,OU=Unternehmen,$baseDN"
    $svcAccounts = @("svc_backup","svc_monitoring","svc_join","svc_print")
    foreach ($svc in $svcAccounts) {
        try {
            if (-not (Get-ADUser -Identity $svc -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADUser `\
                    -Name $svc `\
                    -SamAccountName $svc `\
                    -UserPrincipalName "$svc@$DomainName" `\
                    -Path $svcOU `\
                    -AccountPassword $securePwd `\
                    -Enabled $true `\
                    -Description "Service-Konto (Muster)" `\
                    -Server $adServer `\
                   
                Write-Log "Service-Konto angelegt: $svc"
            }
        } catch { Write-Log "Service-Konto '$svc' nicht angelegt: $_" }
    }

    # Muster-Computerkonten (Clients) anlegen - in T2-Clients OU
    Write-Log "Erstelle Muster-Client-Computerkonten..."
    $clientOU = "OU=T2-Clients,OU=Tier2,OU=Unternehmen,$baseDN"
    for ($i = 1; $i -le 10; $i++) {
        $cname = "CL-WS{0:D3}" -f $i
        try {
            if (-not (Get-ADComputer -Identity $cname -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADComputer -Name $cname -Path $clientOU -Description "Muster-Client $i" -Server $adServer -ErrorAction Stop
                Write-Log "Computerkonto angelegt: $cname"
            }
        } catch { Write-Log "Computerkonto '$cname' nicht angelegt: $_" }
    }

    # Muster-Serverkonten - in T1-Servers OU
    Write-Log "Erstelle Muster-Server-Computerkonten..."
    $serverOU = "OU=T1-Servers,OU=Tier1,OU=Unternehmen,$baseDN"
    for ($i = 1; $i -le 5; $i++) {
        $cname = "SRV-APP{0:D2}" -f $i
        try {
            if (-not (Get-ADComputer -Identity $cname -Server $adServer -ErrorAction SilentlyContinue)) {
                New-ADComputer -Name $cname -Path $serverOU -Description "Muster-Server $i" -Server $adServer -ErrorAction Stop
                Write-Log "Server-Konto angelegt: $cname"
            }
        } catch { Write-Log "Server-Konto '$cname' nicht angelegt: $_" }
    }

    Write-Log "Demo-Daten erfolgreich in die Domaene geladen."
}
catch {
    Write-Log "Fehler aufgetreten: $($_.Exception.Message)"
    Write-Log "Stack: $($_.ScriptStackTrace)"
    exit 1
}
