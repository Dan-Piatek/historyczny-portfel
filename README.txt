HISTORYCZNY PORTFEL – instrukcja
================================
GPW, giełdy europejskie, USA i Japonia. Wycena w PLN po kursach NBP.

JAK OTWORZYĆ
- Rozpakuj ZIP do dowolnego folderu i kliknij dwukrotnie plik index.html.
- Działa w Chrome, Edge i Firefox, bez instalacji i bez uprawnień administratora.
- Notowania pobierają się same z serwera danych na GitHubie: przy otwarciu i potem co godzinę.
  Nie trzeba zakładać kont ani podawać kluczy.
- Bez internetu aplikacja działa na danych zapisanych wcześniej w przeglądarce.

DODAWANIE TRANSAKCJI
- Wpisz symbol albo zacznij pisać nazwę i wybierz z listy. Przykłady:
    PKN.WA (GPW), AAPL (USA), SAP.DE (Niemcy), VOD.L (Londyn), 7203.T (Japonia).
  Dla spółek z GPW wystarczy sam ticker, np. PKN.
- Nie znasz ceny? Zostaw pole „Cena” puste: aplikacja podstawi cenę zamknięcia z dnia
  transakcji (albo z ostatniej wcześniejszej sesji, np. piątku dla soboty).
- Wystarczy podać liczbę akcji ALBO kwotę: z kwoty aplikacja wyliczy liczbę akcji
  (do 4 miejsc po przecinku). Pod formularzem widać, co zostanie zapisane.
- Ceny z serwera są skorygowane o splity (np. Apple w 2002 r. ok. 0,26 USD). Jeśli wpisujesz
  liczbę akcji z dawnego potwierdzenia maklerskiego sprzed splitu, przelicz ją na dzisiejsze akcje
  albo podaj kwotę zamiast liczby akcji.
- Cenę i prowizję podaj w walucie notowań (Londyn: w pensach, GBp).
- Kurs waluty możesz zostawić pusty: aplikacja użyje kursu średniego NBP z dnia transakcji.
  Jeśli znasz kurs zastosowany przez biuro maklerskie, wpisz go ręcznie.

GDY BRAKUJE NOTOWAŃ (tryb awaryjny)
Na serwerze jest ok. 1500–2000 spółek z głównych indeksów. Jeśli waloru nie ma
albo serwer jest niedostępny, aplikacja pokaże link do pliku CSV ze Stooq:
1. Kliknij link, np. https://stooq.pl/q/d/l/?s=pkn&i=d. Zapisze się plik pkn_d.csv.
   Jeśli pojawi się strona weryfikacji, odczekaj chwilę i kliknij ponownie.
2. Przeciągnij plik (można kilka naraz) na stronę albo użyj „Wybierz pliki CSV…”.
   Nie zmieniaj nazwy pliku, bo symbol jest odczytywany z nazwy.
Pasuje każdy CSV z kolumnami Date/Data i Close/Zamkniecie.

GOTOWE PORTFELE I PLANY ZAKUPÓW
- „Gotowy portfel z szablonu…” (panel Portfele): wybierz szablon branżowy lub strategię,
  datę i kwotę – aplikacja kupi składniki po cenach zamknięcia z tego dnia.
- „Plany regularnych zakupów”: stała kwota w PLN co tydzień / miesiąc / kwartał, od wybranej
  daty, opcjonalnie do daty końca. Raty z przeszłości powstają od razu, kolejne są dopisywane
  automatycznie, gdy pojawią się nowe notowania. Ratę można usunąć – nie wróci.
- Tabela pozycji: „Usuń” kasuje wszystkie transakcje waloru; „Usuń wszystkie” czyści portfel.

JAK PRZENIEŚĆ PORTFEL NA INNY KOMPUTER
1. Kliknij „Eksport JSON”.
2. Skopiuj plik portfel-RRRR-MM-DD.json na drugi komputer.
3. Tam otwórz index.html i kliknij „Import JSON” albo przeciągnij plik na stronę.
   Import zastępuje dane zapisane w tej przeglądarce.

INNE
- „Eksport CSV” w tabeli pozycji zapisuje plik dla Excela (separator ;).
- „Stan na dzień” przelicza portfel na wybraną datę z przeszłości.
- Wartości liczone są z cen zamknięcia, bez dywidend i podatków.
  To narzędzie poglądowe, a nie porada inwestycyjna.
- Testy obliczeń: otwórz index.html#selftest albo wpisz runSelfTests() w konsoli (F12).

DLA ADMINISTRATORA SERWERA DANYCH (repozytorium GitHub)
- config/universe.csv          lista walorów (symbole Yahoo Finance). Dopisz wiersz, żeby dodać walor.
- tools/update-data.ps1        pobieranie notowań (Yahoo) i kursów (NBP)
- tools/build-universe.ps1     odtworzenie listy ze składów indeksów (Wikipedia)
- .github/workflows/update-data.yml  automat: pn–pt 22:30 UTC, można też uruchomić ręcznie (Actions → Run workflow)
Dane trafiają na gałąź "data" (zawsze jeden commit, więc repozytorium nie rośnie).
Adres danych w aplikacji można zmienić: panel „Notowania” → „Adres serwera danych”.
