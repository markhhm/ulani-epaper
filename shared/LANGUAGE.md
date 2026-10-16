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
- Colour picker (before the grain picker): 顏色 = Colours; 自然 / 明亮 / 經典 =
  Natural / Bright / Classic (shared/DITHER.md). One line under (or right
  next to) the picker tells what the chosen one does:
  - 自然: 「顏色最鮮明：藍天等鮮豔的淺色會稍暗，以保留顏色。」 / "Most colour:
    light, vivid colours such as a blue sky come out a little darker to keep
    their colour."
  - 明亮: 「保留原本的明暗：藍天等鮮豔的淺色會偏白。」 / "Keeps the photo’s
    brightness: light, vivid colours such as a blue sky lean white."
  - 經典: 「舊版的做法：整體較淡，適合本來就是七種純色的圖。」 / "The original
    method: lighter overall; best for pictures already in the seven pure
    colours."
- Page kinds: 照片 Photo, 本日＋月曆 Today + month, 本日行程＋一週行程
  Today + week, 待辦清單 To-do, 日 Day, 月曆 Month, 留言板 Notes board,
  大字留言 Big message, 牌卡 Card.
- The pages drawn on the device stay Chinese (not part of this change).
- Tests: every key exists in both languages with the same format
  placeholders; switching changes visible texts; the choice persists.
