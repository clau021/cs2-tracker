param(
    [switch]$GetChatId,   # запустить с этим ключом, чтобы узнать свой chat_id
    [switch]$Once,        # сделать один проход и выйти (для проверки)
    [switch]$Portfolio,   # показать состояние портфеля (что куплено) и выйти
    [switch]$Backtest     # прогнать теневой бэктест по накопленной истории и выйти
)

# ============ КОДИРОВКА (чтобы русский текст не превращался в кракозябры) ============
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ==================================================================================
# ================================  Н А С Т Р О Й К И  =============================
# ==================================================================================

# ОБЛАЧНАЯ ВЕРСИЯ: токен и chat_id берутся из "секретов" GitHub (переменные окружения TG_TOKEN / TG_CHAT).
# Для локального теста можно временно вписать значения в кавычки в блоке else ниже.
$TelegramToken  = if ($env:TG_TOKEN) { $env:TG_TOKEN } else { "" }
$TelegramChatId = if ($env:TG_CHAT)  { $env:TG_CHAT }  else { "" }

$DiscountPercent = 20     # сигнал, если цена ниже обычной хотя бы на столько %
                          # (20% = запас на комиссию 13% + риск падения цены за 7 дней блокировки)
$MinVolume       = 15     # минимум продаж в сутки (чтобы предмет реально можно было перепродать)
$FeePercent      = 13     # комиссия Steam при продаже (примерно), для оценки навара
$CurrencyCode    = 37     # 37 = тенге, 5 = рубли, 1 = доллары

$SleepBetweenItemsSec = 6    # пауза между предметами в секундах. НЕ УМЕНЬШАЙ — иначе Steam забанит запросы
$CycleDelayMinutes    = 15   # пауза между полными проходами по списку
$CooldownHours        = 6    # не повторять сигнал по одному предмету чаще, чем раз в N часов

$SkipFalling   = $false      # $true = НЕ слать сигналы по предметам, у которых цена явно падает.
                             # По умолчанию $false: лучше показать тренд и решать самому (см. README).
$TrendDeadband = 3           # % : в пределах +-3% цена считается стабильной
$ConfirmPasses = 1           # АНТИСНАЙП: сколько проходов подряд просадка должна держаться до сигнала.
                             # 1 = сигналы мгновенно (но иногда лот уже увели); 2 = ждать подтверждения ~15 мин (меньше пустых сигналов).

# --- Долгосрочный ориентир (защита от "падающего ножа" — предметов, что дешевеют неделями) ---
$LongTermDays    = 30        # окно долгосрочной истории для средней цены и долгого тренда (дней)
$LongTermMinDays = 7         # сколько дней истории нужно накопить, чтобы доверять долгому тренду
$LongTermFallPct = 12        # если за окно цена упала на столько % и больше — это "падающий нож" -> ⛔

$SellAlertCooldownHours = 12 # как часто повторять сигнал "пора продавать" по одной покупке
$PeakAbovePct           = 8  # если цена выше нормы (медианы/средней) на столько % — это "пик", зовём продавать активнее
$DigestHourUTC          = 5  # час по UTC для суточной сводки в Telegram (5 UTC ≈ 10:00 по Казахстану). Заявки-подсказки — по понедельникам.

# ==================================================================================
# ====== Дальше можно ничего не трогать ======
# ==================================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ItemsFile   = Join-Path $ScriptDir "items.txt"
$StateFile   = Join-Path $ScriptDir "state.json"
$HistoryFile   = Join-Path $ScriptDir "history.tsv"
$PortfolioFile = Join-Path $ScriptDir "portfolio.txt"

function Send-Telegram($text, $buttonUrl, $buttonText) {
    if (-not $TelegramToken -or -not $TelegramChatId) {
        Write-Host "[!] Не заданы TelegramToken/ChatId — сообщение не отправлено." -ForegroundColor Yellow
        return
    }
    try {
        $url = "https://api.telegram.org/bot$TelegramToken/sendMessage"
        $body = @{
            chat_id    = $TelegramChatId
            text       = $text
            parse_mode = "HTML"
        }
        # если передана ссылка — добавляем нажимаемую кнопку под сообщением
        if ($buttonUrl) {
            if (-not $buttonText) { $buttonText = "🛒 Открыть на Steam" }
            $markup = @{ inline_keyboard = @( ,@( @{ text = $buttonText; url = $buttonUrl } ) ) }
            $body.reply_markup = ($markup | ConvertTo-Json -Depth 6 -Compress)
        }
        Invoke-RestMethod -Uri $url -Method Post -Body $body | Out-Null
    } catch {
        Write-Host "[!] Ошибка отправки в Telegram: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Режим "узнать chat_id" ---
if ($GetChatId) {
    if (-not $TelegramToken) { Write-Host "Сначала впиши TelegramToken в настройках." -ForegroundColor Red; exit }
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/getUpdates"
    } catch {
        Write-Host "Ошибка запроса. Проверь токен." -ForegroundColor Red; exit
    }
    if (-not $r.result -or $r.result.Count -eq 0) {
        Write-Host "Нет сообщений. Открой своего бота в Telegram, напиши ему любой текст и запусти скрипт с -GetChatId снова." -ForegroundColor Yellow
        exit
    }
    Write-Host "Найденные chat_id (возьми свой):" -ForegroundColor Cyan
    $r.result | ForEach-Object {
        $c = $_.message.chat
        if ($c) { Write-Host ("  chat_id = {0}   ({1} {2})" -f $c.id, $c.first_name, $c.username) -ForegroundColor Green }
    }
    exit
}

function Parse-Price($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $t = ($s -replace '[^\d.,]', '')   # оставляем только цифры, запятую и точку
    $t = $t -replace '\.', ''          # убираем точку (разделитель тысяч, если есть)
    $t = $t -replace ',', '.'          # запятая -> десятичная точка
    if ($t -eq '') { return $null }
    try { return [double]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Parse-Int($s) {
    if (-not $s) { return 0 }
    $t = ($s -replace '[^\d]', '')
    if ($t -eq '') { return 0 }
    try { return [int]$t } catch { return 0 }
}

function Get-SellerNet($buyerPrice) {
    # Точная сумма "на руки" после комиссий Steam.
    # Комиссии: 5% (Steam) + 10% (издатель), каждая минимум 1, считаются от суммы ПРОДАВЦА и округляются вниз.
    # Возвращаем наибольшую сумму продавца S, при которой S + f5 + f10 <= цена покупателя.
    $p = [int][math]::Round([double]$buyerPrice)
    if ($p -le 2) { return 0 }
    $est = [int][math]::Floor($p / 1.15)
    for ($s = $est + 3; $s -ge 1; $s--) {
        $fSteam = [math]::Max(1, [int][math]::Floor($s * 0.05))
        $fGame  = [math]::Max(1, [int][math]::Floor($s * 0.10))
        if (($s + $fSteam + $fGame) -le $p) { return $s }
    }
    return [int][math]::Floor($p / 1.15)
}

# --- загрузка состояния (чтобы не спамить одинаковыми сигналами) ---
$State = @{}
if (Test-Path $StateFile) {
    try {
        $obj = Get-Content -Raw -Encoding UTF8 $StateFile | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $State[$p.Name] = $p.Value }
    } catch {}
}
function Save-State {
    ($State | ConvertTo-Json -Depth 5) | Out-File -FilePath $StateFile -Encoding UTF8
}

# --- история цен (копим сами, чтобы считать тренд) ---
$InvCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Parse-IsoDate($s) {
    try { return [datetime]::Parse($s, $InvCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

function Load-History {
    $h = @{}
    if (-not (Test-Path $HistoryFile)) { return $h }
    try {
        foreach ($ln in (Get-Content -Path $HistoryFile -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $p = $ln -split "`t"
            if ($p.Count -lt 4) { continue }
            $t = Parse-IsoDate $p[0]
            if (-not $t) { continue }
            $name = $p[1]
            $low = 0.0; $med = 0.0; $vol = 0
            [double]::TryParse($p[2], [System.Globalization.NumberStyles]::Float, $InvCulture, [ref]$low) | Out-Null
            [double]::TryParse($p[3], [System.Globalization.NumberStyles]::Float, $InvCulture, [ref]$med) | Out-Null
            if ($p.Count -ge 5) { [void][int]::TryParse((($p[4]) -replace '[^\d]',''), [ref]$vol) }
            if (-not $h.ContainsKey($name)) { $h[$name] = New-Object System.Collections.ArrayList }
            [void]$h[$name].Add(@{ t = $t; low = $low; med = $med; vol = $vol })
        }
    } catch {}
    return $h
}

function Append-History($name, $low, $med, $vol) {
    try {
        $ts   = (Get-Date).ToString("o")
        $lowS = ([double]$low).ToString($InvCulture)
        $medS = ([double]$med).ToString($InvCulture)
        Add-Content -Path $HistoryFile -Value ("$ts`t$name`t$lowS`t$medS`t$vol") -Encoding UTF8
    } catch {}
}

function Prune-History {
    # оставляем записи за последние ~32 дня (нужно для долгосрочного ориентира за 30 дней)
    if (-not (Test-Path $HistoryFile)) { return }
    try {
        $now  = Get-Date
        $keep = Get-Content -Path $HistoryFile -Encoding UTF8 | Where-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return $false }
            $t = Parse-IsoDate (($_ -split "`t")[0])
            $t -and (($now - $t).TotalDays -le 32)
        }
        Set-Content -Path $HistoryFile -Value $keep -Encoding UTF8
    } catch {}
}

function Get-LongTermRef($histForName, $curPrice) {
    # долгосрочный ориентир: средняя медиана и тренд за ~30 дней по нашей накопленной истории.
    # нужен, чтобы отличать разовую просадку (цена вернётся) от предмета, что дешевеет неделями.
    $res = @{ enough = $false; days = 0; avg = 0; pct = 0 }
    if (-not $histForName -or $histForName.Count -eq 0) { return $res }
    $now = Get-Date
    $window = @($histForName | Where-Object { (($now - $_.t).TotalDays -le $LongTermDays) -and ($_.med -gt 0) })
    if ($window.Count -eq 0) { return $res }
    $oldest   = ($window | Sort-Object { $_.t } | Select-Object -First 1)
    $spanDays = [math]::Round(($now - $oldest.t).TotalDays, 1)
    $sum = 0.0; foreach ($x in $window) { $sum += $x.med }
    $res.days = $spanDays
    $res.avg  = [math]::Round($sum / $window.Count, 0)
    if (($spanDays -ge $LongTermMinDays) -and ($oldest.med -gt 0)) {
        $res.enough = $true
        $res.pct    = [math]::Round((($curPrice - $oldest.med) / $oldest.med) * 100, 1)
    }
    return $res
}

function Get-Trend($histForName, $curMed) {
    # тренд цены за последние ~7 дней: сравниваем текущую медиану с самой ранней в окне
    $res = @{ enough = $false; pct = 0; arrow = "•"; label = "мало данных" }
    if (-not $histForName -or $histForName.Count -eq 0) { return $res }
    $now    = Get-Date
    $window = @($histForName | Where-Object { ($now - $_.t).TotalDays -le 7 })
    if ($window.Count -eq 0) { return $res }
    $oldest = $window | Sort-Object { $_.t } | Select-Object -First 1
    if ((($now - $oldest.t).TotalHours -lt 24) -or ($oldest.med -le 0)) { return $res }
    $pct = [math]::Round((($curMed - $oldest.med) / $oldest.med) * 100, 1)
    $res.enough = $true
    $res.pct    = $pct
    if     ($pct -ge $TrendDeadband)  { $res.arrow = "↗"; $res.label = "растёт" }
    elseif ($pct -le -$TrendDeadband) { $res.arrow = "↘"; $res.label = "падает" }
    else                              { $res.arrow = "→"; $res.label = "стабильна" }
    return $res
}

# --- ПОРТФЕЛЬ: что куплено, по какой цене и когда ---
function Load-Portfolio {
    $list = @()
    if (-not (Test-Path $PortfolioFile)) { return $list }
    foreach ($ln in (Get-Content -Path $PortfolioFile -Encoding UTF8)) {
        $s = $ln.Trim()
        if ($s -eq '' -or $s.StartsWith('#')) { continue }
        $parts = $s -split ';'
        if ($parts.Count -lt 3) { Write-Host ("  [портфель] пропущено (нужно: Название ; цена ; дата): {0}" -f $s) -ForegroundColor DarkYellow; continue }
        $nm = $parts[0].Trim()
        $bp = Parse-Price $parts[1]
        $dt = $null
        try { $dt = [datetime]::Parse($parts[2].Trim(), $InvCulture) } catch {}
        if (-not $nm -or -not $bp -or -not $dt) { Write-Host ("  [портфель] не понял строку: {0}" -f $s) -ForegroundColor DarkYellow; continue }
        $list += @{ name = $nm; buy = $bp; date = $dt }
    }
    return ,$list
}

function Check-Portfolio {
    $holdings = Load-Portfolio
    if ($holdings.Count -eq 0) { return }
    Write-Host ("--- Портфель: позиций {0} ---" -f $holdings.Count) -ForegroundColor Cyan
    $now = Get-Date
    $Hist = Load-History   # для распознавания пика цены по накопленной истории
    $script:PortfolioLines = @()   # для суточной сводки
    foreach ($h in $holdings) {
        try {
            $enc  = [uri]::EscapeDataString($h.name)
            $url  = "https://steamcommunity.com/market/priceoverview/?appid=730&currency=$CurrencyCode&market_hash_name=$enc"
            $resp = Invoke-RestMethod -Uri $url -UserAgent "Mozilla/5.0" -TimeoutSec 20
            $low  = Parse-Price $resp.lowest_price
            # Steam иногда не отдаёт текущую цену — одна повторная попытка, затем запасной вариант (медианная)
            if (-not $low) {
                Start-Sleep -Seconds 4
                try { $resp = Invoke-RestMethod -Uri $url -UserAgent "Mozilla/5.0" -TimeoutSec 20 } catch {}
                $low = Parse-Price $resp.lowest_price
                if (-not $low) { $low = Parse-Price $resp.median_price }
            }
            if (-not $low) { Write-Host ("  {0}: нет цены" -f $h.name) -ForegroundColor DarkGray; Start-Sleep -Seconds $SleepBetweenItemsSec; continue }

            $med = Parse-Price $resp.median_price; if (-not $med) { $med = $low }
            $vol = Parse-Int $resp.volume
            Append-History $h.name $low $med $vol           # копим историю и по своим покупкам (нужно для пика)
            $long = Get-LongTermRef $Hist[$h.name] $low     # средняя цена за ~30 дней

            # "пик": текущая цена заметно выше нормы (медианы или средней за ~30 дн)
            $isPeak = ($low -ge $med * (1 + $PeakAbovePct/100.0))
            if ($long.enough -and ($low -ge $long.avg * (1 + $PeakAbovePct/100.0))) { $isPeak = $true }

            $net    = Get-SellerNet $low   # на руки после комиссий Steam (точный расчёт)
            $profit = [math]::Round($net - $h.buy, 0)
            $unlock = $h.date.AddDays(7)
            $locked = $now -lt $unlock
            $link   = "https://steamcommunity.com/market/listings/730/$enc"
            $status = if ($locked) { "🔒 заблокирован до " + $unlock.ToString("dd.MM.yyyy") } else { "🟢 можно продавать" }
            $pcol   = if ($profit -ge 0) { "Green" } else { "Red" }
            Write-Host ("  {0} | куплен за {1} | продать ~{2} (на руки {3}) | прибыль {4} | {5}" -f $h.name, $h.buy, $low, $net, $profit, $status) -ForegroundColor $pcol

            $stShort = if ($locked) { "🔒 до " + $unlock.ToString("dd.MM") } else { "🟢 продавать" }
            $script:PortfolioLines += @{ text = ("• {0}: куплен {1} → сейчас {2} (на руки {3}, P/L {4}) {5}" -f $h.name, $h.buy, $low, $net, $profit, $stShort); buy = [double]$h.buy; net = [double]$net }

            # Telegram-сигнал: разблокирован И в плюсе -> пора продавать (на пике — активнее)
            if ((-not $locked) -and ($profit -ge 0)) {
                $key  = "SELL::" + $h.name
                $prev = $State[$key]
                $doAlert = $true
                if ($prev -and $prev.lastAlert) {
                    $hrs = (New-TimeSpan -Start ([datetime]$prev.lastAlert) -End $now).TotalHours
                    if ($hrs -lt $SellAlertCooldownHours) { $doAlert = $false }
                    # пик с новой более высокой ценой (>3% выше прошлого сигнала) пробивает кулдаун
                    if ($isPeak -and $prev.lastPrice -and ($low -ge ([double]$prev.lastPrice) * 1.03)) { $doAlert = $true }
                }
                if ($doAlert) {
                    if ($isPeak) {
                        $head  = "🔥 <b>ПИК ЦЕНЫ — продавай сейчас!</b>"
                        $extra = "Цена сейчас выше обычной — хороший момент зафиксировать прибыль."
                    } else {
                        $head  = "🟢 <b>Пора продавать (в плюсе)</b>"
                        $extra = "Можно продать в плюс. Если не срочно — иногда выгоднее дождаться локального пика."
                    }
                    $msg = @"
$head
$($h.name)
Куплено за: $($h.buy) ₸  ($($h.date.ToString("dd.MM.yyyy")))
Продать сейчас примерно за: <b>$low ₸</b>
На руки после комиссий Steam: <b>$net ₸</b>
Прибыль: <b>~$profit ₸</b>
$extra
$link
"@
                    Send-Telegram $msg $link "🟢 Открыть на Steam (продать)"
                    $State[$key] = @{ lastAlert = $now.ToString("o"); lastPrice = $low }
                    Save-State
                }
            }
        } catch {
            Write-Host ("  [!] Ошибка портфеля по {0}: {1}" -f $h.name, $_.Exception.Message) -ForegroundColor Red
        }
        Start-Sleep -Seconds $SleepBetweenItemsSec
    }
}

function Run-Backtest {
    # Теневой бэктест: "если бы покупали каждый сигнал (скидка>=порог, ликвидность ок)
    # и продавали в первый плюс через 7+ дней" — на нашей накопленной истории. Без риска.
    $H = Load-History
    $res = @{ enough = $false; days = 0; trades = 0; wins = 0; pl = 0; open = 0; text = "" }
    if ($H.Count -eq 0) { $res.text = "🧪 Бэктест: истории ещё нет."; return $res }

    $now = Get-Date
    $earliest = $now
    $maxHoldDays = 21
    $trades = 0; $wins = 0; $totalPL = 0.0; $open = 0
    foreach ($name in $H.Keys) {
        $recs = @($H[$name] | Sort-Object { $_.t })
        if ($recs.Count -eq 0) { continue }
        if ($recs[0].t -lt $earliest) { $earliest = $recs[0].t }
        $i = 0
        while ($i -lt $recs.Count) {
            $r = $recs[$i]
            if ($r.med -le 0 -or $r.low -le 0) { $i++; continue }
            $disc = (($r.med - $r.low) / $r.med) * 100
            if (($disc -ge $DiscountPercent) -and ($r.vol -ge $MinVolume)) {
                $buy      = $r.low
                $unlockT  = $r.t.AddDays(7)
                $deadline = $r.t.AddDays($maxHoldDays)
                $sold = $false; $sellNet = 0; $lastNetInWin = $null; $lastIdx = $i
                for ($j = $i + 1; $j -lt $recs.Count; $j++) {
                    $rj = $recs[$j]
                    if ($rj.t -gt $deadline) { break }
                    $lastIdx = $j
                    if ($rj.low -le 0) { continue }
                    $net = Get-SellerNet $rj.low
                    $lastNetInWin = $net
                    if (($rj.t -ge $unlockT) -and ($net -gt $buy)) { $sellNet = $net; $sold = $true; break }
                }
                if ($sold) {
                    $trades++; if (($sellNet - $buy) -gt 0) { $wins++ }; $totalPL += ($sellNet - $buy); $i = $lastIdx + 1
                } elseif (($null -ne $lastNetInWin) -and ($recs[$lastIdx].t -ge $unlockT)) {
                    # не вышли в плюс за окно — закрываем по последней цене (обычно минус)
                    $trades++; if (($lastNetInWin - $buy) -gt 0) { $wins++ }; $totalPL += ($lastNetInWin - $buy); $i = $lastIdx + 1
                } else {
                    $open++; $i++   # позиция ещё "открыта" — данных не хватило, не считаем
                }
            } else { $i++ }
        }
    }
    $spanDays = [math]::Round(($now - $earliest).TotalDays, 1)
    $res.days = $spanDays; $res.trades = $trades; $res.wins = $wins; $res.pl = [math]::Round($totalPL, 0); $res.open = $open
    if (($spanDays -lt ($maxHoldDays * 0.5)) -or ($trades -eq 0)) {
        $res.text = "🧪 Бэктест: пока мало данных (история $spanDays дн, завершённых сделок $trades). Копим — будет точнее."
    } else {
        $res.enough = $true
        $winRate = [math]::Round(100.0 * $wins / $trades, 0)
        $avg     = [math]::Round($totalPL / $trades, 0)
        $res.text = "🧪 Бэктест за $spanDays дн: сделок $trades, в плюс $wins ($winRate%), суммарно ~$($res.pl) ₸ (в среднем ~$avg ₸/сделка). Открытых ещё: $open."
    }
    return $res
}

function Send-Digest {
    # раз в сутки (после часа $DigestHourUTC по UTC) шлём сводку. По понедельникам — ещё и заявки-подсказки.
    $nowUtc = (Get-Date).ToUniversalTime()
    $today  = $nowUtc.ToString("yyyy-MM-dd")
    if ($nowUtc.Hour -lt $DigestHourUTC) { return }
    if ($State["_lastDigestDate"] -eq $today) { return }

    $isMonday      = ($nowUtc.DayOfWeek -eq [System.DayOfWeek]::Monday)
    $havePortfolio = ($script:PortfolioLines -and $script:PortfolioLines.Count -gt 0)
    if ((-not $havePortfolio) -and (-not $isMonday)) {
        $State["_lastDigestDate"] = $today; Save-State; return   # нечего показывать — просто отмечаем день
    }

    # сигналов за 24ч + чистка отметок старше 48ч
    $sig24 = 0; $kept = @()
    if ($State["_signalTimes"]) {
        foreach ($t in @($State["_signalTimes"])) {
            $dt = Parse-IsoDate $t
            if ($dt) {
                $hrs = ($nowUtc - $dt.ToUniversalTime()).TotalHours
                if ($hrs -le 24) { $sig24++ }
                if ($hrs -le 48) { $kept += $t }
            }
        }
        $State["_signalTimes"] = $kept
    }

    $lines = @()
    $lines += "📊 <b>Сводка CS2 за сутки</b>"
    $lines += "Сигналов «брать» за 24ч: <b>$sig24</b>"

    if ($havePortfolio) {
        $lines += ""
        $lines += "<b>Портфель:</b>"
        $totBuy = 0.0; $totVal = 0.0
        foreach ($p in $script:PortfolioLines) {
            $lines += $p.text
            $totBuy += [double]$p.buy; $totVal += [double]$p.net
        }
        $totProfit = [math]::Round($totVal - $totBuy, 0)
        $lines += ("Итого вложено: {0} ₸ → на руки сейчас ~{1} ₸ (P/L ~{2} ₸)" -f [math]::Round($totBuy,0), [math]::Round($totVal,0), $totProfit)
    } else {
        $lines += "Портфель пуст — покупок пока нет."
    }

    if ($isMonday -and $script:WatchMedians -and $script:WatchMedians.Count -gt 0) {
        $lines += ""
        $lines += "<b>💡 Заявки на покупку (недельная подсказка)</b>"
        $lines += "Поставь на Steam ордер по цене ≤ указанной — поймает дип сам:"
        foreach ($k in $script:WatchMedians.Keys) {
            $bo = [math]::Round(([double]$script:WatchMedians[$k]) * (1 - $DiscountPercent/100.0), 0)
            $lines += ("• {0} — ≤ {1} ₸" -f $k, $bo)
        }
    }

    # раз в неделю (по понедельникам) — теневой бэктест стратегии по накопленной истории
    if ($isMonday) {
        $bt = Run-Backtest
        $lines += ""
        $lines += $bt.text
    }

    Send-Telegram ($lines -join "`n")
    $State["_lastDigestDate"] = $today
    Save-State
}

function Handle-Command($text, $m) {
    $lc = $text.ToLower()
    if ($lc -in @('помощь','help','/help','/start')) {
        Send-Telegram @"
🤖 <b>Команды бота</b>
• <b>куплено 15900</b> — в ОТВЕТ (reply) на сигнал: занести покупку в портфель
• <b>куплено Название ; 15900</b> — занести покупку вручную
• <b>портфель</b> — показать мои покупки и прибыль
• <b>бэктест</b> — прогнать бэктест стратегии
• <b>помощь</b> — этот список
Отвечаю раз в ~15 минут (когда бот делает проход).
"@
        return
    }
    if ($lc -in @('портфель','portfolio','/portfolio')) { $script:CmdWantPortfolio = $true; return }
    if ($lc -in @('бэктест','backtest','/backtest')) { $bt = Run-Backtest; Send-Telegram $bt.text; return }
    if ($lc -like 'куплено*' -or $lc -like 'купил*') {
        $rest = ($text -replace '^(?i)(куплено|купил[аи]?)\s*', '').Trim()
        $name = $null; $price = $null
        if ($rest -match ';') {
            $parts = $rest -split ';', 2
            $name = $parts[0].Trim(); $price = Parse-Price $parts[1]
        } else {
            $price = Parse-Price $rest
            if ($m.reply_to_message -and $m.reply_to_message.text) {
                foreach ($ln in ($m.reply_to_message.text -split "`n")) {
                    if ($ln -match '\|') { $name = $ln.Trim(); break }   # строка с названием скина
                }
            }
        }
        if (-not $name)  { Send-Telegram "Не понял, какой предмет. Ответь этой командой на сообщение-сигнал, или напиши: куплено Название ; цена"; return }
        if (-not $price -or $price -le 0) { Send-Telegram "Не понял цену. Пример: куплено 15900"; return }
        $date = (Get-Date).ToString("yyyy-MM-dd")
        Add-Content -Path $PortfolioFile -Value ("{0} ; {1} ; {2}" -f $name, [int]$price, $date) -Encoding UTF8
        Send-Telegram ("✅ Добавил в портфель: {0} за {1} ₸ ({2}). Прослежу и напишу, когда пора продавать." -f $name, [int]$price, $date)
        return
    }
    Send-Telegram "Не понял команду. Напиши «помощь» для списка."
}

function Poll-Commands {
    # читаем сообщения пользователя из Telegram и выполняем простые команды (интерактив без сервера)
    if (-not $TelegramToken -or -not $TelegramChatId) { return }
    $offset = 0
    if ($State["_updateOffset"]) { try { $offset = [int]$State["_updateOffset"] } catch {} }
    $firstTime = (-not $State["_updateOffset"])   # первый запуск — пропускаем старый backlog сообщений
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$TelegramToken/getUpdates?timeout=0&offset=$($offset+1)" -TimeoutSec 20
    } catch { return }
    if (-not $r.ok -or -not $r.result) { return }
    foreach ($upd in $r.result) {
        $offset = [int]$upd.update_id
        if ($firstTime) { continue }   # только запоминаем offset, старые команды не выполняем
        $msg = $upd.message
        if (-not $msg) { continue }
        if ([string]$msg.chat.id -ne [string]$TelegramChatId) { continue }   # только свой чат
        $t = ([string]$msg.text).Trim()
        if ($t -ne '') { try { Handle-Command $t $msg } catch { Write-Host "  [!] команда '$t': $($_.Exception.Message)" -ForegroundColor Red } }
    }
    $State["_updateOffset"] = $offset
    Save-State
}

function Run-Cycle {
    if (-not (Test-Path $ItemsFile)) { Write-Host "Нет файла items.txt рядом со скриптом." -ForegroundColor Red; return }

    $script:CmdWantPortfolio = $false
    Poll-Commands   # сначала читаем команды пользователя из Telegram

    $Hist = Load-History
    $script:WatchMedians = [ordered]@{}   # медианы предметов для недельной подсказки по заявкам

    $items = Get-Content -Path $ItemsFile -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }

    Write-Host ("=== Проход {0} | предметов: {1} ===" -f (Get-Date -Format "HH:mm:ss"), $items.Count) -ForegroundColor Cyan

    foreach ($name in $items) {
        try {
            $enc  = [uri]::EscapeDataString($name)
            $url  = "https://steamcommunity.com/market/priceoverview/?appid=730&currency=$CurrencyCode&market_hash_name=$enc"
            $resp = Invoke-RestMethod -Uri $url -UserAgent "Mozilla/5.0" -TimeoutSec 20

            # Steam иногда не отдаёт текущую цену (lowest_price) с первого раза — делаем одну повторную попытку
            if ($resp.success -and (-not (Parse-Price $resp.lowest_price))) {
                Start-Sleep -Seconds 4
                try { $resp = Invoke-RestMethod -Uri $url -UserAgent "Mozilla/5.0" -TimeoutSec 20 } catch {}
            }

            if (-not $resp.success) {
                Write-Host ("  {0}: нет данных (проверь имя предмета)" -f $name) -ForegroundColor DarkGray
            } else {
                $low = Parse-Price $resp.lowest_price
                $med = Parse-Price $resp.median_price
                $vol = Parse-Int   $resp.volume

                # если текущей цены нет даже после повтора, но есть медианная — берём её как ориентир
                if ((-not $low) -and $med -and $med -gt 0) { $low = $med }

                if ($low -and $med -and $med -gt 0) {
                    $discount = [math]::Round((($med - $low) / $med) * 100, 1)
                    $script:WatchMedians[$name] = $med   # для недельной подсказки по заявкам на покупку

                    # тренд цены за ~7 дней (по нашей накопленной истории)
                    $trend = Get-Trend $Hist[$name] $med
                    if ($trend.enough) { $trendText = "$($trend.arrow) $($trend.label) ($($trend.pct)% за неделю)" }
                    else               { $trendText = "пока мало данных (нужно 1-2 дня работы)" }

                    $line = ("  {0} | сейчас {1} | обычно {2} | скидка {3}% | продаж {4} | тренд: {5}" -f $name, $low, $med, $discount, $vol, $trend.label)

                    # копим историю по ВСЕМ предметам (нужно для расчёта тренда)
                    Append-History $name $low $med $vol

                    if ($discount -ge $DiscountPercent -and $vol -ge $MinVolume) {
                        if ($SkipFalling -and $trend.enough -and $trend.pct -le -$TrendDeadband) {
                            # опция включена: цену, которая явно падает, пропускаем
                            Write-Host ($line + "   [пропущено: цена падает]") -ForegroundColor DarkYellow
                        } else {
                            # АНТИСНАЙП (переключатель $ConfirmPasses): сигнал только если просадка держится N проходов подряд.
                            # $ConfirmPasses=1 -> мгновенно; =2 -> подтверждение на след. проходе (фильтр разовых дешёвых выставок).
                            $pkey = "PEND::" + $name
                            $confirmed = $true; $cnt = 1
                            if ($ConfirmPasses -gt 1) {
                                $pend = $State[$pkey]
                                if ($pend -and $pend.price -and ($low -le ([double]$pend.price) * 1.03)) { $cnt = [int]$pend.count + 1 }
                                $State[$pkey] = @{ price = $low; count = $cnt; t = (Get-Date).ToString("o") }
                                Save-State
                                $confirmed = ($cnt -ge $ConfirmPasses)
                            }
                            if (-not $confirmed) {
                                Write-Host ($line + "   [замечено $cnt/$ConfirmPasses, ждём подтверждения]") -ForegroundColor DarkYellow
                            } else {
                            Write-Host $line -ForegroundColor Green

                            # проверка "не повторять слишком часто"
                            $prev = $State[$name]
                            $doAlert = $true
                            if ($prev -and $prev.lastAlert) {
                                $lastT = [datetime]$prev.lastAlert
                                $hrs = (New-TimeSpan -Start $lastT -End (Get-Date)).TotalHours
                                if ($hrs -lt $CooldownHours -and $low -ge ([double]$prev.lastPrice) * 0.97) { $doAlert = $false }
                            }

                            if ($doAlert) {
                                $net    = Get-SellerNet $med
                                $profit = [math]::Round($net - $low, 0)
                                $link   = "https://steamcommunity.com/market/listings/730/$enc"

                                # долгосрочный ориентир (средняя цена и тренд за ~30 дней по нашей истории)
                                $long = Get-LongTermRef $Hist[$name] $med
                                if ($long.enough) {
                                    $longText = "средняя за $($long.days) дн ~$($long.avg) ₸, долгий тренд $($long.pct)%"
                                } else {
                                    $longText = "долгосрочные данные копятся ($($long.days) из $LongTermMinDays дн)"
                                }

                                # --- АВТО-ВЕРДИКТ: брать или нет ---
                                # (просадка и ликвидность уже прошли пороги — решают тренды цены и запас навара)
                                if (-not $trend.enough) {
                                    $verdict = "⚠️ НА ГРАНИ"
                                    $vReason = "просадка и ликвидность ок, но тренд ещё без данных (нужны 1-2 дня работы). Глянь график перед покупкой или спроси меня."
                                } elseif ($trend.pct -le -$TrendDeadband) {
                                    $verdict = "⛔ ПРОПУСТИТЬ"
                                    $vReason = "цена падает ($($trend.pct)% за неделю) — за 7 дней блокировки может подешеветь ещё."
                                } elseif ($long.enough -and ($long.pct -le -$LongTermFallPct)) {
                                    $verdict = "⛔ ПРОПУСТИТЬ"
                                    $vReason = "«падающий нож»: цена дешевеет давно ($($long.pct)% за $($long.days) дн) — вероятно наплыв предложения, за неделю упадёт ещё."
                                } elseif ($profit -le 0) {
                                    $verdict = "⛔ ПРОПУСТИТЬ"
                                    $vReason = "после комиссий Steam навара нет ($profit ₸) — просадка не покрывает комиссию."
                                } elseif ($long.enough -and ($low -ge $long.avg)) {
                                    $verdict = "⚠️ НА ГРАНИ"
                                    $vReason = "не настоящая просадка: цена ($low ₸) не ниже своей средней за $($long.days) дн (~$($long.avg) ₸). Скидка от медианы могла раздуться из-за недавнего всплеска — решай сам."
                                } elseif ($discount -ge ($DiscountPercent + 8)) {
                                    $verdict = "✅ БРАТЬ (сильный сигнал)"
                                    $vReason = "крупная просадка $discount%, ликвидность ок, недельный тренд $($trend.label), долгосрочно не падает. Навар ~$profit ₸ после комиссии."
                                } else {
                                    $verdict = "✅ БРАТЬ"
                                    $vReason = "просадка $discount%, ликвидность ок, недельный тренд $($trend.label), долгосрочно не падает. Навар ~$profit ₸ после комиссии."
                                }

                                # цена заявки на покупку (buy order): ставим ниже нормы, чтобы поймать будущий дип автоматически
                                $buyOrder = [math]::Round($med * (1 - $DiscountPercent/100.0), 0)

                                $msg = @"
🔥 <b>Выгодный лот CS2</b>
$name
🧭 <b>РЕШЕНИЕ: $verdict</b>
$vReason

Купить сейчас: <b>$low ₸</b>
Продать потом: ~<b>$med ₸</b> (на руки после комиссии ~$net ₸)
Скидка: <b>$discount%</b>   |   Продаж в сутки: $vol
📈 Тренд за неделю: <b>$trendText</b>
🗓 Долгий ориентир: <b>$longText</b>
Потенциальный навар: ~<b>$profit ₸</b>
💡 Не хочешь ждать сигнала — можно держать <b>заявку на покупку ~$buyOrder ₸</b> (сработает сама на дипе).
⏳ Куплено на маркете = продать можно только через 7 дней (навар зависит от цены на тот момент).
$link
"@
                                Send-Telegram $msg $link "🛒 Купить на Steam"
                                $State[$name] = @{ lastAlert = (Get-Date).ToString("o"); lastPrice = $low }
                                # запоминаем время сигнала (для суточной сводки — счётчик за 24ч)
                                $sigTimes = @(); if ($State["_signalTimes"]) { $sigTimes = @($State["_signalTimes"]) }
                                $sigTimes += (Get-Date).ToString("o")
                                $State["_signalTimes"] = $sigTimes
                                Save-State
                            }
                            }
                        }
                    } else {
                        if ($State["PEND::"+$name]) { $State.Remove("PEND::"+$name) }
                        Write-Host $line -ForegroundColor Gray
                    }
                } else {
                    Write-Host ("  {0}: цена не распознана" -f $name) -ForegroundColor DarkGray
                }
            }
        } catch {
            $code = $null
            try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
            if ($code -eq 429) {
                Write-Host "  [!] Steam ограничил частоту (429). Жду 60 сек..." -ForegroundColor Yellow
                Start-Sleep -Seconds 60
            } else {
                Write-Host ("  [!] Ошибка по {0}: {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
            }
        }
        Start-Sleep -Seconds $SleepBetweenItemsSec
    }

    # после списка на покупку проверяем свои покупки (портфель)
    Check-Portfolio

    # ответ на команду "портфель" (если пользователь просил)
    if ($script:CmdWantPortfolio) {
        if ($script:PortfolioLines -and $script:PortfolioLines.Count -gt 0) {
            $pl = @("<b>Твой портфель:</b>"); $tb = 0.0; $tv = 0.0
            foreach ($p in $script:PortfolioLines) { $pl += $p.text; $tb += [double]$p.buy; $tv += [double]$p.net }
            $pl += ("Итого вложено {0} ₸ → на руки ~{1} ₸ (P/L ~{2} ₸)" -f [math]::Round($tb,0), [math]::Round($tv,0), [math]::Round($tv-$tb,0))
            Send-Telegram ($pl -join "`n")
        } else {
            Send-Telegram "Портфель пуст — покупок пока нет."
        }
        $script:CmdWantPortfolio = $false
    }

    # раз в сутки — сводка в Telegram (и по понедельникам — подсказка по заявкам на покупку)
    Send-Digest
}

# ================================  ЗАПУСК  ================================
Prune-History   # чистим историю старше ~32 дней, чтобы файл не разрастался

if ($Backtest) {
    $bt = Run-Backtest
    Write-Host $bt.text
    Send-Telegram $bt.text
    exit
}

if ($Portfolio) {
    Check-Portfolio
    exit
}

if ($Once) {
    Run-Cycle
} else {
    Write-Host "Трекер запущен. Остановить — Ctrl+C." -ForegroundColor Cyan
    while ($true) {
        Run-Cycle
        Write-Host ("Пауза {0} мин до следующего прохода..." -f $CycleDelayMinutes) -ForegroundColor DarkCyan
        Start-Sleep -Seconds ($CycleDelayMinutes * 60)
    }
}
