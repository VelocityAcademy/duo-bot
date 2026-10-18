<#
  iPhone Duo restock bot - Apple Store pickup availability, Melbourne.

  Default: iPhone Duo 512GB Night Sky (MK2G4X/A) at
  Chadstone (R180), Doncaster (R342), Highpoint (R504), Southland (R343).

  Usage:
    .\duo-stock-bot.ps1                      # poll every 60s, alert on restock
    .\duo-stock-bot.ps1 -Once                # single check, then exit
    .\duo-stock-bot.ps1 -NtfyTopic my-secret-topic   # also push to phone via ntfy.sh
    .\duo-stock-bot.ps1 -Part MG6M4X/A -ProbeParts MG6L4X/A -Once -NoBrowser
                                             # test alerts with an in-stock model (iPhone 17 256GB Lavender)

  How it works: Apple's direct per-part stock endpoint is bot-protected, but the
  "similar models available nearby" endpoint is not. That endpoint never lists the
  part you ask about, so we ask about sibling Duo models (-ProbeParts) and look for
  the target part in their results.
#>
param(
    [string]$Part = 'MK2G4X/A',
    # 512GB Star White, 1TB Night Sky, 256GB Night Sky
    [string[]]$ProbeParts = @('MK2F4X/A', 'MK2J4X/A', 'MK2E4X/A'),
    [string[]]$Stores = @('R180', 'R342', 'R504', 'R343'),
    [string]$Postcode = '3148',
    [int]$IntervalSeconds = 60,
    [string]$NtfyTopic = '',
    [switch]$NoBrowser,
    [switch]$Once,
    # Cloud mode: remember stock between separate -Once runs, skip beep/toast/browser.
    [string]$StateFile = '',
    [switch]$Quiet,
    [string]$Label = 'PC'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$json.MaxJsonLength = [int]::MaxValue

$BuyUrl = 'https://www.apple.com/au/shop/buy-iphone/iphone-duo'
$ApiBase = "https://www.apple.com/au/shop/pickup-message-recommendations?mts.0=regular&searchNearby=true&location=$Postcode&product="
$Headers = @{
    'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
    'Accept'          = 'application/json'
    'Accept-Language' = 'en-AU,en;q=0.9'
    'Referer'         = $BuyUrl
}

function Write-Log($msg, $color = 'Gray') {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) -ForegroundColor $color
}

function Show-Toast($title, $body) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $xml.GetElementsByTagName('text')
        $t.Item(0).AppendChild($xml.CreateTextNode($title)) | Out-Null
        $t.Item(1).AppendChild($xml.CreateTextNode($body)) | Out-Null
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch { Write-Log "Toast failed: $($_.Exception.Message)" 'DarkYellow' }
}

function Send-Push($title, $body, $priority) {
    if (-not $NtfyTopic) { return }
    try {
        Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$NtfyTopic" -Body "[$Label] $body" `
            -Headers @{ Title = $title; Priority = $priority; Click = $BuyUrl; Tags = 'iphone' } | Out-Null
    } catch { Write-Log "ntfy push failed: $($_.Exception.Message)" 'DarkYellow' }
}

function Send-Alert($title, $body) {
    Write-Log "$title - $body" 'Green'
    if (-not $Quiet) {
        1..3 | ForEach-Object { [console]::Beep(1200, 300); Start-Sleep -Milliseconds 150 }
        Show-Toast $title $body
    }
    Send-Push $title $body 'urgent'
    if (-not ($NoBrowser -or $Quiet)) { Start-Process $BuyUrl }
}

# Returns @{ R180 = @{ Name='Chadstone'; Available=$true; Quote='Available Today' }; ... }
function Get-Stock {
    $result = @{}
    foreach ($probe in $ProbeParts) {
        $resp = Invoke-WebRequest -Uri ($ApiBase + [uri]::EscapeDataString($probe)) -Headers $Headers -UseBasicParsing -TimeoutSec 30
        $data = $json.DeserializeObject($resp.Content)
        foreach ($s in $data['body']['PickupMessage']['stores']) {
            $id = $s['storeNumber']
            if ($Stores -notcontains $id) { continue }
            if (-not $result.ContainsKey($id)) { $result[$id] = @{ Name = $s['storeName']; Available = $false; Quote = 'Unavailable' } }
            $pa = $s['partsAvailability']
            if ($pa -and $pa.ContainsKey($Part) -and $pa[$Part]['pickupDisplay'] -eq 'available') {
                $result[$id].Available = $true
                $result[$id].Quote = $pa[$Part]['pickupSearchQuote']
            }
        }
        Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 1500)
    }
    $result
}

Write-Log "Watching $Part at $($Stores -join ', ') every ${IntervalSeconds}s. Ctrl+C to stop." 'Cyan'
$wasAvailable = @{}
$failures = 0
if ($StateFile -and (Test-Path $StateFile)) {
    $saved = $json.DeserializeObject((Get-Content $StateFile -Raw))
    foreach ($id in $saved['available']) { $wasAvailable[$id] = $true }
    $failures = [int]$saved['fails']
}

while ($true) {
    try {
        $stock = Get-Stock
        $failures = 0
        foreach ($id in $Stores) {
            if (-not $stock.ContainsKey($id)) { Write-Log "$id not in response (try another -Postcode)" 'DarkYellow'; continue }
            $s = $stock[$id]
            if ($s.Available -and -not $wasAvailable[$id]) {
                Send-Alert "iPhone Duo in stock: Apple $($s.Name)" "$Part - $($s.Quote). Order for pickup now."
            } elseif (-not $s.Available -and $wasAvailable[$id]) {
                Write-Log "$($s.Name): gone again" 'DarkYellow'
            }
            $wasAvailable[$id] = $s.Available
        }
        $summary = ($Stores | Where-Object { $stock.ContainsKey($_) } | ForEach-Object {
            "$($stock[$_].Name): $(if ($stock[$_].Available) { 'IN STOCK' } else { 'no' })"
        }) -join ' | '
        Write-Log $summary
    } catch {
        $failures++
        Write-Log "Check failed ($failures): $($_.Exception.Message)" 'Red'
        # Warn once if Apple keeps refusing us, so a silent bot isn't mistaken for "no stock".
        if ($failures -eq 3) { Send-Push 'iPhone Duo bot is being blocked' "Last 3 checks failed: $($_.Exception.Message)" 'default' }
    }

    if ($StateFile) {
        $state = New-Object 'System.Collections.Generic.Dictionary[string,object]'
        $state['available'] = [string[]]@($wasAvailable.Keys | Where-Object { $wasAvailable[$_] })
        $state['fails'] = [int]$failures
        $json.Serialize($state) |
            Set-Content -Path $StateFile -Encoding UTF8
    }

    if ($Once) { break }
    # Back off on repeated errors (rate limiting), plus jitter so requests aren't perfectly regular.
    $wait = $IntervalSeconds * [math]::Min([math]::Pow(2, $failures), 16) + (Get-Random -Minimum 0 -Maximum 15)
    Start-Sleep -Seconds $wait
}
