<#
.SYNOPSIS
    Launches the LogMeIn Rescue Calling Card with an AI-generated issue summary,
    triggered by a Nexthink remote action escalated from Spark.
 
.DESCRIPTION
    Designed to be invoked by a Nexthink remote action. Auto-detects the installed
    calling card, populates the calling card's CField registry values, and launches
    the calling card in silent channel mode so the user gets connected to a Rescue
    technician with the full context already in place.
 
    CField mapping (based on Rescue calling card config):
      CField0: Device Name           (auto-detected)
      CField1: Current user          (auto-detected)
      CField2: Reason for reaching   (AI summary - parameter)
      CField3: Local IPs             (auto-detected)
      CField4: Ticket ID             ("Spark escalation")
      CField5: Workflow tag          ("Jay workflow")
 
    Must run as the interactive logged-in user — CField values live under HKCU.
 
.PARAMETER IssueSummary
    AI-generated summary of the Spark conversation, max 500 characters.
    Written to CField2 so it shows up as "Reason for reaching out"
    in the Rescue technician console.
#>
 
param (
    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 500)]
    [string]$IssueSummary
)
 
$ErrorActionPreference = 'Stop'
 
try {
    # --- 1. Discover which calling card is installed -------------------------
    # Calling card installers write their metadata under HKLM (machine-wide).
    # We enumerate subkeys and pick the first installed referralId — works
    # because real-world deployments only ever have one calling card installed.
 
    $hklmCardRoot = 'HKLM:\SOFTWARE\Wow6432Node\LogMeInRescueCallingCards'
 
    if (-not (Test-Path $hklmCardRoot)) {
        $host.ui.WriteErrorLine("No LogMeIn Rescue Calling Card installation found at $hklmCardRoot")
        exit 1
    }
 
    $installedCard = Get-ChildItem -Path $hklmCardRoot -ErrorAction SilentlyContinue |
                     Select-Object -First 1
 
    if (-not $installedCard) {
        $host.ui.WriteErrorLine("LogMeIn Rescue Calling Card root key exists but no calling card is registered under it.")
        exit 1
    }
 
    $referralId = $installedCard.PSChildName
    Write-Output "Discovered calling card referralId: $referralId"
 
    # --- 2. Locate the calling card executable -------------------------------
    $cardRegEntry = Get-ItemProperty -Path $installedCard.PSPath -ErrorAction SilentlyContinue
 
    if (-not $cardRegEntry.InstallDir) {
        $host.ui.WriteErrorLine("InstallDir not found in registry for calling card '$referralId'.")
        exit 1
    }
 
    $callingCardExePath = Join-Path $cardRegEntry.InstallDir 'CallingCard.exe'
 
    if (-not (Test-Path $callingCardExePath)) {
        $host.ui.WriteErrorLine("Calling Card executable not found at: $callingCardExePath")
        exit 1
    }
 
    # --- 3. Make sure it's not already running -------------------------------
    $existingProcess = Get-Process -Name 'CallingCard' -ErrorAction SilentlyContinue
    if ($existingProcess) {
        $host.ui.WriteErrorLine("A Rescue Calling Card instance is already running (PID $($existingProcess.Id)).")
        exit 1
    }
 
    # --- 4. Auto-detect machine + user + IP context --------------------------
    $machineName = $env:COMPUTERNAME
    $currentUser = $env:USERNAME
 
    # Pick the first non-virtual IPv4 address. Avoids loopback, VPN, Hyper-V,
    # VMware, and WSL adapters which would otherwise produce noisy values.
    $ipAddress = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue |
                 Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet|VMware|Hyper-V|WSL' } |
                 Select-Object -First 1 -ExpandProperty IPAddress
 
    if (-not $ipAddress) {
        $ipAddress = 'Unknown'
    }
 
    # --- 5. Write CField values to HKCU --------------------------------------
    # CField0: Device Name              (auto)
    # CField1: Current user             (auto)
    # CField2: Reason for reaching out  (AI summary from Spark)
    # CField3: Local IPs                (auto)
    # CField4: Ticket ID                (constant: "Spark escalation")
    # CField5: Workflow tag             (constant: "Jay workflow")
 
    $hkcuRegPath = "HKCU:\Software\LogMeInRescueCallingCards\$referralId"
 
    if (-not (Test-Path $hkcuRegPath)) {
        New-Item -Path $hkcuRegPath -Force | Out-Null
    }
 
    Set-ItemProperty -Path $hkcuRegPath -Name 'CField0' -Value $machineName
    Set-ItemProperty -Path $hkcuRegPath -Name 'CField1' -Value $currentUser
    Set-ItemProperty -Path $hkcuRegPath -Name 'CField2' -Value $IssueSummary
    Set-ItemProperty -Path $hkcuRegPath -Name 'CField3' -Value $ipAddress
    Set-ItemProperty -Path $hkcuRegPath -Name 'CField4' -Value 'Spark escalation'
    Set-ItemProperty -Path $hkcuRegPath -Name 'CField5' -Value 'Jay workflow'
 
    Write-Output "CFields populated for referralId '$referralId'"
 
    # --- 6. Launch the calling card in silent channel mode -------------------
    $arguments = @('-silent', '-channel')
    $process   = Start-Process -FilePath $callingCardExePath -PassThru -ArgumentList $arguments
 
    # Brief wait to make sure the process actually starts cleanly
    Start-Sleep -Seconds 5
 
    if ($process.HasExited -and $process.ExitCode -ne 0) {
        $host.ui.WriteErrorLine("Calling Card exited immediately with code $($process.ExitCode).")
        exit 1
    }
 
    Write-Output "Calling Card launched successfully (PID $($process.Id))."
    exit 0
}
catch {
    $host.ui.WriteErrorLine("Unexpected error: $_")
    exit 2
}
