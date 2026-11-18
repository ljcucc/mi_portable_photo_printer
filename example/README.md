# mi_printer_example

以 Flutter 實作的小米口袋相片印表機（`hannto.printer.basil`）列印 app。Android 為主要平台。

## 功能

- 連線（RFCOMM/SPP channel 1，Android 原生 platform channel）
- 電量 / 狀態輪詢（10s，兼作 RFCOMM 保活）
- `retime` 按鈕：重置印表機 ~10 分鐘的自動關機計時
- 選圖 → 前處理（1040×1560 baseline JPEG，cover/contain/stretch）→ 列印
- 傳輸進度與列印階段即時顯示（預熱/進紙/列印中/校正紙…）
- 完成後顯示印表機終身列印張數（`event.big_data`）

## 使用步驟

1. **取得 token**：用 [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor) 登入你的 Xiaomi 帳號，找到 "Mi Portable Photo Printer"（model `hannto.printer.basil`），複製其 24-hex token。
2. **配對**：先在 Android 藍牙設定中與印表機配對一次。
3. 開啟 app → 填入 MAC 位址與 token → **儲存** → **連線**（Android 12+ 會要求「附近裝置」權限）。
4. 選擇圖片、調整 fit 與份數 → **列印**。整張約 30~90 秒；新相紙包首印會多跑校正（smart_sheet 階段）。

## 注意

- token 是裝置機密，app 存在 `shared_preferences`（本 app 為測試用途）；正式版應改用 `flutter_secure_storage`。
- 列印途中斷線不會自動續傳，job 已毀，需重印。
- 印表機閒置 15 秒會斷線、10 分鐘會關機 — 都正常。
