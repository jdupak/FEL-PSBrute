Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


function New-TmpPath($Extension) {
    $Tmp = if ($IsWindows) {$env:TEMP} else {"/tmp"}
    return Join-Path $Tmp "$(New-Guid)$Extension"
}