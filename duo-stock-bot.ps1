<#
  iPhone Duo restock bot - Apple Store pickup availability, Melbourne.

  Default: iPhone Duo 256GB and 512GB, both colours (Star White, Night Sky), at
  Chadstone (R180), Doncaster (R342), Highpoint (R504), Southland (R343).

  Usage:
    .\duo-stock-bot.ps1                      # poll every 60s, alert on restock, remind every 15 min while in stock
    .\duo-stock-bot.ps1 -Once                # single check, then exit
    .\duo-stock-bot.ps1 -NtfyTopic my-secret-topic   # also push to phone via ntfy.sh
    .\duo-stock-bot.ps1 -Parts MG6M4X/A -ProbeParts MG6L4X/A -Once -NoBrowser
                                             # test alerts with an in-stock model (iPhone 17 256GB Lavender)

  How it works: Apple's direct per-part stock endpoint is bot-protected, but the
  "similar models available nearby" endpoint is not. That endpoint never lists the
  part you ask about, and only lists other colours of the same storage size, so we
  ask about each watched model and pick the watched parts out of every response.
#>
param(
    # 256GB Star White, 256GB Night Sky, 512GB Star White, 512GB Night Sky
    [Alias('Part')]
    [string[]]$Parts = @('MK2D4X/A', 'MK2E4X/A', 'MK2F4X/A', 'MK2G4X/A'),
    # Defaults to $Parts: each probe reports the other colour of its storage size.
    [string[]]$ProbeParts = @(),
    [string[]]$Stores = @('R180', 'R342', 'R504', 'R343'),
    [string]$Postcode = '3148',
    [int]$IntervalSeconds = 60,
    [string]$NtfyTopic = '',
    [switch]$NoBrowser,
    [switch]$Once,
    # Cloud mode: remember stock between separate -Once runs, skip beep/toast/browser.
    [string]$StateFile = '',
    [switch]$Quiet,
    [string]$Label = 'PC',
    # Re-alert this often while a store stays in stock, in case the first ping was missed.
    [int]$RemindMinutes = 15,
    # Also push a "still alive" status after this check, so silence can't be mistaken for "no stock".
    [switch]$Heartbeat,
    # Long-running mode: also send a check-in once during each of these local hours (e.g. 0,6,12,18).
    # (a comma-separated string, since powershell -File passes "0,6,12,18" as one argument)
    [string]$CheckInHours = ''
)
# powershell -File passes "a,b" as one string, so split list arguments here.
$Parts = @($Parts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ProbeParts = @($ProbeParts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $ProbeParts.Count) { $ProbeParts = $Parts }
$checkInHourList = @($CheckInHours -split ',' | Where-Object { $_.Trim() } | ForEach-Object { [int]$_ })

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
# Short names for the log and check-ins; alerts use Apple's own product title.
$PartNames = @{
    'MK2D4X/A' = '256GB Star White'; 'MK2E4X/A' = '256GB Night Sky'
    'MK2F4X/A' = '512GB Star White'; 'MK2G4X/A' = '512GB Night Sky'
}

function Get-PartName($p) { if ($PartNames.ContainsKey($p)) { $PartNames[$p] } else { $p } }

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

function Get-MelbourneTime {
    $t = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'AUS Eastern Standard Time')
    $t.ToString('h:mm tt ddd d MMM')
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

# Returns @{ R180 = @{ Name='Chadstone'; InStock=@{ 'MK2G4X/A' = @{ Title='iPhone Duo 512GB Night Sky'; Quote='Available Today' } } }; ... }
function Get-Stock {
    $result = @{}
    foreach ($probe in $ProbeParts) {
        $resp = Invoke-WebRequest -Uri ($ApiBase + [uri]::EscapeDataString($probe)) -Headers $Headers -UseBasicParsing -TimeoutSec 30
        $data = $json.DeserializeObject($resp.Content)
        foreach ($s in $data['body']['PickupMessage']['stores']) {
            $id = $s['storeNumber']
            if ($Stores -notcontains $id) { continue }
            if (-not $result.ContainsKey($id)) { $result[$id] = @{ Name = $s['storeName']; InStock = @{} } }
            $pa = $s['partsAvailability']
            if (-not $pa) { continue }
            foreach ($p in $Parts) {
                if (-not $pa.ContainsKey($p) -or $pa[$p]['pickupDisplay'] -ne 'available') { continue }
                $title = $null
                try { $title = $pa[$p]['messageTypes']['regular']['storePickupProductTitle'] } catch {}
                if (-not $title) { $title = "iPhone Duo $(Get-PartName $p)" }
                $result[$id].InStock[$p] = @{ Title = $title; Quote = $pa[$p]['pickupSearchQuote'] }
            }
        }
        Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 1500)
    }
    $result
}

Write-Log "Watching $(($Parts | ForEach-Object { Get-PartName $_ }) -join ', ') at $($Stores -join ', ') every ${IntervalSeconds}s. Ctrl+C to stop." 'Cyan'
# "store|part" -> UTC time of the last alert, for models currently in stock.
$lastAlert = @{}
$failures = 0
if ($StateFile -and (Test-Path $StateFile)) {
    $saved = $json.DeserializeObject((Get-Content $StateFile -Raw))
    if ($saved['alerted']) {
        # Keys without "|" are from the single-model version; it only ever tracked the 512GB Night Sky.
        foreach ($k in $saved['alerted'].Keys) {
            $key = if ($k -like '*|*') { $k } else { "$k|MK2G4X/A" }
            $lastAlert[$key] = [datetime]::Parse($saved['alerted'][$k]).ToUniversalTime()
        }
    }
    $failures = [int]$saved['fails']
}

$checkInsSent = @{}
while ($true) {
    $now = Get-Date
    $checkInKey = $now.ToString('yyyyMMddHH')
    $checkIn = $Heartbeat -or (($checkInHourList -contains $now.Hour) -and -not $checkInsSent[$checkInKey])
    if ($checkIn) { $checkInsSent[$checkInKey] = $true }
    try {
        $stock = Get-Stock
        $failures = 0
        foreach ($id in $Stores) {
            if (-not $stock.ContainsKey($id)) { Write-Log "$id not in response (try another -Postcode)" 'DarkYellow'; continue }
            $s = $stock[$id]
            foreach ($p in $Parts) {
                $key = "$id|$p"
                if ($s.InStock.ContainsKey($p)) {
                    $item = $s.InStock[$p]
                    if (-not $lastAlert.ContainsKey($key)) {
                        Send-Alert "In stock: $($item.Title) at Apple $($s.Name)" "$($item.Quote) ($p). Order for pickup now."
                        $lastAlert[$key] = [datetime]::UtcNow
                    } elseif (([datetime]::UtcNow - $lastAlert[$key]).TotalMinutes -ge $RemindMinutes - 0.5) {
                        Send-Alert "Still in stock: $($item.Title) at Apple $($s.Name)" "$($item.Quote) ($p). Reminder - order for pickup now."
                        $lastAlert[$key] = [datetime]::UtcNow
                    }
                } elseif ($lastAlert.ContainsKey($key)) {
                    Write-Log "$($s.Name): $(Get-PartName $p) sold out again" 'DarkYellow'
                    $lastAlert.Remove($key)
                }
            }
        }
        $summary = ($Stores | Where-Object { $stock.ContainsKey($_) } | ForEach-Object {
            $have = @($stock[$_].InStock.Keys | ForEach-Object { Get-PartName $_ })
            "$($stock[$_].Name): $(if ($have.Count) { 'IN STOCK ' + ($have -join ', ') } else { 'no' })"
        }) -join ' | '
        Write-Log $summary
        if ($checkIn) {
            $inStock = @($Stores | Where-Object { $stock.ContainsKey($_) -and $stock[$_].InStock.Count })
            $status = if ($inStock.Count) { "IN STOCK at $(($inStock | ForEach-Object { $stock[$_].Name }) -join ', ')" } else { 'No stock' }
            Send-Push "Duo bot check-in: $status" "$summary. Checked $(Get-MelbourneTime). Next check-in in 6 hours." 'default'
        }
    } catch {
        $failures++
        Write-Log "Check failed ($failures): $($_.Exception.Message)" 'Red'
        if ($checkIn) { Send-Push 'Duo bot check-in: CHECK FAILED' "Couldn't reach Apple at $(Get-MelbourneTime): $($_.Exception.Message)" 'high' }
        # Warn once if Apple keeps refusing us, so a silent bot isn't mistaken for "no stock".
        if ($failures -eq 3) { Send-Push 'iPhone Duo bot is being blocked' "Last 3 checks failed: $($_.Exception.Message)" 'default' }
    }

    if ($StateFile) {
        # ::new() rather than New-Object, which wraps the value in a PSObject the serializer can't handle.
        $state = [System.Collections.Generic.Dictionary[string,object]]::new()
        $alerted = [System.Collections.Generic.Dictionary[string,string]]::new()
        foreach ($k in $lastAlert.Keys) { $alerted[$k] = $lastAlert[$k].ToString('o') }
        $state['alerted'] = $alerted
        $state['fails'] = [int]$failures
        $json.Serialize($state) |
            Set-Content -Path $StateFile -Encoding UTF8
    }

    if ($Once) { break }
    # Back off on repeated errors (rate limiting), plus jitter so requests aren't perfectly regular.
    $wait = $IntervalSeconds * [math]::Min([math]::Pow(2, $failures), 16) + (Get-Random -Minimum 0 -Maximum 15)
    Start-Sleep -Seconds $wait
}
