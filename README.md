# program_update_all

Одна терминальная команда для проверки и запуска обновлений программ, CLI-пакетов и драйверов Windows с выбором через чекбоксы в консоли.

## Запуск

Один раз установите короткую команду:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\projects\My_AI\program_update_all\install-command.ps1
```

После этого из нового терминала можно запускать:

```powershell
update-all
```

Без установки команды можно запускать полным путём:

```powershell
D:\projects\My_AI\program_update_all\program-update-all.cmd
```

Короткий alias из этой же папки:

```powershell
D:\projects\My_AI\program_update_all\update-all.cmd
```

Или из папки проекта:

```powershell
.\program-update-all.cmd
```

Полезные режимы:

```powershell
.\program-update-all.cmd -List
.\program-update-all.cmd -Doctor
.\program-update-all.cmd -Inventory
.\program-update-all.cmd -DryRun
.\program-update-all.cmd -All -DryRun
.\program-update-all.cmd -SkipDrivers
```

## Что сканируется

- `-Inventory` показывает установленные Windows-приложения из uninstall-реестра и глобальные npm CLI-пакеты.
- `winget` - установленные Windows-программы с доступными обновлениями, включая приложения вроде Claude Desktop, если они установлены и видны `winget`.
- `npm outdated -g` - глобальные CLI-пакеты, включая `@anthropic-ai/claude-code`, `@openai/codex` и похожие инструменты, если они установлены через `npm`.
- `choco outdated` - пакеты Chocolatey, если Chocolatey установлен.
- `scoop status` - пакеты Scoop, если Scoop установлен.
- `github-electron` - Electron-приложения из `%LOCALAPPDATA%\Programs`, у которых есть `resources\app-update.yml` с `provider: github`, например Aperant и Auto-Claude.
- `local-git-app` - локальные приложения из Git-репозиториев, установленные через локальные command shims, например Paperclip.
- Windows Update drivers - доступные обновления драйверов через встроенный Windows Update COM API.

Скрипт не может обновлять произвольные программы с закрытыми собственными автообновляторами, если они не видны одному из поддержанных провайдеров.

## Диагностика

Если какой-то провайдер не работает, запустите:

```powershell
update-all -Doctor
```

`Installed=True` означает, что команда найдена. `Starts=True` означает, что она реально запускается из текущего терминала.

## GitHub/Electron Apps

Для приложений, установленных вручную с GitHub, скрипт поддерживает Electron updater metadata:

```text
%LOCALAPPDATA%\Programs\<app>\resources\app-update.yml
```

Если там указаны `owner`, `repo` и `provider: github`, `update-all` проверяет GitHub Releases API и добавляет приложение в чекбоксы только если найден `.exe` asset с более новой версией. При выборе такого пункта installer скачивается во временную папку и запускается.

## Local Git Apps

Paperclip установлен как локальный Git-репозиторий и запускается через command shim `paperclipai`. `update-all -Inventory` показывает его как `local-git-app`.

Для обновления `local-git-app` используется:

```powershell
git pull --ff-only
pnpm install
```

Если в репозитории есть локальные изменения, `update-all` пропускает проверку обновления и пишет warning. Это защищает локальную копию от случайного конфликта при `git pull`.

## Управление чекбоксами

- `Space` - отметить или снять текущий пункт.
- `A` - отметить все.
- `I` - инвертировать выбор.
- `C` - очистить выбор.
- `Enter` - запустить выбранные обновления.
- `Q` или `Esc` - выйти без обновлений.

## Драйверы

Поиск драйверов выполняется через Windows Update. Установка драйверов обычно требует терминал с правами администратора. Для обычного обновления программ без проверки драйверов используйте:

```powershell
.\program-update-all.cmd -SkipDrivers
```

Если выбрать драйверы или другие admin-only обновления из обычного терминала, `update-all` не будет запускать их по одному и собирать ошибки. Он покажет такие пункты отдельно и предложит запустить команду из PowerShell с `Run as Administrator`.

## Проверка

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```
