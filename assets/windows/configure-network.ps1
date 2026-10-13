$ErrorActionPreference = 'Stop'
try {
    $program = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PROGRAM__'))
    $port = __PORT__
    if (-not (Test-Path -LiteralPath $program -PathType Leaf)) {
        throw 'Nearbridge executable not found'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator permission is required'
    }
    foreach ($name in @('Nearbridge-LAN-TCP', 'Nearbridge-LAN-UDP')) {
        Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    }
    New-NetFirewallRule -Name 'Nearbridge-LAN-TCP' -DisplayName 'Nearbridge local connection' -Group 'Nearbridge' -Direction Inbound -Action Allow -Program $program -Protocol TCP -LocalPort $port -RemoteAddress LocalSubnet -Profile Any | Out-Null
    New-NetFirewallRule -Name 'Nearbridge-LAN-UDP' -DisplayName 'Nearbridge local discovery' -Group 'Nearbridge' -Direction Inbound -Action Allow -Program $program -Protocol UDP -LocalPort 45832 -RemoteAddress LocalSubnet -Profile Any | Out-Null
    exit 0
} catch {
    Write-Error $_
    exit 1
}
