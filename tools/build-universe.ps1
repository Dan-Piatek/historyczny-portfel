<#
.SYNOPSIS
  Buduje config\universe-full.csv - listę składników indeksów (symbole Yahoo Finance) oraz wiersze samych indeksów.

.DESCRIPTION
  Pobiera aktualne składy indeksów (Wikipedia + kilka stron oficjalnych/lustrzanych), mapuje tickery
  na symbole Yahoo, weryfikuje każdy symbol w Yahoo chart API i zapisuje CSV w UTF-8 (bez BOM):
    symbol,name,market,type,indexes   (type = EQUITY | INDEX | ETF)
  Jeśli źródło zawiedzie albo zwróci za mało wierszy (< 70% oczekiwanej liczby), wiersze danego
  indeksu są brane z istniejącego pliku wynikowego i wypisywane jest ostrzeżenie.
  Zgodny z Windows PowerShell 5.1 (bez Pythona/Node).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\build-universe.ps1
  powershell -ExecutionPolicy Bypass -File tools\build-universe.ps1 -SkipValidation
#>
[CmdletBinding()]
param(
    [string]$OutFile = '',        # domyślnie: <projekt>\config\universe-full.csv
    [switch]$SkipValidation,      # pomija weryfikację w Yahoo (szybki test parsowania źródeł)
    [int]$DelayMs = 200,          # przerwa między zapytaniami do Yahoo (na wątek)
    [int]$Threads = 4,            # liczba równoległych zapytań do Yahoo podczas walidacji
    [int]$WikiDelayMs = 2000,     # przerwa między zapytaniami do Wikipedii (limity API)
    [double]$MinRatio = 0.7,      # min. stosunek znalezionych/oczekiwanych, poniżej -> stare wiersze
    [int]$MinHistory = 250        # min. liczba niepustych dziennych zamknięć (okno 10 lat) dla INDEX/ETF
)

$ErrorActionPreference = 'Stop'
# Domyślna ścieżka wyniku liczona względem katalogu skryptu (tools\..\config)
if (-not $OutFile) { $OutFile = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'config\universe-full.csv' }
$ProgressPreference = 'SilentlyContinue'   # pasek postępu mocno spowalnia Invoke-WebRequest w PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36'

# ---------------------------------------------------------------- rynki
# Sufiks Yahoo -> kod rynku (kraj notowania) i odwrotnie
$SuffixToMarket = [ordered]@{
    T = 'JP'; WA = 'PL'; DE = 'DE'; PA = 'FR'; L = 'UK'; AS = 'NL'; BR = 'BE'; MC = 'ES'; MI = 'IT'
    SW = 'CH'; ST = 'SE'; CO = 'DK'; HE = 'FI'; OL = 'NO'; LS = 'PT'; VI = 'AT'; IR = 'IE'; PR = 'CZ'; BD = 'HU'
}
$MarketToSuffix = @{}
foreach ($k in $SuffixToMarket.Keys) { $MarketToSuffix[$SuffixToMarket[$k]] = $k }

# ---------------------------------------------------------------- wiersze indeksów (symbole Yahoo)
# Trafiają do pliku tylko te, które przejdą walidację (realna historia notowań w Yahoo).
$IndexRows = @(
    @('^GSPC', 'S&P 500', 'US'), @('^NDX', 'Nasdaq-100', 'US'), @('^DJI', 'Dow Jones Industrial Average', 'US'),
    @('^N225', 'Nikkei 225', 'JP'),
    @('WIG20.WA', 'WIG20', 'PL'), @('WIG.WA', 'WIG', 'PL'), @('MWIG40.WA', 'mWIG40', 'PL'), @('SWIG80.WA', 'sWIG80', 'PL'),
    @('^GDAXI', 'DAX', 'DE'), @('^MDAXI', 'MDAX', 'DE'), @('^STOXX50E', 'Euro Stoxx 50', 'DE'),
    @('^FCHI', 'CAC 40', 'FR'),
    @('^FTSE', 'FTSE 100', 'UK'), @('^FTMC', 'FTSE 250', 'UK'),
    @('^AEX', 'AEX', 'NL'), @('^BFX', 'BEL 20', 'BE'), @('^IBEX', 'IBEX 35', 'ES'), @('FTSEMIB.MI', 'FTSE MIB', 'IT'),
    @('^SSMI', 'SMI', 'CH'), @('^OMX', 'OMX Stockholm 30', 'SE'), @('^OMXC25', 'OMX Copenhagen 25', 'DK'),
    @('^OMXH25', 'OMX Helsinki 25', 'FI'), @('OBX.OL', 'OBX', 'NO'), @('PSI20.LS', 'PSI', 'PT'),
    @('^ATX', 'ATX', 'AT'), @('^ISEQ', 'ISEQ All Share', 'IE'), @('^PX', 'PX', 'CZ'), @('^BUX.BD', 'BUX', 'HU')
)
# ETF-y jako zamienniki indeksów bez użytecznej historii w Yahoo (type=ETF, puste indexes)
$EtfRows = @(
    @('ETFBW20TR.WA', 'Beta ETF WIG20TR', 'PL'), @('ETFBM40TR.WA', 'Beta ETF mWIG40TR', 'PL'), @('ETFBS80TR.WA', 'Beta ETF sWIG80TR', 'PL')
)

# ---------------------------------------------------------------- HTTP
# Pobiera URL jako tekst UTF-8. Ponawia przy błędach (429 -> dłuższe czekanie), 404 rzuca od razu.
function Get-Url([string]$Url, [int]$Retries = 4) {
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UA -TimeoutSec 60 -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' }
            # dekodujemy bajty jawnie jako UTF-8 (PS 5.1 bywa, że zgaduje kodowanie źle)
            return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            # Część serwisów (Cloudflare itp., np. nikkei.co.jp, slickcharts) odrzuca "odcisk" TLS z .NET
            # zwracając 403 -> jednorazowa próba przez systemowy curl.exe
            if ($code -eq 403 -and (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
                $tmp = [IO.Path]::GetTempFileName()
                try {
                    $http = & curl.exe -s -L -A $UA -H 'Accept-Language: en-US,en;q=0.9' --max-time 60 -o $tmp -w '%{http_code}' $Url
                    if ($http -eq '200') { return [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) }
                } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
                throw
            }
            if ($code -eq 404 -or $i -eq $Retries) { throw }
            $wait = if ($code -eq 429) { 5 * $i } else { 2 * $i }
            Write-Verbose "HTTP $code for $Url - retry in $wait s"
            Start-Sleep -Seconds $wait
        }
    }
}

$script:LastWiki = [DateTime]::MinValue
# Zwraca wyrenderowany HTML strony Wikipedii (MediaWiki API action=parse).
# Pilnuje odstępu $WikiDelayMs między zapytaniami - API szybko zwraca "too many requests".
function Get-WikiHtml([string]$Lang, [string]$Page) {
    $elapsed = ([DateTime]::Now - $script:LastWiki).TotalMilliseconds
    if ($elapsed -lt $WikiDelayMs) { Start-Sleep -Milliseconds ([int]($WikiDelayMs - $elapsed)) }
    $u = "https://$Lang.wikipedia.org/w/api.php?action=parse&page=$([Uri]::EscapeDataString($Page))&prop=text&format=json&formatversion=2&redirects=1"
    try { $txt = Get-Url $u } finally { $script:LastWiki = [DateTime]::Now }
    $j = $txt | ConvertFrom-Json
    if ($j.error) { throw "Wikipedia ($Lang) '$Page': $($j.error.info)" }
    return [string]$j.parse.text
}

# ---------------------------------------------------------------- parsowanie tabel HTML (regex)
# Zamienia HTML komórki na czysty tekst: usuwa przypisy <sup>, style, ukryte spany, tagi; dekoduje encje.
function Convert-CellText([string]$h) {
    $h = [regex]::Replace($h, '(?is)<sup[^>]*>.*?</sup>', '')
    $h = [regex]::Replace($h, '(?is)<style[^>]*>.*?</style>', '')
    $h = [regex]::Replace($h, '(?is)<span[^>]*display:\s*none[^>]*>.*?</span>', '')
    $h = [regex]::Replace($h, '(?is)<br\s*/?>', ' ')
    $h = [regex]::Replace($h, '(?s)<[^>]+>', '')
    $h = [Net.WebUtility]::HtmlDecode($h)
    $h = $h -replace '[\u00A0\u2009\u200B\u200E\u200F]', ' '   # twarde spacje i znaki sterujące kierunkiem
    return ($h -replace '\s+', ' ').Trim()
}

# Wyciąga wszystkie tabele z HTML. Zwraca listę obiektów { Header = string[]; Rows = string[][] }.
# Obsługuje colspan/rowspan; wiersz nagłówka = pierwszy wiersz złożony z samych <th>.
# Uwaga: proste regexy - tabele zagnieżdżone nie są obsługiwane (w tabelach składów nie występują).
function Get-HtmlTables([string]$Html) {
    $tables = New-Object System.Collections.ArrayList
    foreach ($tm in [regex]::Matches($Html, '(?is)<table[^>]*>(.*?)</table>')) {
        $hdr = @(); $data = New-Object System.Collections.ArrayList
        $pending = @{}   # przeniesienie rowspan: kolumna -> @(tekst, ile wierszy jeszcze)
        foreach ($rm in [regex]::Matches($tm.Groups[1].Value, '(?is)<tr[^>]*>(.*?)</tr>')) {
            $cells = New-Object System.Collections.ArrayList
            $isHead = $true; $col = 0; $ci = 0
            $cms = [regex]::Matches($rm.Groups[1].Value, '(?is)<(t[hd])([^>]*)>(.*?)(?=<t[hd][\s>]|$)')
            while ($true) {
                # najpierw wstaw komórki "spływające" z wierszy powyżej (rowspan)
                while ($pending.ContainsKey($col)) {
                    $p = $pending[$col]; [void]$cells.Add($p[0]); $p[1]--
                    if ($p[1] -le 0) { $pending.Remove($col) }
                    $col++
                }
                if ($ci -ge $cms.Count) { break }
                $cm = $cms[$ci]; $ci++
                if ($cm.Groups[1].Value -eq 'td') { $isHead = $false }
                $txt = Convert-CellText ($cm.Groups[3].Value -replace '(?is)</t[hd]>\s*$', '')
                $attr = $cm.Groups[2].Value
                $cs = 1; if ($attr -match 'colspan="?(\d+)') { $cs = [int]$matches[1] }
                $rs = 1; if ($attr -match 'rowspan="?(\d+)') { $rs = [int]$matches[1] }
                for ($k = 0; $k -lt $cs; $k++) {
                    [void]$cells.Add($txt)
                    if ($rs -gt 1) { $pending[$col] = @($txt, ($rs - 1)) }
                    $col++
                }
            }
            if ($isHead -and $data.Count -eq 0) { $hdr = @($cells) }
            elseif (-not $isHead) { [void]$data.Add(@($cells)) }
        }
        [void]$tables.Add([pscustomobject]@{ Header = $hdr; Rows = @($data) })
    }
    return , $tables   # przecinek: zwróć listę jako jeden obiekt (bez rozwijania)
}

# Szuka na stronie Wikipedii pierwszej tabeli z kolumną tickera i nazwy oraz >= MinRows wierszy.
# Zwraca obiekty { Ticker; Name; Symbol = $null }. Prefiks giełdy typu "OSE: AKRBP" jest obcinany.
function Get-WikiConstituents {
    param([string]$Lang, [string]$Page, [int]$MinRows,
        [string]$TickerHdr = '^(Ticker|Ticker symbol|Symbol|MNEM code|Kod|Ticker code)$',
        [string]$NameHdr = '^(Company|Name|Security|Sp\u00f3\u0142ka|Constituent)$')
    $tables = Get-HtmlTables (Get-WikiHtml $Lang $Page)
    foreach ($t in $tables) {
        if ($t.Rows.Count -lt $MinRows) { continue }
        $ti = -1; $ni = -1
        for ($i = 0; $i -lt $t.Header.Count; $i++) {
            if ($ti -lt 0 -and $t.Header[$i] -match $TickerHdr) { $ti = $i }
            elseif ($ni -lt 0 -and $t.Header[$i] -match $NameHdr) { $ni = $i }
        }
        if ($ti -lt 0 -or $ni -lt 0) { continue }
        $out = foreach ($r in $t.Rows) {
            if ($r.Count -le [Math]::Max($ti, $ni)) { continue }
            $tk = ($r[$ti] -split ':')[-1].Trim().TrimEnd('*').Trim()   # "Euronext Brussels: ABI" -> "ABI"
            if ($tk) { [pscustomobject]@{ Ticker = $tk; Name = $r[$ni]; Symbol = $null } }
        }
        return @($out)
    }
    throw "No constituent table found on $Lang wiki '$Page'"
}

# ---------------------------------------------------------------- źródła spoza Wikipedii
# S&P 500 z lustra CSV na GitHubie (kolumny Symbol, Security).
function Get-SP500Csv {
    $csv = Get-Url 'https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv' | ConvertFrom-Csv
    @($csv | Where-Object { $_.Symbol } | ForEach-Object { [pscustomobject]@{ Ticker = $_.Symbol.Trim(); Name = $_.Security; Symbol = $null } })
}

# slickcharts.com (np. 'dowjones', 'nasdaq100'): w pierwszej tabeli każdy wiersz ma dwa linki
# /symbol/XXX - jeden z nazwą spółki, drugi z tickerem.
function Get-SlickCharts([string]$Slug) {
    $html = Get-Url "https://www.slickcharts.com/$Slug"
    $tbl = [regex]::Match($html, '(?is)<table.*?</table>').Value   # tylko główna tabela (bez SPY/QQQ z paska bocznego)
    $names = @{}; $order = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($tbl, '<a href="/symbol/([^"]+)">([^<]+)</a>')) {
        $s = $m.Groups[1].Value; $txt = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim()
        if (-not $names.ContainsKey($s)) { $names[$s] = $null; [void]$order.Add($s) }
        if ($txt -ne $s) { $names[$s] = $txt }
    }
    @($order | ForEach-Object { [pscustomobject]@{ Ticker = $_; Name = $names[$_]; Symbol = $null } })
}

# Nikkei 225 z oficjalnej strony nikkei.co.jp: pary <td>kod</td><td>NAZWA</td>.
# Kody są 4-znakowe, mogą zawierać litery (np. 285A). Nazwy WIELKIMI literami -> TitleCase.
function Get-Nikkei225 {
    $html = Get-Url 'https://indexes.nikkei.co.jp/en/nkave/index/component?idx=nk225'
    @([regex]::Matches($html, '(?is)<td>\s*([0-9][0-9A-Z]{3})\s*</td>\s*<td>([^<]+)</td>') | ForEach-Object {
            [pscustomobject]@{ Ticker = $_.Groups[1].Value; Name = [Net.WebUtility]::HtmlDecode($_.Groups[2].Value).Trim(); Symbol = $null; TitleCase = $true } })
}

# Indeksy GPW (WIG20, mWIG40, sWIG80) z biznesradar.pl - polska Wikipedia nie ma tabel składów.
# Linki mają postać <a href="/notowania/..." title="NAZWA">TICKER (SKRÓT)</a>.
function Get-BiznesRadar([string]$Index) {
    $html = Get-Url "https://www.biznesradar.pl/gielda/indeks:$Index"
    $seen = @{}
    @([regex]::Matches($html, '<a href="/notowania/[^"]+" title="([^"]+)">([A-Z0-9]{2,6})(?: \([^)]*\))?</a>') | ForEach-Object {
            $t = $_.Groups[2].Value
            if (-not $seen.ContainsKey($t)) {
                $seen[$t] = 1
                [pscustomobject]@{ Ticker = $t; Name = ([Net.WebUtility]::HtmlDecode($_.Groups[1].Value) -replace '_', ' '); Symbol = $null; TitleCase = $true }
            } })
}

# Wyszukiwarka Yahoo: ISIN albo nazwa -> pierwszy symbol EQUITY z żądanym sufiksem (np. 'VI').
# Pusty $Suffix = symbol bez kropki (USA). $NameCheck: pierwsze słowo nazwy musi wystąpić w nazwie
# z Yahoo (ochrona przed przypisaniem innej spółki). Zwraca symbol albo $null.
function Find-YahooSymbol([string]$Query, [string]$Suffix, [string]$NameCheck) {
    $u = "https://query2.finance.yahoo.com/v1/finance/search?q=$([Uri]::EscapeDataString($Query))&quotesCount=15&newsCount=0"
    try { $j = Get-Url $u | ConvertFrom-Json } catch { return $null }
    Start-Sleep -Milliseconds $DelayMs
    foreach ($q in @($j.quotes)) {
        if (-not $q.symbol) { continue }
        $okSuffix = if ($Suffix) { $q.symbol.EndsWith(".$Suffix") } else { $q.symbol -notmatch '\.' }
        if (-not $okSuffix) { continue }
        if ($q.quoteType -and $q.quoteType -ne 'EQUITY') { continue }
        if ($NameCheck) {
            $w = (($NameCheck -replace '[^\p{L}\p{N} ]', ' ').Trim() -split '\s+')[0]
            $qn = "$($q.longname) $($q.shortname)"
            if ($w.Length -ge 2 -and $qn -notmatch [regex]::Escape($w)) { continue }
        }
        return $q.symbol
    }
    return $null
}

# ATX ze strony Wiener Börse: strona podaje tylko nazwy i ISIN-y, więc symbol .VI ustalamy
# przez wyszukiwarkę Yahoo (najpierw po ISIN, potem po nazwie).
function Get-WienerBoerse {
    $html = Get-Url 'https://www.wienerborse.at/en/indices/index-values/prices-constituents/?ISIN=AT0000999982&ID_NOTATION=92866'
    @([regex]::Matches($html, 'data-action="chart" data-module="[^"]*" data-value="[^"]*" data-pjax="0" data-name="([^"]+)" data-isin="([A-Z0-9]{12})"') | ForEach-Object {
            $name = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
            $sym = Find-YahooSymbol $_.Groups[2].Value 'VI'
            if (-not $sym) { $sym = Find-YahooSymbol $name 'VI' $name }
            [pscustomobject]@{ Ticker = $_.Groups[2].Value; Name = $name; Symbol = $sym; TitleCase = $true } })
}

# PX z giełdy praskiej (pse.cz): nazwy + ISIN-y, symbol .PR ustalany przez wyszukiwarkę Yahoo.
function Get-PsePX {
    $html = Get-Url 'https://www.pse.cz/en/indices/index-values/detail/XC0009698371?tab=detail-composition'
    @([regex]::Matches($html, '(?s)data-title="([^"]+)">\s*<a href="/en/detail/([A-Z0-9]{12})"') | ForEach-Object {
            $name = [Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
            $sym = Find-YahooSymbol $_.Groups[2].Value 'PR'
            if (-not $sym) { $sym = Find-YahooSymbol $name 'PR' $name }
            [pscustomobject]@{ Ticker = $_.Groups[2].Value; Name = $name; Symbol = $sym; TitleCase = $true } })
}

# ---------------------------------------------------------------- definicje indeksów
# Źródła są próbowane po kolei, aż któreś zwróci >= MinRatio * Expected wierszy.
# Market = rynek docelowy (sufiks Yahoo); $null = zostaw sufiks z tickera (Euro Stoxx 50 - rynek macierzysty).
# Trzeci argument Get-WikiConstituents = minimalna liczba wierszy tabeli (odsiewa tabele historyczne).
$Indexes = @(
    # USA: S&P 500 z CSV (zapas: Wikipedia), Nasdaq-100 z Wikipedii, DJIA ze slickcharts
    @{ Code = 'SP500'; Market = 'US'; Expected = 503; Sources = @({ Get-SP500Csv }, { Get-WikiConstituents en 'List of S&P 500 companies' 300 }) }
    @{ Code = 'NDX100'; Market = 'US'; Expected = 101; Sources = @({ Get-WikiConstituents en 'List of NASDAQ-100 companies' 60 }, { Get-WikiConstituents en 'Nasdaq-100' 60 }, { Get-SlickCharts 'nasdaq100' }) }
    @{ Code = 'DJIA'; Market = 'US'; Expected = 30; Sources = @({ Get-SlickCharts 'dowjones' }, { Get-WikiConstituents en 'Dow Jones Industrial Average' 25 }) }
    # Japonia: oficjalna strona Nikkei
    @{ Code = 'N225'; Market = 'JP'; Expected = 225; Sources = @({ Get-Nikkei225 }) }
    # Polska: biznesradar.pl
    @{ Code = 'WIG20'; Market = 'PL'; Expected = 20; Sources = @({ Get-BiznesRadar 'WIG20' }) }
    @{ Code = 'MWIG40'; Market = 'PL'; Expected = 40; Sources = @({ Get-BiznesRadar 'mWIG40' }) }
    @{ Code = 'SWIG80'; Market = 'PL'; Expected = 80; Sources = @({ Get-BiznesRadar 'sWIG80' }) }
    # Europa: angielska Wikipedia (tabele z tickerami)
    @{ Code = 'DAX'; Market = 'DE'; Expected = 40; Sources = @({ Get-WikiConstituents en 'DAX' 30 }) }
    @{ Code = 'MDAX'; Market = 'DE'; Expected = 50; Sources = @({ Get-WikiConstituents en 'MDAX' 35 }) }
    @{ Code = 'CAC40'; Market = 'FR'; Expected = 40; Sources = @({ Get-WikiConstituents en 'CAC 40' 30 }) }
    @{ Code = 'FTSE100'; Market = 'UK'; Expected = 100; Sources = @({ Get-WikiConstituents en 'FTSE 100 Index' 70 }) }
    @{ Code = 'FTSE250'; Market = 'UK'; Expected = 250; Sources = @({ Get-WikiConstituents en 'FTSE 250 Index' 175 }) }
    @{ Code = 'AEX'; Market = 'NL'; Expected = 25; Sources = @({ Get-WikiConstituents en 'AEX index' 18 }) }
    @{ Code = 'BEL20'; Market = 'BE'; Expected = 20; Sources = @({ Get-WikiConstituents en 'BEL 20' 14 }) }
    @{ Code = 'IBEX35'; Market = 'ES'; Expected = 35; Sources = @({ Get-WikiConstituents en 'IBEX 35' 25 }) }
    @{ Code = 'FTSEMIB'; Market = 'IT'; Expected = 40; Sources = @({ Get-WikiConstituents en 'FTSE MIB' 28 }) }
    @{ Code = 'SMI'; Market = 'CH'; Expected = 20; Sources = @({ Get-WikiConstituents en 'Swiss Market Index' 14 }) }
    @{ Code = 'OMXS30'; Market = 'SE'; Expected = 30; Sources = @({ Get-WikiConstituents en 'OMX Stockholm 30' 21 }) }
    @{ Code = 'OMXC25'; Market = 'DK'; Expected = 25; Sources = @({ Get-WikiConstituents en 'OMX Copenhagen 25' 18 }) }
    @{ Code = 'OMXH25'; Market = 'FI'; Expected = 25; Sources = @({ Get-WikiConstituents en 'OMX Helsinki 25' 18 }) }
    @{ Code = 'OBX'; Market = 'NO'; Expected = 25; Sources = @({ Get-WikiConstituents en 'OBX Index' 18 }) }
    @{ Code = 'PSI'; Market = 'PT'; Expected = 15; Sources = @({ Get-WikiConstituents en 'PSI-20' 10 }) }
    # Austria i Czechy: strony giełd (ISIN -> symbol przez wyszukiwarkę Yahoo)
    @{ Code = 'ATX'; Market = 'AT'; Expected = 20; Sources = @({ Get-WienerBoerse }) }
    @{ Code = 'ISEQ20'; Market = 'IE'; Expected = 20; Sources = @({ Get-WikiConstituents en 'ISEQ 20' 14 }) }
    @{ Code = 'PX'; Market = 'CZ'; Expected = 10; Sources = @({ Get-PsePX }) }
    # Węgry: angielska Wikipedia, zapas: węgierska
    @{ Code = 'BUX'; Market = 'HU'; Expected = 14; Sources = @({ Get-WikiConstituents en 'BUX' 10 }, { Get-WikiConstituents hu 'BUX' 10 -NameHdr '^(V\u00e1llalat|Company)$' }) }
    # Euro Stoxx 50: tickery z sufiksem rynku macierzystego (ADS.DE, AIR.PA...)
    @{ Code = 'STOXX50'; Market = $null; Expected = 50; Sources = @({ Get-WikiConstituents en 'Euro Stoxx 50' 35 }) }
)

# ---------------------------------------------------------------- ticker -> symbol Yahoo
# Zwraca @(symbolYahoo, rynek) albo $null. Reguły:
#  - ticker ze znanym sufiksem Yahoo (np. AIR.PA): przy Market=$null zostaje bez zmian (rynek z sufiksu),
#    w przeciwnym razie sufiks jest zamieniany na sufiks rynku indeksu (DAX: AIR.PA -> AIR.DE)
#  - US: kropka/spacja -> myślnik (BRK.B -> BRK-B)
#  - JP: kod + '.T'
#  - UK: końcowa kropka usuwana (RR. -> RR.L), kropka w środku -> myślnik (BT.A -> BT-A.L)
#  - pozostałe: spacja/kropka -> myślnik + sufiks rynku (MAERSK B -> MAERSK-B.CO)
function ConvertTo-YahooSymbol([string]$Ticker, [string]$Market) {
    $t = ($Ticker -replace '\s+', ' ').Trim()
    if ($t -match '^(.+)\.([A-Z]{1,2})$' -and $SuffixToMarket.Contains($matches[2])) {
        if (-not $Market) { return @($t, $SuffixToMarket[$matches[2]]) }   # notowanie macierzyste (Euro Stoxx 50)
        $t = $matches[1]
    }
    if (-not $Market) { return $null }
    switch ($Market) {
        'US' { return @(($t -replace '[\./ ]', '-').ToUpper(), 'US') }
        'JP' { return @("$t.T", 'JP') }
        'UK' { return @((($t.TrimEnd('.') -replace '[\. ]', '-') + '.L'), 'UK') }
        default { return @((($t -replace '[\. ]', '-') + '.' + $MarketToSuffix[$Market]), $Market) }
    }
}

# Porządkuje nazwę: usuwa znaczniki interwiki typu "[fi]", zbędne spacje.
# $TitleCase = źródło podaje nazwy WIELKIMI literami -> zamiana na "Title Case".
function Format-Name([string]$n, [bool]$TitleCase) {
    $n = (($n -replace '\s*\[[a-z]{2,3}\]', '') -replace '\s+', ' ').Trim()
    if (-not $TitleCase -or $n -cmatch '\p{Ll}') { return $n }   # ma już małe litery -> zostaw
    return (Get-Culture).TextInfo.ToTitleCase($n.ToLower())
}

# ---------------------------------------------------------------- walidacja w Yahoo
$script:MetaCache = @{}   # klucz "symbol|interwał" -> meta (albo $null)
# Uwaga: Yahoo dla range=1y/2y potrafi zwrócić 1 punkt, a dla range=10y pełną historię, dlatego
# używamy 10y: interwał dzienny dla INDEX/ETF (test historii), tygodniowy dla akcji (mniejsza odpowiedź).
# Pobiera meta wykresu i dokleja PointCount = liczba NIEPUSTYCH zamknięć (indicators.quote[0].close).
# Liczymy zamknięcia, a nie znaczniki czasu: np. WIG.WA ma ~1800 timestampów, ale tylko 1 niepuste
# zamknięcie. Zwykły scriptblock (nie funkcja), żeby dało się go uruchomić także w runspace.
$FetchChart = {
    param([string]$Symbol, [string]$Interval, [string]$UA, [int]$DelayMs)
    $ProgressPreference = 'SilentlyContinue'
    $u = "https://query1.finance.yahoo.com/v8/finance/chart/$([Uri]::EscapeDataString($Symbol))?range=10y&interval=$Interval"
    $meta = $null
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Milliseconds $DelayMs
        try {
            $r = Invoke-WebRequest -Uri $u -UseBasicParsing -UserAgent $UA -TimeoutSec 30
            $j = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
            if ($j.chart.result) {
                $res = $j.chart.result[0]
                $meta = $res.meta
                # indicators.quote[0].close (nie indicators.adjclose) - liczymy tylko wartości różne od null
                $pc = 0
                if ($res.indicators -and $res.indicators.quote) {
                    $pc = @($res.indicators.quote[0].close | Where-Object { $null -ne $_ }).Count
                }
                $meta | Add-Member -NotePropertyName PointCount -NotePropertyValue $pc -Force
            }
            break
        } catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 404 -or $code -eq 400) { break }   # nieznany symbol - nie ponawiamy
            Start-Sleep -Seconds $(if ($code -eq 429) { 10 * $i } else { 2 * $i })   # 429 = limit, czekamy dłużej
        }
    }
    return $meta
}

# Meta symbolu z pamięci podręcznej albo z Yahoo (sekwencyjnie). Zwraca obiekt meta lub $null.
function Get-YahooMeta([string]$Symbol, [string]$Interval = '1wk') {
    $key = "$Symbol|$Interval"
    if ($script:MetaCache.ContainsKey($key)) { return $script:MetaCache[$key] }
    $meta = & $FetchChart $Symbol $Interval $UA $DelayMs
    $script:MetaCache[$key] = $meta
    return $meta
}

# Równoległe pobranie meta dla wielu symboli do MetaCache (RunspacePool, $Threads wątków).
# Yahoo odpowiada ~1-2 s na zapytanie, więc wątki skracają walidację kilkukrotnie.
function Start-YahooPrefetch([string[]]$Symbols, [string]$Interval) {
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, $Threads)); $pool.Open()
    $jobs = foreach ($s in $Symbols) {
        $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript($FetchChart).AddArgument($s).AddArgument($Interval).AddArgument($UA).AddArgument($DelayMs)
        [pscustomobject]@{ Sym = $s; PS = $ps; H = $ps.BeginInvoke() }
    }
    $done = 0
    foreach ($j in $jobs) {
        $res = $j.PS.EndInvoke($j.H)
        $script:MetaCache["$($j.Sym)|$Interval"] = if ($res.Count) { $res[0] } else { $null }
        $j.PS.Dispose(); $done++
        if ($done % 200 -eq 0) { Write-Host "  fetched $done / $($Symbols.Count) ..." }
    }
    $pool.Close(); $pool.Dispose()
}

$MinEpoch = [int64](([DateTime]::UtcNow.AddDays(-30)) - [DateTime]'1970-01-01').TotalSeconds
# Sprawdza symbol w Yahoo. $Type = EQUITY | INDEX | ETF. Zwraca meta, gdy poprawny, inaczej $null.
# Reguły: notowanie w ostatnich 30 dniach; INDEX/ETF >= $MinHistory niepustych dziennych zamknięć;
# akcje >= 4 niepuste tygodniowe zamknięcia (nowe debiuty zostają); zgodny instrumentType.
function Test-YahooSymbol([string]$Symbol, [string]$Type) {
    $iv = if ($Type -eq 'EQUITY') { '1wk' } else { '1d' }
    $m = Get-YahooMeta $Symbol $iv
    if (-not $m) { return $null }
    if ([int64]$m.regularMarketTime -lt $MinEpoch) { return $null }          # brak świeżych notowań
    if ($Type -in @('INDEX', 'ETF') -and $m.PointCount -lt $MinHistory) { return $null }
    if ($Type -eq 'EQUITY' -and $m.PointCount -lt 4) { return $null }
    if ($Type -eq 'INDEX' -and $m.instrumentType -ne 'INDEX') { return $null }
    if ($Type -eq 'ETF' -and $m.instrumentType -notin @('ETF', 'EQUITY', 'MUTUALFUND')) { return $null }
    if ($Type -eq 'EQUITY' -and $m.instrumentType -in @('INDEX', 'CURRENCY', 'FUTURE', 'CRYPTOCURRENCY')) { return $null }
    return $m
}

# Oczywiste warianty niedziałającego symbolu (kropka<->myślnik, bez myślnika, bez klasy akcji itp.).
function Get-SymbolVariants([string]$Symbol) {
    $base = $Symbol; $suf = ''
    if ($Symbol -match '^(.+)(\.[A-Z]{1,2})$') { $base = $matches[1]; $suf = $matches[2] }
    $v = @(
        ($base -replace '\.', '-'), ($base -replace '-', '.'), ($base -replace '-', ''),
        ($base -replace '-', '_'), ($base -replace '-[A-Z]$', ''), ($base -replace '-([A-Z])$', '$1')
    ) | ForEach-Object { "$_$suf" }
    @($v | Where-Object { $_ -ne $Symbol } | Select-Object -Unique)
}

# ---------------------------------------------------------------- istniejący plik (źródło zapasowe)
$existing = @()
if (Test-Path $OutFile) {
    try { $existing = @(Import-Csv -Path $OutFile -Encoding UTF8) } catch { Write-Warning "Cannot read existing $OutFile : $_" }
}
# Wiersze EQUITY z istniejącego pliku należące do indeksu $Code.
function Get-ExistingRows([string]$Code) {
    @($existing | Where-Object { $_.type -eq 'EQUITY' -and (" $($_.indexes) " -like "* $Code *") })
}

# ---------------------------------------------------------------- zbieranie składów
# UWAGA: słowniki czytamy przez get_Keys()/get_Values()/get_Count(), bo ticker np. "KEYS"
# przesłoniłby właściwość .Keys (PowerShell preferuje klucz słownika nad właściwość).
$members = [ordered]@{}   # symbol -> wiersz
$stats = [ordered]@{}     # kod indeksu -> statystyki do podsumowania
$fallbackCodes = New-Object System.Collections.ArrayList

# Dodaje symbol do zbioru albo dopisuje kod indeksu do istniejącego wiersza (deduplikacja po symbolu).
function Add-UniverseMember([string]$Symbol, [string]$Name, [string]$Market, [string]$Code) {
    if (-not $members.Contains($Symbol)) {
        # ArrayList przez ::new() - (New-Object ...) z pustą listą zostałby "rozwinięty" do $null
        $members[$Symbol] = [pscustomobject]@{ Symbol = $Symbol; Name = $Name; Market = $Market; Type = 'EQUITY'; Indexes = [System.Collections.ArrayList]::new() }
    }
    $row = $members[$Symbol]
    if (-not $row.Name -and $Name) { $row.Name = $Name }
    if (-not $row.Indexes.Contains($Code)) { [void]$row.Indexes.Add($Code) }
}

# Awaria źródła: bierze wiersze indeksu z istniejącego pliku zamiast je gubić. Zwraca ich liczbę.
function Use-Existing([string]$Code, [string]$Why) {
    $old = Get-ExistingRows $Code
    Write-Warning "$Code : $Why - keeping $($old.Count) rows from existing output file"
    foreach ($o in $old) { Add-UniverseMember $o.symbol $o.name $o.market $Code }
    [void]$fallbackCodes.Add($Code)
    return $old.Count
}

foreach ($ix in $Indexes) {
    $code = $ix.Code; $rows = @(); $err = $null
    # kolejne źródła, aż liczba wierszy będzie wiarygodna (>= MinRatio * Expected)
    foreach ($src in $ix.Sources) {
        try {
            $rows = @(& $src)
            if ($rows.Count -ge $MinRatio * $ix.Expected) { $err = $null; break }
            $err = "only $($rows.Count) rows (expected ~$($ix.Expected))"
        } catch { $err = "source error: $($_.Exception.Message)" }
        Write-Verbose "$code source failed: $err"
    }
    if ($err) {
        # żadne źródło nie dało rady -> stare wiersze z pliku + ostrzeżenie
        $n = Use-Existing $code $err
        $stats[$code] = [pscustomobject]@{ Found = $n; Validated = 0; Note = "fallback ($err)" }
        continue
    }
    $added = 0
    foreach ($r in $rows) {
        if ($r.Symbol) {
            # źródło podało już symbol Yahoo (ATX/PX przez wyszukiwarkę) - rynek z sufiksu
            $sfx = ($r.Symbol -split '\.')[-1]
            $mapped = @($r.Symbol, $SuffixToMarket[$sfx])
        } elseif ($r.Ticker -match '^[A-Z]{2}[A-Z0-9]{9}\d$' -and $ix.Market -in @('AT', 'CZ')) {
            # sam ISIN bez znalezionego symbolu - nie da się zmapować
            Write-Warning "$code : no Yahoo symbol for $($r.Name) ($($r.Ticker))"; continue
        } else {
            $mapped = ConvertTo-YahooSymbol $r.Ticker $ix.Market
        }
        if (-not $mapped -or -not $mapped[1]) { Write-Warning "$code : cannot map ticker '$($r.Ticker)'"; continue }
        Add-UniverseMember $mapped[0] (Format-Name $r.Name ([bool]$r.TitleCase)) $mapped[1] $code
        $added++
    }
    $stats[$code] = [pscustomobject]@{ Found = $added; Validated = $added; Note = '' }
    Write-Host ("{0,-8} {1,4} constituents" -f $code, $added)
}

# ---------------------------------------------------------------- walidacja
$dropped = New-Object System.Collections.ArrayList
$renamed = New-Object System.Collections.ArrayList
$final = [ordered]@{}
$total = $members.get_Count(); $n = 0
# najpierw równoległe pobranie wszystkich symboli, potem sekwencyjna pętla korzysta z cache
if (-not $SkipValidation) { Write-Host "Validating $total symbols on Yahoo ($Threads threads)..."; Start-YahooPrefetch @($members.get_Keys()) '1wk' }
foreach ($sym in @($members.get_Keys())) {
    $row = $members[$sym]; $n++
    if ($SkipValidation) { $final[$sym] = $row; continue }
    if ($n % 100 -eq 0) { Write-Host "  validated $n / $total ..." }
    $newSym = $null; $m = Test-YahooSymbol $sym 'EQUITY'
    if ($m) { $newSym = $sym }
    else {
        # 1) oczywiste warianty zapisu symbolu
        foreach ($alt in Get-SymbolVariants $sym) {
            $m = Test-YahooSymbol $alt 'EQUITY'
            if ($m) { $newSym = $alt; break }
        }
        # 2) wyszukiwarka Yahoo po nazwie (ten sam sufiks rynku)
        if (-not $newSym -and $row.Name) {
            $suf = if ($sym -match '\.([A-Z]{1,2})$') { $matches[1] } else { '' }
            $cand = Find-YahooSymbol $row.Name $suf $row.Name
            if ($cand) { $m = Test-YahooSymbol $cand 'EQUITY'; if ($m) { $newSym = $cand } }
        }
        if ($newSym) { [void]$renamed.Add("$sym -> $newSym") }
    }
    if (-not $newSym) { [void]$dropped.Add("$sym ($($row.Indexes -join ' '))"); continue }
    # brak nazwy w źródle -> longName/shortName z Yahoo
    if (-not $row.Name) { $row.Name = if ($m.longName) { $m.longName } else { $m.shortName } }
    if ($final.Contains($newSym)) {
        # poprawiony symbol już istnieje -> scal kody indeksów
        foreach ($c in $row.Indexes) { if (-not $final[$newSym].Indexes.Contains($c)) { [void]$final[$newSym].Indexes.Add($c) } }
    } else {
        $row.Symbol = $newSym; $final[$newSym] = $row
    }
}

# Liczba zwalidowanych na indeks; jeśli walidacja odrzuciła za dużo (< MinRatio * Expected, np. awaria
# Yahoo), a stary plik ma więcej wierszy tego indeksu - bierzemy wiersze ze starego pliku.
foreach ($code in @($stats.get_Keys())) {
    if ($fallbackCodes.Contains($code)) { continue }
    $v = @($final.get_Values() | Where-Object { $_.Indexes.Contains($code) }).Count
    $stats[$code].Validated = $v
    $exp = ($Indexes | Where-Object { $_.Code -eq $code }).Expected
    if (-not $SkipValidation -and $v -lt $MinRatio * $exp -and (Get-ExistingRows $code).Count -gt $v) {
        Write-Warning "$code : only $v validated symbols - using existing rows instead"
        foreach ($o in Get-ExistingRows $code) {
            if (-not $final.Contains($o.symbol)) {
                $final[$o.symbol] = [pscustomobject]@{ Symbol = $o.symbol; Name = $o.name; Market = $o.market; Type = 'EQUITY'; Indexes = [System.Collections.ArrayList]::new() }
            }
            if (-not $final[$o.symbol].Indexes.Contains($code)) { [void]$final[$o.symbol].Indexes.Add($code) }
        }
        $stats[$code].Note = 'validation fallback'
    }
}

# Wiersze INDEX i ETF - tylko te z realną historią (>= $MinHistory niepustych dziennych zamknięć)
$indexOk = 0; $droppedIdx = New-Object System.Collections.ArrayList
foreach ($pair in @(@('INDEX', $IndexRows), @('ETF', $EtfRows))) {
    foreach ($ir in $pair[1]) {
        if (-not $SkipValidation) {
            $m = Test-YahooSymbol $ir[0] $pair[0]
            if (-not $m) {
                $raw = $script:MetaCache["$($ir[0])|1d"]
                $why = if ($raw) { "only $($raw.PointCount) non-null daily closes" } else { 'no data' }
                Write-Warning "$($pair[0]) symbol $($ir[0]) skipped ($why)"; [void]$droppedIdx.Add("$($ir[0]) ($why)"); continue
            }
        }
        $final[$ir[0]] = [pscustomobject]@{ Symbol = $ir[0]; Name = $ir[1]; Market = $ir[2]; Type = $pair[0]; Indexes = [System.Collections.ArrayList]::new() }
        $indexOk++
    }
}

# ---------------------------------------------------------------- zapis CSV
$codeOrder = @($Indexes | ForEach-Object { $_.Code })   # kody indeksów w stałej kolejności
# Pole CSV w cudzysłowie (cudzysłów w treści podwajany).
function Q([string]$s) { '"' + ($s -replace '"', '""') + '"' }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('symbol,name,market,type,indexes')
$sorted = $final.get_Values() | Sort-Object @{ e = { $_.Market } }, @{ e = { $_.Symbol } }   # rynek, potem symbol
foreach ($r in $sorted) {
    $idx = @($codeOrder | Where-Object { $r.Indexes.Contains($_) }) -join ' '
    $lines.Add(((Q $r.Symbol), (Q $r.Name), (Q $r.Market), (Q $r.Type), (Q $idx)) -join ',')
}
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
[IO.File]::WriteAllText($OutFile, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))   # UTF-8 bez BOM

# ---------------------------------------------------------------- podsumowanie
Write-Host ''
Write-Host 'Index      found validated  note'
foreach ($k in $stats.get_Keys()) { Write-Host ("{0,-9} {1,6} {2,9}  {3}" -f $k, $stats[$k].Found, $stats[$k].Validated, $stats[$k].Note) }
if ($droppedIdx.Count) { Write-Host "Dropped index/ETF rows: $($droppedIdx -join ', ')" }
Write-Host ("Equities: {0}, index/ETF rows: {1}, total rows: {2}" -f ($final.get_Count() - $indexOk), $indexOk, $final.get_Count())
if ($renamed.Count) { Write-Host "Fixed symbols ($($renamed.Count)): $($renamed -join ', ')" }
if ($dropped.Count) { Write-Host "Dropped symbols ($($dropped.Count)): $($dropped -join ', ')" }
Write-Host "Written: $OutFile"
