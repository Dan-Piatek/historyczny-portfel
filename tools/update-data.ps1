<#
  Aktualizacja lustra notowań (uruchamiane przez GitHub Actions, zgodne z Windows PowerShell 5.1).

  Wejście:  config/universe.csv  (symbol,name,market,type,indexes) – symbole Yahoo Finance
  Wyjście (katalog -Out, publikowany na gałęzi "data"):
    q/<SYMBOL>.csv   – "Date,Close" dzienne ceny zamknięcia (^ w nazwie pliku zamieniane na _)
    fx/<KOD>.csv     – "Date,Close" kursy średnie NBP (tabela A), PLN za 1 jednostkę waluty
    meta.json        – metadane symboli (waluta, nazwa, rynek, typ)
    index.json       – manifest dla aplikacji (lista symboli z datami, waluty)
    status.json      – wynik ostatniego przebiegu (błędy)

  Przyrostowo: istniejące pliki są uzupełniane ostatnimi 3 miesiącami; nowe symbole – pełna historia.
  Błąd pobrania nigdy nie usuwa wcześniejszych danych.
#>
param(
  [string]$Universe = 'config/universe.csv',
  [string]$Out = 'out',
  [int]$Limit = 0,                 # do testów: tylko pierwsze N symboli
  [string[]]$Only = @(),           # do testów: tylko wskazane symbole
  [int]$DelayMs = 250,
  [switch]$SkipFx
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object Text.UTF8Encoding $false
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$FxBase = @('EUR','USD','GBP','CHF','SEK','DKK','NOK','CZK','HUF','JPY')

New-Item -ItemType Directory -Force -Path (Join-Path $Out 'q'), (Join-Path $Out 'fx') | Out-Null

function FullPath([string]$p) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText((FullPath $path), $text, $Utf8) }
function SymFile([string]$sym) { return ($sym.ToUpperInvariant() -replace '\^', '_') + '.csv' }

function Read-Series([string]$path) {
  $map = New-Object 'System.Collections.Generic.SortedDictionary[string,string]'
  if (Test-Path -LiteralPath $path) {
    foreach ($line in [IO.File]::ReadAllLines((FullPath $path))) {
      if ($line -match '^(\d{4}-\d{2}-\d{2}),([0-9.eE+-]+)$') { $map[$Matches[1]] = $Matches[2] }
    }
  }
  return ,$map
}
function Write-Series([string]$path, $map) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("Date,Close`n")
  foreach ($k in $map.Keys) { [void]$sb.Append($k).Append(',').Append($map[$k]).Append("`n") }
  Write-Utf8 $path $sb.ToString()
}
function Format-Num([double]$v) {
  $r = if ([math]::Abs($v) -ge 1000) { [math]::Round($v, 2) } elseif ([math]::Abs($v) -ge 1) { [math]::Round($v, 4) } else { [math]::Round($v, 6) }
  return $r.ToString('0.######', $Inv)
}

function Invoke-Get([string]$url) {
  $wait = 5
  for ($i = 0; $i -lt 4; $i++) {
    try {
      $r = Invoke-WebRequest -UseBasicParsing -Uri $url -UserAgent $UA -TimeoutSec 30
      return @{ status = [int]$r.StatusCode; body = $r.Content }
    } catch {
      $code = 0
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($code -eq 404 -or $code -eq 400) { return @{ status = $code; body = '' } }
      if ($i -eq 3) { throw }
      Start-Sleep -Seconds $wait; $wait *= 3
    }
  }
}

function JsonStr([string]$body, [string]$key) {
  if ($body -match ('"' + $key + '":"((?:[^"\\]|\\.)*)"')) { return [regex]::Unescape($Matches[1]) }
  return $null
}

# Pobiera serię z Yahoo (chart API v8). Parsowanie wyrażeniami regularnymi zamiast ConvertFrom-Json
# (limit 2 MB w PS 5.1 przy długich historiach, np. ^GSPC od 1927 r.).
function Get-Yahoo([string]$sym, [bool]$full, [int]$n) {
  $host_ = if ($n % 2) { 'query2' } else { 'query1' }
  $q = if ($full) { 'period1=0&period2=' + [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 86400) } else { 'range=3mo' }
  $url = "https://$host_.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($sym) + "?$q&interval=1d&includePrePost=false&events=div%2Csplits"
  $r = Invoke-Get $url
  if ($r.status -ne 200) { throw "HTTP $($r.status)" }
  $b = $r.body
  if ($b -notmatch '"result":\[\{') { throw ('brak danych: ' + (JsonStr $b 'description')) }
  $off = 0; if ($b -match '"gmtoffset":(-?\d+)') { $off = [int]$Matches[1] }
  if ($b -notmatch '"timestamp":\[([^\]]*)\]') { throw 'brak notowań' }
  $ts = $Matches[1].Split(',')
  $qi = $b.IndexOf('"quote":[')
  $ci = if ($qi -ge 0) { $b.IndexOf('"close":[', $qi) } else { -1 }   # "adjclose" nie pasuje – klucz poprzedza cudzysłów
  if ($ci -lt 0) { throw 'brak cen zamknięcia' }
  $ci += 9
  $cl = $b.Substring($ci, $b.IndexOf(']', $ci) - $ci).Split(',')
  $rows = New-Object 'System.Collections.Generic.SortedDictionary[string,string]'
  for ($i = 0; $i -lt [math]::Min($ts.Length, $cl.Length); $i++) {
    if ($cl[$i] -eq 'null' -or $cl[$i] -eq '') { continue }
    $v = [double]::Parse($cl[$i], $Inv)
    if ($v -le 0) { continue }
    $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts[$i] + $off).UtcDateTime.ToString('yyyy-MM-dd')
    $rows[$d] = Format-Num $v
  }
  return @{
    rows = $rows
    currency = JsonStr $b 'currency'
    type = JsonStr $b 'instrumentType'
    exchange = JsonStr $b 'fullExchangeName'
    name = $(if (JsonStr $b 'longName') { JsonStr $b 'longName' } else { JsonStr $b 'shortName' })
  }
}

# ---------------------------------------------------------------- symbole
$metaPath = Join-Path $Out 'meta.json'
$meta = @{}
if (Test-Path $metaPath) {
  $mj = [IO.File]::ReadAllText((FullPath $metaPath), $Utf8) | ConvertFrom-Json
  foreach ($p in $mj.PSObject.Properties) { $meta[$p.Name] = $p.Value }
}

$univ = @(Import-Csv -LiteralPath $Universe -Encoding UTF8)
if ($Only.Count) { $univ = @($univ | Where-Object { $Only -contains $_.symbol }) }
if ($Limit -gt 0) { $univ = @($univ | Select-Object -First $Limit) }
Write-Host "Symboli do aktualizacji: $($univ.Count)"

$errors = @(); $ok = 0; $n = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($u in $univ) {
  $n++
  $sym = $u.symbol.Trim()
  if (-not $sym) { continue }
  $path = Join-Path (Join-Path $Out 'q') (SymFile $sym)
  $series = Read-Series $path
  $last = $null; foreach ($k in $series.Keys) { $last = $k }
  $full = (-not $last) -or ((New-TimeSpan -Start ([datetime]::ParseExact($last, 'yyyy-MM-dd', $Inv)) -End (Get-Date)).TotalDays -gt 80)
  try {
    $y = Get-Yahoo $sym $full $n
    if ($y.rows.Count -eq 0) { throw 'pusta seria' }
    if ($full -and $series.Count -eq 0 -and $y.rows.Count -lt 5) { throw 'Yahoo nie udostępnia historii notowań' }
    foreach ($k in $y.rows.Keys) { $series[$k] = $y.rows[$k] }
    Write-Series $path $series
    $first = $null; $lastNew = $null; foreach ($k in $series.Keys) { if (-not $first) { $first = $k }; $lastNew = $k }
    $meta[$sym] = [ordered]@{
      n = $(if ($u.name) { $u.name } else { $y.name }); m = $u.market; t = $(if ($u.type) { $u.type } else { $y.type })
      c = $y.currency; x = $y.exchange; i = $u.indexes; f = $first; l = $lastNew; p = $series[$lastNew]
    }
    $ok++
  } catch {
    $errors += [ordered]@{ symbol = $sym; error = $_.Exception.Message }
    Write-Host ("  ! {0}: {1}" -f $sym, $_.Exception.Message)
  }
  if ($n % 100 -eq 0) { Write-Host ("  {0}/{1} ({2:n0} s)" -f $n, $univ.Count, $sw.Elapsed.TotalSeconds) }
  Start-Sleep -Milliseconds $DelayMs
}
Write-Host "Symbole: OK $ok, błędy $($errors.Count), czas $([int]$sw.Elapsed.TotalSeconds) s"

# ---------------------------------------------------------------- waluty (NBP)
$fxInfo = [ordered]@{}
$codes = New-Object 'System.Collections.Generic.SortedSet[string]'
foreach ($c in $FxBase) { [void]$codes.Add($c) }
foreach ($k in $meta.Keys) {
  $c = [string]$meta[$k].c
  if ($c -eq 'GBp' -or $c -eq 'GBX') { $c = 'GBP' }
  if ($c -and $c -ne 'PLN') { [void]$codes.Add($c.ToUpperInvariant()) }
}
foreach ($code in $codes) {
  $path = Join-Path (Join-Path $Out 'fx') "$code.csv"
  $series = Read-Series $path
  if (-not $SkipFx) {
    $last = $null; foreach ($k in $series.Keys) { $last = $k }
    $start = if ($last) { ([datetime]::ParseExact($last, 'yyyy-MM-dd', $Inv)).AddDays(-7) } else { [datetime]'2002-01-02' }
    $end = [datetime]::ParseExact($Today, 'yyyy-MM-dd', $Inv)
    try {
      while ($start -le $end) {
        $wEnd = $start.AddDays(92); if ($wEnd -gt $end) { $wEnd = $end }
        $url = 'https://api.nbp.pl/api/exchangerates/rates/a/{0}/{1}/{2}/?format=json' -f $code.ToLower(), $start.ToString('yyyy-MM-dd'), $wEnd.ToString('yyyy-MM-dd')
        $r = Invoke-Get $url
        if ($r.status -eq 200) {
          foreach ($m in [regex]::Matches($r.body, '"effectiveDate":"(\d{4}-\d{2}-\d{2})","mid":([0-9.]+)')) { $series[$m.Groups[1].Value] = $m.Groups[2].Value }
        } elseif ($r.status -eq 400 -and -not $last) { break }  # waluta spoza tabeli A
        $start = $wEnd.AddDays(1)
        Start-Sleep -Milliseconds 60
      }
    } catch { $errors += [ordered]@{ symbol = "FX:$code"; error = $_.Exception.Message } }
  }
  if ($series.Count) {
    Write-Series $path $series
    $first = $null; $lastNew = $null; foreach ($k in $series.Keys) { if (-not $first) { $first = $k }; $lastNew = $k }
    $fxInfo[$code] = @($first, $lastNew)
  }
}
Write-Host "Waluty: $($fxInfo.Keys -join ', ')"

# ---------------------------------------------------------------- manifest
$sortedMeta = [ordered]@{}
foreach ($k in ($meta.Keys | Sort-Object)) {
  if (Test-Path -LiteralPath (Join-Path (Join-Path $Out 'q') (SymFile $k))) { $sortedMeta[$k] = $meta[$k] }
}
Write-Utf8 $metaPath ($sortedMeta | ConvertTo-Json -Depth 4 -Compress)

# Kompaktowy manifest: s = [symbol, nazwa, rynek, typ, waluta, pierwsza data, ostatnia data, ostatnie zamknięcie, indeksy]
$list = foreach ($k in $sortedMeta.Keys) {
  $m = $sortedMeta[$k]
  ,@($k, $m.n, $m.m, $m.t, $m.c, $m.f, $m.l, $m.p, $m.i)
}
$manifest = [ordered]@{
  app = 'gpw-portfolio-data'; version = 1
  generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  source = 'Yahoo Finance (ceny zamknięcia, korekta o splity), NBP tabela A (kursy średnie)'
  fields = @('symbol','name','market','type','currency','first','last','lastClose','indexes')
  symbols = @($list)
  fx = $fxInfo
}
Write-Utf8 (Join-Path $Out 'index.json') ($manifest | ConvertTo-Json -Depth 5 -Compress)
Write-Utf8 (Join-Path $Out 'status.json') (([ordered]@{ finished = $manifest.generated; ok = $ok; failed = $errors.Count; errors = $errors }) | ConvertTo-Json -Depth 4)
Write-Host "Manifest: $($sortedMeta.Count) symboli"
