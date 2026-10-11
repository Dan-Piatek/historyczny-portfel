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

  Plik musi być zapisany w UTF-8 z BOM – inaczej PowerShell 5.1 czyta polskie znaki jako ANSI.
#>
param(
  [string]$Universe = 'config/universe.csv',   # lista walorów do aktualizacji
  [string]$Out = 'out',                         # katalog z danymi (kopia gałęzi "data")
  [int]$Limit = 0,                 # do testów: tylko pierwsze N symboli
  [string[]]$Only = @(),           # do testów: tylko wskazane symbole
  [int]$DelayMs = 250,             # przerwa między zapytaniami do Yahoo (ochrona przed blokadą)
  [switch]$SkipFx                  # do testów: bez pobierania kursów NBP
)

# ---------------------------------------------------------------- ustawienia globalne
$ErrorActionPreference = 'Stop'                 # każdy nieobsłużony błąd przerywa skrypt
$ProgressPreference = 'SilentlyContinue'        # pasek postępu Invoke-WebRequest bardzo spowalnia PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # PS 5.1 domyślnie nie włącza TLS 1.2
$Inv = [Globalization.CultureInfo]::InvariantCulture   # kropka dziesiętna niezależnie od ustawień systemu
$Utf8 = New-Object Text.UTF8Encoding $false            # UTF-8 bez BOM dla plików z danymi
# Yahoo odrzuca zapytania bez nagłówka przeglądarki
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
# Waluty pobierane zawsze, nawet jeśli żaden walor z listy ich nie używa (aplikacja może ich potrzebować)
$FxBase = @('EUR','USD','GBP','CHF','SEK','DKK','NOK','CZK','HUF','JPY')

New-Item -ItemType Directory -Force -Path (Join-Path $Out 'q'), (Join-Path $Out 'fx') | Out-Null

# ---------------------------------------------------------------- funkcje pomocnicze

# Ścieżka bezwzględna względem bieżącego katalogu PowerShella (metody .NET go nie znają).
function FullPath([string]$p) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
# Zapis tekstu w UTF-8 bez BOM.
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText((FullPath $path), $text, $Utf8) }
# Nazwa pliku dla symbolu: "^GSPC" → "_GSPC.csv" (znak ^ jest kłopotliwy w adresach URL).
# Nazwy zarezerwowane w Windows (CON, PRN, AUX, NUL, COM1-9, LPT1-9 – także z rozszerzeniem, np. "CON.DE.csv")
# dostają przedrostek "~": CON.DE → "~CON.DE.csv". Tę samą regułę stosuje aplikacja (Util.symFile).
function SymFile([string]$sym) {
  $f = $sym.ToUpperInvariant() -replace '\^', '_'
  if ($f -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { $f = '~' + $f }
  return $f + '.csv'
}

# Wczytuje istniejący plik "Date,Close" do słownika posortowanego po dacie (pusty, jeśli pliku nie ma).
function Read-Series([string]$path) {
  $map = New-Object 'System.Collections.Generic.SortedDictionary[string,string]'
  if (Test-Path -LiteralPath $path) {
    foreach ($line in [IO.File]::ReadAllLines((FullPath $path))) {
      if ($line -match '^(\d{4}-\d{2}-\d{2}),([0-9.eE+-]+)$') { $map[$Matches[1]] = $Matches[2] }
    }
  }
  return ,$map   # przecinek: PowerShell nie rozwija słownika na elementy przy zwracaniu
}
# Zapisuje słownik data → wartość jako CSV "Date,Close" (ten sam format czyta aplikacja).
function Write-Series([string]$path, $map) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("Date,Close`n")
  foreach ($k in $map.Keys) { [void]$sb.Append($k).Append(',').Append($map[$k]).Append("`n") }
  Write-Utf8 $path $sb.ToString()
}
# Zaokrągla cenę zależnie od rzędu wielkości (mniej cyfr = mniejsze pliki) i formatuje z kropką.
function Format-Num([double]$v) {
  $r = if ([math]::Abs($v) -ge 1000) { [math]::Round($v, 2) } elseif ([math]::Abs($v) -ge 1) { [math]::Round($v, 4) } else { [math]::Round($v, 6) }
  return $r.ToString('0.######', $Inv)
}

# GET z ponowieniami (4 próby, przerwy 5/15/45 s). 400 i 404 zwraca jako wynik, bez ponawiania:
# Yahoo zwraca 404 dla nieistniejącego symbolu, NBP 404 dla okresu bez notowań.
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

# Wyciąga wartość tekstową pola "key":"..." z JSON-a (bez pełnego parsowania).
function JsonStr([string]$body, [string]$key) {
  if ($body -match ('"' + $key + '":"((?:[^"\\]|\\.)*)"')) { return [regex]::Unescape($Matches[1]) }
  return $null
}

# Pobiera serię z Yahoo (chart API v8). Parsowanie wyrażeniami regularnymi zamiast ConvertFrom-Json
# (limit 2 MB w PS 5.1 przy długich historiach, np. ^GSPC od 1927 r.).
#   $full – pełna historia (period1=0) albo tylko ostatnie 3 miesiące
#   $n    – numer kolejny; naprzemiennie query1/query2 rozkłada ruch między serwery Yahoo
#   Yahoo dla części symboli (np. WIG.WA) zwraca 1 notowanie przy jednym zakresie, a pełną historię
#   przy innym – dlatego przy podejrzanie krótkim wyniku próbujemy kolejnych wariantów zapytania.
function Get-Yahoo([string]$sym, [bool]$full, [int]$n) {
  $variants = if ($full) { @(('period1=0&period2=' + [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 86400)), 'range=10y', 'range=max') }
              else { @('range=3mo', 'range=1y', 'range=10y') }
  $minRows = if ($full) { 5 } else { 10 }   # 3 miesiące to ok. 60 sesji; mniej niż 10 oznacza „okrojoną” odpowiedź
  $best = $null
  foreach ($q in $variants) {
    $y = Get-YahooOnce $sym $q $n
    if (-not $best -or $y.rows.Count -gt $best.rows.Count) { $best = $y }
    if ($y.rows.Count -ge $minRows) { break }
    Write-Host ("  ~ {0}: {1} → {2} notowań, próbuję innego zakresu" -f $sym, $q, $y.rows.Count)
  }
  return $best
}

# Jedno zapytanie do Yahoo z podanym zakresem ($q) – zwraca serię i metadane.
function Get-YahooOnce([string]$sym, [string]$q, [int]$n) {
  $host_ = if ($n % 2) { 'query2' } else { 'query1' }
  $url = "https://$host_.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($sym) + "?$q&interval=1d&includePrePost=false&events=div%2Csplits"
  $r = Invoke-Get $url
  if ($r.status -ne 200) { throw "HTTP $($r.status)" }
  $b = $r.body
  if ($b -notmatch '"result":\[\{') { throw ('brak danych: ' + (JsonStr $b 'description')) }
  # Znaczniki czasu Yahoo to początek sesji w UTC; przesunięcie strefy giełdy daje właściwą datę sesji
  $off = 0; if ($b -match '"gmtoffset":(-?\d+)') { $off = [int]$Matches[1] }
  if ($b -notmatch '"timestamp":\[([^\]]*)\]') { throw 'brak notowań' }
  $ts = $Matches[1].Split(',')
  # Tablica cen zamknięcia: pierwsze "close":[ po "quote":[ (kolejność pól w JSON nie jest gwarantowana)
  $qi = $b.IndexOf('"quote":[')
  $ci = if ($qi -ge 0) { $b.IndexOf('"close":[', $qi) } else { -1 }   # "adjclose" nie pasuje – klucz poprzedza cudzysłów
  if ($ci -lt 0) { throw 'brak cen zamknięcia' }
  $ci += 9   # długość tekstu '"close":['
  $cl = $b.Substring($ci, $b.IndexOf(']', $ci) - $ci).Split(',')
  $rows = New-Object 'System.Collections.Generic.SortedDictionary[string,string]'
  for ($i = 0; $i -lt [math]::Min($ts.Length, $cl.Length); $i++) {
    if ($cl[$i] -eq 'null' -or $cl[$i] -eq '') { continue }   # dni bez notowań w danych Yahoo
    $v = [double]::Parse($cl[$i], $Inv)
    if ($v -le 0) { continue }
    $d = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ts[$i] + $off).UtcDateTime.ToString('yyyy-MM-dd')
    $rows[$d] = Format-Num $v   # kilka wpisów z tego samego dnia → zostaje ostatni
  }
  return @{
    rows = $rows
    currency = JsonStr $b 'currency'          # np. PLN, USD, EUR, GBp (pensy)
    type = JsonStr $b 'instrumentType'        # EQUITY, INDEX, ETF
    exchange = JsonStr $b 'fullExchangeName'
    name = $(if (JsonStr $b 'longName') { JsonStr $b 'longName' } else { JsonStr $b 'shortName' })
  }
}

# ---------------------------------------------------------------- symbole
# meta.json z poprzedniego przebiegu – zachowuje metadane symboli, których dziś nie udało się pobrać
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
  $last = $null; foreach ($k in $series.Keys) { $last = $k }   # ostatnia posiadana data
  # Pełna historia dla nowych symboli i dla takich, których dane są starsze niż 80 dni
  # (3-miesięczne okno przyrostowe nie zamknęłoby wtedy luki)
  $full = (-not $last) -or ((New-TimeSpan -Start ([datetime]::ParseExact($last, 'yyyy-MM-dd', $Inv)) -End (Get-Date)).TotalDays -gt 80)
  try {
    $y = Get-Yahoo $sym $full $n
    if ($y.rows.Count -eq 0) { throw 'pusta seria' }
    # Niektóre indeksy (np. WIG20.WA) mają w Yahoo tylko bieżącą wartość – nie publikujemy ich
    if ($full -and $series.Count -eq 0 -and $y.rows.Count -lt 5) { throw 'Yahoo nie udostępnia historii notowań' }
    # Scalenie: nowe dane nadpisują nakładające się dni (korekty Yahoo), starsze zostają
    foreach ($k in $y.rows.Keys) { $series[$k] = $y.rows[$k] }
    Write-Series $path $series
    $first = $null; $lastNew = $null; foreach ($k in $series.Keys) { if (-not $first) { $first = $k }; $lastNew = $k }
    # Krótkie klucze ograniczają rozmiar manifestu: n=nazwa, m=rynek, t=typ, c=waluta, x=giełda,
    # i=indeksy, f/l=pierwsza/ostatnia data, p=ostatnie zamknięcie
    $meta[$sym] = [ordered]@{
      n = $(if ($u.name) { $u.name } else { $y.name }); m = $u.market; t = $(if ($u.type) { $u.type } else { $y.type })
      c = $y.currency; x = $y.exchange; i = $u.indexes; f = $first; l = $lastNew; p = $series[$lastNew]
    }
    $ok++
  } catch {
    # Błąd jednego symbolu nie przerywa przebiegu; poprzedni plik zostaje bez zmian
    $errors += [ordered]@{ symbol = $sym; error = $_.Exception.Message }
    Write-Host ("  ! {0}: {1}" -f $sym, $_.Exception.Message)
  }
  if ($n % 100 -eq 0) { Write-Host ("  {0}/{1} ({2:n0} s)" -f $n, $univ.Count, $sw.Elapsed.TotalSeconds) }
  Start-Sleep -Milliseconds $DelayMs
}
Write-Host "Symbole: OK $ok, błędy $($errors.Count), czas $([int]$sw.Elapsed.TotalSeconds) s"

# ---------------------------------------------------------------- waluty (NBP)
# Zbiór walut: stała lista + waluty wszystkich symboli (GBp/GBX = pensy → kurs GBP)
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
    # Nowa waluta: od 2002-01-02 (początek archiwum API NBP); istniejąca: od ostatniej daty − 7 dni (korekty)
    $start = if ($last) { ([datetime]::ParseExact($last, 'yyyy-MM-dd', $Inv)).AddDays(-7) } else { [datetime]'2002-01-02' }
    $end = [datetime]::ParseExact($Today, 'yyyy-MM-dd', $Inv)
    try {
      # API NBP przyjmuje zakres najwyżej 93 dni – pobieramy kolejne okna
      while ($start -le $end) {
        $wEnd = $start.AddDays(92); if ($wEnd -gt $end) { $wEnd = $end }
        $url = 'https://api.nbp.pl/api/exchangerates/rates/a/{0}/{1}/{2}/?format=json' -f $code.ToLower(), $start.ToString('yyyy-MM-dd'), $wEnd.ToString('yyyy-MM-dd')
        $r = Invoke-Get $url
        if ($r.status -eq 200) {
          foreach ($m in [regex]::Matches($r.body, '"effectiveDate":"(\d{4}-\d{2}-\d{2})","mid":([0-9.]+)')) { $series[$m.Groups[1].Value] = $m.Groups[2].Value }
        } elseif ($r.status -eq 400 -and -not $last) { break }  # waluta spoza tabeli A
        # 404 = brak notowań w oknie (np. same święta) – przechodzimy do następnego
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

# ---------------------------------------------------------------- inflacja (Eurostat HICP, Polska)
# Zharmonizowany wskaźnik cen konsumpcyjnych (HICP), indeks 2015=100, dane miesięczne od 1996 r.
# Zbiór prc_hicp_minr (ECOICOP ver.2, od 2026 r.; stary prc_hicp_midx kończy się na 12.2025).
# Oficjalny CPI GUS byłby lepszy, ale jego publiczny plik CSV nie jest aktualizowany na bieżąco.
# Wartość miesiąca (średnia z miesiąca) zapisujemy pod 15. dniem – aplikacja interpoluje liniowo między miesiącami.
$macroInfo = [ordered]@{}
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'macro') | Out-Null
$cpiPath = Join-Path (Join-Path $Out 'macro') 'CPI_PL.csv'
try {
  $r = Invoke-Get 'https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/prc_hicp_minr?format=JSON&geo=PL&coicop18=TOTAL&unit=I15&lang=EN'
  if ($r.status -ne 200) { throw "HTTP $($r.status)" }
  $j = $r.body | ConvertFrom-Json   # ok. 20 kB – mieści się w limicie ConvertFrom-Json
  # JSON-stat: "value" to słownik pozycja → wartość, "dimension.time.category.index" to miesiąc → pozycja
  $cpi = New-Object 'System.Collections.Generic.SortedDictionary[string,string]'
  foreach ($t in $j.dimension.time.category.index.PSObject.Properties) {
    $v = $j.value.PSObject.Properties[[string]$t.Value]
    if ($v -and $t.Name -match '^\d{4}-\d{2}$') { $cpi[$t.Name + '-15'] = ([double]$v.Value).ToString('0.###', $Inv) }
  }
  if ($cpi.Count -lt 100) { throw "za mało danych ($($cpi.Count) miesięcy)" }
  Write-Series $cpiPath $cpi
} catch { $errors += [ordered]@{ symbol = 'CPI_PL'; error = $_.Exception.Message }; Write-Host "  ! CPI_PL: $($_.Exception.Message)" }
# Przy błędzie zostaje plik z poprzedniego przebiegu
$cpiOld = Read-Series $cpiPath
if ($cpiOld.Count) {
  $first = $null; $lastNew = $null; foreach ($k in $cpiOld.Keys) { if (-not $first) { $first = $k }; $lastNew = $k }
  $macroInfo['CPI_PL'] = @($first, $lastNew)
  Write-Host "Inflacja PL (HICP): $first – $lastNew"
}

# ---------------------------------------------------------------- manifest
# Do manifestu trafiają tylko symbole, dla których istnieje plik z notowaniami
$sortedMeta = [ordered]@{}
foreach ($k in ($meta.Keys | Sort-Object)) {
  if (Test-Path -LiteralPath (Join-Path (Join-Path $Out 'q') (SymFile $k))) { $sortedMeta[$k] = $meta[$k] }
}
Write-Utf8 $metaPath ($sortedMeta | ConvertTo-Json -Depth 4 -Compress)

# Kompaktowy manifest: s = [symbol, nazwa, rynek, typ, waluta, pierwsza data, ostatnia data, ostatnie zamknięcie, indeksy]
# (tablice zamiast obiektów – przy ~2000 symboli manifest jest o połowę mniejszy)
$list = foreach ($k in $sortedMeta.Keys) {
  $m = $sortedMeta[$k]
  ,@($k, $m.n, $m.m, $m.t, $m.c, $m.f, $m.l, $m.p, $m.i)
}
$manifest = [ordered]@{
  app = 'gpw-portfolio-data'; version = 1
  generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')   # aplikacja używa tego jako wersji danych (cache-busting)
  source = 'Yahoo Finance (ceny zamknięcia, korekta o splity), NBP tabela A (kursy średnie)'
  fields = @('symbol','name','market','type','currency','first','last','lastClose','indexes')   # kolejność kolumn w "symbols"
  symbols = @($list)
  fx = $fxInfo   # KOD → [pierwsza data, ostatnia data]
  macro = $macroInfo   # dane makro (CPI_PL – inflacja HICP) → [pierwsza data, ostatnia data]
}
Write-Utf8 (Join-Path $Out 'index.json') ($manifest | ConvertTo-Json -Depth 5 -Compress)
# status.json – podsumowanie przebiegu do diagnostyki (lista błędów per symbol)
Write-Utf8 (Join-Path $Out 'status.json') (([ordered]@{ finished = $manifest.generated; ok = $ok; failed = $errors.Count; errors = $errors }) | ConvertTo-Json -Depth 4)
Write-Host "Manifest: $($sortedMeta.Count) symboli"
