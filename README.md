# MoneyMoney Real Estate Tracker

A [MoneyMoney](https://moneymoney.app) extension that tracks the market value of
apartments and houses as portfolio positions, using free official data. It needs
no paid APIs and does no scraping.

## Method

The extension starts from your actual purchase price, which is a real notarised
transaction, and rolls it forward with a regional, transaction-based price index:

```
value = purchase price × index(latest quarter) / index(purchase quarter)
        × faktor × (1 − afa)^years
```

All the details of your property (location within the city, floor, layout,
condition at purchase) are already priced into what you paid. Don't add
a floor or location premium on top, because that would count it twice. The index then
captures how that market has moved since.

The extension picks an index from the postcode, most specific first:

| Priority | Source | Coverage |
|---|---|---|
| 1 | [GREIX](https://greix.de): transaction data from the local Gutachterausschüsse, quarterly, by property type | Berlin, Hamburg, München, Köln, Frankfurt, Düsseldorf, Stuttgart, Dortmund, Duisburg, Bochum, Bonn, Münster, Hamm, Bocholt, Kreis Mettmann, Rhein-Erft-Kreis, Chemnitz, Dresden, Leipzig, Erfurt, Karlsruhe, Lübeck, Potsdam, Wiesbaden, LK Ludwigslust-Parchim |
| 2 | [Destatis Häuserpreisindex](https://www.destatis.de/DE/Themen/Wirtschaft/Preise/Baupreise-Immobilienpreisindex/_inhalt.html) by settlement type (Top 7 cities, urban districts, rural districts, …), separately for flats and houses | All of Germany (every postcode, via its district's [BBSR type](https://www.bbsr.bund.de/BBSR/DE/forschung/raumbeobachtung/Raumabgrenzungen/deutschland/kreise/siedlungsstrukturelle-kreistypen/kreistypen.html)) |
| 3 | [Eurostat house price index](https://ec.europa.eu/eurostat/databrowser/view/prc_hpi_q/default/table) | 30 European countries |

Where a source has gaps, it is chained with the next one. GREIX series are
carried forward with the Destatis index for the district's settlement type, and
Destatis (which starts in Q4 2015) is extended back with the long-running GREIX
national index. The source used for each object appears in the MoneyMoney
"Börse/Markt" column.

**Limits:** an index follows the market average, not your specific property. Use
`afa` for building ageing, `sanierung` for renovations and `faktor` for anything else. If you have a recent
professional valuation, you can also enter it in place of the purchase price,
with its date.

## Installation

1. Download [`RealEstateTracker.lua`](RealEstateTracker.lua).
2. In MoneyMoney, open **Help → Show Database in Finder** and copy the file into the `Extensions` folder.
3. Under **Settings → Extensions**, turn off **Verify digital signatures of extensions**. This is needed because the extension isn't signed by MoneyMoney.
4. Choose **Account → Add Account → Other → Immobilien (Preisindex)**.

## Configuration

Enter one or more objects in the **username** field, separated by `;`:

```
Name | PLZ | Typ | m² | Kaufpreis | Kaufdatum [| option=wert ...]
```

Example (fictional):

```
Musterstraße 1 | 10115 | etw | 80 | 320000 | 2017-05; Gartenweg 7 | 49074 | efh | 140 | 280.000 | 2012
```

| Field | Values |
|---|---|
| Name | Any label |
| PLZ | 5-digit German postcode, or an ISO country code (`AT`, `ES`, `FR`, …) for objects abroad |
| Typ | `etw` (apartment), `efh` (single/two-family house, also `haus`, `rh`, `dhh`), `mfh` (multi-family house) |
| m² | Living area. Optional: if given, MoneyMoney shows quantity = m² and price = €/m² |
| Kaufpreis | Purchase price without transaction costs. `320000`, `320.000`, `320.000 €`, `1,2 Mio` |
| Kaufdatum | `2017`, `2017-Q2`, `Q2/2017`, `05/2017`, `2017-05`, `15.05.2017` |

Options:

| Option | Meaning |
|---|---|
| `afa=1` | Annual ageing discount in percent (default 0). Index values reflect a constant quality level, so a building that has aged since purchase is worth a bit less than the index suggests. See the guide below. |
| `sanierung=80000@2018-06` | Renovation or modernisation spending since purchase. Each amount is carried forward with the index from its own date and added to the purchase price for gain/loss. Join several with `+`: `sanierung=80000@2018 + 25000@2022-03` |
| `abzug=75000` | Known renovation backlog (Instandhaltungsstau), such as work a buyer would have to do. Deducted from today's value; not indexed |
| `faktor=1.08` | Fixed multiplier for any other value difference (better or worse than the market average) |
| `index=de-kt2` | Force a specific index area (see `areas` in [`data/indices.json`](data/indices.json)) |
| `waehrung=CHF` | Currency for objects outside the euro area |

**Choosing `afa` by build year.** The build year itself is already priced into
the purchase price, so it is not a multiplier. What it changes is how fast the
building loses value after purchase. Rules of thumb (not official figures):

| Building | `afa` |
|---|---|
| Altbau (before 1919), renovated | 0–0.5 |
| Post-war to 1990s | 0.5–1 |
| New build bought new, or under ~15 years old at purchase | 1–1.5 |

Renovations you enter with `sanierung` already offset part of the ageing, so
lean towards the lower value when you use them.

The **password** field is not used, but MoneyMoney requires a value, so enter
anything. If the username field gets too long, you can put more objects in the
password field using the same format.

Your object data stays in MoneyMoney. The extension only downloads the two
public index files from this repository.

## Data updates

[`scripts/build_data.py`](scripts/build_data.py) downloads all sources and writes
[`data/indices.json`](data/indices.json) and [`data/de_plz.json`](data/de_plz.json).
A [GitHub Action](.github/workflows/update-data.yml) runs it weekly, runs the tests,
and commits the files when the data has changed.

```sh
pip install -r scripts/requirements.txt
python scripts/build_data.py
lua tests/run.lua                                                  # tests (fictional objects)
lua tests/run.lua "Test | 10115 | etw | 80 | 320000 | 2017-05"     # value an object locally
```

## Sources and licences

- **GREIX** – German Real Estate Index, Kiel Institut für Weltwirtschaft / ECONtribute / Gutachterausschüsse, [greix.de](https://greix.de). Publicly funded and freely accessible; cite the source when using it.
- **Statistisches Bundesamt (Destatis)**, Preisindizes für Wohnimmobilien nach Kreistypen (61262), [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0)
- **BBSR**, Raumgliederungen (siedlungsstrukturelle Kreistypen), [dl-de/by-2-0](https://www.govdata.de/dl-de/by-2-0)
- **OpenStreetMap** contributors, postcode → municipality via [OpenPLZ API data](https://github.com/openpotato/openplzapi.data), [ODbL](https://opendatacommons.org/licenses/odbl/)
- **Eurostat**, House price index (prc_hpi_q), [CC BY 4.0](https://ec.europa.eu/eurostat/about-us/policies/copyright)

The code is MIT licensed. Values are estimates for personal tracking only, not a
valuation report (Verkehrswertgutachten).
