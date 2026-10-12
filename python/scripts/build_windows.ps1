# Build python\dist\Paperhue.exe (the desktop app, no console) as a single
# file, in an isolated venv. From the repo root:
#
#   powershell -ExecutionPolicy Bypass -File python\scripts\build_windows.ps1 [-Python <python.exe>]
#
# Without -Python, the py launcher picks the first installed 3.12, 3.13,
# 3.14, 3.11 or 3.10 (bleak's winrt dependencies have no 3.15 wheels yet).
# Dependencies are pinned by python\scripts\build-constraints.txt (the
# hardware-tested set). Nothing is installed outside python\.build-venv\
# (git-ignored).
param([string]$Python = "")

$ErrorActionPreference = "Stop"
# The python\ folder (it holds pyproject.toml); every path below is relative to it.
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

$supported = "import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 14) else 1)"

if (-not $Python) {
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
        throw "py launcher not found; pass -Python <full path to a Python 3.10-3.14 python.exe>"
    }
    # Probing writes to stderr for missing versions; under "Stop" Windows
    # PowerShell would turn that into a terminating error, so relax it here.
    $ErrorActionPreference = "Continue"
    foreach ($v in "3.12", "3.13", "3.14", "3.11", "3.10") {
        $exe = & py "-$v" -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { $Python = "$exe".Trim(); break }
    }
    $ErrorActionPreference = "Stop"
    if (-not $Python) { throw "no Python 3.10-3.14 found by the py launcher; pass -Python <python.exe>" }
}
& $Python -c $supported
if ($LASTEXITCODE -ne 0) { throw "$Python is not Python 3.10-3.14 (winrt has no wheels for newer versions yet)" }

if (-not (Test-Path .build-venv)) {
    Invoke-Checked "creating .build-venv" { & $Python -m venv .build-venv }
}
$py = Join-Path $root ".build-venv\Scripts\python.exe"
& $py -c $supported
if ($LASTEXITCODE -ne 0) { throw ".build-venv is not Python 3.10-3.14; delete it and run again" }

Invoke-Checked "pip upgrade" { & $py -m pip install --quiet --upgrade pip }
Invoke-Checked "installing the package and PyInstaller" {
    & $py -m pip install --quiet -c scripts\build-constraints.txt . pyinstaller
}

# --collect-submodules makes sure every Bluetooth (WinRT) module bleak loads
# at run time ends up in the executable.
Invoke-Checked "PyInstaller" {
    & $py -m PyInstaller --noconfirm --clean --onefile --windowed --name Paperhue `
        --collect-submodules bleak --collect-submodules winrt `
        --distpath dist --workpath build\pyinstaller --specpath build\pyinstaller `
        scripts\paperhue_entry.py
}
$exe = Join-Path $root "dist\Paperhue.exe"

# Smoke test: start the app and wait for its main window (it uses Bluetooth
# only when a button is pressed), then close it. A start-up error would show
# an error dialog instead, which has a different title.
function Get-AppProcesses([int]$id) {
    # The one-file executable unpacks itself and runs the app in a child process.
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" | ForEach-Object { [int]$_.ProcessId })
    @(Get-Process -Id (@($id) + $children) -ErrorAction SilentlyContinue)
}
$app = Start-Process -FilePath $exe -PassThru
try {
    $deadline = (Get-Date).AddSeconds(90)
    $opened = $false
    while (-not $opened -and -not $app.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $opened = @(Get-AppProcesses $app.Id | Where-Object { $_.MainWindowTitle -eq "Paperhue" }).Count -gt 0
    }
} finally {
    # Child first, so the parent can still remove its unpacked files.
    $procs = @(Get-AppProcesses $app.Id)
    [array]::Reverse($procs)
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }
}
if (-not $opened) { throw "smoke test failed: Paperhue.exe did not open its window" }

"built: $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB)"
