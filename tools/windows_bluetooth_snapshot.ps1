# Read-only Windows Bluetooth/PnP snapshot for BTPhonoSink development.
# Does not change drivers, paired devices, settings, or Bluetooth radio state.
$ErrorActionPreference = 'Continue'
Write-Output ('BTPhonoSink Windows PnP snapshot at ' + (Get-Date -Format o))
Write-Output ('Windows version: ' + [Environment]::OSVersion.VersionString)
Write-Output "`n== Present Bluetooth devices (name, class, status only) =="
$bt = @(Get-PnpDevice -PresentOnly -Class Bluetooth -ErrorAction SilentlyContinue)
$bt | Select-Object FriendlyName,Class,Status | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Write-Output "`n== Present audio endpoints =="
$audio = @(Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction SilentlyContinue)
$audio | Select-Object FriendlyName,Status | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Write-Output "`n== Cached BTHENUM service instances mentioning Sink UUID 0x110B =="
$services = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match '^BTHENUM' -and $_.InstanceId -match '0000110B' })
Write-Output ('Cached services containing 0000110B: ' + $services.Count)
$services | Select-Object FriendlyName,Status | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Write-Output 'NOTE: Cached BTHENUM services may belong to other devices or remain after unpairing.'
Write-Output 'NOTE: No 0x110B service is expected from the BTPhonoSink v6 tweak itself.'
