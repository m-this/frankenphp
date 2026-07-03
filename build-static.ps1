#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a static FrankenPHP binary for Windows.
.DESCRIPTION
    Windows counterpart of build-static.sh: builds a static FrankenPHP binary
    (frankenphp.exe containing the PHP interpreter and Caddy) using static-php-cli,
    optionally embedding a PHP app.

    Requirements:
    - git
    - the "C++ Clang tools for Windows" component of Visual Studio (LLVM toolchain)
    - Go
#>

# Supported variables:
# - PHP_VERSION: PHP version to build (default: latest 8.5 release)
# - PHP_EXTENSIONS: PHP extensions to build (default: $defaultExtensions set below)
# - PHP_EXTENSION_LIBS: PHP extension libraries to build (default: $defaultExtensionLibs set below)
# - FRANKENPHP_VERSION: FrankenPHP version (default: latest stable release fetched by static-php-cli)
# - EMBED: Path to the PHP app to embed (default: none)
# - DEBUG_SYMBOLS: Disable stripping if set to 1 (default: none)
# - CLEAN: Remove dist/ and the Go build cache before building (default: none)
# - SPC_REL_TYPE: static-php-cli release type ("source" or "binary", default: "binary")
# - SPC_OPT_BUILD_ARGS: Additional arguments to pass to spc build:frankenphp
# - SPC_OPT_DOWNLOAD_ARGS: Additional arguments to pass to spc download
#
# Differences with the Unix build (build-static.sh):
# - The Windows build of FrankenPHP in static-php-cli uses "go build" directly instead
#   of xcaddy, so extra Caddy modules (Mercure, Vulcain, cbrotli...) are not included
#   and SPC_CMD_VAR_FRANKENPHP_XCADDY_MODULES/XCADDY_ARGS are ignored.
# - The watcher library (worker hot reloading) is not supported by the static build yet.
# - Extensions only available on Linux/Darwin are excluded from the default set
#   (imagick, ldap, memcached, password-argon2, pcntl, posix, protobuf, sysvmsg, sysvsem).
# - COMPRESS (UPX) and MIMALLOC are Linux-only and not supported.

$ErrorActionPreference = 'Stop'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error 'The "git" command must be installed.'
}

$currentDir = (Get-Location).Path
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' }

if (-not $env:SPC_REL_TYPE) { $env:SPC_REL_TYPE = 'binary' }
if (-not $env:SPC_OPT_BUILD_ARGS) { $env:SPC_OPT_BUILD_ARGS = '' }
if (-not $env:SPC_OPT_DOWNLOAD_ARGS) { $env:SPC_OPT_DOWNLOAD_ARGS = '--ignore-cache-sources=php-src --retry 5' }

if (-not $env:PHP_VERSION) {
    $release = Invoke-RestMethod 'https://www.php.net/releases/index.php?json&version=8.5'
    $env:PHP_VERSION = if ("$($release.version)".StartsWith('8.5')) { $release.version } else { '8.5' }
}

$defaultExtensions = 'amqp,apcu,ast,bcmath,brotli,bz2,calendar,ctype,curl,dba,dom,exif,fileinfo,filter,ftp,gd,gmp,gettext,iconv,igbinary,intl,lz4,mbregex,mbstring,mysqli,mysqlnd,opcache,openssl,parallel,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,readline,redis,session,shmop,simplexml,soap,sockets,sodium,sqlite3,ssh2,sysvshm,tidy,tokenizer,xlswriter,xml,xmlreader,xmlwriter,xsl,xz,zip,zlib,yaml,zstd'
$defaultExtensionLibs = 'libavif,nghttp2,nghttp3,ngtcp2'

if ($env:CLEAN) {
    Remove-Item -Recurse -Force dist -ErrorAction SilentlyContinue
    go clean -cache
}

New-Item -ItemType Directory -Force -Path dist | Out-Null
Set-Location dist

# Fetch static-php-cli. FrankenPHP support for Windows requires the development version
# (v3), so the "binary" release type downloads a nightly build.
if ($env:SPC_REL_TYPE -eq 'binary') {
    New-Item -ItemType Directory -Force -Path static-php-cli | Out-Null
    Set-Location static-php-cli
    if (-not (Test-Path spc.exe)) {
        Invoke-WebRequest -Uri "https://dl.static-php.dev/static-php-cli/spc-bin/nightly/spc-windows-x64.exe" -OutFile spc.exe
    }
    $spcCommand = Join-Path (Get-Location).Path 'spc.exe'
} elseif (Test-Path static-php-cli/src) {
    Set-Location static-php-cli
    git pull
    composer install --no-dev -a --no-interaction
    $spcCommand = 'php'
} else {
    git clone --depth 1 https://github.com/crazywhalecc/static-php-cli --branch main
    Set-Location static-php-cli
    composer install --no-dev -a --no-interaction
    $spcCommand = 'php'
}

function Invoke-Spc {
    if ($spcCommand -eq 'php') {
        php bin/spc @args
    } else {
        & $spcCommand @args
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "spc $($args -join ' ') failed with exit code ${LASTEXITCODE}."
    }
}

# Turn potentially relative EMBED path into absolute path
if ($env:EMBED -and -not [System.IO.Path]::IsPathRooted($env:EMBED)) {
    $env:EMBED = Join-Path $currentDir $env:EMBED
}

# Extensions to build
if (-not $env:PHP_EXTENSIONS) {
    if ($env:EMBED -and (Test-Path "$env:EMBED/composer.json") -and (Test-Path "$env:EMBED/composer.lock") -and (Test-Path "$env:EMBED/vendor/composer/installed.json")) {
        # Read the extensions used by the app to embed
        $env:PHP_EXTENSIONS = (Invoke-Spc dump-extensions "$env:EMBED" --format=text --no-dev "--no-ext-output=$defaultExtensions" | Select-Object -Last 1)
    } else {
        $env:PHP_EXTENSIONS = $defaultExtensions
    }
}

# Additional libraries to build
if (-not $env:PHP_EXTENSION_LIBS) { $env:PHP_EXTENSION_LIBS = $defaultExtensionLibs }

$buildArgs = @()
if ($env:SPC_OPT_BUILD_ARGS) { $buildArgs += ($env:SPC_OPT_BUILD_ARGS -split ' ' | Where-Object { $_ }) }
if ($env:DEBUG_SYMBOLS) { $buildArgs += '--no-strip' }

# Embed PHP app, if any
if ($env:EMBED -and (Test-Path $env:EMBED -PathType Container)) {
    $buildArgs += "--with-frankenphp-app=$env:EMBED"
}

$downloadArgs = $env:SPC_OPT_DOWNLOAD_ARGS -split ' ' | Where-Object { $_ }

# Build FrankenPHP
Invoke-Spc doctor --auto-fix
Invoke-Spc download "--with-php=$env:PHP_VERSION" "--for-extensions=$env:PHP_EXTENSIONS" "--for-libs=$env:PHP_EXTENSION_LIBS" @downloadArgs
Invoke-Spc build:frankenphp --enable-zts "--with-libs=$env:PHP_EXTENSION_LIBS" @buildArgs "$env:PHP_EXTENSIONS"

if ($env:CI) {
    Remove-Item -Recurse -Force downloads, source -ErrorAction SilentlyContinue
}

Set-Location $currentDir

$bin = "dist\frankenphp-windows-${arch}.exe"
Copy-Item 'dist\static-php-cli\buildroot\bin\frankenphp.exe' $bin
& ".\$bin" version
& ".\$bin" build-info
