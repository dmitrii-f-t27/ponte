# Ponte — своё приложение: живой переводчик PT-BR ⇄ RU для любых звонков

Владелец: Дмитрий Фёдоров. Дата постановки: 2026-10-11. Платформа: только этот Мак
(MacBook M4, macOS 26.7.1, Xcode 27, Swift 6.4). Код — Swift Package, режим языка Swift 5.

## Зачем

Звонки с бразильцами. Дмитрий говорит по-русски, они — на бразильском португальском.
Ponte — **собственное приложение владельца**, а не функция Zoom. Оно не привязано к одной звонилке:
источник звука — любая программа (Zoom, Google Meet/Teams в браузере, Telegram, WhatsApp, FaceTime)
или весь звук Мака. Zoom — только первый пример.

1. **Входящий канал.** Звук собеседников из выбранной программы сразу попадает в Ponte.
   Ponte показывает русский перевод субтитрами. По желанию озвучивает его в наушники.
2. **Исходящий канал.** Дмитрий говорит в микрофон по-русски. Ponte распознаёт речь,
   переводит на pt-BR и синтезирует голос. Голос уходит в звонилку через виртуальный микрофон.
   Собеседники слышат португальский.
3. **Режим «вживую»** (вторая очередь). Разговор без звонка, за одним столом:
   один микрофон, Ponte сам определяет язык фразы (ru или pt-BR) и озвучивает перевод в динамик.

## Проверено на этом Маке 2026-10-11 (проба `SpeechTranscriber`/`LanguageAvailability`)

| Что | Результат |
|---|---|
| `SpeechTranscriber.supportedLocales` | pt-BR, pt-PT (ru нет) |
| `DictationTranscriber.supportedLocales` | pt-BR, ru-RU, pt-PT |
| `SpeechTranscriber.installedLocales` | пусто, модели надо скачать (`AssetInventory`) |
| Translation framework ru→pt-BR и pt-BR→ru | `supported` (языковые пакеты ещё не скачаны) |
| Голоса AVSpeech | ru-RU Milena; pt-BR Luciana, Eddy, Flo, Reed, Sandy, Shelley и др. (все compact) |
| Аудиоустройства | MacBook Pro Microphone, MacBook Pro Speakers, S6-L. **BlackHole не установлен** |
| Ключи облачных ИИ | ключа Anthropic/OpenAI в связке ключей нет |

Вывод: базовый конвейер полностью на устройстве и бесплатный.
Облачный LLM-перевод — опция. Он включается, только если владелец добавит ключ.

## Архитектура

```
ВХОДЯЩИЙ  Любая программа (Zoom, браузер, Telegram…) ─process tap─▶ Transcriber pt-BR ─final─▶ Translator pt→ru ─▶ субтитры
                                                                                     └─▶ (опц.) SpeechSynth ru ─▶ AudioPlayer(наушники)
ИСХОДЯЩИЙ Микрофон ─▶ Transcriber ru-RU ─final─▶ Translator ru→pt ─▶ SpeechSynth pt-BR ─▶ AudioPlayer(BlackHole 2ch)
                                                                       в звонилке: микрофон = BlackHole 2ch
```

- Захват звука собеседников: Core Audio process tap (`CATapDescription` + `AudioHardwareCreateProcessTap`
  + приватный aggregate device + IOProc). Драйвер не нужен. Нужен `NSAudioCaptureUsageDescription`.
  Источник выбирается в UI: список программ, которые сейчас выводят звук (по bundle ID, со всеми
  их процессами — у браузеров звук идёт из helper-процессов), или «Весь звук Мака, кроме Ponte».
  Известные звонилки помечаются: `us.zoom.xos`, `com.google.Chrome`, `com.apple.Safari`,
  `com.browseros.BrowserClaw` (Meet в BrowserOS), `ru.keepcoder.Telegram`, `org.telegram.desktop`,
  `net.whatsapp.WhatsApp`, `com.apple.FaceTime`, `com.microsoft.teams2`.
  Если программа закрылась и открылась снова — переподключиться самому.
- Виртуальный микрофон: BlackHole 2ch. Ставит владелец: `brew install --cask blackhole-2ch`
  (нужен пароль администратора). В любой звонилке: «Микрофон» = BlackHole 2ch, «Динамик» = наушники.
- Распознавание: `SpeechAnalyzer`. pt-BR — `SpeechTranscriber` (лучше качество, есть volatile-результаты).
  ru-RU — `DictationTranscriber`. Модели скачиваются через `AssetInventory`.
- Перевод по умолчанию: Translation framework на устройстве (`TranslationSession`).
  Языковые пакеты скачиваются один раз через SwiftUI `.translationTask` / `prepareTranslation()`.
  Опционально: LLM-переводчик (Anthropic Messages API, модель `claude-haiku-5-5`)
  с контекстом последних фраз и глоссарием. Ключ — только из связки ключей, элемент `ponte-anthropic-key`.
  Без ключа опция скрыта. Ключи из других проектов не брать.
- Синтез: `AVSpeechSynthesizer.write(_:toBufferCallback:)` → PCM → `AudioPlayer` на нужное устройство.
  Голос выбирается в настройках. Если есть enhanced/premium-голос, брать его.
- Эхо: собеседники не слышат свой голос обратно, потому что звонилка не возвращает наш микрофон.
  Но если Дмитрий без наушников, микрофон слышит динамики. Тогда Ponte предупреждает и просит наушники.

## Логика на t27 (указание владельца 2026-10-11)

Приложение пишется на t27 по образцу DiskBloom. Каждое решение Ponte — спека `Specs/*.t27` →
C через `t27c gen-c`. Swift собирает факты, спрашивает спеку и выполняет ответ.
В Swift остаются только: окна SwiftUI и русские тексты, системные API
(Core Audio, AVFoundation, SpeechAnalyzer, Translation, AVSpeechSynthesizer, Keychain, URLSession),
конкурентность и JSON. Спека возвращает коды, Swift превращает их в текст и действия.

- Компилятор: релиз t27c v0.5.1 (`~/Documents/t27-v051/target/release/t27c`, коммит 579bc55aa), записан в `Specs/T27C_PIN`.
  Он уже собирает спеки DiskBloom. Массивы `[N]f32` работают (в C — `float x[static N]`).
- `Specs/generate.sh` (как в DiskBloom): `t27c check` → `t27c gen-c` → собственные тесты спеки
  через `clang -std=c11 -ffp-contract=off -Wall -Wshorten-64-to-32 -Werror -DT27_TEST_MAIN` →
  `Sources/PonteSpecs/<spec>.h` (полный C) и `Sources/PonteSpecs/include/<spec>.api.h` (константы и прототипы для Swift).
  Сгенерированный C коммитится: сборка приложения не требует t27c.
- Только ASCII в спеках. Ловушки компилятора: см. `~/Brain/claude/t27-spec-authoring-traps.md`
  (массив из одного элемента ломает gen-c; без `switch`; булевы через `and`/`or`/`== false`; тест с литералом массива — проверить C).

Спеки (префикс функций):

| Спека | Решает |
|---|---|
| `audio_rules.t27` (`au_`) | даунмикс в моно, RMS/пик блока, dBFS, сглаживание индикатора уровня, усиление с ограничением, размер чанка 100 мс по частоте, детектор речи с гистерезисом (`au_vad_step`) |
| `segment_rules.t27` (`sg_`) | когда закрыть фразу: пауза, длина, знак препинания, флаг анализатора, отпускание push-to-talk → код действия; где резать длинный монолог (байтовый индекс последнего `. ! ? ,` в UTF-8); слишком короткая фраза не переводится |
| `lane_rules.t27` (`ln_`) | конечный автомат канала: состояния и события → следующее состояние и действие (перевести, синтезировать, в очередь, только показать, отбросить); push-to-talk; пауза голоса; защита от эха; темп речи по длине очереди; «повторить последнюю» |
| `context_rules.t27` (`cx_`) | сколько прошлых фраз идёт в контекст (4, не больше N байт); выбор переводчика Apple/Claude, таймаут, откат на Apple при ошибке |
| `device_rules.t27` (`dv_`) | тип устройства по имени/UID (BlackHole, встроенные динамики → предупреждение «наушники», Bluetooth/USB); выбор по умолчанию; порядок звонилок; helper-процесс → родительское приложение по префиксам bundle ID (таблицы байтов) |
| `voice_rules.t27` (`vo_`) | ранжирование голосов (premium > enhanced > default, предпочтения Luciana / Milena) |
| `ui_rules.t27` (`ui_`) | индикаторы состояния (ок/внимание/ошибка/выкл), доступность кнопок, порядок и готовность шагов мастера, цвет задержки, сколько строк в оверлее |
| `transcript_rules.t27` (`tr_`) | имя файла стенограммы из компонентов даты, экранирование Markdown по байтам, коды направлений |

Swift-фасады: в каждом модуле один файл правил (`PonteAudio/AudioRules.swift`, `PonteSpeech/SpeechRules.swift`,
`PonteApp/AppRules.swift`). Пока C не готов, фасад содержит чистый Swift. При сведении тела фасадов
заменяются вызовами C из `PonteSpecs`, а Swift-версии уходят в тесты как оракул для сравнительных тестов (как в DiskBloom).

## Владение модулями (параллельная работа)

| Папка | Владелец | Что внутри |
|---|---|---|
| `Specs/`, `Sources/PonteSpecs`, `Tests/PonteTests/SpecsTests.swift` | агент «t27» | спеки, generate.sh, сгенерированный C, тесты спек |
| `Sources/PonteCore` | ведущий | контракты (`Contracts.swift`). Агенты не правят, а предлагают изменения в отчёте |
| `Sources/PonteAudio` + `Sources/AudioProbe` | агент «audio» | каталог устройств, `AppAudioTapSource` (по bundle ID / весь звук), `AudioAppCatalog` (кто сейчас звучит), `MicSource`, `FileSource`, `DeviceAudioPlayer`, `BlackHoleCheck` |
| `Sources/PonteSpeech` + `Sources/SpeechProbe` | агент «speech» | `AppleTranscriber`, `AppleTranslator`, `ClaudeTranslator`, `SystemSpeechSynth` |
| `Sources/PonteApp`, `Resources/`, `scripts/` | агент «app» | SwiftUI-приложение, конвейер `TranslationLane`, мастер настройки, оверлей субтитров, сборка .app |
| `Tests/PonteTests` | каждый — свой файл `<Module>Tests.swift` | |
| `Package.swift` | ведущий | правку не делать; нужна зависимость → написать в отчёте |

Правила для всех агентов:
- Собирать только со своим каталогом сборки: `swift build --scratch-path .build-<agent>`.
  Общий `.build` одновременно блокирует SwiftPM.
- Не трогать чужие папки. Не делать `git commit`. Ведущий коммитит сам.
- Секреты не печатать и не записывать в файлы.
- TCC (микрофон, запись звука, распознавание): если macOS показала запрос или отказала —
  сообщить, что именно нужно разрешить, и не повторять запуск в цикле.
- В конце отчёт: что сделано, команды проверки и их вывод, что не проверено, какие правки контрактов нужны.

## Публичный API модулей (агент app пишет против него сразу, до готовности модулей)

PonteAudio:
- `public final class CoreAudioDeviceCatalog: AudioDeviceCatalog { public init() }`
- `public final class RunningAudioAppCatalog: AudioAppCatalog { public init() }`
- `public final class AppAudioTapSource: AudioSource { public init(target: CaptureTarget) }`
  — после закрытия и нового запуска программы переподключается сама.
- `public final class MicSource: AudioSource { public init(device: AudioDevice?) }` (nil = системный по умолчанию)
- `public final class FileSource: AudioSource { public init(url: URL, realtime: Bool) }` — для тестов и демо
- `public final class DeviceAudioPlayer: AudioPlayer { public init(device: AudioDevice?) }`
- `public enum BlackHoleCheck { public static func find(in catalog: AudioDeviceCatalog) -> AudioDevice? }`

PonteSpeech:
- `public final class AppleTranscriber: Transcriber { public init(language: Lang) }`
  (pt-BR → SpeechTranscriber, ru-RU → DictationTranscriber)
- `public final class AppleTranslator: Translator { public init() }` — если языковой пакет не скачан,
  `prepare` бросает `PonteSpeechError.translationAssetsMissing(from:to:)`; скачивание делает UI через `.translationTask`.
- `public final class ClaudeTranslator: Translator { public init?(keychainItem: String = "ponte-anthropic-key", model: String = "claude-haiku-5-5") }`
  — nil, если ключа нет.
- `public final class SystemSpeechSynth: SpeechSynth { public init(voiceIdentifiers: [Lang: String] = [:]) }`
  и `public static func voices(for lang: Lang) -> [SpeechVoice]` (`SpeechVoice`: id, name, quality).
- `public enum PonteSpeechError: Error`.

Если реальная реализация требует другой сигнатуры — агент модуля пишет это в отчёте, ведущий согласует.

## Приложение (UX)

- Главное окно, две колонки:
  - Сверху выбор источника: «Zoom», «Chrome (Meet)», «Telegram»… или «Весь звук Мака».
  - «Они → по-русски»: крупный русский перевод, под ним серым оригинал pt-BR, живой volatile-текст.
  - «Я → по-португальски»: распознанный русский и pt-BR перевод; индикатор «говорит в звонок».
- Верхняя строка состояния: звук источника ✓/✗, микрофон ✓/✗, BlackHole ✓/✗, модели ✓/✗, задержка последней фразы.
- Кнопки: Старт/Стоп, «Пауза голоса в звонок» (пауза исходящего), «Сказать заново» последнюю фразу.
- Режим исходящего: «Авто» (фраза закончилась → перевод → голос) и «Push-to-talk»
  (удерживать клавишу; глобальная горячая клавиша по умолчанию Right Option).
- Настройки: устройства (мой микрофон, мои наушники, вывод в звонок = BlackHole), голос pt-BR, голос ru,
  озвучка русского в наушники (выкл. по умолчанию), переводчик (Apple / Claude), глоссарий (имена, термины).
- Плавающая панель субтитров поверх окна звонка (`NSPanel`, всегда сверху, полупрозрачная).
- Мастер первого запуска: разрешения, скачивание моделей и языковых пакетов, проверка BlackHole,
  инструкция «как выбрать микрофон BlackHole» для Zoom, Meet, Telegram, WhatsApp, тестовая фраза в BlackHole.
- После звонка: экспорт стенограммы Markdown (время, направление, оригинал, перевод)
  в `~/Documents/Ponte/YYYY-MM-DD-HHMM.md`.

## Критерии готовности

1. `swift build` и `swift test` зелёные; `scripts/bundle.sh` собирает `dist/Ponte.app`,
   подписанную стабильной подписью «Apple Development» (иначе ad-hoc), чтобы разрешения TCC не слетали.
2. Офлайн-тест входящего канала: фраза pt-BR из `fixtures/` (сгенерирована `say -v Luciana`)
   через `FileSource` → русский текст за ≤ 2 с после конца фразы.
3. Офлайн-тест исходящего канала: русская фраза (`say -v Milena`) → pt-BR голос в WAV-файл и/или в BlackHole.
4. Живой тест захвата: `afplay` играет pt-BR фразу, process tap ловит именно этот процесс, русский текст появляется.
   Отдельно: звук из браузера (helper-процессы Chrome/Safari) ловится по bundle ID родителя.
5. Живой тест со звонком (с владельцем; Zoom или любая звонилка): собеседник говорит → русские субтитры;
   владелец говорит → собеседник слышит pt-BR.
6. Задержка (конец фразы → перевод на экране) записывается в лог и видна в UI.
