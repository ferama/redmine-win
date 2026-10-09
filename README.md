# redmine-win

Redmine on Windows with PostgreSQL, fully portable (everything lives in one folder) and running as Windows services:

| Component | Version | Service |
|---|---|---|
| [Redmine](https://www.redmine.org) | 7.0.2 (Puma) | `Redmine`, via [wsw](https://github.com/ferama/wsw) |
| [PostgreSQL](https://www.postgresql.org) | 17 (EDB zip binaries) | `RedminePostgreSQL`, via `pg_ctl register` |
| [Ruby](https://rubyinstaller.org) | 3.4 (RubyInstaller) | — |

Both services run as `NT AUTHORITY\NetworkService`. `Redmine` uses delayed automatic start, depends on
`RedminePostgreSQL`, stops Puma gracefully with Ctrl+C and restarts it if it crashes.

## Offline installer

Download `Redmine-<version>-Setup.exe` from the [releases](https://github.com/ferama/redmine-win/releases)
(or from the artifacts of the latest pipeline run). It contains everything, with the native gems already compiled,
and installs without an Internet connection.

The wizard asks for:
- the installation folder (no spaces, max 60 characters);
- the Redmine HTTP port and the PostgreSQL port (it checks they are free);
- the language of the Redmine default data;
- whether to open the HTTP port in Windows Firewall.

Unattended installation:

```
Redmine-7.0.2-Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /DIR=D:\Redmine /HTTPPORT=8080 /PGPORT=5433 /REDMINELANG=en /TASKS=firewall /LOG=setup.log
```

The exit code is 0 only if the configuration succeeded as well. The details are in `<folder>\logs\setup.log`.

Uninstalling removes the services and the program files. The database, attachments, credentials and logs are kept,
and a new installation in the same folder reuses them, unless you confirm their deletion (silently: `unins000.exe /VERYSILENT /REMOVEDATA`).

After installation open `http://localhost:<port>` and log in with `admin` / `admin`; Redmine asks to change the
password. The generated PostgreSQL passwords are in `<folder>\credentials.txt`, which only administrators can read.

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

The component versions are the parameters at the top of `Install-Redmine.ps1`. When changing the PostgreSQL version,
update `-PostgresZipUrl` too: EDB publishes the zip files with an id instead of a versioned name.
