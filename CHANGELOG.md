# Changelog

Semua perubahan penting project dicatat di file ini. Format versi mengikuti Semantic Versioning.

## [Unreleased]

### Added

- Auto-profile konservatif untuk GBPUSD, AUDUSD, NZDUSD, USDCAD, dan USDCHF pada M5 sesi London + New York.
- Deteksi PROFILE_AUTO untuk symbol major forex baru, termasuk prefix/suffix broker.

### Planned

- Hasil optimasi dan forward-test per broker dapat ditambahkan sebagai preset terpisah tanpa mengubah risk engine.

## [1.0.0] - 2026-09-03

### Added

- EA Asian high/low liquidity sweep dengan konfirmasi MSS candle-close pada M5/M15.
- Profile konservatif otomatis untuk XAUUSD, EURUSD, dan USDJPY, termasuk dukungan suffix/prefix symbol broker.
- Fixed-lot dan equity risk-percent sizing melalui kalkulasi nilai SL aktual.
- Spread, slippage, stop-distance, filling-mode, margin, dan `OrderCheck` validation.
- Daily trade cap, consecutive-loss breaker, profit target, loss limit, serta optional emergency close.
- Per-symbol dan per-magic history/position isolation untuk penggunaan multi-chart.
- Persistent daily money lock dan one-trade-per-direction state melalui Terminal Global Variables.
- Dokumentasi instalasi, cara kerja strategi, quick-start per pair, backtest, dan troubleshooting.
