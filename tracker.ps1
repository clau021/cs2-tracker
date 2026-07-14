param(
    [switch]$GetChatId,   # запустить с этим ключом, чтобы узнать свой chat_id
    [switch]$Once,        # сделать один проход и выйти (для проверки)
    [switch]$Portfolio    # показать состояние портфеля (что куплено) и выйти
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

$SellAlertCooldownHours = 12 # как часто повторять сигнал "пора продавать" по одной покупке

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
            $med = 0.0
            [double]::TryParse($p[3], [System.Globalization.NumberStyles]::Float, $InvCulture, [ref]$med) | Out-Null
            if (-not $h.ContainsKey($name)) { $h[$name] = New-Object System.Collections.ArrayList }
            [void]$h[$name].Add(@{ t = $t; med = $med })
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
    # оставляем только записи за последние 10 дней, чтобы файл не разрастался
    if (-not (Test-Path $HistoryFile)) { return }
    try {
        $now  = Get-Date
        $keep = Get-Content -Path $HistoryFile -Encoding UTF8 | Where-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return $false }
            $t = Parse-IsoDate (($_ -split "`t")[0])
            $t -and (($now - $t).TotalDays -le 10)
        }
        Set-Content -Path $HistoryFile -Value $keep -Encoding UTF8
    } catch {}
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

            $net    = [math]::Round($low * (1 - $FeePercent/100.0), 0)   # на руки после комиссии
            $profit = [math]::Round($net - $h.buy, 0)
            $unlock = $h.date.AddDays(7)
            $locked = $now -lt $unlock
            $link   = "https://steamcommunity.com/market/listings/730/$enc"
            $status = if ($locked) { "🔒 заблокирован до " + $unlock.ToString("dd.MM.yyyy") } else { "🟢 можно продавать" }
            $pcol   = if ($profit -ge 0) { "Green" } else { "Red" }
            Write-Host ("  {0} | куплен за {1} | продать ~{2} (на руки {3}) | прибыль {4} | {5}" -f $h.name, $h.buy, $low, $net, $profit, $status) -ForegroundColor $pcol

            # Telegram-сигнал: разблокирован И в плюсе -> пора продавать
            if ((-not $locked) -and ($profit -ge 0)) {
                $key  = "SELL::" + $h.name
                $prev = $State[$key]
                $doAlert = $true
                if ($prev -and $prev.lastAlert) {
                    $hrs = (New-TimeSpan -Start ([datetime]$prev.lastAlert) -End $now).TotalHours
                    if ($hrs -lt $SellAlertCooldownHours) { $doAlert = $false }
                }
                if ($doAlert) {
                    $msg = @"
🟢 <b>Пора продавать (в плюсе)</b>
$($h.name)
Куплено за: $($h.buy) ₸  ($($h.date.ToString("dd.MM.yyyy")))
Выставить на продажу примерно за: <b>$low ₸</b>
На руки после комиссии (~$FeePercent%): <b>$net ₸</b>
Прибыль: <b>~$profit ₸</b>
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

function Run-Cycle {
    if (-not (Test-Path $ItemsFile)) { Write-Host "Нет файла items.txt рядом со скриптом." -ForegroundColor Red; return }

    $Hist = Load-History

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
                                $net    = [math]::Round($med * (1 - $FeePercent/100.0), 0)
                                $profit = [math]::Round($net - $low, 0)
                                $link   = "https://steamcommunity.com/market/listings/730/$enc"

                                # --- АВТО-ВЕРДИКТ: брать или нет ---
                                # (просадка и ликвидность уже прошли пороги — решает тренд цены и запас навара)
                                if (-not $trend.enough) {
                                    $verdict = "⚠️ НА ГРАНИ"
                                    $vReason = "просадка и ликвидность ок, но тренд ещё без данных (нужны 1-2 дня работы). Глянь график перед покупкой или спроси меня."
                                } elseif ($trend.pct -le -$TrendDeadband) {
                                    $verdict = "⛔ ПРОПУСТИТЬ"
                                    $vReason = "цена падает ($($trend.pct)% за неделю) — за 7 дней блокировки может подешеветь ещё."
                                } elseif ($profit -le 0) {
                                    $verdict = "⛔ ПРОПУСТИТЬ"
                                    $vReason = "после комиссии ~$FeePercent% навара нет ($profit ₸) — просадка не покрывает комиссию."
                                } elseif ($discount -ge ($DiscountPercent + 8)) {
                                    $verdict = "✅ БРАТЬ (сильный сигнал)"
                                    $vReason = "крупная просадка $discount%, ликвидность ок, тренд $($trend.label). Навар ~$profit ₸ после комиссии."
                                } else {
                                    $verdict = "✅ БРАТЬ"
                                    $vReason = "просадка $discount%, ликвидность ок, тренд $($trend.label). Навар ~$profit ₸ после комиссии, риск умеренный."
                                }

                                $msg = @"
🔥 <b>Выгодный лот CS2</b>
$name
🧭 <b>РЕШЕНИЕ: $verdict</b>
$vReason

Купить сейчас: <b>$low ₸</b>
Продать потом: ~<b>$med ₸</b> (на руки после комиссии ~$net ₸)
Скидка: <b>$discount%</b>   |   Продаж в сутки: $vol
📈 Тренд цены: <b>$trendText</b>
Потенциальный навар: ~<b>$profit ₸</b>
⏳ Куплено на маркете = продать можно только через 7 дней (навар зависит от цены на тот момент).
$link
"@
                                Send-Telegram $msg $link "🛒 Купить на Steam"
                                $State[$name] = @{ lastAlert = (Get-Date).ToString("o"); lastPrice = $low }
                                Save-State
                            }
                        }
                    } else {
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
}

# ================================  ЗАПУСК  ================================
Prune-History   # чистим историю старше 10 дней, чтобы файл не разрастался

# при РУЧНОМ запуске из GitHub (кнопка Run workflow) — разовое подтверждение в Telegram.
# По расписанию (schedule) это правило молчит, чтобы не было спама.
if ($env:RUN_KIND -eq 'workflow_dispatch') {
    Send-Telegram "✅ Облачный трекер запущен из GitHub — связь с Telegram работает. Дальше слежу за ценами сам и пришлю сигнал, когда появится выгодный лот."
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
