# TWM / TPQA на Flutter

Порт двух инструментов проекта EMPIR 15RPT04 **TracePQM** в одно Flutter-приложение:

- **TWM** — TracePQM Wattmeter (LabVIEW, CMI): <https://github.com/smaslan/TWM>
- **TPQA** — Traceable Power & PQ Analyzer (LabWindows/CVI, INRIM): <https://github.com/btrinchera/TPQA>

Приложение оцифровывает напряжение и ток, сохраняет записи в формате TWM и считает мощность и
показатели качества электроэнергии алгоритмами QWTB в GNU Octave или Matlab. Формат папки
измерения полностью совместим с оригинальным TWM, поэтому данные можно обрабатывать в любом из них.

## Архитектура

```
packages/twm_model   чистый Dart (работает и в вебе): форматы INFO / CSV / MAT v4, модели всех
                     панелей, контракт TwmBackend, RPC-клиент, DSP (FFT, гармоники, онлайн-анализ TPQA)
packages/twm_engine  чистый Dart: движок измерения, запись/чтение сессий через FileStore, симулятор
                     дигитайзера, Dart-версии алгоритмов QWTB, BrowserBackend (веб-версия без сервера)
packages/twm_core    dart:io: движок измерения, запись и чтение сессий, драйверы (FFI), мост к
                     GNU Octave, LocalBackend, IsolateBackend, HTTP/WebSocket-сервер, bin/twm_server.dart
app                  Flutter UI (Linux / Windows / macOS / Web)
octave/api           twm_api.m — JSON-обёртка над функциями TWM (замена GOLPI)
octave/compat        совместимость с современным Octave (nan*-функции, пути с '\' на Linux)
octave/octprog       неизменённая копия octprog из TWM (скрипты обработки + QWTB)
data/corrections     примеры коррекций из TWM (в том числе «dummy»-трансдьюсеры)
```

- **Десктоп.** Бэкенд работает в фоновом изоляте, поэтому блокирующие вызовы драйверов не замораживают интерфейс.
- **Веб (самостоятельная версия).** Всё работает в браузере, сервер не нужен: симулятор дигитайзера,
  4 алгоритма QWTB, переписанные на Dart, данные в IndexedDB браузера. Подходит для статического хостинга.
- **Веб (клиент сервера).** С параметром `?server=http://host:8080` браузер подключается к `twm_server`
  на компьютере с приборами и Octave. Сервер можно запустить и из десктопного приложения кнопкой **Server**.

Интерфейс на русском и английском (по умолчанию — язык системы/браузера, переключатель в меню «⋮»).

## Окна

| Оригинал | Здесь |
|---|---|
| TWM: главная панель, просмотр результатов QWTB | главное окно, вкладка *QWTB results* |
| TWM: Digitizer configuration (страница на каждый драйвер), мультиплексор | **Digitizer**, CONFIG MULTIPLEXER |
| TWM: Octave/Matlab + Package assistant | **Octave/Matlab** |
| TWM: HW corrections, редакторы коррекций и CSV | **HW Corrections**, Edit / EDIT CORRECTION / EDIT CSV |
| TWM: New measurement + Sampling setup assistant | **SETUP MEASUREMENT** |
| TWM: Processing setup (RAW / QWTB, multicore) | *Processing setup* в настройке измерения и в пакетной обработке |
| TWM: View record / View FFT / Batch processing / Server | **VIEW RECORD**, **VIEW FFT**, **START QWTB CALC**, **Server** |
| TPQA: WB setup PXI-5922 (вертикаль, горизонталь, триггер) | Digitizer → NI PXI-5922 |
| TPQA: LF-Setup DMMs (3458A, SINT/DINT, режимы памяти) | Digitizer → 3458A |
| TPQA: Single shot / Continuous acquisitions | START; режим *Continuous acquisition until STOP* |
| TPQA: CVI Data Processing (гармоники, окна, статистика, графики) | вкладка *On-line analysis (TPQA)* |
| TPQA: графики Sampled / Differential Sampled Voltage | вкладка *Live waveforms* |
| TPQA: Save Sampled Data / Save CVI Processed Data | флажки в настройке измерения и онлайн-анализе |

## Драйверы

| Прибор | Реализация | Проверено |
|---|---|---|
| Симулятор (гармоники, шум, джиттер) | Dart | да |
| Звуковая карта | ALSA (Linux), winmm (Windows) | захват на реальной карте под Linux |
| HP/Keysight 3458A (master-slave, AWG, TIMER) | VISA через FFI, команды взяты из TPQA | только на эмуляторе `SIM::3458A::n` |
| NI PXI-5922 (несколько карт, NI-TClk) | niScope/niTClk через FFI | нет (нет железа и драйвера) |
| NI cDAQ 9238 | NI-DAQmx через FFI | нет |
| Keysight DSO 90000/S | SCPI через VISA | только на эмуляторе `SIM::DSO::1` |
| AWG (33xxx, 3352x, AFG3000, HMF2500), счётчик U62xx | SCPI через VISA | нет |
| Мультиплексоры: COM DTR/RTS, VISA-команды, PFI niScope | VISA / niScope | нет |
| Fluke 8588A | **нет**: систему команд нельзя проверить без прибора | — |
| CMI ADS127L21, CMI Clock Divider/Sync | **нет**: протокол не опубликован | — |

**Драйверы реальных приборов написаны по документации и не проверялись на железе.** Перед
метрологическим использованием их нужно проверить. Эмуляторы (ресурсы VISA вида `SIM::3458A::1`)
позволяют пройти весь сценарий без приборов.

## Сборка и запуск

Нужно: Flutter 3.47+, для обработки — GNU Octave 7+ с пакетами `io signal statistics optim` (или Matlab).

```bash
# Linux: sudo apt install clang ninja-build libgtk-3-dev octave octave-{io,signal,statistics,optim}
cd app
flutter run -d linux                      # или: flutter build linux --release
flutter build windows                     # только на Windows
flutter build web                         # веб-клиент (каталог app/build/web)

# сервер без интерфейса (компьютер с приборами), заодно раздаёт веб-UI
cd packages/twm_core
dart run bin/twm_server.dart --host 0.0.0.0 --port 8080 --web ../../app/build/web --token SECRET
```

Ресурсы (`octave/`, `data/`) приложение ищет через `TWM_HOME`, рядом с исполняемым файлом или в
родительских каталогах. Настройки хранятся в `~/.config/twm_flutter/settings.json`
(на Windows — `%APPDATA%\TWM-Flutter`). Нестандартный путь к библиотеке VISA задаётся через `TWM_VISA_LIBRARY`.

## Веб-версия: хостинг как сайта

```bash
cd app
flutter build web --release --no-web-resources-cdn   # всё своё, без загрузки CanvasKit с gstatic
# результат: app/build/web — обычные статические файлы
python3 -m http.server -d build/web 8000             # проверить локально: http://localhost:8000
```

Каталог `app/build/web` можно выложить на любой статический хостинг: GitHub Pages, Netlify,
Cloudflare Pages, Vercel. Если сайт лежит не в корне домена (например, GitHub Pages
`https://user.github.io/twm/`), собирать с `--base-href /twm/`.

Что умеет веб-версия:
- симулятор дигитайзера (сигналы, гармоники, шум, джиттер) вместо приборов;
- измерение, осциллограммы, спектр, онлайн-анализ TPQA, просмотр записей;
- алгоритмы QWTB, переписанные на Dart и сверенные с Octave: **TWM-WRMS, TWM-PWRTDI, TWM-WFFT, TWM-PSFE**
  (расхождение 1e-12…1e-16); без расчёта неопределённости и частотных коррекций трансдьюсеров;
- страница «Файлы»: загрузка/скачивание сессий ZIP в формате TWM, коррекции, очистка данных.

Безопасность: сайт статический, на сервере ничего не выполняется и не хранится. Все данные пользователя
остаются в его браузере (IndexedDB). Доступа к файлам компьютера и к Octave у сайта нет.

Для проверки веб-интерфейса на десктопе: `TWM_BROWSER_MODE=1 ./build/linux/x64/release/bundle/twm_app`.

## Тесты

```bash
cd packages/twm_model && dart test        # форматы, DSP
cd packages/twm_core  && dart test        # движок, Octave (нужен octave-cli), драйверы на эмуляторах, звук
cd app && flutter test                    # все окна, удалённый режим end-to-end
```

## Отличия и ограничения

- Связь с Octave идёт через постоянный процесс `octave-cli` и JSON (`octave/api/twm_api.m`), а не через GOLPI.
  Долгий расчёт можно прервать (SIGINT на Linux, перезапуск процесса на Windows).
- Сервер TWM использует HTTP/WebSocket вместо Windows named pipe, поэтому старые клиенты (Open-Z-Bridge) не совместимы.
- Экспорт результатов: CSV-файл и буфер обмена в формате Excel; прямой записи в MS Excel через ActiveX нет.
- Графики строятся во Flutter, а не окнами Octave.
- Режим «Parallel Record Processing» (экспериментальный в TWM) пока выполняется последовательно.
- Онлайн-анализ TPQA ориентировочный, как и в оригинале. Валидированные результаты дают только алгоритмы QWTB.

Лицензия MIT, как у TWM и TPQA. У алгоритмов QWTB свои лицензии.
