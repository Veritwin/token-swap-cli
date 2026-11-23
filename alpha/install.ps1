# Installs the Veritwin Token Swap CLI on Windows: a standalone build that brings its own Node.js,
# as `veritwin` in a bin folder on the user PATH.
#
#   alpha:  irm https://veritwin.github.io/token-swap-cli/alpha/install.ps1 | iex
#   prod:   irm https://veritwin.github.io/token-swap-cli/install.ps1 | iex
#   dev:    powershell -File apps\cli\release\install.ps1 -Dev   (from a checkout of Veritwin/token-swap)
#
# Each copy that ships has its release type built in (the $ReleaseType line below, filled in by
# the release build): the copy at an install address, and the one inside every build, which
# `veritwin update` runs. Only the source copy in the repo has none; it installs dev releases,
# with -Dev.
#
# Parameters (each also from the environment, the only way when piped to iex):
#   -Version <v>       VERITWIN_VERSION   install that version instead of the newest (older too)
#   -Archive <file>                       install a local build archive
#   -VeritwinHome <d>  VERITWIN_HOME      default %LOCALAPPDATA%\Veritwin
#   -BinDir <dir>      VERITWIN_BIN_DIR   default <home>\bin, added to the user PATH
#   -Dev                                  the source copy only: install a dev release
# (-VeritwinHome, not -Home: $HOME is a read-only PowerShell variable.)
# Hosts (tests point them at local stubs): VERITWIN_NPM_REGISTRY, VERITWIN_RELEASES_URL.
#
# Needs Windows PowerShell 5.1 or later. Pure ASCII on purpose: Windows PowerShell reads a script
# without a byte-order mark in the system's code page.
param(
  [switch]$Dev,
  [string]$Archive = '',
  [string]$Version = '',
  [string]$VeritwinHome = '',
  [string]$BinDir = ''
)

$ReleaseType = "alpha"

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Pages = 'https://veritwin.github.io/token-swap-cli'
$DevRepo = 'Veritwin/token-swap'
$CliName = 'Veritwin Token Swap CLI'
$Num = '(0|[1-9][0-9]*)'

function Get-VersionType([string]$v) {
  if ($v -cmatch "^$Num\.$Num\.$Num$") { return 'prod' }
  if ($v -cmatch "^$Num\.$Num\.$Num-alpha\.$Num$") { return 'alpha' }
  if ($v -cmatch "^$Num\.$Num\.$Num-dev\.$Num$") { return 'dev' }
  return ''
}

function Get-An([string]$t) {
  if ($t -eq 'alpha') { return 'an alpha' }
  return "a $t"
}

# Runs a native program with its stderr dropped. Windows PowerShell turns a native program's stderr
# lines into errors, which 'Stop' would throw on: the exit code ($LASTEXITCODE) decides instead.
function Invoke-Native([scriptblock]$Block) {
  $ErrorActionPreference = 'Continue'
  & $Block 2>$null
}

# A file's SHA-256 through .NET, not Get-FileHash: Windows PowerShell started with PowerShell 7's
# module path (e.g. `veritwin update` run from a pwsh terminal) can't load Get-FileHash.
function Get-Sha256([string]$file) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $stream = [System.IO.File]::OpenRead($file)
  try {
    return ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
  } finally {
    $stream.Dispose()
    $sha.Dispose()
  }
}

function Get-StatusCode($err) {
  try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
}

function Install-Veritwin {
  if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'This installer needs Windows PowerShell 5.1 or later.'
  }
  # Windows PowerShell 5.1 may still default to TLS 1.0.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  if ($ReleaseType) {
    if ($Dev) { throw "This installer is for $ReleaseType releases and takes no type option." }
    $type = $ReleaseType
  } else {
    if (-not $Dev) {
      throw 'This copy has no release type: run it with -Dev, or use the install address for alpha or prod.'
    }
    $type = 'dev'
  }
  $version = $Version
  if (-not $version) { $version = "$env:VERITWIN_VERSION" }
  if ($Archive -and $version) { throw "-Version and -Archive can't be used together." }

  $home_ = $VeritwinHome
  if (-not $home_) { $home_ = "$env:VERITWIN_HOME" }
  if (-not $home_) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set: give -VeritwinHome, or set VERITWIN_HOME.' }
    $home_ = Join-Path $env:LOCALAPPDATA 'Veritwin'
  }
  $bin = $BinDir
  if (-not $bin) { $bin = "$env:VERITWIN_BIN_DIR" }
  if (-not $bin) { $bin = Join-Path $home_ 'bin' }
  $releasesUrl = "$env:VERITWIN_RELEASES_URL"
  if (-not $releasesUrl) { $releasesUrl = 'https://github.com/Veritwin/token-swap-cli/releases/download' }
  $registry = "$env:VERITWIN_NPM_REGISTRY"
  if (-not $registry) { $registry = 'https://registry.npmjs.org' }
  $registry = $registry.TrimEnd('/')

  # --- The platform ------------------------------------------------------------------------------
  $osArch = ''
  try { $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { }
  if (-not $osArch) {
    $osArch = $env:PROCESSOR_ARCHITEW6432
    if (-not $osArch) { $osArch = $env:PROCESSOR_ARCHITECTURE }
  }
  switch ($osArch.ToUpperInvariant()) {
    { $_ -in 'X64', 'AMD64' } { $arch = 'x64' }
    'ARM64' { $arch = 'arm64' }
    default {
      throw "There is no build for this platform (Windows $osArch). Builds exist for macOS (arm64, x64), Linux (x64, arm64) and Windows (x64, arm64)."
    }
  }
  $platform = "win-$arch"

  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("veritwin-install-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    # --- The version -----------------------------------------------------------------------------
    if ($Archive) {
      if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw "No such archive: $Archive" }
      $leaf = Split-Path -Leaf $Archive
      if ($leaf -notmatch '^veritwin-(.+)-(win-x64|win-arm64)\.zip$') {
        throw "$Archive is not a Veritwin CLI build for Windows."
      }
      if ($Matches[2] -ne $platform) { throw "$Archive is not for this platform ($platform)." }
      $version = $Matches[1]
    } elseif (-not $version) {
      if ($type -eq 'dev') {
        $version = Get-NewestDev
      } else {
        $tagsUrl = "$registry/-/package/@veritwin%2fcli/dist-tags"
        $tags = $null
        try {
          $tags = Invoke-RestMethod -Uri $tagsUrl -UseBasicParsing
        } catch {
          $code = Get-StatusCode $_
          if ($code -ne 401 -and $code -ne 404) { throw "Could not read the npm registry ($tagsUrl): $($_.Exception.Message)" }
        }
        $tag = 'alpha'
        if ($type -eq 'prod') { $tag = 'latest' }
        if ($tags) { $version = "$($tags.$tag)" }
        if ($type -eq 'prod' -and (Get-VersionType $version) -ne 'prod') {
          throw "No prod release yet. For alpha, use $Pages/alpha/install.ps1"
        }
        if (-not $version) { throw "No $type release yet." }
      }
    }
    $vtype = Get-VersionType $version
    if (-not $vtype) { throw "`"$version`" is not a CLI version: expected X.Y.Z (prod), X.Y.Z-alpha.N or X.Y.Z-dev.N." }
    if ($vtype -ne $type) { throw "$version is not $(Get-An $type) version: use the installer of its type." }

    $cli = Join-Path $home_ 'cli'
    $dir = Join-Path $cli $version
    $target = Join-Path $dir 'bin\veritwin.cmd'
    $wrapper = Join-Path $bin 'veritwin.cmd'
    $relative = (Join-Path $home_ 'bin') -eq $bin
    $targetText = if ($relative) { "%~dp0..\cli\$version\bin\veritwin.cmd" } else { $target }
    if ((Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $wrapper) -and
        ((Get-Content -LiteralPath $wrapper -Raw).Contains($targetText))) {
      Remove-OtherVersions $cli $version
      Write-Output "$CliName $version ($type) is already installed."
      Add-UserPath $bin
      return
    }

    # --- Download and check ----------------------------------------------------------------------
    $name = "veritwin-$version-$platform.zip"
    if (-not $Archive) {
      if ($type -eq 'dev') {
        Assert-Gh
        Invoke-Native { gh release download "cli-v$version" -R $DevRepo -p $name -p SHA256SUMS -D $work } | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No dev release $version (or it has no $platform build)." }
      } else {
        $url = "$releasesUrl/v$version"
        try {
          Invoke-WebRequest -Uri "$url/$name" -OutFile (Join-Path $work $name) -UseBasicParsing
          Invoke-WebRequest -Uri "$url/SHA256SUMS" -OutFile (Join-Path $work 'SHA256SUMS') -UseBasicParsing
        } catch {
          throw "No $type release $version (or it has no $platform build): $url/$name"
        }
      }
      $expected = ''
      foreach ($line in Get-Content -LiteralPath (Join-Path $work 'SHA256SUMS')) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2 -and ($parts[1] -eq $name -or $parts[1] -eq "*$name")) { $expected = $parts[0].ToLowerInvariant() }
      }
      if (-not $expected) { throw "SHA256SUMS lists no ${name}: nothing was installed." }
      $actual = Get-Sha256 (Join-Path $work $name)
      if ($expected -ne $actual) { throw "The download's checksum doesn't match SHA256SUMS: nothing was installed." }
      $Archive = Join-Path $work $name
    }

    # --- Install ---------------------------------------------------------------------------------
    $previous = ''
    if (Test-Path -LiteralPath $cli) {
      foreach ($d in Get-ChildItem -LiteralPath $cli -Directory) {
        if ($d.Name -ne $version -and (Get-VersionType $d.Name)) { $previous = $d.Name }
      }
    }
    New-Item -ItemType Directory -Force -Path $cli | Out-Null
    $tmp = "$dir.tmp"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) {
      # Windows 10 1803 and later: much faster than Expand-Archive.
      Invoke-Native { & $tar -xf $Archive -C $tmp --strip-components 1 } | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "Could not extract ${Archive}: nothing was installed." }
    } else {
      $x = Join-Path $work 'x'
      Expand-Archive -LiteralPath $Archive -DestinationPath $x
      $top = Get-ChildItem -LiteralPath $x -Directory | Select-Object -First 1
      if (-not $top) { throw "Could not extract ${Archive}: nothing was installed." }
      Get-ChildItem -LiteralPath $top.FullName -Force | Move-Item -Destination $tmp
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'bin\veritwin.cmd'))) {
      throw "$Archive holds no bin\veritwin.cmd: nothing was installed."
    }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Move-Item -LiteralPath $tmp -Destination $dir

    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    # One line that ends in an exit: cmd.exe reads a batch file line by line while it runs it, and
    # `veritwin update` replaces this one meanwhile. Any failure exits 1, as the CLI documents.
    $text = "@call `"$targetText`" %* && exit /b 0 || exit /b 1`r`n"
    $wrapperTmp = "$wrapper.tmp"
    # cmd.exe reads a batch file in the console's code page (OEM).
    $oem = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [System.IO.File]::WriteAllText($wrapperTmp, $text, $oem)
    Move-Item -LiteralPath $wrapperTmp -Destination $wrapper -Force
    [System.IO.File]::WriteAllText((Join-Path $cli 'bin-dir'), "$bin`r`n")

    Remove-OtherVersions $cli $version

    # --- Report ----------------------------------------------------------------------------------
    if ($previous) {
      Write-Output "Replaced $(Get-VersionType $previous) $previous with $type $version."
    } else {
      Write-Output "Installed $CliName $version ($type)."
    }
    Add-UserPath $bin
    $first = Get-Command veritwin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($first -and ($first.Source -ine $wrapper)) {
      Write-Output "Another veritwin comes first on your PATH: $($first.Source) (an npm install?). Remove it, or put $bin before it."
    }
    Write-Output 'Run: veritwin --version'
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Removes the version folders other than $keep (and unfinished *.tmp ones). The one whose node.exe
# is running `veritwin update` is kept whole: it is named, and the next install removes it.
function Remove-OtherVersions([string]$cli, [string]$keep) {
  foreach ($d in Get-ChildItem -LiteralPath $cli -Directory) {
    if ($d.Name -eq $keep) { continue }
    if (-not ($d.Name.EndsWith('.tmp') -or (Get-VersionType $d.Name))) { continue }
    # Untouched while its Node.js runs (the one running `veritwin update`): cmd.exe still needs that
    # version's bin\veritwin.cmd when node exits, and a removal would fail on node.exe only after
    # deleting the rest ("The system cannot find the path specified.", exit 1; CI, #260).
    if (Test-NodeRunning $d.FullName) {
      Write-Output "Kept $($d.FullName): its Node.js is running; the next install removes it."
      continue
    }
    $removed = $false
    for ($i = 0; $i -lt 5 -and -not $removed; $i++) {
      try {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
        $removed = $true
      } catch {
        Start-Sleep -Milliseconds 200
      }
    }
    if (-not $removed) { Write-Output "Could not remove $($d.FullName): the next install removes it." }
  }
}

# Whether a version folder's runtime\node.exe is running: Windows refuses write access to a running
# program's file. It can also hold a program's file for a moment after the program exits
# (antivirus, process teardown), so a few tries over a second before it counts as running.
function Test-NodeRunning([string]$dir) {
  $exe = Join-Path $dir 'runtime\node.exe'
  if (-not (Test-Path -LiteralPath $exe)) { return $false }
  for ($i = 0; $i -lt 5; $i++) {
    try {
      [System.IO.File]::Open($exe, 'Open', 'ReadWrite', 'None').Dispose()
      return $false
    } catch {
      Start-Sleep -Milliseconds 200
    }
  }
  return $true
}

function Assert-Gh {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "Dev releases need gh (GitHub's CLI), logged in to an account that can read $DevRepo."
  }
}

function Get-NewestDev {
  Assert-Gh
  $tags = Invoke-Native { gh release list -R $DevRepo --json tagName --limit 100 --jq '.[].tagName' }
  if ($LASTEXITCODE -ne 0) { throw "gh could not list the releases of $DevRepo." }
  $newest = $null
  foreach ($t in $tags) {
    if ($t -cmatch "^cli-v$Num\.$Num\.$Num-dev\.$Num$") {
      $key = @([int64]$Matches[1], [int64]$Matches[2], [int64]$Matches[3], [int64]$Matches[4])
      $newer = $true
      if ($newest) {
        $newer = $false
        for ($i = 0; $i -lt 4; $i++) {
          if ($key[$i] -ne $newest.Key[$i]) { $newer = $key[$i] -gt $newest.Key[$i]; break }
        }
      }
      if ($newer) { $newest = @{ Key = $key; Version = $t.Substring(5) } }
    }
  }
  if (-not $newest) { throw 'No dev release yet.' }
  return $newest.Version
}

# The bin folder on the user PATH (HKCU\Environment), kept as REG_EXPAND_SZ so %VARIABLES% in it
# survive; this session's PATH too.
function Add-UserPath([string]$dir) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try {
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($raw -split ';' | Where-Object { $_ })
    if (-not ($entries | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') })) {
      $key.SetValue('Path', (($entries + $dir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
      # Tells running programs (Explorer, new terminals) that the environment changed.
      [Environment]::SetEnvironmentVariable('VERITWIN_PATH_UPDATED', '1', 'User')
      [Environment]::SetEnvironmentVariable('VERITWIN_PATH_UPDATED', $null, 'User')
      Write-Output "Added $dir to your user PATH: new terminals find veritwin."
    }
  } finally {
    $key.Close()
  }
  if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') })) {
    $env:Path = "$env:Path;$dir"
  }
}

# Run with -File (as `veritwin update` does), a failure is exit code 1; piped to iex, it only
# prints, so the user's PowerShell window stays open.
$failed = $false
try {
  Install-Veritwin
} catch {
  [Console]::Error.WriteLine("veritwin install: $($_.Exception.Message)")
  $failed = $true
}
if ($PSCommandPath) {
  if ($failed) { exit 1 }
  exit 0
}
