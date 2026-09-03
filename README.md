# Institutional Liquidity Sweep EA

EA MetaTrader 5 ini memperdagangkan sweep high/low sesi Asia yang dikonfirmasi oleh Market Structure Shift (MSS) pada candle tertutup. Risk guard, history, posisi, dan lock harian selalu difilter menggunakan kombinasi symbol dan `InpMagicNumber`.

> Profile bawaan adalah baseline konservatif untuk backtest dan forward-test. Tidak ada strategi yang menjamin profit. Gunakan akun demo sebelum akun live.

## Instalasi

1. Salin `InstitutionalLiquiditySweepEA.mq5` ke `MQL5/Experts/`.
2. Buka MetaEditor, compile file, dan pastikan hasilnya nol error serta nol warning.
3. Aktifkan Algo Trading di MT5.
4. Pasang EA pada satu chart untuk setiap pair. Timeframe chart bebas karena EA membaca timeframe signal dari profile/input.
5. Beri `InpMagicNumber` berbeda pada setiap chart, misalnya XAUUSD `1001`, EURUSD `1002`, dan USDJPY `1003`.
6. Isi `InpBrokerUtcOffsetHours` sesuai waktu server broker. Contoh: bila server menunjukkan 10:00 ketika UTC 08:00, isi `2`. Sesuaikan kembali ketika broker mengubah DST.

## Quick start per pair

### Gold / XAUUSD

1. Buka chart XAUUSD dan pasang EA.
2. Set `InpMagicNumber=1001`, `InpUseAutoPairProfile=true`, dan `InpSymbolProfile=PROFILE_AUTO`.
3. Pilih `LOT_RISK_PERCENT` dengan `InpRiskPercent=0.25` untuk forward-test awal, atau fixed lot minimum broker bila memang ingin fixed sizing.
4. Pastikan log initialization menampilkan `XAUUSD_CONSERVATIVE`, M15, SL 300, dan TP 600.
5. Jangan mengubah 300 pips menjadi 30 sebelum memeriksa definisi pip broker; pada XAUUSD dua digit, 300 pips umumnya setara jarak harga `3.00`.

### EURUSD

1. Buka chart EURUSD dan gunakan magic berbeda, misalnya `1002`.
2. Profile otomatis memakai konfirmasi M5 pada sesi London dan New York, SL 20 pips, serta TP 40 pips.
3. Spread harus maksimum 2 pips. Bila broker sering berada di atas nilai ini pada sesi aktif, periksa kualitas feed sebelum melonggarkan filter.

### USDJPY

1. Buka chart USDJPY dan gunakan magic berbeda, misalnya `1003`.
2. Profile otomatis memakai M15 dan hanya sesi London untuk mengurangi sinyal berulang.
3. Karena pair JPY umumnya tiga digit, satu pip dihitung sebagai 10 points oleh EA. SL 20 berarti sekitar `0.20` pada harga USDJPY.

Untuk semua pair, nilai profit target dan loss limit adalah per kombinasi symbol+magic, bukan batas seluruh akun. Bila ingin batas akun global, gunakan risk manager terpisah.

## Cara kerja entry

- EA membentuk range dari sesi Asia terakhir yang sudah selesai.
- BUY: candle menembus Asian low plus buffer dan kembali close di atas Asian low. Candle berikutnya harus close di atas confirmed swing high terakhir.
- SELL: kebalikan dari BUY pada Asian high dan swing low.
- Entry dilakukan market pada tick pertama setelah candle MSS selesai.
- Satu Asian range hanya boleh menghasilkan satu BUY dan satu SELL. Semua entry tetap tunduk pada maksimum trade dan loss streak harian.
- TP selalu sekurang-kurangnya dua kali jarak SL.

Contoh BUY: Asian low berada di `1.0800`. Candle M5 turun melewati `1.0799`, tetapi close kembali di atas `1.0800`; setup bullish menjadi armed. EA mencari swing high terkonfirmasi sebelum sweep. Bila candle berikutnya close di atas swing tersebut saat sesi masih aktif, EA menjalankan pemeriksaan risiko lalu mengirim BUY market. Jika MSS tidak muncul sebelum expiry, setup dibatalkan.

EA tidak memakai candle yang masih berjalan, tidak langsung entry hanya karena wick menyentuh range, dan menolak candle ekstrem yang menyapu Asian high serta low sekaligus.

## Profile pair

Dengan `InpUseAutoPairProfile=true` dan `InpSymbolProfile=PROFILE_AUTO`, suffix/prefix broker seperti `EURUSD.a` atau `XAUUSDpro` tetap dikenali.

| Pair | Signal | Sesi | SL | TP | Max spread | Sweep buffer |
|---|---:|---|---:|---:|---:|---:|
| XAUUSD | M15 | London + New York | 300 pips | 600 pips | 50 pips | 20 pips |
| EURUSD | M5 | London + New York | 20 pips | 40 pips | 2 pips | 1 pip |
| USDJPY | M15 | London | 20 pips | 40 pips | 2 pips | 1 pip |

Definisi pip mengikuti digits symbol: symbol 3/5 digit memakai 10 points per pip; symbol lain memakai 1 point per pip. Pada XAUUSD dua digit, 300 pips biasanya berarti pergerakan harga `3.00`. Periksa spesifikasi symbol broker sebelum live.

Untuk mengubah parameter profile, set `InpUseAutoPairProfile=false` atau pilih `PROFILE_CUSTOM`, lalu isi SL, TP, spread, session, timeframe, buffer, dan swing settings secara manual.

## Lot dan risiko

- `LOT_FIXED`: EA memakai `InpLotSize`, dinormalisasi turun mengikuti volume step broker. Nilai di luar batas min/max broker ditolak.
- `LOT_RISK_PERCENT`: lot dihitung dari equity, `InpRiskPercent`, dan nilai kerugian aktual pada harga SL melalui `OrderCalcProfit`. Bila lot hasil kalkulasi lebih kecil dari minimum broker, order ditolak agar risiko tidak dinaikkan diam-diam.
- Sebelum order, EA memeriksa spread, stop level, free margin, projected margin level, filling mode, dan `OrderCheck`.

Untuk permulaan di demo, risk-percent `0.25%` sampai `0.50%` per trade lebih mudah dikontrol daripada fixed lot yang sama pada semua pair. XAUUSD dan forex memiliki nilai tick yang berbeda, jadi jangan menyamakan lot hanya berdasarkan ukuran angka SL.

## Daily guardrails

- Hari trading mengikuti candle D1 broker. Semua statistik memakai deal history milik symbol+magic tersebut.
- Daily PnL adalah closed net PnL ditambah floating PnL. Closed net memasukkan profit, swap, commission, dan fee.
- Semua closed trade dengan net PnL negatif menghitung consecutive-loss streak, termasuk posisi yang ditutup manual.
- Profit target atau loss limit mengunci EA sampai hari broker berikutnya. Lock disimpan sebagai Terminal Global Variable sehingga restart terminal tidak membuka lock.
- Jika `InpCloseFloatingOnDailyLimit=true`, hanya posisi dengan symbol dan magic milik EA tersebut yang ditutup.
- Input bernama `USD` secara teknis menggunakan mata uang deposit akun MT5. Gunakan akun USD untuk nilai USD yang literal.

## Multi-chart dan jenis akun

- Pada akun hedging, EA dapat berjalan pada banyak pair dan hanya mengelola ticket dengan symbol+magic yang cocok.
- Pada akun netting, MT5 hanya menyediakan satu posisi gabungan per symbol. Karena itu EA menolak entry bila symbol yang sama sudah mempunyai posisi dari magic lain. Jangan menjalankan beberapa strategi independen pada symbol yang sama di akun netting.

## Backtest wajib

Gunakan Strategy Tester dengan mode **Every tick based on real ticks**. Uji minimal satu periode yang mencakup kondisi spread tinggi dan perubahan DST. Periksa tab Journal untuk alasan entry ditolak, profile efektif, Asian range, sweep, MSS, daily lock, dan emergency close. Setelah backtest, jalankan forward-test demo beberapa minggu dengan UTC offset broker yang benar sebelum mempertimbangkan live.

Checklist hasil backtest:

- Profile, digits, tick size, dan pip conversion sesuai spesifikasi symbol broker.
- Tidak ada entry sebelum sesi atau sebelum MSS candle selesai.
- Spread rejection muncul saat spread melewati batas.
- TP selalu minimal 2R terhadap SL.
- Trade ketiga pada hari yang sama ditolak dengan default maksimum dua trade.
- Dua closed trade rugi berturut-turut mengunci entry sampai D1 broker berganti.
- Daily target/loss limit menutup hanya posisi milik symbol+magic tersebut ketika force-close aktif.

## Pengaturan dan troubleshooting

- **Tidak ada entry:** periksa tab Experts untuk `Asian range ready`, sesi UTC, spread, minimum lot, dan margin level. Strategi memang membutuhkan sweep lalu MSS; tidak setiap hari menghasilkan trade.
- **Profile terbaca CUSTOM:** nama symbol broker tidak mengandung `XAUUSD`, `EURUSD`, atau `USDJPY`. Pilih profile secara eksplisit atau gunakan custom settings.
- **OrderCheck gagal:** baca retcode broker di log; penyebab umum adalah market tutup, stop distance, filling mode, volume, atau margin.
- **EA tetap terkunci setelah restart:** ini perilaku yang disengaja. Daily money lock disimpan di Terminal Global Variables dan dibersihkan saat candle D1 broker berganti.
- **Jam sesi meleset:** bandingkan waktu Market Watch dengan UTC, lalu koreksi `InpBrokerUtcOffsetHours`; lakukan kembali saat DST berubah.

## Versioning

Project memakai Git. Nomor versi EA ada pada `#property version`, sedangkan perubahan antarrilis dicatat di `CHANGELOG.md`. Sebelum membuat versi baru, compile dan backtest, naikkan nomor versi, perbarui changelog, lalu buat Git tag seperti `v1.0.0`.
