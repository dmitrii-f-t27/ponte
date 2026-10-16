# Ponte 0.1.14 → 0.1.15: полный проход по production-коду и перенос оставшихся решений в t27

Дата: 2026-10-15. Версия 0.1.15, build 16 (`Resources/Info.plist`, `camera/extension/manifest.json`).
Отчёт о прошлом этапе (`reports/camera-t27-2026-10-15.md`) не менялся: его проверки относятся к коду 0.1.14.

Что не изменилось: ключ и ID расширения (`jinldckdcbeojhpahpkagmacfdapfnln`), Origin, порт 47839 только на 127.0.0.1,
`host_permissions`, протокол связи с расширением и протокол релея, коды закрытия и лимиты.

**Это снимок локальных проверок** на 2026-10-15, 21:49 BRT, сделанный до коммита и публикации. Всё, что ниже сказано
о публикации и установке, относится к этому моменту. GitHub Actions CI в репозитории не настроен: все результаты
получены локально, CI-статуса нет.

**Состояние на момент проверок.**

- Код 0.1.15 записал исполнитель. Координатор проверил его локально (раздел 7): генерация C и WebAssembly,
  константы, векторы, релей, `swift test`, оба e2e камеры, faults, файловый конвейер речи, release-сборка и подпись.
  Всё прошло после одного исправления: первый запуск генерации упал на комментариях спеки, не в ASCII.
- **Не проверено:**
  - 0.1.15 на настоящей камере и GPU — последний hardware PASS (Apple M4) был на 0.1.14,
    `reports/camera-t27-2026-10-15.md`;
  - живой звонок Google Meet с другим говорящим участником.
- Release 0.1.15 собран и подписан. На момент этих локальных проверок он ещё не был опубликован и установлен; в
  приложении 0.1.14 у владельца ничего не менялось.

## 1. Как искали

- Каждый production-файл прочитан один раз (раздел 2). Все целиком, кроме двух фасадов, о которых ниже. Я не
  ограничивался поиском по числам и литералам.
- Фасады прочитаны так:
  - целиком: `AppRules.swift`, `TextRules.swift`, `AnalysisRules.swift`, `PeerRules.swift`, `CameraRules.swift`,
    `policy.js`, `rules.js`;
  - не целиком: `AudioRules.swift` и `SpeechRules.swift`. Исполнитель просмотрел в них все места с логикой (поиск по
    `if`, `for`, `while`, `guard`, `switch`, тернарным выражениям, `filter`, `sorted`, `first(where:)`, `contains` и
    чтение найденного) и отдельные участки.

  Итог по исполнителю: 68 из 70 production-файлов прочитаны целиком, в двух фасадах — все места с логикой. Затем
  координатор прочитал оба фасада целиком (985 строк `AudioRules.swift`, 582 строки `SpeechRules.swift`) и новой
  политики не нашёл. Реестр сверен с `git ls-files`: 70 отслеживаемых production-файлов, ни один не пропущен.

  В просмотренных местах логика только маршалинговая: буферы, флаги вместо optional, перевод кодов.
- Для каждого места с условием, сравнением, выбором или вычислением решалось одно из двух:
  - это правило, и оно переносится в t27;
  - это законная нативная граница, и для неё записана причина (раздел 5).
- Если комментарий спеки описывал правило, которое код не выполнял, это считалось находкой. Так было у
  `cm_report_error_rank` (выбор среди равных) и у `dv_is_hear_output` (selectable).

Найдено девять решений, которые ещё принимались в Swift и JavaScript. По review добавлено десятое: первая проверка
приёма кадра в `PeerLink.open` (свой кадр или чужой, вместе со свежестью). Первоначально я ошибочно отнёс его к
нативным границам. Ещё в двух местах вместо вызова уже
существующего правила спеки было записано то же условие. Всё это перенесено (раздел 3). Поведение не менялось: доказанных
ошибок среди найденного нет, поэтому намеренных изменений ответов тоже нет.

## 2. Реестр файлов

В реестр не входят как продукт:

- сгенерированный `Sources/PonteSpecs/*`;
- сгенерированные `camera/extension/cm.wasm` и `relay/rl.wasm`;
- пробники `Sources/{AudioProbe,SpeechProbe,PeerProbe,CameraProbe}`;
- стенды `camera/test/*`, `relay/test.mjs`, `Tests/*`;
- сборочные скрипты `scripts/*`, `camera/build-wasm.sh`, `relay/build-wasm.sh`;
- `relay/node_modules`.

Изменены только те стенды и скрипты, что названы в разделе 6.

| Файл | Прочитан | Итог |
|---|---|---|
| `Sources/PonteCore/Contracts.swift` | целиком | чисто: `Direction`/`Lang` переводят коды `ln_dir_*`; протоколы и структуры |
| `Sources/PonteCamera/CameraRules.swift` | целиком | фасад; **добавлен** `reportErrorTakes` |
| `Sources/PonteCamera/CameraLink.swift` | целиком | **перенесено**: выбор ошибки среди равных → `cm_report_error_takes`; остальное — протокол (5) |
| `Sources/PonteApp/AppModel.swift` | целиком | **перенесено**: список наушников → `headphoneChoices` (`dv_is_headphones_choice`); остальное вызывает спеки, тексты баннеров |
| `Sources/PonteApp/AppRules.swift` | целиком | фасад, только маршалинг |
| `Sources/PonteApp/TextRules.swift` | целиком | фасад, только маршалинг |
| `Sources/PonteApp/TranslationLane.swift` | целиком | чисто: все шаги через `AppRules`; потоки, блокировки, поколения |
| `Sources/PonteApp/CameraModel.swift` | целиком | чисто: настройки через `CameraRules`, копирование файлов расширения |
| `Sources/PonteApp/CameraPanel.swift` | целиком | чисто: тексты, иконки, цвета по кодам `cm_link_panel` |
| `Sources/PonteApp/SettingsView.swift` | целиком | **перенесено**: фильтр «Мои наушники» |
| `Sources/PonteApp/AnalysisSettingsView.swift` | целиком | **перенесено**: условие «Вернуть по умолчанию» → `an_offers_reset` |
| `Sources/PonteApp/CallAnalysisModel.swift` | целиком | чисто: решения через `AnalysisRules`; поколения, задачи |
| `Sources/PonteApp/CallReportExporter.swift`, `CallReportView.swift` | целиком | чисто: разметка TXT и окна |
| `Sources/PonteApp/ChecklistView.swift`, `Components.swift`, `MainView.swift`, `PeerPanel.swift`, `SetupWizardView.swift`, `SubtitleOverlay.swift` | целиком | чисто: представление по кодам спек |
| `Sources/PonteApp/Glossary.swift` | целиком | граница Unicode (5) |
| `Sources/PonteApp/LaunchOptions.swift`, `Permissions.swift`, `Preferences.swift`, `PushToTalkMonitor.swift`, `PonteMain.swift` | целиком | чисто: разбор аргументов, перевод перечислений ОС, мониторы NSEvent |
| `Sources/PonteApp/TestFileSource.swift`, `WAVFileSink.swift`, `TranscriptExporter.swift` | целиком | чисто: тестовый ввод-вывод, файлы, разметка Markdown |
| `Sources/PonteAudio/AudioRules.swift` | исполнитель: все места с логикой; координатор: целиком | фасад; **добавлены** `isHeadphonesChoice`, `isSelectableOutput` |
| `Sources/PonteAudio/CoreAudioDeviceCatalog.swift` | целиком | **перенесено**: `isSelectableOutput` → `dv_is_selectable_output` |
| `Sources/PonteAudio/AudioProcesses.swift` | целиком | **вызов существующего правила**: «обычное приложение» в обходе родителей → `dv_is_regular_app` |
| `Sources/PonteAudio/DeviceAudioPlayer.swift` | целиком | **вызов существующего правила**: «устройство выводит звук» → `dv_is_output` |
| `Sources/PonteAudio/AppAudioTapSource.swift`, `MicSource.swift`, `LiveRelay.swift`, `PlayerBook.swift`, `FileSource.swift`, `HAL.swift`, `PCM.swift`, `AudioInputReaders.swift`, `RunningAudioAppCatalog.swift`, `BlackHoleCheck.swift`, `Diagnostics.swift`, `PonteAudio.swift` | целиком | чисто: Core Audio, AVFoundation, учёт; решения через `AudioRules` |
| `Sources/PonteSpeech/AnalysisRules.swift` | целиком | фасад; **добавлены** `keyDeleteOK`, `offersReset` |
| `Sources/PonteSpeech/AnalysisKeychain.swift` | целиком | **перенесено**: «удаление ключа удалось» → `an_key_delete_ok` |
| `Sources/PonteSpeech/SpeechRules.swift` | исполнитель: все места с логикой; координатор: целиком | фасад, только маршалинг |
| `Sources/PonteSpeech/AppleTranscriber.swift`, `AppleTranslator.swift`, `RoutingTranslator.swift`, `ClaudeTranslator.swift`, `SystemSpeechSynth.swift`, `VoiceActivity.swift`, `AudioConversion.swift`, `CallAnalyst.swift`, `PonteSpeech.swift` | целиком | чисто: SpeechAnalyzer, Translation, URLSession, JSON, промпты; решения через `SpeechRules`/`AnalysisRules` |
| `Sources/PontePeer/PeerRules.swift` | целиком | фасад; **добавлены** `micSends`, `frameAccepted` |
| `Sources/PontePeer/PeerSession.swift` | целиком | **перенесено**: `PeerMicGate.push` — `open && vadSends` → `pe_mic_sends` |
| `Sources/PontePeer/PeerLink.swift` | целиком | **перенесено по review**: первая проверка приёма в `open` (`peer != sender`, свежесть) → `pe_frame_accepted`; остальное — шифрование, байты кадра по смещениям спеки, сокет |
| `Sources/PonteObjC/PonteObjC.m`, `include/PonteObjC.h` | целиком | чисто: перехват исключений Objective-C |
| `camera/extension/policy.js` | целиком | адаптер cm.wasm; **добавлены** таблица `errorTakes`, `errorTakes`, `pageGoneForgets`; ревизия таблиц 3 |
| `camera/extension/sw.js` | целиком | **перенесено**: выбор ошибки (новейшая среди равных) и правило pagehide |
| `camera/extension/page.js` | целиком | **перенесено**: выбор ошибки → таблица `errorTakes`; остальное — API браузера (5) |
| `camera/extension/bridge.js` | целиком | чисто: передача сообщений, ограничение длины текста в дороге |
| `camera/extension/manifest.json` | целиком | конфигурация; изменена только версия |
| `camera/wasm/cm_wasm.c` | целиком | чисто: только буферы |
| `relay/server.js` | целиком | **перенесено**: литерал `400` → `rl_upgrade_refusal`, `url.slice(3)` → `rl_room_id_start`, литерал `200` → `RL_HTTP_OK` |
| `relay/rules.js` | целиком | адаптер rl.wasm; **добавлены** `upgradeRefusal`, `roomIdStart`, `HTTP_OK` |
| `relay/wasm/rl_wasm.c` | целиком | чисто: только буфер |

## 3. Карта переноса: место → правило t27 → фасад и потребитель → проверка

| Место (до) | Решение | Правило t27 | Фасад → потребитель | Проверка |
|---|---|---|---|---|
| `SettingsView` «Мои наушники»: `outputDevices.filter { !isBlackHole }` | какие выходы можно выбрать наушниками | `dv_is_headphones_choice` | `AudioRules.isHeadphonesChoice` → `AppModel.headphoneChoices` → `SettingsView` | spec `dv_completion_rules`; Swift `deviceLists` (оракул: прежнее выражение) |
| `CoreAudioDeviceCatalog.isSelectableOutput`: `hidden == 0 && canDefault != 0` | может ли выход стать системным | `dv_is_selectable_output` | `AudioRules.isSelectableOutput` → `isSelectableOutput` (меню «Звук», выбор спасательного выхода) | spec; Swift `deviceLists` (флаги HAL как `UInt32`) |
| `AudioProcesses.resolveOwner`: `activationPolicy == .regular` + bundle ID в обходе родителей | обычное ли приложение у родителя | существующее `dv_is_regular_app` | `AudioRules.isRegularApp` | Swift `deviceLists`; прежние тесты владения |
| `DeviceAudioPlayer.startEngine`: `live.outputChannels > 0` | может ли устройство играть | существующее `dv_is_output` | `AudioRules.isOutput` | Swift `deviceLists` |
| `KeychainAnalysisKeyStore.delete`: `errSecSuccess \|\| errSecItemNotFound` | удалось ли удалить ключ | `an_key_delete_ok` | `AnalysisRules.keyDeleteOK` (через `statusCode`) | spec `an_completion_rules`; Swift `analysisKeyAndReset`, `keyDeletionThroughTheStore` (сыгранная связка ключей) |
| `AnalysisSettingsView`: `!isDefault, provider != providerCustom` | показывать ли «Вернуть по умолчанию» | `an_offers_reset` | `AnalysisRules.offersReset` | spec; Swift `analysisKeyAndReset` |
| `PeerMicGate.push`: `open && PeerRules.vadSends(...)` | уходит ли буфер микрофона другим русским | `pe_mic_sends` (= `pe_sends_mic` и `pe_vad_sends`) | `PeerRules.micSends` → `PeerMicGate` | spec `pe_completion_rules` (все флаги × время); Swift `peerMicrophone` (оракул `PeerRulesLegacy`) |
| `PeerLink.open`: `guard peer != sender, PeerRules.frameFresh(...)` (по review) | принять ли расшифрованный кадр: только от другого Ponte и только свежий. Порядок приёма прежний: затем `seqNewer`, `frameAdmitted`, запись `lastSeq` | `pe_frame_accepted(is_self, sent_ms, now_ms)` | `PeerRules.frameAccepted(isSelf: peer == sender, …)` → `PeerLink.open`. Сравнение UInt64, разбор little-endian, AES-GCM и случайное ID остаются в Swift | spec `pe_completion_rules`: свой и чужой × свежий и устаревший, границы `PE_MAX_SKEW_MS`, концы i64. Swift `peerFrameAdmission`: шаг вызывающего, ID 0/1/2/max−1/max с обеих сторон, оракул — прежний guard с `PeerRulesLegacy.frameFresh` |
| sw.js `totals`: `rank > t.rank \|\| (rank > 0 && rank === t.rank && errorAt > t.at)`; page.js `r > best`; CameraLink `r > rank` | какая ошибка из нескольких показывается: выше ранг; среди равных новейшая, если есть времена, иначе первая | `cm_report_error_takes`, `CM_ERROR_RANK_COUNT`, `CM_POLICY_REV` = 3 | sw.js `errorTakes` (cm.wasm); page.js — таблица `errorTakes` из `policy.js`; `CameraRules.reportErrorTakes` → CameraLink | spec `cm_completion_rules`; Swift `errorChoice` (правило и списки до четырёх отчётов против прежних выражений и `CameraRulesLegacy.chosenError`); wasm-vectors `t` и сверка с прежним JS |
| sw.js pagehide: `old && (old.doc === doc \|\| old.doc == null)` | забыть ли отчёт вкладки | `cm_page_gone_forgets` | `pageGoneForgets` (cm.wasm) → sw.js | spec; Swift `pageGone`; wasm-vectors `o` и сверка с прежним JS |
| server.js: `if (!roomPath(url)) rejectUpgrade(socket, 400, …)` | чем ответить на upgrade не в комнату | `rl_upgrade_refusal` | `rules.upgradeRefusal` → server.js | spec `rl_completion_rules`; `relay/test.mjs` (прежнее правило на 20 010 путях); Swift `relayUpgrade` |
| server.js: `url.slice(3)` | где начинается ID комнаты | `rl_room_id_start`, `RL_ROOM_PREFIX_BYTES` | `rules.roomIdStart` → server.js | spec; `relay/test.mjs`; Swift `relayUpgrade` |
| server.js: `status === 200` | ответ проверки здоровья | `RL_HTTP_OK` (константа уже была) | `rules.HTTP_OK` (сверяется `constants.mjs`) | `constants.mjs`; `relay/test.mjs` (HTTP) |

## 4. Новые API

- **`device_rules.t27`:**
  - `dv_is_headphones_choice(output_channels, is_blackhole)`;
  - `dv_is_selectable_output(hidden, can_be_default)`.
- **`analysis_rules.t27`:**
  - `an_key_delete_ok(deleted)`;
  - `an_offers_reset(provider, is_default)`.
- **`peer_rules.t27`:**
  - `pe_mic_sends(link_up, muted, headphones_like, key_held, has_signal, ms_since_signal)`;
  - `pe_frame_accepted(is_self, sent_ms, now_ms)` (по review).
- **`camera_rules.t27`:**
  - `cm_report_error_takes(rank, best, newer)`;
  - `cm_page_gone_forgets(has_report, same_document, report_has_document)`;
  - `CM_ERROR_RANK_COUNT` = 3;
  - `CM_POLICY_REV` 2 → 3: таблицы для страницы получили `errorTakes`.
- **`relay_rules.t27`:**
  - `rl_room_id_start()`;
  - `rl_upgrade_refusal(room_path)`;
  - `RL_ROOM_PREFIX_BYTES` = 3; `rl_room_path` теперь читает префикс по этой константе.
- **Swift-фасады:**
  - `AudioRules.isHeadphonesChoice`, `AudioRules.isSelectableOutput`;
  - `AnalysisRules.keyDeleteOK`, `AnalysisRules.offersReset`;
  - `PeerRules.micSends`, `PeerRules.frameAccepted`;
  - `CameraRules.reportErrorTakes`;
  - `AppModel.headphoneChoices`.
- **JS:**
  - `policy.js`: `errorTakes`, `pageGoneForgets`, таблица `errorTakes`;
  - `rules.js`: `upgradeRefusal`, `roomIdStart`, `HTTP_OK`.
- **Экспорт WASM:**
  - `camera/build-wasm.sh`: `cm_report_error_takes`, `cm_page_gone_forgets`;
  - `relay/build-wasm.sh`: `rl_room_id_start`, `rl_upgrade_refusal`.

`Package.swift` и `Contracts.swift` не менялись.

## 5. Что остаётся нативным, точно

| Символ | Где | Почему не t27 |
|---|---|---|
| `GlossaryTerm.isComplete`, `caseInsensitiveCompare`, регулярное выражение границ слова | `Glossary.swift` | Unicode Foundation: обрезка пробелов, регистр и границы слов по Unicode, а спеки работают с байтами ASCII |
| `SystemSpeechSynth.voices`: `language.lowercased().replacingOccurrences("_", "-")`; `localizedCaseInsensitiveContains` предпочтённых имён | `SystemSpeechSynth.swift` | нормализация языкового тега и Unicode; ранжирование голосов — `vo_*` |
| `AppModel.sheet`: мастер раньше списка «Перед звонком» | `AppModel.swift` | отображение двух флагов в один лист SwiftUI; правило «список не открывается поверх мастера» — `ui_checklist_opens` |
| `hearIcon`, тексты и иконки статусов, `CameraPanel.shown` (зум как 1.0×) | представления | представление по кодам спек |
| `PeerPanel`: `.disabled(model.peerOn)`, `.disabled(peerSecret.isEmpty)` | `PeerPanel.swift` | доступность элемента по одному факту без комбинации; ничего не решает о звонке |
| `PeerLink`: `UInt64.random` (своё ID), `peer == sender` (сравнение как факт `is_self`), разбор полей little-endian, AES-GCM | `PeerLink.swift` | случайность, криптографический примитив и байты протокола. Решение «принять или отбросить» — `pe_frame_accepted` |
| `PeerWindows`: отправитель 0 — «этот Ponte», `endMs < 0` — окно открыто | `PeerSession.swift` | соглашение о кодировании в учёте окон; решения по окнам — `pe_window_*`, `pe_is_peer_voice` |
| `PlayerBook.scheduled`: `max(queueEnd, position)`; `LiveRelay`: `min(lowMs, queued)` | PonteAudio | арифметика шкалы времени узла и нижняя граница окна; решения — `au_player_*`, `au_relay_*` |
| sw.js `pageMap`: ближайшая аренда для таймера; `sameError` и сохранённый `errorAt` | `sw.js` | учёт таймеров и время первого сообщения об ошибке (обнаружение изменения); срок — `cm_page_lease_left_ms`, выбор — `cm_report_error_takes` |
| page.js: `usablePolicy` (форма таблиц), `frame.displayWidth > 0` (факт `sized`), индексы таблиц | `page.js` | страница Meet не исполняет WebAssembly, поэтому проверяет целостность таблиц и собирает факты; ответы — из таблиц |
| CameraLink: `request.hasPrefix("GET ")`, `upgrade == "websocket"`, `len7 == 126`, `statusLine` | `CameraLink.swift` | разбор и запись байтов протокола; проверки и ответы — `cm_ws_*` |
| relay: `'Bad Request'`, `'ok'`, `'not found'`, `'room full'` / `'relay full'`, карты комнат и адресов | `server.js` | текст ответа и учёт; коды, лимиты и решения — `rl_*` |
| `ClaudeRequestBuilder.parseResponse`: `stop_reason == "refusal"`, пустой текст; `ChatCompletionsClient.parse` | PonteSpeech | чтение JSON ответа; классы ошибок и коды — `cx_*`, `an_*` |
| Проверки присутствия и пустоты (`if let`, `isEmpty`, `frameLength > 0`, `count > 0`) | везде | охраняют само значение Swift или JS; решение о значении — в спеке |
| Шейдер GLSL | `page.js` | исполняет шаги `cm_apply_pixel` над матрицей из `cm_color_params`; сверка в e2e, diagnose и differential |
| Core Audio, AVFoundation, Speech, Translation, URLSession, Keychain, NSWorkspace, NSEvent/AX, TCC, FileManager, Network.framework, CryptoKit/CommonCrypto, browser и Node API | см. `Specs/README.md` | системные API, криптографические примитивы, владение ресурсами и конкурентность |

## 6. Тесты, добавленные к перенесённым правилам

**Спеки.** Пять новых блоков:

- `dv_completion_rules`;
- `an_completion_rules`;
- `pe_completion_rules` — полный перебор 32 комбинаций флагов × время; по review в тот же блок добавлен приём кадра;
- `cm_completion_rules` — все пары рангов;
- `rl_completion_rules`.

Итого 99 блоков в 13 спеках вместо 94. Review нового блока не добавлял. `generate.sh` запустил и прошёл все 99
(раздел 7).

**Swift.** Новые `Tests/PonteTests/CompletionRulesDifferentialTests.swift` (8 тестов, один suite; `peerFrameAdmission`
по review) и оракул
`Tests/PonteTests/Oracles/CompletionRulesLegacy.swift`:

- оракул содержит прежние выражения Swift и транскрипцию прежнего JS;
- старые оракулы не изменены, используются `PeerRulesLegacy`, `AnalysisRulesLegacy` и
  `CameraRulesLegacy.chosenError`;
- выбор ошибки проверен не только как правило, но и как цикл вызывающего: CameraLink и sw.js на всех списках до
  четырёх отчётов с разным порядком времён;
- удаление ключа проверено через `KeychainAnalysisKeyStore` на сыгранной связке ключей.

**WASM.**

- `camera/test/vectors.c` и `camera/test/wasm-vectors.mjs`: случаи `t` (`cm_report_error_takes`) и `o`
  (`cm_page_gone_forgets`), сверка с тем же C, скомпилированным нативно;
- отдельная сверка cm.wasm с прежним JS: sw.js `totals`, page.js `report`, sw.js pagehide.

**Релей.** В `relay/test.mjs` две новые проверки: отказ в upgrade против прежнего правила на всех путях стенда и
ID комнаты против `slice(3)`.

## 7. Результаты проверок 0.1.15 (координатор, локально)

Все проверки — на коде 0.1.15, логи лежат вне репозитория. Генерированный C и WebAssembly получены только скриптами,
вручную ничего не писалось.

### 7.1 Генерация, WebAssembly, тесты

| Проверка | Результат |
|---|---|
| `Specs/generate.sh`, первый запуск | **FAIL** (EXIT 1): `analysis_rules.t27: not ASCII after generation`. Причина — два новых комментария с русскими названиями кнопок. Исправлено: комментарии в ASCII, поведение не менялось |
| `T27C=/path/to/t27c ./Specs/generate.sh`, повтор | PASS (EXIT 0): `parse-complete` и `check-calls` прошли, 13 спек, 99 тестовых блоков. clang `-Werror` PASS. Осталось два прежних предупреждения typecheck о 9 параметрах (`cm_apply_pixel`, `dv_is_tap_target_process`); новых нет |
| `camera/build-wasm.sh`, `relay/build-wasm.sh` | EXIT 0: cm.wasm 30 874 Б, rl.wasm 6 781 Б |
| `node camera/test/constants.mjs` | PASS: 70 констант / 168 define, 0 проблем |
| `node camera/test/wasm-vectors.mjs` | PASS: 157 951 случай, 0 расхождений; плюс 82 случая против заменённого JavaScript, 0 расхождений |
| `(cd relay && npm test)` | PASS: 45 проверок |
| `swift test --jobs 2` | PASS (EXIT 0): 341 тест, 42 suite, новых предупреждений компиляции нет. Новые сравнения без расхождений: `micSends` 320, `frameAccepted` 375, удаление ключа и кнопка сброса 27, `reportErrorTakes` 2 171 |
| `node camera/test/e2e.mjs` (заместитель Ponte) и `PONTE_LINK=1 node camera/test/e2e.mjs` (настоящий CameraLink) | PASS оба: шейдер против `cm_apply_pixel` 0/255 (порог 6), зум и зеркало, здоровая дорожка без «в беде», выключение и остановка правильные |
| `node camera/test/faults.mjs` (фейковая камера, SwiftShader) | PASS 28 проверок: 0 ошибок до первой инъекции; 224 записи кадров, 0 закрытых; уход со страницы засчитан за 106 мс; восстановление рендерера; истёкшая аренда после сна воркера |
| `git diff --check` | PASS |

### 7.2 Файловый конвейер речи (не звонок)

`SpeechProbe` из новой сборки, перевод Apple на устройстве. На вход — синтетические фрагменты `pt_1.wav` и `ru_1.wav`,
в звонок ничего не воспроизводилось.

| Направление | Результат | От конца фразы до перевода |
|---|---|---|
| Входящий PT → RU | EXIT 0, одна итоговая фраза, распознавание 0,43 с, перевод 1,12 с | 1,55 с |
| Исходящий RU → PT | EXIT 0, одна итоговая фраза, распознавание 0,63 с, перевод 0,36 с | 0,98 с |

Синтез в файл: 6,34 с португальской речи за 0,65 с; `ffprobe`: PCM s16le, 22 050 Гц, моно, 6,337868 с.

Это по одному фрагменту на направление. Это не измерение производительности и не доказательство для живого звонка.

### 7.3 Сборка релиза (на момент проверок ещё не опубликован и не установлен)

| Проверка | Результат |
|---|---|
| `swift build -c release --jobs 2 --product Ponte` | EXIT 0, 19,59 с |
| `scripts/bundle.sh` | EXIT 0 (инкрементально, 0,42 с) |
| Подпись Apple Development, `codesign` strict/deep | PASS |
| Содержимое | Info.plist 0.1.15 / build 16, manifest 0.1.15, Mach-O arm64; вложенная папка расширения побайтно совпадает с `camera/extension` |
| Архив `Ponte-0.1.15-macos-arm64.zip` | 2 569 475 Б, SHA-256 `e6e55f068a9791ba5d62880b337f3e2f8866c0c13e7c6b9643014b331bce7602`; распакованный архив побайтно совпадает с `dist/Ponte.app`, `codesign` strict/deep PASS |

### 7.4 Не запускалось

- Hardware-проверка `camera/test/diagnose.mjs` на настоящей камере и GPU для 0.1.15. Последний hardware PASS
  (BrowserOS neo, ANGLE Metal, Apple M4) был на 0.1.14 — `reports/camera-t27-2026-10-15.md`, раздел 6.4.
- Живой звонок Google Meet с другим говорящим участником.
- Публикация и установка 0.1.15 — на момент этих локальных проверок они ещё не выполнялись.
- CI: GitHub Actions в репозитории не настроен, все результаты выше локальные.

## 8. Риски и ограничения

- **Hardware для 0.1.15 не проверен.** Новый код камеры прошёл e2e и faults под SwiftShader. На Apple M4 с настоящей
  камерой проверялась только 0.1.14.
- **`relay/rules.js` требует новый `rl.wasm`.** `roomIdStart` читается при загрузке модуля. Пересобранный `rl.wasm`
  прошёл `npm test`, его надо закоммитить вместе с кодом. Production-релей на Railway не трогался и не деплоился.
  Протокол и ответы релея не изменились.
- **Ревизия таблиц 3.** page.js 0.1.15 не берёт таблицы ревизии 2. Сразу после обновления расширения, пока воркер
  не пересчитал таблицы (`onInstalled` → `refresh`), кадры идут «как есть», и статус говорит это честно. Затем
  обработка продолжается.
- **Живой звонок Google Meet** с речью собеседника не проверялся, ни в 0.1.14, ни в 0.1.15. Тишина в прошлом звонке
  владельца, где он был один, не считается ни доказательством ошибки, ни доказательством работы.
- **Аудит.** Это полный проход по файлам с реестром, сверенным по `git ls-files`. Два фасада исполнитель просмотрел по
  местам с логикой, координатор прочитал их целиком. Границы перечислены в разделе 5. Выводы о «чистых» файлах —
  суждение проверяющих по прочитанному коду, а не формальное доказательство.
- **Release 0.1.15** собран и подписан Apple Development для Мака владельца, не нотаризован. На момент этих
  локальных проверок он ещё не был опубликован и установлен.
- **CI нет.** GitHub Actions в репозитории не настроен; все результаты отчёта получены локально.

Dmitrii Fedorov ([@dmitrii-f-t27](https://github.com/dmitrii-f-t27))
