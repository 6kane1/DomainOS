<#
  Domain OS — честное A/B-сравнение Win32PrioritySeparation: 0x18 (24, значение Domain OS) против 0x26 (38).
  Меняет ТОЛЬКО одно значение реестра:
      HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl\Win32PrioritySeparation
  Перед первой сменой записывает исходное значение в файл PrioritySeparation-original.txt рядом со скриптом;
  -Restore возвращает ровно его (или удаляет значение, если его не было) и удаляет этот файл.

      .\Compare-PrioritySeparation.ps1                 текущее значение, записанное исходное и план замеров
      .\Compare-PrioritySeparation.ps1 -Set 0x18       вариант A (Domain OS)
      .\Compare-PrioritySeparation.ps1 -Set 0x26       вариант B (как в Windows на ПК: короткие переменные кванты, 3:1)
      .\Compare-PrioritySeparation.ps1 -Restore        вернуть записанное исходное значение

  Значение ядро применяет сразу, перезагрузка для него не нужна. План всё равно перезагружает ПК при каждой смене
  варианта и даёт 10 минут простоя: так у обоих вариантов одинаковые условия (прогрев, фоновые задачи после старта).
  Права администратора нужны только для -Set и -Restore; скрипт сам запросит их (UAC).
  Windows PowerShell 5.1.
#>
param(
    [string]$Set,
    [switch]$Restore,
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$keyPath = 'SYSTEM\CurrentControlSet\Control\PriorityControl'
$valueName = 'Win32PrioritySeparation'
$stateFile = Join-Path $PSScriptRoot 'PrioritySeparation-original.txt'

function Wait-IfElevated {
    if ($Elevated) { Write-Host ''; Read-Host 'Нажмите Enter, чтобы закрыть окно' | Out-Null }
}

function Format-Value([object]$v) {
    if ($null -eq $v) { return 'нет значения (Windows считает как 2: на ПК это то же, что 0x26)' }
    $n = [int]$v
    $len = @('по умолчанию (на ПК: короткие)', 'длинные', 'короткие', 'по умолчанию')[($n -shr 4) -band 3]
    $var = @('по умолчанию (на ПК: переменные)', 'переменные', 'фиксированные', 'по умолчанию')[($n -shr 2) -band 3]
    $fg = ($n -band 3); if ($fg -eq 3) { $fg = 2 }
    $boost = if ((($n -shr 2) -band 3) -eq 2) { '1:1 (фиксированные кванты не растягиваются)' } else { @('1:1', '2:1', '3:1')[$fg] }
    return ('0x{0:X2} ({0}): кванты {1}, {2}, квант активного окна к фоновому {3}' -f $n, $len, $var, $boost)
}

function Read-Current {
    # returns @{ Exists; Value; Kind }
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath, $false)
    if ($null -eq $k) { throw "Нет раздела HKLM\$keyPath" }
    try {
        $names = $k.GetValueNames()
        if ($names -notcontains $valueName) { return @{ Exists = $false; Value = $null; Kind = '' } }
        return @{ Exists = $true; Value = $k.GetValue($valueName); Kind = [string]$k.GetValueKind($valueName) }
    } finally { $k.Close() }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    $line = (Get-Content -LiteralPath $stateFile -Encoding UTF8 | Where-Object { $_ -match '^value=' } | Select-Object -First 1)
    if ($null -eq $line) { throw "Файл $stateFile повреждён: нет строки value=. Ничего не изменено." }
    $raw = $line.Substring(6).Trim()
    if ($raw -eq 'absent') { return @{ Exists = $false; Value = $null } }
    if ($raw -notmatch '^-?\d+$') { throw "Файл $stateFile повреждён: value=$raw. Ничего не изменено." }
    return @{ Exists = $true; Value = [int64]$raw }
}

function Show-Plan {
    $exe = '.\DomainSchedTest.exe'
    $common = '--mode game --seconds 60 --process cs2 --out C:\PS-Test --yes'
    Write-Host ''
    Write-Host 'ПЛАН (6 замеров по 60 с, порядок A B B A A B, чтобы дрейф не попал в один вариант):' -ForegroundColor Cyan
    Write-Host '  Всё время одно и то же: карта, место, направление взгляда, настройки игры, программы в фоне.'
    Write-Host '  После каждой перезагрузки — 10 минут не трогать ПК, потом запустить CS2 и встать в то же место.'
    Write-Host '  Каждый замер: запустить команду в окне администратора в папке DomainSchedTest, за 10 с переключиться'
    Write-Host '  в игру, стоять на месте до звукового сигнала.'
    Write-Host ''
    Write-Host '  Сеанс 1:  Compare-PrioritySeparation.ps1 -Set 0x18, перезагрузка, 10 мин простоя'
    Write-Host "            $exe $common --label ps18-1"
    Write-Host '  Сеанс 2:  Compare-PrioritySeparation.ps1 -Set 0x26, перезагрузка, 10 мин простоя'
    Write-Host "            $exe $common --label ps26-1"
    Write-Host "            $exe $common --label ps26-2"
    Write-Host '  Сеанс 3:  Compare-PrioritySeparation.ps1 -Set 0x18, перезагрузка, 10 мин простоя'
    Write-Host "            $exe $common --label ps18-2"
    Write-Host "            $exe $common --label ps18-3"
    Write-Host '  Сеанс 4:  Compare-PrioritySeparation.ps1 -Set 0x26, перезагрузка, 10 мин простоя'
    Write-Host "            $exe $common --label ps26-3"
    Write-Host '  Конец:    Compare-PrioritySeparation.ps1 -Restore'
    Write-Host '            python compare_runs.py C:\PS-Test'
}

function Show-Status {
    $cur = Read-Current
    Write-Host ('Сейчас:     ' + (Format-Value $cur.Value))
    $st = Read-State
    if ($null -eq $st) { Write-Host 'Исходное:   ещё не записано (запишется при первом -Set)' }
    else { Write-Host ('Исходное:   ' + (Format-Value $st.Value) + "  [$stateFile]") }
}

# ---- what to do --------------------------------------------------------------------------------------------------
if ($Restore -and $Set) { Write-Host 'Укажите что-то одно: -Set или -Restore.' -ForegroundColor Red; Wait-IfElevated; exit 2 }

$target = $null
if ($Set) {
    $s = $Set.Trim().ToLowerInvariant()
    # "-Set 0x18" arrives as the number 24 (PowerShell reads 0x18 as a number), "-Set '0x18'" as text
    if ($s -eq '0x18' -or $s -eq '24') { $target = 24 }
    elseif ($s -eq '0x26' -or $s -eq '38') { $target = 38 }
    else { Write-Host "Допустимо только -Set 0x18 или -Set 0x26 (получено: $Set). Ничего не изменено." -ForegroundColor Red; Wait-IfElevated; exit 2 }
}

if ($null -eq $target -and -not $Restore) {
    Show-Status
    Show-Plan
    exit 0
}

# ---- elevation (only for changes) --------------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
    if ($Restore) { $argList += ' -Restore' } else { $argList += " -Set $target" }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argList -Verb RunAs
    exit 0
}

try {
    $cur = Read-Current
    if ($Restore) {
        $st = Read-State
        if ($null -eq $st) {
            Write-Host 'Исходное значение не записано (файла нет) — возвращать нечего, ничего не изменено.' -ForegroundColor Yellow
            Show-Status
            Wait-IfElevated; exit 0
        }
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath, $true)
        try {
            if ($st.Exists) { $k.SetValue($valueName, [int]$st.Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
            elseif ($cur.Exists) { $k.DeleteValue($valueName, $false) }
        } finally { $k.Close() }
        $after = Read-Current
        $ok = ($st.Exists -eq $after.Exists) -and (-not $st.Exists -or [int64]$after.Value -eq $st.Value)
        if (-not $ok) { throw 'После записи значение не совпало с исходным. Файл с исходным значением оставлен.' }
        Remove-Item -LiteralPath $stateFile -Force
        Write-Host ('Возвращено исходное: ' + (Format-Value $after.Value)) -ForegroundColor Green
        Write-Host 'Перезагрузка не нужна: значение действует сразу.'
        Wait-IfElevated; exit 0
    }

    # -Set: record the original once (first change), then write
    if ($cur.Exists -and $cur.Kind -ne 'DWord') {
        throw "Сейчас $valueName имеет тип $($cur.Kind), а не DWORD. Скрипт такое не трогает. Ничего не изменено."
    }
    if (-not (Test-Path -LiteralPath $stateFile)) {
        $rec = if ($cur.Exists) { [string][int]$cur.Value } else { 'absent' }
        $text = "# Domain OS: Win32PrioritySeparation before Compare-PrioritySeparation.ps1 changed it`r`n" +
                "# recorded $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); -Restore writes this value back`r`n" +
                "value=$rec`r`n"
        [IO.File]::WriteAllText($stateFile, $text, (New-Object Text.UTF8Encoding($false)))
        if ((Read-State).Value -ne $(if ($cur.Exists) { [int64][int]$cur.Value } else { $null })) {
            throw "Не удалось проверить записанный файл $stateFile. Ничего не изменено."
        }
        Write-Host "Исходное значение записано: $stateFile"
    } else {
        Write-Host "Исходное значение уже записано раньше: $stateFile (не перезаписываю)"
    }
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath, $true)
    try { $k.SetValue($valueName, [int]$target, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
    $after = Read-Current
    if ([int64]$after.Value -ne $target) { throw 'После записи значение не совпало. Запустите -Restore.' }
    $variant = if ($target -eq 24) { 'A (ps18)' } else { 'B (ps26)' }
    Write-Host ("Вариант $variant установлен: " + (Format-Value $after.Value)) -ForegroundColor Green
    Write-Host 'Для самого значения перезагрузка не нужна (ядро применяет его сразу).'
    Write-Host 'По плану замеров всё же перезагрузите ПК и подождите 10 минут — одинаковые условия для A и B.'
    Wait-IfElevated; exit 0
} catch {
    Write-Host ("Ошибка: " + $_.Exception.Message) -ForegroundColor Red
    Wait-IfElevated; exit 1
}
