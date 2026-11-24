#Requires -Version 5.1

<#
.SYNOPSIS
Build a portable Manga Studio Windows x64 CPU distribution.

.DESCRIPTION
Assembles a distribution from exactly two trusted inputs:

  1. An already-extracted upstream CPU portable package containing
     packaging\python\pythonw.exe, packaging\uv.exe, models\, and optionally
     PortableGit\.
  2. This fork's Git-tracked distribution files.

Nothing from an upstream source checkout, a user's config, .env, result/,
logs/, presets/, .git, or any untracked file is copied. The output starts as
the trusted upstream runtime/model base; tracked fork files are then overlaid;
the new launcher, startup document, licence notices, and BUILD-INFO.json are
added last.

The launcher is compiled with the .NET Framework csc.exe as a GUI-subsystem
executable. It resolves packaging\python\pythonw.exe, runs
desktop_qt_ui\main.py with the distribution root as the working directory,
waits for the child, and reports non-zero exits or captured Python startup
tracebacks in a message box. No .bat file and no external Python are used.
The launcher also holds a mutex scoped to the distribution root (one instance
per folder, protecting shared config/result files) and accepts no file paths
or arbitrary application arguments. BUILD-INFO.json marks the build as
portable with updater_enabled=false so the desktop can gate Git updater code.

.PARAMETER Upstream
Path to the extracted upstream CPU portable package root. Must contain
packaging\python\pythonw.exe, packaging\python\python.exe,
packaging\python\python312.dll, packaging\uv.exe, packaging\python\LICENSE.txt,
and all required model files under models\.

.PARAMETER Output
New output directory. It must not exist. The parent directory may be created.
Use a path outside the upstream extraction and outside the fork's source
directories. Prefer a short path (for example D:\build\MangaStudio-win64-cpu):
the bundled Python contains a few licence files near 250 characters, so a
very long output root can hit legacy path limits in ZIP/copy tools.

.PARAMETER Fork
Fork checkout root. Defaults to the repository containing this script.

.PARAMETER Archive
Also create <Output>.zip (ZIP64 via .NET) and <Output>.zip.sha256.

.PARAMETER SkipPortableGit
Do not copy PortableGit from the upstream extraction. The in-app Git update
check then has no bundled Git.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\studio-windows\build.ps1 `
  -Upstream D:\MT\Development\MangaStudio-build\upstream `
  -Output D:\MT\Development\MangaStudio-build\MangaStudio-3.0.4-win64-cpu `
  -Archive

.NOTES
Preconditions:
  * Windows 10/11 x64.
  * .NET Framework 4.x csc.exe (normally
    %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe).
  * Git for Windows on PATH, and the fork must be a Git working tree.
  * A complete upstream portable extraction, not merely a source checkout.
  * Enough free space: roughly 3.2 GB for the directory and additional space
    for the optional archive.
  * All files under distribution paths must be tracked by Git. The build
    fails on untracked files because they are never copied.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Upstream,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Output,

    [string]$Fork,

    [switch]$Archive,

    [switch]$SkipPortableGit
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Git for Windows emits UTF-8 paths for non-ASCII tracked files (for example
# a doc image name outside ASCII). Windows PowerShell 5.1 otherwise decodes
# output with the legacy console code page and would fail to find those files.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch {
    Write-Warning 'Could not set the console output encoding to UTF-8; non-ASCII tracked paths may fail to copy.'
}
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$script:GitExe = $null
$script:ForkFull = $null
$script:OutputFull = $null

# Files that are bundled from the extracted upstream CPU portable package.
# These are the defaults needed for an offline first run with the stock config:
# default detector, LaMa Large inpainting, 48px/default OCR, CTC OCR, and the
# PaddleOCR Chinese/Korean recognition models. Additional models are downloaded
# by the application on first use and remain subject to their upstream licences.
$script:ModelFiles = @(
    'detection\detect-20241225.ckpt',
    'inpainting\lamalarge.onnx',
    'ocr\alphabet-all-v5.txt',
    'ocr\alphabet-all-v7.txt',
    'ocr\ch_PP-OCRv5_rec_server_infer.onnx',
    'ocr\korean_PP-OCRv5_rec_mobile_infer.onnx',
    'ocr\ocr-ctc.ckpt',
    'ocr\ocr_ar_48px.ckpt',
    'ocr\ppocrv5_dict.txt',
    'ocr\ppocrv5_korean_dict.txt'
)

# Distribution paths copied from Git-tracked fork files. This is an allowlist:
# development scripts, tests, packaging tooling, runtime user data, and private
# files are never part of the overlay.
$script:DistributionPaths = @(
    'desktop_qt_ui',
    'manga_translator',
    'dict',
    'fonts',
    'doc',
    'config/config-example.json',
    'config/config/translators.json',
    'packaging/VERSION',
    'packaging/launch.py',
    'packaging/build_utils',
    'pyproject.toml',
    'uv.lock',
    'LICENSE.txt',
    'README.md',
    'README_EN.md'
)

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('==> ' + $Message) -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host ('    ' + $Message)
}

function Normalize-DirectoryPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -le $root.Length) {
        return $full
    }
    return $full.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
}

function Resolve-RequiredDirectory {
    param([string]$Path, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw ($Label + ' path is empty.')
    }
    $full = Normalize-DirectoryPath $Path
    if (-not [IO.Directory]::Exists($full)) {
        throw ($Label + ' directory does not exist: ' + $full)
    }
    return $full
}

function Test-IsInsidePath {
    param([string]$Child, [string]$Parent)
    $childPath = (Normalize-DirectoryPath $Child).TrimEnd([char[]]@('\', '/'))
    $parentPath = (Normalize-DirectoryPath $Parent).TrimEnd([char[]]@('\', '/'))
    if ($childPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $childPath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-ForbiddenReason {
    param([string]$RelativePath)
    $path = $RelativePath -replace '\\', '/'
    if ($path -match '(?i)(^|/)\.env($|\.)') { return 'environment file' }
    if ($path -match '(?i)^\.git($|/)') { return 'Git metadata' }
    if ($path -match '(?i)(^|/)config\.json$') { return 'runtime config' }
    if ($path -match '(?i)(^|/)(maintenance_config|admin_config|server_config)\.json$') { return 'private config' }
    if ($path -match '(?i)(^|/)(result|logs|uploads?|upload-cache|presets|models_backup|uv_cache|__pycache__)(/|$)') { return 'generated or private data' }
    if ($path -match '(?i)^\.venv[^/]*(/|$)') { return 'virtual environment' }
    if ($path -match '(?i)^(test|\.github|packaging/studio-windows)(/|$)') { return 'development-only path' }
    if ($path -match '(?i)\.(pyc|pyo|log|tmp|bak|key|pem|pfx|p12)$') { return 'generated or secret file' }
    if ($path -match '(?i)(^|/)(thumbs\.db|desktop\.ini|\.ds_store)$') { return 'operating-system metadata' }
    return $null
}

function Invoke-GitText {
    param([string[]]$Arguments)
    $gitArguments = @('-C', $script:ForkFull, '-c', 'core.quotepath=false') + $Arguments
    $output = & $script:GitExe @gitArguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = (($output | ForEach-Object { [string]$_ }) -join "`n")
    if ($exitCode -ne 0) {
        throw ('git ' + ($Arguments -join ' ') + ' failed with exit code ' + $exitCode + '.' + [Environment]::NewLine + $text)
    }
    return $text
}

function Split-GitPaths {
    param([string]$Text)
    return @(
        $Text -split "`n" |
            ForEach-Object { $_.TrimEnd("`r") } |
            Where-Object { $_.Length -gt 0 }
    )
}

function Copy-RequiredFile {
    param([string]$Source, [string]$Destination, [string]$Label)
    if (-not [IO.File]::Exists($Source)) {
        throw ($Label + ' is missing: ' + $Source)
    }
    $parent = [IO.Path]::GetDirectoryName($Destination)
    if (-not [string]::IsNullOrEmpty($parent) -and -not [IO.Directory]::Exists($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Copy-IntoOutput {
    param([string]$Source, [string]$Destination, [string]$Label)
    $destinationFull = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-IsInsidePath $destinationFull $script:OutputFull)) {
        throw ('Refusing to write outside the output directory: ' + $destinationFull)
    }
    Copy-RequiredFile -Source $Source -Destination $destinationFull -Label $Label
}

function Copy-DirectoryTree {
    param([string]$Source, [string]$Destination, [string]$Label)
    if (-not [IO.Directory]::Exists($Source)) {
        throw ($Label + ' source directory is missing: ' + $Source)
    }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null

    $robocopy = Join-Path $env:WINDIR 'System32\robocopy.exe'
    if (-not [IO.File]::Exists($robocopy)) {
        $robocopy = 'robocopy.exe'
    }

    & $robocopy $Source $Destination /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XJ | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw ('robocopy failed while copying ' + $Label + ' (exit code ' + $exitCode + ').')
    }
    Write-Info ('copied ' + $Label)
}

function Get-NumericVersion {
    param([string]$Version)
    $match = [regex]::Match($Version, '\d+(?:\.\d+){0,3}')
    if (-not $match.Success) {
        throw ("Cannot derive a numeric launcher version from '" + $Version + "'.")
    }

    $parts = @($match.Value.Split('.'))
    while ($parts.Count -lt 4) {
        $parts += '0'
    }

    $numbers = @()
    foreach ($part in $parts[0..3]) {
        $number = 0
        if (-not [int]::TryParse($part, [ref]$number) -or $number -lt 0 -or $number -gt 65534) {
            throw ("Invalid launcher version component '" + $part + "' in '" + $Version + "'.")
        }
        $numbers += $number
    }
    return ($numbers -join '.')
}

$upstreamFull = Resolve-RequiredDirectory $Upstream 'Upstream'
if ([string]::IsNullOrWhiteSpace($Fork)) {
    $Fork = Join-Path $PSScriptRoot '..\..'
}
$forkFull = Resolve-RequiredDirectory $Fork 'Fork'
$script:ForkFull = $forkFull
$outputFull = Normalize-DirectoryPath $Output
$script:OutputFull = $outputFull

if ([IO.File]::Exists($outputFull) -or [IO.Directory]::Exists($outputFull)) {
    throw ('Output already exists. Choose a new, non-existing directory: ' + $outputFull)
}
if (Test-IsInsidePath $outputFull $upstreamFull) {
    throw ('Output must be outside the upstream extraction: ' + $upstreamFull)
}

$protectedForkPaths = @(
    (Join-Path $forkFull 'desktop_qt_ui'),
    (Join-Path $forkFull 'manga_translator'),
    (Join-Path $forkFull 'dict'),
    (Join-Path $forkFull 'fonts'),
    (Join-Path $forkFull 'doc'),
    (Join-Path $forkFull 'config'),
    (Join-Path $forkFull 'packaging'),
    (Join-Path $forkFull '.git')
)
foreach ($protectedPath in $protectedForkPaths) {
    if (Test-IsInsidePath $outputFull $protectedPath) {
        throw ('Output must not be inside a fork source directory: ' + $protectedPath)
    }
}

$archivePath = $outputFull + '.zip'
$archiveHashPath = $archivePath + '.sha256'
if ($Archive -and ([IO.File]::Exists($archivePath) -or [IO.Directory]::Exists($archivePath))) {
    throw ('Archive already exists. Choose a new output name or remove it: ' + $archivePath)
}
if ($Archive -and ([IO.File]::Exists($archiveHashPath) -or [IO.Directory]::Exists($archiveHashPath))) {
    throw ('Archive checksum file already exists. Choose a new output name or remove it: ' + $archiveHashPath)
}

Write-Step 'Checking build prerequisites'

$cscCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$csc = $null
foreach ($candidate in $cscCandidates) {
    if ([IO.File]::Exists($candidate)) {
        $csc = $candidate
        break
    }
}
if ([string]::IsNullOrEmpty($csc)) {
    throw 'The .NET Framework 4.x C# compiler (csc.exe) was not found. Enable .NET Framework 4.x / install the Windows .NET Framework 4.8 runtime or developer pack.'
}
Write-Info ('csc: ' + $csc)

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
}
if ($null -eq $gitCommand) {
    throw 'Git for Windows is required on PATH to enumerate fork-tracked distribution files.'
}
$script:GitExe = $gitCommand.Source
if ([string]::IsNullOrEmpty($script:GitExe)) {
    $script:GitExe = $gitCommand.Path
}
if ([string]::IsNullOrEmpty($script:GitExe)) {
    throw 'Could not resolve the git executable.'
}
Write-Info ('git: ' + $script:GitExe)

$insideWorkTree = (Invoke-GitText @('rev-parse', '--is-inside-work-tree')).Trim()
if ($insideWorkTree -ne 'true') {
    throw ('Fork is not a Git working tree: ' + $forkFull)
}

$requiredBuildInputs = @(
    (Join-Path $PSScriptRoot 'launcher\MangaStudioLauncher.cs'),
    (Join-Path $PSScriptRoot 'launcher\MangaStudio.exe.manifest'),
    (Join-Path $PSScriptRoot 'layout\START-HERE.txt'),
    (Join-Path $PSScriptRoot 'layout\THIRD-PARTY-NOTICES.txt'),
    (Join-Path $forkFull 'desktop_qt_ui\ui\icons\icon.ico'),
    (Join-Path $forkFull 'doc\MODEL_REPO_README.md'),
    (Join-Path $forkFull 'LICENSE.txt'),
    (Join-Path $forkFull 'packaging\VERSION')
)
foreach ($requiredSource in $requiredBuildInputs) {
    if (-not [IO.File]::Exists($requiredSource)) {
        throw ('Required launcher/build input is missing: ' + $requiredSource)
    }
}

$upstreamRequiredFiles = @(
    'packaging\python\pythonw.exe',
    'packaging\python\python.exe',
    'packaging\python\python312.dll',
    'packaging\python\LICENSE.txt',
    'packaging\uv.exe'
)
foreach ($relativePath in $upstreamRequiredFiles) {
    $absolutePath = Join-Path $upstreamFull $relativePath
    if (-not [IO.File]::Exists($absolutePath)) {
        throw ('Upstream portable package is incomplete; missing: ' + $absolutePath)
    }
}
if (-not [IO.Directory]::Exists((Join-Path $upstreamFull 'packaging\python\Lib\site-packages'))) {
    throw ('Upstream portable Python has no Lib\site-packages directory: ' + $upstreamFull)
}

foreach ($modelFile in $script:ModelFiles) {
    $modelPath = Join-Path (Join-Path $upstreamFull 'models') $modelFile
    if (-not [IO.File]::Exists($modelPath)) {
        throw ('Required redistributable model is missing from the upstream extraction: ' + $modelPath)
    }
    if ((Get-Item -LiteralPath $modelPath).Length -le 0) {
        throw ('Required model file is empty: ' + $modelPath)
    }
}

$portableGitSource = Join-Path $upstreamFull 'PortableGit'
$portableGitBundled = $false
if (-not $SkipPortableGit) {
    if ([IO.File]::Exists((Join-Path $portableGitSource 'cmd\git.exe'))) {
        $portableGitBundled = $true
    }
    else {
        Write-Warning ('PortableGit\cmd\git.exe is not present in the upstream extraction. The output will have no bundled Git.')
    }
}

$forkVersionPath = Join-Path $forkFull 'packaging\VERSION'
$upstreamVersionPath = Join-Path $upstreamFull 'packaging\VERSION'
$forkVersion = (Get-Content -LiteralPath $forkVersionPath -Raw -Encoding UTF8).Trim()
$upstreamVersion = $forkVersion
if ([IO.File]::Exists($upstreamVersionPath)) {
    $upstreamVersion = (Get-Content -LiteralPath $upstreamVersionPath -Raw -Encoding UTF8).Trim()
}
if ([string]::IsNullOrWhiteSpace($forkVersion)) {
    throw ('Fork packaging\VERSION is empty: ' + $forkVersionPath)
}
if ($forkVersion -ne $upstreamVersion) {
    Write-Warning ('Fork version ' + $forkVersion + ' differs from upstream portable version ' + $upstreamVersion + '. Verify the bundled runtime matches the fork dependencies.')
}

Write-Info ('fork: ' + $forkFull)
Write-Info ('upstream: ' + $upstreamFull)
Write-Info ('output: ' + $outputFull)
Write-Info ('version: ' + $forkVersion)

Write-Step 'Enumerating Git-tracked fork distribution files'
$trackedText = Invoke-GitText (@('ls-files', '--') + $script:DistributionPaths)
$trackedFiles = @(Split-GitPaths $trackedText)
if ($trackedFiles.Count -eq 0) {
    throw 'No tracked distribution files were found. Check the fork paths and Git state.'
}

foreach ($relativePath in $trackedFiles) {
    $forbiddenReason = Get-ForbiddenReason $relativePath
    if ($null -ne $forbiddenReason) {
        throw ('Refusing to copy tracked path ' + $relativePath + ' (' + $forbiddenReason + ').')
    }
    $sourcePath = Join-Path $forkFull ($relativePath -replace '/', '\')
    if (-not [IO.File]::Exists($sourcePath)) {
        throw ('Tracked distribution file is missing from the working tree: ' + $sourcePath)
    }
}

$untrackedText = Invoke-GitText (@('ls-files', '--others', '--exclude-standard', '--') + $script:DistributionPaths)
$untrackedFiles = @(Split-GitPaths $untrackedText)
if ($untrackedFiles.Count -gt 0) {
    throw ('Untracked files exist under distribution paths. They are never copied into the build; track them if they belong to the application or move them outside the distribution paths first:' + [Environment]::NewLine + ($untrackedFiles -join [Environment]::NewLine))
}

$statusText = Invoke-GitText (@('status', '--porcelain', '--untracked-files=no', '--') + $script:DistributionPaths)
$forkDirty = -not [string]::IsNullOrWhiteSpace($statusText)
$forkCommit = (Invoke-GitText @('rev-parse', '--short', 'HEAD')).Trim()
Write-Info ('tracked distribution files: ' + $trackedFiles.Count.ToString([Globalization.CultureInfo]::InvariantCulture))
Write-Info ('fork commit: ' + $forkCommit + $(if ($forkDirty) { ' (tracked files contain uncommitted changes)' } else { '' }))

Write-Step 'Compiling the GUI launcher in a temporary directory'
$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('MangaStudio-launcher-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
$outputCreated = $false
$outputReady = $false

try {
    $numericVersion = Get-NumericVersion $forkVersion
    $informationalVersion = (($forkVersion -replace '[\\"]', '_') -replace '[\r\n]', ' ')
    $assemblyInfo = @"
using System.Reflection;

[assembly: AssemblyTitle("Manga Studio")]
[assembly: AssemblyDescription("Manga Studio desktop launcher")]
[assembly: AssemblyProduct("Manga Studio")]
[assembly: AssemblyCompany("Manga Studio contributors")]
[assembly: AssemblyCopyright("GPL-3.0; see LICENSE.txt")]
[assembly: AssemblyVersion("$numericVersion")]
[assembly: AssemblyFileVersion("$numericVersion")]
[assembly: AssemblyInformationalVersion("$informationalVersion")]
"@
    $assemblyInfoPath = Join-Path $tempDirectory 'LauncherAssemblyInfo.cs'
    [IO.File]::WriteAllText($assemblyInfoPath, $assemblyInfo, (New-Object System.Text.UTF8Encoding($false)))

    $temporaryLauncher = Join-Path $tempDirectory 'MangaStudio.exe'
    $cscArguments = @(
        '/nologo',
        '/target:winexe',
        '/platform:anycpu',
        '/optimize+',
        '/debug-',
        '/warn:4',
        '/codepage:65001',
        '/utf8output',
        '/reference:System.dll',
        ('/win32icon:' + (Join-Path $forkFull 'desktop_qt_ui\ui\icons\icon.ico')),
        ('/win32manifest:' + (Join-Path $PSScriptRoot 'launcher\MangaStudio.exe.manifest')),
        ('/out:' + $temporaryLauncher),
        (Join-Path $PSScriptRoot 'launcher\MangaStudioLauncher.cs'),
        $assemblyInfoPath
    )
    & $csc @cscArguments
    if ($LASTEXITCODE -ne 0) {
        throw ('csc failed with exit code ' + $LASTEXITCODE + '.')
    }
    if (-not [IO.File]::Exists($temporaryLauncher) -or (Get-Item -LiteralPath $temporaryLauncher).Length -le 0) {
        throw 'csc did not produce MangaStudio.exe.'
    }
    Write-Info ('launcher: ' + (Get-Item -LiteralPath $temporaryLauncher).Length.ToString([Globalization.CultureInfo]::InvariantCulture) + ' bytes')

    Write-Step 'Creating output directory'
    [IO.Directory]::CreateDirectory($outputFull) | Out-Null
    $outputCreated = $true

    Write-Step 'Copying the bundled Python runtime'
    Copy-DirectoryTree -Source (Join-Path $upstreamFull 'packaging\python') -Destination (Join-Path $outputFull 'packaging\python') -Label 'Python 3.12 runtime'
    Copy-RequiredFile -Source (Join-Path $upstreamFull 'packaging\uv.exe') -Destination (Join-Path $outputFull 'packaging\uv.exe') -Label 'uv.exe'

    Write-Step 'Copying required CPU models'
    foreach ($modelFile in $script:ModelFiles) {
        $modelSource = Join-Path (Join-Path $upstreamFull 'models') $modelFile
        $modelDestination = Join-Path (Join-Path $outputFull 'models') $modelFile
        Copy-RequiredFile -Source $modelSource -Destination $modelDestination -Label ('model ' + $modelFile)
    }
    Write-Info ('bundled model files: ' + $script:ModelFiles.Count.ToString([Globalization.CultureInfo]::InvariantCulture))

    if ($portableGitBundled) {
        Write-Step 'Copying PortableGit'
        Copy-DirectoryTree -Source $portableGitSource -Destination (Join-Path $outputFull 'PortableGit') -Label 'PortableGit'
    }
    elseif ($SkipPortableGit) {
        Write-Info 'PortableGit skipped by -SkipPortableGit.'
    }

    Write-Step 'Overlaying tracked fork distribution files'
    foreach ($relativePath in $trackedFiles) {
        $relativeWindows = $relativePath -replace '/', '\'
        Copy-IntoOutput -Source (Join-Path $forkFull $relativeWindows) -Destination (Join-Path $outputFull $relativeWindows) -Label ('fork file ' + $relativePath)
    }

    Write-Step 'Adding launcher, startup document, and observed licence notices'
    Copy-RequiredFile -Source $temporaryLauncher -Destination (Join-Path $outputFull 'MangaStudio.exe') -Label 'launcher'

    $layoutDirectory = Join-Path $PSScriptRoot 'layout'
    Copy-RequiredFile -Source (Join-Path $layoutDirectory 'START-HERE.txt') -Destination (Join-Path $outputFull 'START-HERE.txt') -Label 'startup document'
    Copy-RequiredFile -Source (Join-Path $layoutDirectory 'THIRD-PARTY-NOTICES.txt') -Destination (Join-Path $outputFull 'THIRD-PARTY-NOTICES.txt') -Label 'third-party notices'

    $licenceDirectory = Join-Path $outputFull 'LICENSES'
    [IO.Directory]::CreateDirectory($licenceDirectory) | Out-Null
    Copy-RequiredFile -Source (Join-Path $forkFull 'doc\MODEL_REPO_README.md') -Destination (Join-Path $licenceDirectory 'MODELS.md') -Label 'model licence notice'
    Copy-RequiredFile -Source (Join-Path $upstreamFull 'packaging\python\LICENSE.txt') -Destination (Join-Path $licenceDirectory 'PYTHON.txt') -Label 'Python licence'
    if ($portableGitBundled) {
        Copy-RequiredFile -Source (Join-Path $upstreamFull 'PortableGit\LICENSE.txt') -Destination (Join-Path $licenceDirectory 'PORTABLE-GIT.txt') -Label 'PortableGit licence'
    }

    Write-Step 'Writing BUILD-INFO.json'
    $buildInfo = [ordered]@{
        build_info_schema = 1
        product = 'Manga Studio'
        distribution = 'windows-x64-cpu-portable'
        variant = 'cpu'
        platform = 'windows-x64'
        portable = $true
        git_checkout = $false
        updater_enabled = $false
        update_mode = 'replace-distribution'
        single_instance = $true
        launcher = 'MangaStudio.exe'
        launcher_accepts_application_args = $false
        launcher_reserved_flags = @('--studio-help', '--studio-version')
        app_version = $forkVersion
        upstream_version = $upstreamVersion
        fork_commit = $forkCommit
        fork_worktree_dirty = $forkDirty
        built_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        entrypoint = 'desktop_qt_ui/main.py'
        runtime = 'packaging/python/pythonw.exe'
        python = '3.12 (bundled)'
        models = @($script:ModelFiles | ForEach-Object { $_ -replace '\\', '/' })
        portable_git = $portableGitBundled
    }
    $buildInfoJson = $buildInfo | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText(
        (Join-Path $outputFull 'BUILD-INFO.json'),
        $buildInfoJson + "`n",
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Step 'Validating the clean output'
    $requiredOutputFiles = @(
        'MangaStudio.exe',
        'START-HERE.txt',
        'THIRD-PARTY-NOTICES.txt',
        'BUILD-INFO.json',
        'LICENSE.txt',
        'desktop_qt_ui\main.py',
        'packaging\VERSION',
        'packaging\python\pythonw.exe',
        'packaging\python\python.exe',
        'packaging\uv.exe',
        'LICENSES\MODELS.md',
        'LICENSES\PYTHON.txt'
    )
    foreach ($relativePath in $requiredOutputFiles) {
        if (-not [IO.File]::Exists((Join-Path $outputFull $relativePath))) {
            throw ('Output is missing a required file: ' + $relativePath)
        }
    }
    foreach ($modelFile in $script:ModelFiles) {
        if (-not [IO.File]::Exists((Join-Path (Join-Path $outputFull 'models') $modelFile))) {
            throw ('Output is missing a required model: ' + $modelFile)
        }
    }

    $forbiddenOutputPaths = @(
        '.env',
        '.git',
        'config\config.json',
        'presets',
        'result',
        'logs',
        'uploads',
        'upload-cache',
        'packaging\maintenance_config.json',
        'packaging\uv_cache'
    )
    foreach ($relativePath in $forbiddenOutputPaths) {
        $absolutePath = Join-Path $outputFull $relativePath
        if ([IO.File]::Exists($absolutePath) -or [IO.Directory]::Exists($absolutePath)) {
            throw ('Output contains a forbidden private or generated artifact: ' + $relativePath)
        }
    }

    foreach ($sourceDirectory in @('desktop_qt_ui', 'manga_translator', 'config', 'dict', 'doc')) {
        $scanRoot = Join-Path $outputFull $sourceDirectory
        if (-not [IO.Directory]::Exists($scanRoot)) {
            continue
        }
        $environmentFiles = @(
            Get-ChildItem -LiteralPath $scanRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq '.env' -or $_.Name -like '.env.*' }
        )
        if ($environmentFiles.Count -gt 0) {
            throw ('Output contains an environment file: ' + $environmentFiles[0].FullName)
        }
    }

    $legacyScripts = @(
        Get-ChildItem -LiteralPath $outputFull -File -Force |
            Where-Object { $_.Extension -in @('.bat', '.cmd', '.sh', '.ps1') }
    )
    if ($legacyScripts.Count -gt 0) {
        throw ('Output root contains a legacy script instead of the EXE: ' + (($legacyScripts | ForEach-Object { $_.Name }) -join ', '))
    }

    $outputFiles = @(Get-ChildItem -LiteralPath $outputFull -Recurse -File -Force)
    if ($outputFiles.Count -eq 0) {
        throw 'Output contains no files.'
    }
    $outputBytes = ($outputFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $outputBytes) {
        $outputBytes = 0
    }

    $outputReady = $true
    Write-Info ('files: ' + $outputFiles.Count.ToString([Globalization.CultureInfo]::InvariantCulture))
    Write-Info ('size: ' + ([math]::Round([double]$outputBytes / 1GB, 2)).ToString([Globalization.CultureInfo]::InvariantCulture) + ' GiB')

    if ($Archive) {
        Write-Step 'Creating ZIP64 archive (this can take a while)'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $outputFull,
            $archivePath,
            [IO.Compression.CompressionLevel]::Fastest,
            $true
        )

        $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $entryCount = $zip.Entries.Count
        }
        finally {
            $zip.Dispose()
        }
        if ($entryCount -le 0) {
            throw 'Archive is empty.'
        }

        $archiveHash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
        [IO.File]::WriteAllText(
            $archiveHashPath,
            $archiveHash.Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($archivePath) + "`n",
            (New-Object System.Text.UTF8Encoding($false))
        )
        Write-Info ('archive: ' + $archivePath)
        Write-Info ('archive entries: ' + $entryCount.ToString([Globalization.CultureInfo]::InvariantCulture))
        Write-Info ('sha256: ' + $archiveHash.Hash.ToLowerInvariant())
        Write-Info ('checksum file: ' + $hashPath)
    }

    Write-Step 'Build complete'
    Write-Host ('    Version: ' + $forkVersion)
    Write-Host ('    Output:  ' + $outputFull)
    Write-Host ('    Launch:  ' + (Join-Path $outputFull 'MangaStudio.exe'))
    if ($Archive) {
        Write-Host ('    Archive: ' + $archivePath)
    }
}
catch {
    if ($outputCreated -and -not $outputReady -and [IO.Directory]::Exists($outputFull)) {
        Write-Warning ('Build failed before validation completed. Removing incomplete output: ' + $outputFull)
        Remove-Item -LiteralPath $outputFull -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    if ([IO.Directory]::Exists($tempDirectory)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
