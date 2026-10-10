# redmine-win

Redmine on Windows with MariaDB, fully portable (everything lives in one folder) and running as Windows services:

| Component | Version | Service |
|---|---|---|
| [Redmine](https://www.redmine.org) | 7.0.2 (Puma) | `Redmine`, via [wsw](https://github.com/ferama/wsw) |
| [MariaDB](https://mariadb.org) | 11.8 LTS (official zip) | `RedmineMariaDB`, via `mariadb-install-db` |
| [Ruby](https://rubyinstaller.org) | 3.4 (RubyInstaller) | — |

Both services run as `NT AUTHORITY\NetworkService`. MariaDB only listens on `127.0.0.1`, uses `utf8mb4` and the
`READ-COMMITTED` isolation level Redmine requires. `Redmine` uses delayed automatic start, depends on
`RedmineMariaDB`, stops Puma gracefully with Ctrl+C and restarts it if it crashes.

> Redmine 7.0 officially lists MySQL 8.0–8.4 (plus PostgreSQL, SQL Server and SQLite) as supported databases.
> MariaDB works through the same `mysql2` adapter and is widely used with Redmine, but it is not part of the
> databases Redmine is tested against.

## Offline installer

Download `Redmine-<version>-Setup.exe` from the [releases](https://github.com/ferama/redmine-win/releases)
(or from the artifacts of the latest pipeline run). It contains everything, with the native gems already compiled,
and installs without an Internet connection.

Nothing is installed system-wide besides the two services: MariaDB ships its Visual C++ runtime DLLs in its own `bin`
folder, and the DLLs needed by the native Ruby gems (e.g. `libmariadb.dll` for `mysql2`) are copied next to `ruby.exe`.

The wizard asks for:
- the installation folder (no spaces, max 60 characters);
- the Redmine HTTP port and the MariaDB port (it checks they are free);
- the language of the Redmine default data;
- whether to open the HTTP port in Windows Firewall.

Unattended installation:

```
Redmine-7.0.2-Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /DIR=D:\Redmine /HTTPPORT=8080 /DBPORT=3307 /REDMINELANG=en /TASKS=firewall /LOG=setup.log
```

The exit code is 0 only if the configuration succeeded as well. The details are in `<folder>\logs\setup.log`.

Uninstalling removes the services and the program files. The database, attachments, credentials and logs are kept,
and a new installation in the same folder reuses them, unless you confirm their deletion (silently: `unins000.exe /VERYSILENT /REMOVEDATA`).

After installation open `http://localhost:<port>` and log in with `admin` / `admin`; Redmine asks to change the
password. The generated MariaDB passwords (`root` and `redmine`) are in `<folder>\credentials.txt`, which only
administrators can read.

## Service management with wsw

The `Redmine` service is run by [wsw](https://github.com/ferama/wsw), a small Windows service wrapper written in Rust
(single executable, no .NET runtime). wsw starts Puma, captures its output in rotating log files, restarts it if it
crashes (with backoff) and, on stop or shutdown, sends it Ctrl+C and waits up to the stop timeout before killing the
whole process tree, so Puma shuts down cleanly.

The executable is `<folder>\service\wsw.exe`. The service configuration lives in the registry, not in a file:

| Setting | Value |
|---|---|
| Command | `ruby.exe bundle exec puma` in `<folder>\redmine` |
| Environment | `RAILS_ENV=production`, Ruby on `PATH` |
| Account | `NT AUTHORITY\NetworkService`, with write access to `<folder>\redmine` |
| Start | delayed automatic, after `RedmineMariaDB` |
| Stop timeout | 20 s |
| Restart | always, 10 s delay doubling up to 120 s |
| Logs | `<folder>\logs`, rotated at 10 MB, 8 files kept |

Useful commands (elevated PowerShell):

```powershell
C:\Redmine\service\wsw.exe status -n Redmine -v    # state and effective configuration
C:\Redmine\service\wsw.exe logs -n Redmine -f      # follow the Puma/wsw log
C:\Redmine\service\wsw.exe restart -n Redmine
C:\Redmine\service\wsw.exe update -n Redmine --stop-timeout 30   # change a setting, then restart
```

The regular Windows tools (`services.msc`, `Get-Service`, `Restart-Service`) work as well.

## Scripts

| Script | Purpose |
|---|---|
| `Install-Redmine.ps1` | Online installation: downloads and compiles everything (MSYS2), creates database and services. Can be run again safely. `-Offline` is used by the installer. |
| `Uninstall-Redmine.ps1` | Removes the services and the firewall rule; `-RemoveFiles` also deletes the folder. |
| `Test-RedmineService.ps1` | Checks an installation: service configuration, account, graceful stop, restart, automatic recovery after a crash. |
| `installer/Build-Installer.ps1` | Builds the offline installer: a real build installation in `C:\RedmineBuild`, a cleaned-up `installer/stage`, then Inno Setup. |
| `installer/Test-Installer.ps1` | End-to-end test of the installer: silent install with custom parameters, service checks, uninstall keeping the data, reinstall, full uninstall. |
| `installer/redmine-setup.iss` | Inno Setup script (wizard, validation, configuration, uninstall). |

All scripts need an elevated PowerShell. The installer itself only relies on Windows PowerShell 5.1.

## Building the installer

```powershell
# elevated PowerShell
.\installer\Build-Installer.ps1        # -> installer\dist\Redmine-<version>-Setup.exe
.\installer\Test-Installer.ps1
```

`Build-Installer.ps1` downloads a portable copy of [Inno Setup](https://jrsoftware.org/isinfo.php) into
`installer/tools` the first time. The [pipeline](.github/workflows/build.yml) does the same on every push,
publishes the installer as an artifact and, for tags, as a GitHub release.

## Versions

The component versions are the parameters at the top of `Install-Redmine.ps1`. When changing the MariaDB version,
update `-MariaDBSha256` too: the downloaded zip is checked against it (the checksums are on
[mariadb.org/download](https://mariadb.org/download/) and in the `downloads.mariadb.org` REST API).

The database settings live in `<folder>\mariadb-data\my.ini`; Redmine connects with `<folder>\redmine\config\database.yml`.
