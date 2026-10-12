# Language switch (中文 / English) — every Paperhue app

- Two UI languages: Traditional Chinese (zh) and English (en).
- Default: the system UI language; zh-* → 中文, anything else → English.
- One button in the main window's top bar, labelled with the OTHER language:
  "English" while the UI is Chinese, "中文" while it is English. One click
  switches every visible text at once (main window and open dialogs), without
  restart, without losing state (photos, previews, running push).
- The choice is remembered (Windows: settings.json "language": "zh" | "en";
  absent = follow the system).
- Everything the user reads is translated: titles, labels, buttons, page
  names in the page selector, status line, progress texts, tooltips, dialogs,
  confirmations, error pop-ups (the technical English detail stays underneath).
- English calls the hardware "device", never "calendar". Calendar DATA
  (iCal feeds) may say calendar.
- Grain picker: 顆粒感 = Grain; 標準 / 柔和 / 更柔和 / 最平滑 =
  Standard / Soft / Softer / Smoothest.
- Page kinds: 照片 Photo, 本日＋月曆 Today + month, 本日行程＋一週行程
  Today + week, 待辦清單 To-do, 日 Day, 月曆 Month, 留言板 Notes board,
  大字留言 Big message, 牌卡 Card.
- The pages drawn on the device stay Chinese (not part of this change).
- Tests: every key exists in both languages with the same format
  placeholders; switching changes visible texts; the choice persists.
