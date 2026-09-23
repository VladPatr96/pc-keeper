# Проверка работоспособности программ (Health) — дизайн

Дата: 2026-09-23

## Зачем

23.09.2026 codex CLI «не работал» в herdr, Git Bash и PowerShell: `codex --version` отвечал сразу, а до первого ответа модели проходило около 100 секунд. Существующий `-Doctor` проверяет только менеджеры пакетов через `--version`, и такую поломку он бы не заметил. Нужна ежедневная автоматическая проверка всех установленных программ. Она должна находить и поломку, и деградацию («стало заметно медленнее обычного») и сообщать о них уведомлением.

## Решения, принятые с человеком

- Охват: все программы, включая GUI. GUI-программы не запускаются: проверяются exe, версия файла и подпись.
- Запуск: задача Планировщика заданий после входа и раз в день. Окно не показывается, отчёт пишется в файл, уведомление Windows приходит только при проблеме.
- ИИ-агенты: раз в день настоящий запрос к модели «ответь PONG» с таймаутом и замером времени.

## Архитектура

Новый раздел `src/Health.ps1`, подключается в `ProgramUpdateAll.psm1` по тому же принципу, что и остальные разделы. Здесь тоже действует разделение «чистая функция + тонкая обёртка»: логика проверки и оценки — в чистых функциях с тестами, обращения к системе (реестр, файлы, процессы, Планировщик) — в тонких обёртках без тестов.

### 1. Обнаружение (что проверяем)

`Get-HealthTargets` собирает список целей `New-HealthTarget` (`Kind`, `Name`, `Command`/`Path`, `Source`, `ProbeArguments`):

- **Cli** — консольные программы из глобальных npm-пакетов (уже есть `Get-NpmGlobalPackageInventory`), инструментов Volta (`volta list --format plain`), шимов choco (`C:\ProgramData\chocolatey\bin\*.exe`) и scoop (`~\scoop\shims`), а также команды из каталога ИИ-агентов.
- **Gui** — программы из реестра uninstall (уже есть `Get-InstalledApplicationInventory`). Путь к exe берётся из `DisplayIcon` (без `,N`) или ищется в `InstallLocation`. Разбор — чистая функция `ConvertFrom-UninstallExePath`.
- **Agent** — каталог ИИ-агентов с командой PONG. Это данные, а не код:

| Имя | Команда |
|---|---|
| codex | `codex exec --skip-git-repo-check --ephemeral "<PONG>"` (stdin закрыт) |
| claude | `claude -p "<PONG>"` |
| opencode | `opencode run "<PONG>"` |
| agy | `agy -p "<PONG>"` |
| gemini | `gemini -p "<PONG>"` |
| grok | `grok -p "<PONG>"` |

`<PONG>` = `Reply with the single word PONG`. Агент, которого нет на PATH, пропускается со статусом `Missing`, а не считается поломкой.

### 2. Проверки

- **Gui:** `Test-Path` exe, `VersionInfo.FileVersion`, `Get-AuthenticodeSignature`. Итоговый статус: `Missing`, если exe нет, `Broken`, если подпись `HashMismatch`, иначе `OK`. Неподписанные exe — это нормально, не ошибка.
- **Cli:** `<cmd> --version` с таймаутом 15 с. Результат: `OK` / `Failed` (код ≠ 0) / `TimedOut`.
- **Agent:** команда PONG с таймаутом 180 с, в рабочем каталоге `%LOCALAPPDATA%\pc-keeper\health\probe-cwd`. `OK` — вывод содержит `PONG`, иначе `Failed` / `TimedOut`, плюс `DurationSeconds`.
- **Окружение (чистые функции над собранными данными):**
  - `Find-DuplicateCommands` — одна команда на PATH из нескольких источников с разными версиями.
  - codex: есть `~/.codex/.sandbox/setup_error.json`; в `~/.codex/.tmp/marketplaces/.staging` больше 10 000 файлов.

`Invoke-NativeText` получает необязательный параметр `-TimeoutSeconds`. По таймауту всё дерево процессов завершается (`taskkill /T /F`), результат `TimedOut = $true`. Без параметра поведение прежнее.

### 3. Оценка

`Get-HealthVerdict` — чистая функция: принимает текущий результат и историю прошлых запусков этой цели. Добавляет статус `Slow`, если `DurationSeconds` больше 2× медианы последних 7 успешных запусков и больше 30 с. Если истории меньше 3 запусков, `Slow` не ставится.

### 4. Результаты и уведомления

- История: `%LOCALAPPDATA%\pc-keeper\health\<yyyy-MM-dd>.json`, хранится 30 дней. Отчёт для человека — `latest.txt`.
- `Format-HealthNotification` — чистая функция: из проблемных результатов (`Missing` у Gui/Cli, `Broken`, `Failed`, `TimedOut`, `Slow`, находки окружения) собирает заголовок и до 3 строк текста. Если проблем нет, уведомление не отправляется.
- Уведомление показывается через `powershell.exe` 5.1 (WinRT `Windows.UI.Notifications`) — без внешних модулей.

### 5. Запуск

- `update-all -Health` — проверка с выводом в консоль.
- `update-all -Health -Quiet` — режим для расписания: без интерактива, отчёт и уведомление.
- `update-all -Health -RegisterSchedule` — регистрирует задачу `PcKeeperHealthCheck`: триггеры «при входе с задержкой 5 мин» и «ежедневно в 12:00», действие `conhost.exe --headless pwsh … -Health -Quiet`. Способ без окон проверен в #9: код возврата conhost не передаёт, поэтому сбой виден по логу. Права администратора не нужны.
- Пункт главного меню «Проверка программ».

## Тесты (сначала тест, потом код)

Чистые функции: `ConvertFrom-UninstallExePath`, `New-HealthTarget`, выбор статуса Gui/Cli/Agent из результата процесса, `Find-DuplicateCommands`, `Get-HealthVerdict` (медиана, порог, мало истории), `Format-HealthNotification`, проверки состояния codex на поддельном каталоге. `Invoke-NativeText -TimeoutSeconds` — на настоящем `pwsh -c Start-Sleep 30` с таймаутом 2 с. Обёртки над реестром, Планировщиком и уведомлениями тестами не покрываются (по CLAUDE.md).

## Вне рамок

Запуск GUI-программ; исправление найденных проблем (только отчёт); проверки по сети; проверка сервисов Windows.
