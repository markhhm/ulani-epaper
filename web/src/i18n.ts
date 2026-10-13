/**
 * UI strings in Traditional Chinese (Taiwan) and English, and the language
 * the page shows them in.
 *
 * The language comes from the choice saved by the language button, else
 * from the browser's preferred languages (Chinese for zh-*, else English).
 * Every key has both languages. Placeholders such as `{page}` are filled
 * from the `params` of t(). The hardware is called 裝置 / device; "calendar"
 * (行事曆) only ever means calendar data, such as an iCal feed.
 */

export type Locale = 'zh-TW' | 'en';

export const LOCALES: readonly Locale[] = Object.freeze(['zh-TW', 'en']);

const en = {
  // --- Pages and app shell ---
  appName: 'Paperhue',
  'title.app': 'Paperhue',
  'title.diagnostics': 'Paperhue diagnostics — ULANI e-paper',
  openDiagnostics: 'Open diagnostics',
  backToApp: 'Back to the app',
  bluetoothUnsupported:
    'This browser cannot use Bluetooth. On iPhone, open this page in the Bluefy browser; on a computer or Android, use Chrome.',
  /** The language button: the name of the OTHER language. */
  'language.other': '中文',
  'language.otherTitle': 'Show this page in Traditional Chinese',

  // --- Device chooser of the Android app ---
  'chooser.scanning': 'Looking for devices…',
  'chooser.cancel': 'Cancel',
  'chooser.found': 'Devices found',
  'chooser.none': 'No device found',

  // --- Diagnostics: header and connection state ---
  'diag.heading': 'Paperhue diagnostics',
  'diag.intro':
    'Checks whether this browser can talk to a ULANI e-paper device over Bluetooth. Go through the steps top to bottom, then tap "Copy log" and send the result back.',
  'link.notConnected': 'Not connected',
  'link.connected': 'Connected',
  'link.connectedTo': 'Connected: {name}',
  'link.lost': 'Link lost: the next action reconnects',
  'link.waiting': 'Waiting for the device to finish redrawing: connecting in {seconds} s',
  'link.reconnecting': 'Connecting (attempt {attempt})…',
  'link.busy': 'Working…',

  // --- Checklist ---
  'checklist.title': 'Checklist',
  'checklist.summary': 'PASS {pass} · FAIL {fail} · WARN {warn} · INFO {info} · not run {pending}',
  'badge.pending': 'NOT RUN',
  'badge.running': 'RUNNING',
  'badge.pass': 'PASS',
  'badge.fail': 'FAIL',
  'badge.warn': 'WARN',
  'badge.info': 'INFO',
  'check.webBluetooth': 'Web Bluetooth API',
  'check.availability': 'Bluetooth available',
  'check.secureContext': 'Secure context (https)',
  'check.writeMethods': 'Write methods',
  'check.calendarFeed': 'Calendar download',
  'check.connect': 'Connect, notifications, unlock',
  'check.deviceInfo': 'Model and firmware',
  'check.battery': 'Battery',
  'check.page': 'Page on screen',
  'check.switch': 'Switch page',
  'check.upload': 'Upload test card',
  'check.disconnect': 'Disconnect',

  // --- Values ---
  'value.present': 'yes',
  'value.absent': 'no',
  'value.true': 'yes',
  'value.false': 'no',
  'value.unknown': 'unknown',
  'value.unreadable': 'unreadable',
  'value.unreadableBecause': 'unreadable: {detail}',
  'value.none': 'none',
  'value.charging': 'charging',
  'page.n': 'Page {page}',

  // --- Step: browser ---
  'browser.title': 'Check the browser',
  'browser.row.bluetooth': 'Web Bluetooth',
  'browser.row.availability': 'Bluetooth available',
  'browser.row.secure': 'Secure context',
  'browser.row.methods': 'Write methods',
  'browser.row.agent': 'User agent',
  'browser.availability.yes': 'available',
  'browser.availability.no': 'not available (Bluetooth is off or not allowed)',
  'browser.availability.missing': 'cannot tell beforehand (no getAvailability)',
  'browser.availability.timeout': 'no answer',
  'browser.availability.error': 'error: {error}',
  'browser.methodsAfterConnect': 'Checked after connecting (this browser does not expose BluetoothRemoteGATTCharacteristic)',
  'browser.methodsFromDevice': 'on the connected device',
  'browser.checkAgain': 'Check again',
  'verdict.noBluetooth': 'no navigator.bluetooth',
  'verdict.insecure': 'not a secure context ({protocol})',
  'verdict.cannotTell': 'cannot tell',
  'verdict.availabilityOff': 'getAvailability() = false: Bluetooth is off or not allowed',
  'verdict.availabilityMissing': 'no getAvailability(): connecting will tell',
  'verdict.availabilityTimeout': 'getAvailability() did not answer',
  'verdict.availabilityError': 'getAvailability() failed: {error}',
  'verdict.noCharacteristic': 'checked after connecting: this browser does not expose BluetoothRemoteGATTCharacteristic',
  'verdict.deviceMethods': '{methods} (on the device’s image characteristic)',
  'verdict.noWithoutResponse': '{methods} (no writeValueWithoutResponse: "auto" uses another method)',

  // --- Step: calendar download ---
  'feed.title': 'Calendar download test',
  'feed.intro':
    'No Bluetooth needed. The button makes this browser download the public Taiwan holidays calendar (iCal) from Google Calendar directly, without any go-between, to see whether calendar data can be fetched here.',
  'feed.button': 'Test the download',
  'feed.row.result': 'Result',
  'feed.row.status': 'HTTP status',
  'feed.row.size': 'Size',
  'feed.row.format': 'Content',
  'feed.row.time': 'Time',
  'feed.result.pass': 'PASS',
  'feed.result.blocked': 'BLOCKED',
  'feed.result.unexpected': 'not calendar data',
  'feed.size': '{bytes} bytes',
  'feed.format.ok': 'starts with BEGIN:VCALENDAR ({events} events)',
  'feed.format.bad': 'does not start with BEGIN:VCALENDAR',
  'feed.explain.pass': 'This browser can download calendar feeds directly, so calendar pages can be synced here.',
  'feed.explain.blocked':
    'The browser blocked the download (CORS or network error), so calendar pages cannot be synced in this browser.',
  'feed.explain.unexpected':
    'The download went through, but it was not calendar data (HTTP {status}), so calendar pages cannot be synced right now. Try again later.',

  // --- Step: connect ---
  'connect.title': 'Connect',
  'connect.note':
    'Before this phone connects for the first time, hold the device’s button about 5 s until the LED blinks green (pairing mode). Connect opens a list of Bluetooth devices: pick the device whose name starts with ULANI, and accept when the phone asks to pair.',
  'connect.button': 'Connect',
  'connect.pairingHint':
    'First time with this phone? Hold the device’s button about 5 s until the light blinks green (pairing mode), then connect again.',
  'device.row.name': 'Device name',
  'device.row.model': 'Model',
  'device.row.firmware': 'Firmware',
  'device.row.kind': 'Transport',

  // --- Step: status ---
  'status.title': 'Read status',
  'status.button': 'Read status',
  'status.row.battery': 'Battery',
  'status.row.page': 'Page on screen',

  // --- Step: switch page ---
  'switch.title': 'Switch page',
  'switch.note': 'The e-paper redraws after a switch; that takes a moment.',
  'switch.shown': 'On screen: page {page}',
  'switch.shownUnknown': 'Page on screen: unknown',

  // --- Step: upload ---
  'upload.title': 'Send a test card',
  'upload.note':
    'Uploading to the page on screen makes the panel refresh for about 40 s, during which the device answers nothing. To test several times, upload to another page, then switch to it to look.',
  'upload.onScreenWarning':
    'This page is on screen: after the upload the panel refreshes for about 40 s and the device answers nothing meanwhile.',
  'upload.page': 'Page',
  'upload.onScreen': 'on screen',
  'upload.mode': 'Write mode',
  'upload.mode.auto': 'auto',
  'upload.mode.withoutResponse': 'without response',
  'upload.mode.withResponse': 'with response (only if the device allows it)',
  'upload.chunk': 'Chunk size (bytes)',
  'upload.flush': 'Flush every N packets',
  'upload.flush.off': 'off',
  'upload.flush.every': 'every {count}',
  'upload.resend': 'Send the previous card again (same page: expect "unchanged")',
  'upload.preview': 'Test card preview',
  'upload.keepOn': 'Keep the screen on and stay on this page until the upload finishes.',
  'upload.send': 'Send the test card',
  'upload.stop': 'Stop',
  'upload.waiting': 'Unlocking, waiting for the device…',
  'upload.progress': '{percent}% · {sent} / {total} bytes · {time}',
  'upload.progressDone': '{percent}% · {sent} / {total} bytes · {time}, waiting for the result…',
  'upload.showPageN': 'Show page {page}',
  'result.row.outcome': 'Result',
  'result.row.total': 'Total time',
  'result.row.data': 'Data transfer',
  'result.row.speed': 'Throughput',
  'result.row.wait': 'Waiting for the result',
  'result.row.packets': 'Packets',
  'result.ok': 'OK',
  'result.unchanged': 'unchanged (this page already holds the same card; no data sent)',
  'result.stopped': 'stopped',
  'result.error': 'error',
  'result.packets': '{count} × {size} bytes',
  'result.packetsLimited': '{count} × {size} bytes (this transport cannot change some settings)',
  'refresh.redrawing':
    'The device is redrawing its screen (about {seconds} s left); if the link drops meanwhile, it reconnects by itself.',
  'refresh.done': 'The device should be done redrawing its screen.',

  // --- Step: disconnect ---
  'disconnect.title': 'Disconnect',
  'disconnect.button': 'Disconnect',

  // --- Log ---
  'log.title': 'Log',
  'log.copy': 'Copy log',
  'log.clear': 'Clear',
  'log.copied': 'Copied: paste it into a message and send it back.',
  'log.copyManually': 'Could not copy automatically: select the text below and copy it.',

  // --- Checklist notes ---
  'note.firmwareUnreadable': '{parts}; cannot read the firmware: set "Flush every N packets" to "off"',
  'note.uploadOk': 'page {page}, {details}',
  'note.uploadStopped': 'stopped ({sent} / {total} bytes)',
  'note.uploadUnchanged': 'page {page} already holds this card; no data sent',

  // --- Copied report ---
  'report.title': 'Paperhue diagnostics log',
  'report.time': 'Time',
  'report.page': 'Page',
  'report.checklist': 'Checklist',
  'report.feed': 'Calendar download',
  'report.device': 'Device',
  'report.status': 'Status',
  'report.uploads': 'Uploads',
  'report.log': 'Log',
  'report.empty': '(empty)',

  // --- Errors ---
  'error.stopped': 'Stopped.',
  'error.notConnected': 'Not connected to the device yet. Tap "Connect" first.',
  'error.noReply': 'The device did not answer. {hint}',
  'error.busy': 'The device stayed busy (perhaps still refreshing the panel). Wait a minute, then try again.',
  'error.uploadRejected':
    'The device rejected the picture (incomplete data or a checksum mismatch). Try smaller packets or a smaller flush interval, and keep the screen on while sending.',
  'error.protocol': 'The device answered something unexpected. Copy the log and report it.',
  'error.connectStale':
    'Could not connect after {attempts} tries: each time the link dropped while pairing. {hint} If this phone was paired with the device before, the pairing no longer works: {steps}',
  'error.connectFailed': 'Could not connect after {attempts} tries. {cause}',
  'error.device': 'Something went wrong while talking to the device. Copy the log and report it.',
  'error.unexpected': 'Something unexpected went wrong. Copy the log and report it.',
  'error.refreshHint':
    'If you just sent a picture to the page on screen, the panel refreshes for about 40 s and the device answers nothing meanwhile: wait, then try again.',
  'error.repairSteps':
    'In the phone’s Settings > Bluetooth, forget this device, then hold the device’s button about 5 s until the LED blinks green (pairing mode), tap "Connect" and accept the pairing.',
  'error.locationHint':
    'Phones with Android 11 or older need Location on to find Bluetooth devices: turn on Location in the phone’s settings, then try again.',
  'error.noWriteMethod': 'This browser does not have this write method: set "Write mode" back to "auto" and try again.',
  'error.withResponseRefused':
    'The device does not accept writes "with response": set "Write mode" back to "auto" and try again.',
  'error.firmwareUnreadable':
    'This browser cannot read the device’s firmware version, so "Flush every N packets" cannot be used: set it to "off" and try again.',
  'error.notPermitted':
    'The device or the browser does not allow this Bluetooth operation, so trying again will not help. Set "Write mode" back to "auto"; if it still fails, copy the log and report it.',
  'error.locationOff': 'Location is off on this phone. {hint}',
  'error.unavailable':
    'Bluetooth is off, or this browser may not use it. Turn on Bluetooth and allow this browser to use it, then try again.',
  'error.cancelled': 'Cancelled: no device was chosen, or connecting was stopped.',
  'error.cancelledEmptyList': 'If the list stays empty: {hint}',
  'error.notFound': 'No device found. Bring the phone close to the device, wait a few seconds and tap "Connect" again.',
  'error.bondLost': 'The device refused the encrypted link (the pairing no longer works). {steps}',
  'error.linkLostPairing':
    'The Bluetooth link dropped while pairing. {hint} If this phone was paired with the device before and it happens every time, the pairing may no longer work: {steps}',
  'error.droppedWhileConnecting': 'The device dropped the Bluetooth link while connecting. {hint}',
  'error.linkLost': 'The Bluetooth link dropped. Try again; if needed, tap "Connect" first.',
  'error.droppedWhileRedrawing':
    'The device dropped the link while redrawing its screen, as it does; it reconnects by itself. Try again once connected.',
  'error.timeout': 'A Bluetooth operation took too long. {hint}',

  // --- The app: sections, status, jobs ---
  'app.tabs': 'Sections',
  'app.tab.cards': 'My cards',
  'app.tab.photos': 'Photos',
  'app.tab.pages': 'Pages',
  'app.tab.backup': 'Backup',
  'app.device': 'Device',
  'app.dismiss': 'Dismiss',
  'job.connecting': 'Connecting…',
  'job.preparing': 'Preparing the picture…',
  'job.sending': 'Sending page {page}… {percent}%',
  'notice.card': 'Showing on page {page}.',
  'notice.cardSwitched': 'Switched to page {page}: the device already had this card there.',
  'notice.cardAlready': 'Page {page} already shows this card.',
  'notice.preload': 'Put {count} cards on the card pages.',
  'notice.photo': 'Sent the photo to page {page}.',
  'notice.photoUnchanged': 'Page {page} already has this photo.',
  'notice.calendar': 'Sent page {page} to the device.',
  'notice.calendarUnchanged': 'Page {page} already shows this.',

  // --- Colours ---
  'colour.black': 'Black',
  'colour.white': 'White',
  'colour.green': 'Green',
  'colour.blue': 'Blue',
  'colour.red': 'Red',
  'colour.yellow': 'Yellow',
  'colour.orange': 'Orange',

  // --- My cards ---
  'cards.title': 'My cards',
  'cards.new': 'New card',
  'cards.import': 'Import a card',
  'cards.preload': 'Preload to the device',
  'cards.preloadHint': 'Choose the cards for the card pages (up to {max}), then tap Upload.',
  'cards.preloadGo': 'Upload {count}',
  'cards.preloadNoPage': 'Preloading needs a card page: set a page to Card under Pages first.',
  'cards.cancel': 'Cancel',
  'cards.empty': 'No cards yet. Tap "New card" to make one; after that one tap shows it on the device.',
  'cards.edit': 'Edit',
  'cards.show': 'Show on the device',
  'cards.select': 'Select',
  'cards.noBackup': 'Not backed up yet. The browser may clear its data when you have not used it for a while: export a backup under Backup.',
  'offer.title': 'No card page yet',
  'offer.body': 'Make page {page} a card page and show this card there?',
  'offer.yes': 'Make it a card page and show',
  'offer.no': 'Not now',

  // --- The card editor ---
  'editor.new': 'New card',
  'editor.edit': 'Edit card',
  'editor.save': 'Save',
  'editor.saveShow': 'Save and show',
  'editor.cancel': 'Cancel',
  'editor.delete': 'Delete card',
  'editor.deleteConfirm': 'Delete this card?',
  'editor.discardConfirm': 'Discard your changes?',
  'editor.export': 'Save as a card file',
  'editor.preview': 'Preview: the 7 colours of the panel',
  'editor.hint': 'Drag a text to move it. Pinch to resize it.',
  'editor.background': 'Background',
  'editor.addText': 'Add text',
  'editor.maxTexts': 'A card holds at most {max} texts.',
  'editor.noTexts': 'No text yet. Tap "Add text".',
  'editor.text': 'Text',
  'editor.textPlaceholder': 'Type here',
  'editor.counter': '{count} / {max}',
  'editor.color': 'Text colour',
  'editor.outline': 'Outline',
  'editor.outlineColor': 'Outline colour',
  'editor.align': 'Alignment',
  'editor.align.left': 'Left',
  'editor.align.center': 'Centre',
  'editor.align.right': 'Right',
  'editor.size': 'Size',
  'editor.width': 'Width',
  'editor.removeText': 'Delete text',
  'editor.drawing': 'Drawing…',

  // --- Photos (card backgrounds and photo pages) ---
  'photo.choose': 'Choose a photo',
  'photo.camera': 'Take a photo',
  'photo.crop': 'Adjust crop…',
  'photo.reading': 'Opening the photo…',
  'crop.title': 'Choose the area',
  'crop.hint': 'Drag to move. Pinch or use the slider to zoom.',
  'crop.zoom': 'Zoom',
  'crop.reset': 'Reset',
  'crop.ok': 'OK',
  'crop.cancel': 'Cancel',
  'photos.title': 'Photos',
  'photos.intro': 'Choose a photo, pick the part that fills the screen, and send it to a photo page.',
  'photos.page': 'Send to',
  'photos.noPhotoPage': 'No page is set to Photo.',
  'photos.makePhotoPage': 'Make page {page} a photo page',
  'photos.mode': 'Show as',
  'photos.fill': 'Fill (crop the extra)',
  'photos.fit': 'Whole photo (white edges)',
  'photos.preview': 'Preview: the 7 colours of the panel',
  'photos.send': 'Send to page {page}',
  'grain.label': 'Grain',
  'grain.standard': 'Standard',
  'grain.soft': 'Soft',
  'grain.softer': 'Softer',
  'grain.smoothest': 'Smoothest',

  // --- Pages ---
  'pages.title': 'Pages',
  'pages.intro': 'The device has 4 pages and its button flips through them. Choose what each page shows.',
  'pages.note':
    'Notes pages are drawn by the computer apps for now; this app sends cards, photos and the day, month and to-do pages. The plan is kept in this app: use the same plan everywhere.',
  'pages.send': 'Send page {page}',
  'pages.bg.title': 'Background photo',
  'pages.bg.hint': 'Optional: the page is drawn on your photo, with white text and a black outline. The photo stays on this phone.',
  'pages.bg.remove': 'Remove the photo',
  'pages.preview': 'Page {page} as the device will show it',
  'calendar.default': 'No calendar is set up yet, so these pages show Taiwan’s public holidays.',
  'calendar.unavailable': 'These pages could not be drawn: the calendar they show could not be loaded. Check the connection and try again.',
  'calendar.sync.intro':
    'Your iPhone’s calendar and reminders reach the device through the Paperhue-Sync Shortcut. It opens this page in Bluefy: keep the phone unlocked and near the device for a minute or two.',
  'calendar.sync.now': 'Sync now',
  'calendar.sync.preview':
    'The previews show Taiwan’s public holidays. Tap Sync now to draw these pages from this iPhone’s calendar and send them to the device.',
  'calendar.sync.install': 'Install the Shortcut',
  'calendar.sync.running': 'Syncing the phone’s calendar to the device. Keep this page open, the phone unlocked and near the device.',
  'calendar.sync.done': 'Sync finished.',
  'calendar.sync.updated': 'Updated: {pages}.',
  'calendar.sync.unchanged': 'Already up to date: {pages}.',
  'calendar.sync.failed': 'The sync did not finish.',
  'calendar.sync.failedAt': 'It stopped at {page}.',
  'calendar.sync.notFound': 'The device was not found within a minute, so nothing was sent. Keep the phone unlocked and near the device, then tap Sync now again.',
  'calendar.sync.notPaired': 'This browser has not been connected to a device yet. Tap Connect and choose the device once, then sync.',
  'calendar.sync.noPages': 'No page is set to show the calendar, so nothing was sent. Set one in Pages.',
  'calendar.sync.unreadable': 'The calendar data from the Shortcut could not be read. Run the Shortcut again.',
  'calendar.android.title': 'Calendars',
  'calendar.android.phoneOn': 'The calendar pages show the calendars on this phone, and the iCal addresses below.',
  'calendar.android.phoneOff': 'Paperhue may not read the calendars on this phone, so the calendar pages show only the iCal addresses below (with none: Taiwan’s public holidays).',
  'calendar.android.allow': 'Use this phone’s calendars',
  'calendar.android.settings': 'If nothing asks: Settings > Apps > Paperhue > Permissions > Calendar.',
  'feed.listTitle': 'iCal addresses',
  'feed.listIntro': 'Optional: calendars that are not on this phone, and to-do lists. An address is a password: it stays on this phone and only its site is shown.',
  'feed.none': 'No iCal address yet.',
  'feed.name': 'Name',
  'feed.url': 'iCal address (starts with https or webcal)',
  'feed.add': 'Add',
  'feed.checking': 'Checking the address…',
  'feed.added': 'Added. It has {events} events and {tasks} to-dos now.',
  'feed.remove': 'Remove {name}',
  'feed.error.url': 'This is not an iCal address: it should start with https or webcal.',
  'feed.error.http': 'HTTP {status}: the address is wrong, was reset, or needs a login.',
  'feed.error.connect': 'The site could not be reached. Check the connection and try again.',
  'feed.error.notIcal': 'What came back is not calendar data: the address may be wrong, or need a login.',
  'calendar.schedule.title': 'Scheduled sync',
  'calendar.schedule.intro':
    'Off until you add a time. At each time Paperhue updates the calendar pages without opening the app, when Bluetooth is on and the phone is near the device; if the device is not found, it tries every 15 minutes for 2 hours. For example, one time in the morning and one in the afternoon.',
  'calendar.schedule.none': 'No time set: the pages are updated only when you send them.',
  'calendar.schedule.time': 'Time',
  'calendar.schedule.add': 'Add time',
  'calendar.schedule.remove': 'Remove {time}',
  'calendar.schedule.battery': 'Android may hold these runs back to save battery. Choose Unrestricted in Settings > Apps > Paperhue > Battery.',
  'calendar.schedule.log': 'Recent runs',
  'calendar.schedule.retry': 'Device not found: trying again at {time}.',
  'calendar.schedule.gaveUp': 'Device not found for 2 hours: skipped this time.',
  'calendar.schedule.notPaired': 'No device yet: connect to the device once in the app.',
  'calendar.schedule.error': 'Did not finish ({detail}).',
  'kind.photo': 'Photo',
  'kind.month': 'Today + month',
  'kind.agenda': 'Today + week',
  'kind.todo': 'To-do',
  'kind.day': 'Day',
  'kind.monthgrid': 'Month',
  'kind.board': 'Notes board',
  'kind.message': 'Big message',
  'kind.card': 'Card',

  // --- Backup ---
  'backup.title': 'Backup',
  'backup.warning':
    "iOS may clear a website's data (cards, backgrounds and settings) when you have not opened it for a while. Export a backup now and then and keep the file in Files or in the cloud.",
  'backup.export': 'Export a backup',
  'backup.import': 'Import a backup',
  'backup.importConfirm': 'Importing replaces all cards and settings here with the ones in the file. Continue?',
  'backup.imported': 'Imported {count} cards.',
  'backup.last': 'Last backup: {date}',
  'backup.never': 'Never backed up.',
  'backup.kept': 'The browser has promised to keep this data.',
  'backup.notKept': 'The browser has not promised to keep this data, so backups matter.',
  'backup.noStorage':
    'This browser does not let the page store data (private mode?). Cards last only until you close the page: export a backup first.',
  'backup.cardImported': 'Added the card from the file.',

  // --- Problems with cards and photos ---
  'error.photoTooLarge': 'This photo is over the 50-megapixel limit. Shrink it, then choose it again.',
  'error.photoUnreadable': 'This photo cannot be opened. Try another one.',
  'error.badFile': 'This file cannot be used: it is not a Paperhue file, or it is damaged. Nothing was changed.',
  'error.saveFailed': 'The browser could not save this. Nothing was changed.',
} as const;

/** Every string the UI uses. */
export type StringKey = keyof typeof en;

const zhTW: Record<StringKey, string> = {
  appName: 'Paperhue 紙彩',
  'title.app': 'Paperhue 紙彩',
  'title.diagnostics': 'Paperhue 紙彩 診斷 — ULANI e-paper',
  openDiagnostics: '開啟診斷頁',
  backToApp: '回到應用程式',
  bluetoothUnsupported: '這個瀏覽器無法使用藍牙。iPhone 請用 Bluefy 瀏覽器開啟本頁；電腦或 Android 請使用 Chrome。',
  'language.other': 'English',
  'language.otherTitle': '改用英文顯示這個頁面',

  'chooser.scanning': '正在搜尋裝置…',
  'chooser.cancel': '取消',
  'chooser.found': '找到的裝置',
  'chooser.none': '找不到裝置',

  'diag.heading': 'Paperhue 紙彩 診斷',
  'diag.intro': '測試這個瀏覽器能不能用藍牙連上 ULANI 永恆曆裝置。從上到下依序按，最後按「複製紀錄」把結果傳回來。',
  'link.notConnected': '未連線',
  'link.connected': '已連線',
  'link.connectedTo': '已連線：{name}',
  'link.lost': '連線中斷，下一個動作會自動重連',
  'link.waiting': '等裝置刷新完畫面：{seconds} 秒後連線',
  'link.reconnecting': '連線中（第 {attempt} 次）…',
  'link.busy': '處理中…',

  'checklist.title': '檢查清單',
  'checklist.summary': 'PASS {pass} · FAIL {fail} · WARN {warn} · 資訊 {info} · 未測 {pending}',
  'badge.pending': '未測',
  'badge.running': '進行中',
  'badge.pass': 'PASS',
  'badge.fail': 'FAIL',
  'badge.warn': 'WARN',
  'badge.info': '資訊',
  'check.webBluetooth': '瀏覽器支援藍牙',
  'check.availability': '藍牙可用',
  'check.secureContext': '安全連線 (https)',
  'check.writeMethods': '寫入方法',
  'check.calendarFeed': '行事曆下載',
  'check.connect': '連線、通知、解鎖',
  'check.deviceInfo': '型號與韌體',
  'check.battery': '讀取電量',
  'check.page': '讀取目前頁面',
  'check.switch': '切換頁面',
  'check.upload': '傳送測試圖',
  'check.disconnect': '中斷連線',

  'value.present': '有',
  'value.absent': '沒有',
  'value.true': '是',
  'value.false': '否',
  'value.unknown': '不明',
  'value.unreadable': '讀不到',
  'value.unreadableBecause': '讀不到：{detail}',
  'value.none': '無',
  'value.charging': '充電中',
  'page.n': '第 {page} 頁',

  'browser.title': '檢查瀏覽器',
  'browser.row.bluetooth': 'Web Bluetooth',
  'browser.row.availability': '藍牙可用',
  'browser.row.secure': '安全連線',
  'browser.row.methods': '寫入方法',
  'browser.row.agent': '瀏覽器',
  'browser.availability.yes': '可用',
  'browser.availability.no': '不可用（藍牙關閉或沒有權限）',
  'browser.availability.missing': '無法事先判斷（沒有 getAvailability）',
  'browser.availability.timeout': '沒有回應',
  'browser.availability.error': '錯誤：{error}',
  'browser.methodsAfterConnect': '連上裝置後才能確認（這個瀏覽器沒有公開 BluetoothRemoteGATTCharacteristic）',
  'browser.methodsFromDevice': '已連線裝置上實際的方法',
  'browser.checkAgain': '重新檢查',
  'verdict.noBluetooth': '沒有 navigator.bluetooth',
  'verdict.insecure': '不是安全連線 ({protocol})',
  'verdict.cannotTell': '無法判斷',
  'verdict.availabilityOff': 'getAvailability() = false：藍牙關閉或沒有權限',
  'verdict.availabilityMissing': '沒有 getAvailability()，連線時才知道',
  'verdict.availabilityTimeout': 'getAvailability() 沒有回應',
  'verdict.availabilityError': 'getAvailability() 失敗：{error}',
  'verdict.noCharacteristic': '連上裝置後確認：這個瀏覽器沒有公開 BluetoothRemoteGATTCharacteristic',
  'verdict.deviceMethods': '{methods}（裝置圖片特徵值上的方法）',
  'verdict.noWithoutResponse': '{methods}（沒有 writeValueWithoutResponse，「自動」會改用其他方法）',

  'feed.title': '行事曆下載測試',
  'feed.intro':
    '不需要藍牙。按下按鈕後，這個瀏覽器會直接（不經過任何中轉）從 Google 日曆下載公開的台灣國定假日行事曆（iCal），看看在這裡能不能取得行事曆資料。',
  'feed.button': '測試下載',
  'feed.row.result': '結果',
  'feed.row.status': 'HTTP 狀態',
  'feed.row.size': '大小',
  'feed.row.format': '內容',
  'feed.row.time': '耗時',
  'feed.result.pass': 'PASS 可以下載',
  'feed.result.blocked': 'BLOCKED 被擋下',
  'feed.result.unexpected': '不是行事曆資料',
  'feed.size': '{bytes} bytes',
  'feed.format.ok': '以 BEGIN:VCALENDAR 開頭（{events} 個事件）',
  'feed.format.bad': '不是以 BEGIN:VCALENDAR 開頭',
  'feed.explain.pass': '這個瀏覽器可以直接下載行事曆，行事曆頁面可以在這裡同步。',
  'feed.explain.blocked': '瀏覽器擋下了下載（CORS 或網路錯誤），所以在這個瀏覽器裡無法同步行事曆頁面。',
  'feed.explain.unexpected': '有下載到東西，但不是行事曆資料（HTTP {status}），所以目前無法同步行事曆頁面。請稍後再試。',

  'connect.title': '連線',
  'connect.note':
    '這支手機第一次連線前，先按住裝置的按鈕約 5 秒，直到燈號閃綠燈（配對模式）。按「連線」後會跳出藍牙裝置清單，請選名稱以 ULANI 開頭的裝置；手機要求配對時請按「配對」。',
  'connect.button': '連線',
  'connect.pairingHint': '第一次用這支手機連線？請長按裝置按鍵約 5 秒，綠燈閃爍（配對模式）後再按連線。',
  'device.row.name': '裝置名稱',
  'device.row.model': '型號',
  'device.row.firmware': '韌體',
  'device.row.kind': '連線方式',

  'status.title': '讀取狀態',
  'status.button': '讀取狀態',
  'status.row.battery': '電量',
  'status.row.page': '目前頁面',

  'switch.title': '切換頁面',
  'switch.note': '切換後電子紙會重畫畫面，需要一點時間。',
  'switch.shown': '目前顯示：第 {page} 頁',
  'switch.shownUnknown': '目前頁面：未知',

  'upload.title': '傳送測試圖',
  'upload.note':
    '傳到「目前顯示中」的頁面時，裝置收完圖會馬上刷新面板，大約 40 秒內不回應任何指令。想多測幾次，請傳到其他頁面，再用「切換頁面」看結果。',
  'upload.onScreenWarning': '注意：這是目前顯示中的頁面。傳完後面板會刷新約 40 秒，期間裝置不回應。',
  'upload.page': '頁面',
  'upload.onScreen': '顯示中',
  'upload.mode': '寫入方式',
  'upload.mode.auto': '自動',
  'upload.mode.withoutResponse': '不等回應',
  'upload.mode.withResponse': '等回應（裝置允許時才用）',
  'upload.chunk': '封包大小（bytes）',
  'upload.flush': '同步間隔',
  'upload.flush.off': '不同步',
  'upload.flush.every': '每 {count} 包',
  'upload.resend': '重送上一張圖（同一頁應該得到「未變更」）',
  'upload.preview': '測試圖預覽',
  'upload.keepOn': '傳送時請保持螢幕亮著，不要鎖定螢幕或切換到其他 App，直到傳完。',
  'upload.send': '傳送測試圖',
  'upload.stop': '停止',
  'upload.waiting': '解鎖並等待裝置接受…',
  'upload.progress': '{percent}% · {sent} / {total} bytes · {time}',
  'upload.progressDone': '{percent}% · {sent} / {total} bytes · {time}，等待裝置確認…',
  'upload.showPageN': '切換到第 {page} 頁看結果',
  'result.row.outcome': '結果',
  'result.row.total': '總耗時',
  'result.row.data': '傳送資料',
  'result.row.speed': '速度',
  'result.row.wait': '等待確認',
  'result.row.packets': '封包',
  'result.ok': '成功',
  'result.unchanged': '未變更（這頁已有同一張圖，沒有傳資料）',
  'result.stopped': '已停止',
  'result.error': '失敗',
  'result.packets': '{count} × {size} bytes',
  'result.packetsLimited': '{count} × {size} bytes（這種連線方式不能調整部分設定）',
  'refresh.redrawing': '裝置正在刷新畫面（約剩 {seconds} 秒）；這段時間如果斷線，會自動重新連線。',
  'refresh.done': '裝置應該已經刷新完畫面。',

  'disconnect.title': '中斷連線',
  'disconnect.button': '中斷連線',

  'log.title': '紀錄',
  'log.copy': '複製紀錄',
  'log.clear': '清除紀錄',
  'log.copied': '已複製，請貼到訊息裡傳回來。',
  'log.copyManually': '無法自動複製，請長按下方文字全選後複製。',

  'note.firmwareUnreadable': '{parts}；讀不到韌體，同步間隔請選「不同步」',
  'note.uploadOk': '第 {page} 頁，{details}',
  'note.uploadStopped': '已停止（{sent} / {total} bytes）',
  'note.uploadUnchanged': '第 {page} 頁已有同一張圖，沒有傳資料',

  'report.title': 'Paperhue 紙彩 診斷紀錄',
  'report.time': '時間',
  'report.page': '網頁',
  'report.checklist': '檢查清單',
  'report.feed': '行事曆下載',
  'report.device': '裝置',
  'report.status': '狀態',
  'report.uploads': '上傳',
  'report.log': '紀錄',
  'report.empty': '（空白）',

  'error.stopped': '已停止。',
  'error.notConnected': '還沒連上裝置。請先按「連線」。',
  'error.noReply': '裝置沒有回應。{hint}',
  'error.busy': '裝置一直沒有空（可能還在刷新面板）。請等一分鐘再試。',
  'error.uploadRejected':
    '裝置拒收這張圖（資料不完整或檢查碼不符）。可以試試較小的封包或較小的同步間隔，並在傳送時保持螢幕亮著。',
  'error.protocol': '裝置的回應和預期不同。請把紀錄複製下來回報。',
  'error.connectStale':
    '試了 {attempts} 次都連不上裝置：每次都在配對加密時斷線。{hint}如果這支手機以前和裝置配對過，表示配對已失效：{steps}',
  'error.connectFailed': '試了 {attempts} 次都連不上裝置。{cause}',
  'error.device': '和裝置溝通時發生錯誤。請把紀錄複製下來回報。',
  'error.unexpected': '發生未預期的錯誤。請把紀錄複製下來回報。',
  'error.refreshHint': '如果剛把圖傳到顯示中的頁面，面板會刷新約 40 秒，這段時間裝置不回應，請稍候再試。',
  'error.repairSteps':
    '請到手機的「設定 > 藍牙」對這台裝置按「忘記此裝置」，再按住裝置的按鈕約 5 秒，直到燈號閃綠燈（配對模式），然後按「連線」並同意配對。',
  'error.locationHint': 'Android 11 以前的手機要開啟「定位」才找得到藍牙裝置，請到手機設定打開定位後再試。',
  'error.noWriteMethod': '這個瀏覽器沒有這種寫入方法，請把「寫入方式」改回「自動」再試。',
  'error.withResponseRefused': '裝置不接受「等回應」的寫入方式。請把「寫入方式」改回「自動」再試。',
  'error.firmwareUnreadable': '這個瀏覽器讀不到裝置的韌體版本，所以不能用「同步間隔」。請把同步間隔設為「不同步」再試。',
  'error.notPermitted':
    '裝置或瀏覽器不允許這個藍牙操作，再試也不會成功。請把「寫入方式」改回「自動」；仍然失敗的話，請把紀錄複製下來回報。',
  'error.locationOff': '手機的「定位」沒有開啟。{hint}',
  'error.unavailable': '藍牙沒有開啟，或這個瀏覽器沒有藍牙權限。請打開手機的藍牙，並允許這個瀏覽器使用藍牙後再試。',
  'error.cancelled': '已取消：沒有選擇裝置，或連線被中止。',
  'error.cancelledEmptyList': '如果清單一直是空的：{hint}',
  'error.notFound': '找不到裝置。請把手機靠近裝置，稍等幾秒再按一次「連線」。',
  'error.bondLost': '裝置拒絕加密連線（配對失效）。{steps}',
  'error.linkLostPairing':
    '藍牙連線在配對加密時中斷了。{hint}如果這支手機以前和裝置配對過，而且每次都這樣，可能是配對失效：{steps}',
  'error.droppedWhileConnecting': '裝置在連線途中切斷了藍牙連線。{hint}',
  'error.linkLost': '藍牙連線中斷了。請再試一次；需要的話先按「連線」重新連上。',
  'error.droppedWhileRedrawing': '裝置刷新畫面時會切斷藍牙連線，這是正常的；會自動重新連線，連上後再試一次。',
  'error.timeout': '藍牙操作等太久沒有完成。{hint}',

  // --- The app: sections, status, jobs ---
  'app.tabs': '功能',
  'app.tab.cards': '我的牌卡',
  'app.tab.photos': '照片',
  'app.tab.pages': '頁面',
  'app.tab.backup': '備份',
  'app.device': '裝置',
  'app.dismiss': '關閉',
  'job.connecting': '正在連線…',
  'job.preparing': '正在準備圖片…',
  'job.sending': '正在傳送第 {page} 頁… {percent}%',
  'notice.card': '已顯示在第 {page} 頁。',
  'notice.cardSwitched': '已切換到第 {page} 頁：裝置上本來就有這張牌卡。',
  'notice.cardAlready': '第 {page} 頁已經在顯示這張牌卡。',
  'notice.preload': '已把 {count} 張牌卡放進牌卡頁。',
  'notice.photo': '已把照片傳到第 {page} 頁。',
  'notice.photoUnchanged': '第 {page} 頁已經是這張照片。',
  'notice.calendar': '已把第 {page} 頁傳到裝置。',
  'notice.calendarUnchanged': '第 {page} 頁已經是這個內容。',

  // --- Colours ---
  'colour.black': '黑',
  'colour.white': '白',
  'colour.green': '綠',
  'colour.blue': '藍',
  'colour.red': '紅',
  'colour.yellow': '黃',
  'colour.orange': '橘',

  // --- My cards ---
  'cards.title': '我的牌卡',
  'cards.new': '新增牌卡',
  'cards.import': '匯入牌卡檔',
  'cards.preload': '預載到裝置',
  'cards.preloadHint': '選擇要放進牌卡頁的牌卡（最多 {max} 張），再按「上傳」。',
  'cards.preloadGo': '上傳 {count} 張',
  'cards.preloadNoPage': '預載需要牌卡頁：請先到「頁面」把某一頁設為牌卡。',
  'cards.cancel': '取消',
  'cards.empty': '還沒有牌卡。按「新增牌卡」做一張；之後點一下就能顯示在裝置上。',
  'cards.edit': '編輯',
  'cards.show': '顯示在裝置上',
  'cards.select': '選取',
  'cards.noBackup': '還沒有備份過。瀏覽器可能在你一段時間沒用後清除資料，請到「備份」匯出備份檔。',
  'offer.title': '還沒有牌卡頁',
  'offer.body': '要把第 {page} 頁改成牌卡頁，並把這張牌卡顯示在那裡嗎？',
  'offer.yes': '改成牌卡頁並顯示',
  'offer.no': '先不要',

  // --- The card editor ---
  'editor.new': '新增牌卡',
  'editor.edit': '編輯牌卡',
  'editor.save': '儲存',
  'editor.saveShow': '儲存並顯示',
  'editor.cancel': '取消',
  'editor.delete': '刪除牌卡',
  'editor.deleteConfirm': '要刪除這張牌卡嗎？',
  'editor.discardConfirm': '要放棄修改嗎？',
  'editor.export': '存成牌卡檔',
  'editor.preview': '預覽：面板的 7 種顏色',
  'editor.hint': '拖曳文字可以移動，兩指捏合可以調整大小。',
  'editor.background': '背景',
  'editor.addText': '加文字',
  'editor.maxTexts': '一張牌卡最多 {max} 個文字。',
  'editor.noTexts': '還沒有文字。按「加文字」。',
  'editor.text': '文字',
  'editor.textPlaceholder': '在這裡輸入',
  'editor.counter': '{count} / {max}',
  'editor.color': '文字顏色',
  'editor.outline': '外框',
  'editor.outlineColor': '外框顏色',
  'editor.align': '對齊',
  'editor.align.left': '靠左',
  'editor.align.center': '置中',
  'editor.align.right': '靠右',
  'editor.size': '字級',
  'editor.width': '寬度',
  'editor.removeText': '刪除文字',
  'editor.drawing': '正在繪製…',

  // --- Photos (card backgrounds and photo pages) ---
  'photo.choose': '選擇照片',
  'photo.camera': '拍照',
  'photo.crop': '調整範圍…',
  'photo.reading': '正在開啟照片…',
  'crop.title': '選擇範圍',
  'crop.hint': '拖曳移動；兩指捏合或用滑桿縮放。',
  'crop.zoom': '縮放',
  'crop.reset': '重設',
  'crop.ok': '確定',
  'crop.cancel': '取消',
  'photos.title': '照片',
  'photos.intro': '選一張照片，決定哪一部分填滿畫面，再傳到照片頁。',
  'photos.page': '傳到',
  'photos.noPhotoPage': '沒有頁面設為「照片」。',
  'photos.makePhotoPage': '把第 {page} 頁設為照片頁',
  'photos.mode': '顯示方式',
  'photos.fill': '填滿畫面（裁切多餘部分）',
  'photos.fit': '完整顯示（留白邊）',
  'photos.preview': '預覽：面板的 7 種顏色',
  'photos.send': '傳到第 {page} 頁',
  'grain.label': '顆粒感',
  'grain.standard': '標準',
  'grain.soft': '柔和',
  'grain.softer': '更柔和',
  'grain.smoothest': '最平滑',

  // --- Pages ---
  'pages.title': '頁面',
  'pages.intro': '裝置有 4 頁，按它的按鈕會一頁一頁切換。這裡決定每一頁放什麼。',
  'pages.note':
    '留言頁目前由電腦版繪製；這個 App 傳送牌卡、照片，以及日、月、待辦等頁面。頁面安排只存在這個 App 裡，每個 App 請用同樣的安排。',
  'pages.send': '傳送第 {page} 頁',
  'pages.bg.title': '背景照片',
  'pages.bg.hint': '選用：頁面會畫在你的照片上，文字為白色加黑色外框。照片只留在這支手機。',
  'pages.bg.remove': '移除照片',
  'pages.preview': '第 {page} 頁在裝置上的樣子',
  'calendar.default': '尚未設定行事曆，這些頁面先顯示台灣的公共假日。',
  'calendar.unavailable': '無法畫出這些頁面：讀不到它們要顯示的行事曆。請檢查網路後再試。',
  'calendar.sync.intro':
    'iPhone 的行事曆與提醒事項，透過「Paperhue-Sync」捷徑送到裝置。捷徑會在 Bluefy 開啟本頁，請讓手機保持解鎖，並放在裝置附近一兩分鐘。',
  'calendar.sync.now': '立即同步',
  'calendar.sync.preview': '預覽先用台灣的公共假日。按「立即同步」後，這些頁面會用這支 iPhone 的行事曆畫好，並傳到裝置。',
  'calendar.sync.install': '安裝捷徑',
  'calendar.sync.running': '正在把手機的行事曆同步到裝置。請保持本頁開啟、手機解鎖，並靠近裝置。',
  'calendar.sync.done': '同步完成。',
  'calendar.sync.updated': '已更新：{pages}。',
  'calendar.sync.unchanged': '本來就是最新：{pages}。',
  'calendar.sync.failed': '同步沒有完成。',
  'calendar.sync.failedAt': '停在{page}。',
  'calendar.sync.notFound': '一分鐘內找不到裝置，所以沒有傳送任何東西。請把手機解鎖並靠近裝置，再按「立即同步」。',
  'calendar.sync.notPaired': '這個瀏覽器還沒連線過裝置。請先按「連線」選擇一次裝置，再同步。',
  'calendar.sync.noPages': '沒有任何一頁設為行事曆頁，所以沒有傳送任何東西。請到「頁面」設定。',
  'calendar.sync.unreadable': '讀不到捷徑傳來的行事曆資料。請重新執行捷徑。',
  'calendar.android.title': '行事曆',
  'calendar.android.phoneOn': '行事曆頁顯示這支手機上的行事曆，以及下面的 iCal 網址。',
  'calendar.android.phoneOff': 'Paperhue 沒有讀取這支手機行事曆的權限，所以行事曆頁只顯示下面的 iCal 網址（沒有網址時顯示台灣的公共假日）。',
  'calendar.android.allow': '使用這支手機的行事曆',
  'calendar.android.settings': '如果沒有跳出詢問：設定 > 應用程式 > Paperhue > 權限 > 日曆。',
  'feed.listTitle': 'iCal 網址',
  'feed.listIntro': '選用：不在這支手機上的行事曆，以及待辦清單。網址等同密碼：只存在這支手機，畫面上只顯示網站名稱。',
  'feed.none': '還沒有 iCal 網址。',
  'feed.name': '名稱',
  'feed.url': 'iCal 網址（https 或 webcal 開頭）',
  'feed.add': '新增',
  'feed.checking': '正在檢查網址…',
  'feed.added': '已新增。目前有 {events} 個行程、{tasks} 項待辦。',
  'feed.remove': '移除「{name}」',
  'feed.error.url': '這不是 iCal 網址：開頭應為 https 或 webcal。',
  'feed.error.http': 'HTTP {status}：網址不對、已被重設，或需要登入。',
  'feed.error.connect': '連不到這個網站。請檢查網路後再試。',
  'feed.error.notIcal': '收到的不是行事曆資料：網址可能不對，或需要登入。',
  'calendar.schedule.title': '定時同步',
  'calendar.schedule.intro':
    '加入時間後才會開始。每到設定的時間，只要藍牙開著、手機在裝置附近，Paperhue 就會在背景更新行事曆頁，不必打開 App；找不到裝置時，兩小時內每 15 分鐘再試一次。例如早上一次、下午一次。',
  'calendar.schedule.none': '尚未設定時間：只有你按傳送時才會更新頁面。',
  'calendar.schedule.time': '時間',
  'calendar.schedule.add': '加入時間',
  'calendar.schedule.remove': '移除 {time}',
  'calendar.schedule.battery': 'Android 可能為了省電而延後這些同步。請到 設定 > 應用程式 > Paperhue > 電池，選擇「不受限制」。',
  'calendar.schedule.log': '最近幾次',
  'calendar.schedule.retry': '找不到裝置：{time} 再試一次。',
  'calendar.schedule.gaveUp': '兩小時內都找不到裝置，這次略過。',
  'calendar.schedule.notPaired': '還沒有裝置：請先在 App 裡連線一次裝置。',
  'calendar.schedule.error': '沒有完成（{detail}）。',
  'kind.photo': '照片',
  'kind.month': '本日＋月曆',
  'kind.agenda': '本日行程＋一週行程',
  'kind.todo': '待辦清單',
  'kind.day': '日',
  'kind.monthgrid': '月曆',
  'kind.board': '留言板',
  'kind.message': '大字留言',
  'kind.card': '牌卡',

  // --- Backup ---
  'backup.title': '備份',
  'backup.warning':
    'iPhone 的瀏覽器可能在你一段時間沒開這個網頁後，清除它的資料（牌卡、背景和設定）。請定期匯出備份檔，存到「檔案」或雲端。',
  'backup.export': '匯出備份',
  'backup.import': '匯入備份',
  'backup.importConfirm': '匯入會用檔案裡的牌卡和設定取代這裡現有的全部內容。要繼續嗎？',
  'backup.imported': '已匯入 {count} 張牌卡。',
  'backup.last': '上次備份：{date}',
  'backup.never': '還沒有備份過。',
  'backup.kept': '瀏覽器已答應保留這些資料。',
  'backup.notKept': '瀏覽器沒有保證保留這些資料，所以備份很重要。',
  'backup.noStorage': '這個瀏覽器不讓網頁儲存資料（也許是無痕模式）。牌卡只會留到你關掉頁面為止，請先匯出備份。',
  'backup.cardImported': '已加入檔案裡的牌卡。',

  // --- Problems with cards and photos ---
  'error.photoTooLarge': '照片超過 5000 萬像素的上限，請先縮小再選。',
  'error.photoUnreadable': '這張照片打不開，請換一張試試。',
  'error.badFile': '這個檔案不能用：它不是 Paperhue 的檔案，或內容有問題。沒有任何東西被改動。',
  'error.saveFailed': '瀏覽器無法儲存。沒有任何東西被改動。',
};

const tables: Readonly<Record<Locale, Readonly<Record<StringKey, string>>>> = { 'zh-TW': zhTW, en };

/** Every key, in the order of the English table. */
export const STRING_KEYS: readonly StringKey[] = Object.freeze(Object.keys(en) as StringKey[]);

/** Values for the `{name}` placeholders of a string. */
export type Params = Readonly<Record<string, string | number>>;

/** The raw string for `key` in `locale`, placeholders unfilled. */
export function template(key: StringKey, locale: Locale): string {
  return tables[locale][key];
}

/** The `{name}` placeholders of a template, sorted. */
export function placeholders(text: string): string[] {
  return [...text.matchAll(/\{(\w+)\}/g)].map((match) => match[1] ?? '').sort();
}

function fill(text: string, params: Params | undefined): string {
  if (!params) return text;
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => (name in params ? String(params[name]) : whole));
}

/** The string for `key` in `locale` (default: the current locale), placeholders filled from `params`. */
export function t(key: StringKey, params?: Params, locale: Locale = current): string {
  return fill(tables[locale][key], params);
}

// --- Text in both languages ---------------------------------------------------------------

/** One text in every locale, e.g. a checklist note that must follow the language button. */
export type Localized = Readonly<Record<Locale, string>>;

/** `render` for every locale. */
export function localize(render: (locale: Locale) => string): Localized {
  return { 'zh-TW': render('zh-TW'), en: render('en') };
}

/** The same text in every locale (a name, a number, a technical value). */
export function same(text: string): Localized {
  return { 'zh-TW': text, en: text };
}

/** t() in every locale. */
export function message(key: StringKey, params?: Params): Localized {
  return localize((locale) => t(key, params, locale));
}

// --- Which language -----------------------------------------------------------------------

/**
 * The UI locale for a browser's preferred languages (navigator.languages):
 * the first Chinese (zh-*) or English entry decides; with neither, or with
 * no preferences at all, English.
 */
export function pickLocale(languages: readonly string[]): Locale {
  for (const tag of languages) {
    const primary = tag.toLowerCase().split('-')[0];
    if (primary === 'zh') return 'zh-TW';
    if (primary === 'en') return 'en';
  }
  return 'en';
}

/** BCP 47 tag for the `lang` attribute of the page. */
export function htmlLang(locale: Locale): string {
  return locale === 'zh-TW' ? 'zh-Hant-TW' : 'en';
}

export function otherLocale(locale: Locale): Locale {
  return locale === 'zh-TW' ? 'en' : 'zh-TW';
}

export function isLocale(value: unknown): value is Locale {
  return value === 'zh-TW' || value === 'en';
}

/** Where the language button's choice is kept (localStorage). */
export const LOCALE_STORAGE_KEY = 'paperhue.locale';

/** The part of `Storage` the locale needs; tests pass a stand-in. */
export interface LocaleStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/** localStorage, or undefined where the browser refuses it (private mode, blocked site data). */
function browserStore(): LocaleStore | undefined {
  try {
    const storage = (globalThis as { localStorage?: LocaleStore }).localStorage;
    return storage ?? undefined;
  } catch {
    return undefined;
  }
}

/** The saved choice, if any and readable. */
export function savedLocale(store: LocaleStore | undefined = browserStore()): Locale | undefined {
  try {
    const value = store?.getItem(LOCALE_STORAGE_KEY);
    return isLocale(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

/** Save the choice; false when it could not be saved (the page still works). */
export function saveLocale(locale: Locale, store: LocaleStore | undefined = browserStore()): boolean {
  if (!store) return false;
  try {
    store.setItem(LOCALE_STORAGE_KEY, locale);
    return true;
  } catch {
    return false;
  }
}

function browserLanguages(): readonly string[] {
  const nav = typeof navigator === 'undefined' ? undefined : navigator;
  if (nav?.languages?.length) return nav.languages;
  return nav?.language ? [nav.language] : [];
}

let current: Locale = 'zh-TW';
const listeners = new Set<(locale: Locale) => void>();

export interface DetectOptions {
  /** Default navigator.languages. */
  readonly languages?: readonly string[];
  /** Default localStorage. */
  readonly store?: LocaleStore;
}

/**
 * Pick the locale (the saved choice, else the browser's preferences), use it
 * and return it.
 */
export function detectLocale(options: DetectOptions = {}): Locale {
  const store = 'store' in options ? options.store : browserStore();
  current = savedLocale(store) ?? pickLocale(options.languages ?? browserLanguages());
  return current;
}

/** Use `locale` and tell the listeners when it changed. */
export function setLocale(locale: Locale): void {
  if (locale === current) return;
  current = locale;
  for (const listener of [...listeners]) listener(locale);
}

export function getLocale(): Locale {
  return current;
}

/** What the language button does: switch to the other language and remember the choice. */
export function toggleLocale(store: LocaleStore | undefined = browserStore()): Locale {
  const next = otherLocale(current);
  saveLocale(next, store);
  setLocale(next);
  return next;
}

/** Called with the new locale whenever it changes. */
export function onLocaleChange(listener: (locale: Locale) => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
