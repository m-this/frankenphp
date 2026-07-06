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

# Fetch static-php-cli. FrankenPHP support for Windows requires the v3 branch
# (unreleased), so the "binary" release type downloads a v3 nightly build.
if ($env:SPC_REL_TYPE -eq 'binary') {
    New-Item -ItemType Directory -Force -Path static-php-cli | Out-Null
    Set-Location static-php-cli
    if (-not (Test-Path spc.exe)) {
        Invoke-WebRequest -Uri "https://dl.static-php.dev/v3/spc-bin/nightly/spc-windows-x64.exe" -OutFile spc.exe
    }
    $spcCommand = Join-Path (Get-Location).Path 'spc.exe'
} elseif (Test-Path static-php-cli/src) {
    Set-Location static-php-cli
    git pull
    composer install --no-dev -a --no-interaction
    $spcCommand = 'php'
} else {
    git clone --depth 1 https://github.com/crazywhalecc/static-php-cli --branch v3
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

# Go unconditionally passes the MinGW-only -mthreads flag to the C compiler when
# building cgo code on Windows (https://github.com/golang/go/issues/16932), and
# recent Clang versions reject it when targeting MSVC. When the Clang in use does,
# build a transparent wrapper that strips the flag before forwarding to Clang.
$clang = $null
$wrapperClang = $null
if ($env:CC -and (Test-Path $env:CC)) {
    $clang = (Resolve-Path $env:CC).Path
} elseif ($cmd = Get-Command clang.exe -ErrorAction SilentlyContinue) {
    $clang = $cmd.Source
} else {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Llvm.Clang -property installationPath
        if ($vs -and (Test-Path "$vs\VC\Tools\Llvm\x64\bin\clang.exe")) {
            $clang = "$vs\VC\Tools\Llvm\x64\bin\clang.exe"
        }
    }
}
if ($clang) {
    Set-Content probe_mthreads.c 'int main(void){return 0;}'
    & $clang -mthreads -c probe_mthreads.c -o probe_mthreads.o 2>$null
    $needsWrapper = ($LASTEXITCODE -ne 0)
    Remove-Item probe_mthreads.c, probe_mthreads.o -ErrorAction SilentlyContinue
    if ($needsWrapper) {
        Write-Host "Clang rejects -mthreads; building a wrapper stripping it around $clang"
        New-Item -ItemType Directory -Force -Path ccwrap | Out-Null
        Set-Content ccwrap\ccwrap.c @'
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

/* Transparent compiler wrapper: forwards to the real Clang of the same name
   located in the CCWRAP_DIR directory, dropping the MinGW-only -mthreads flag
   that Go passes unconditionally on Windows (golang/go#16932) and that Clang
   rejects when targeting MSVC. */

int main(void)
{
    wchar_t *cmd = GetCommandLineW();

    /* skip our own argv[0] */
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd) cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    }

    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wchar_t *base = wcsrchr(self, L'\\');
    base = base ? base + 1 : self;

    wchar_t dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"CCWRAP_DIR", dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        fwprintf(stderr, L"ccwrap: CCWRAP_DIR is not set\n");
        return 111;
    }

    size_t len = wcslen(dir) + wcslen(base) + wcslen(cmd) + 32;
    wchar_t *out = malloc(len * sizeof(wchar_t));
    if (!out) return 111;
    swprintf(out, len, L"\"%s\\%s\"", dir, base);

    int compiles = 0, links = 0;
    wchar_t *w = out + wcslen(out);
    wchar_t *p = cmd;
    while (*p) {
        if (wcsncmp(p, L" -mthreads", 10) == 0 && (p[10] == L' ' || p[10] == L'\t' || p[10] == L'\0')) {
            p += 10;
            continue;
        }
        if (wcsncmp(p, L" -c", 3) == 0 && (p[3] == L' ' || p[3] == L'\t' || p[3] == L'\0')) compiles = 1;
        if (wcsncmp(p, L" -o", 3) == 0 && (p[3] == L' ' || p[3] == L'\t' || p[3] == L'\0')) links = 1;
        *w++ = *p++;
    }
    *w = L'\0';

    /* php8embed.lib references PathCch* symbols but static-php-cli does not link
       Pathcch.lib; add it to link invocations */
    if (links && !compiles) wcscat(out, L" -lpathcch");

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(NULL, out, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fwprintf(stderr, L"ccwrap: failed to run %s\n", out);
        return 112;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 113;
    GetExitCodeProcess(pi.hProcess, &code);
    return (int) code;
}
'@
        & $clang -O2 ccwrap\ccwrap.c -o ccwrap\clang.exe
        if ($LASTEXITCODE -ne 0) { Write-Error 'Failed to build the Clang wrapper.' }
        Copy-Item ccwrap\clang.exe ccwrap\clang++.exe -Force
        $wrapperClang = Join-Path (Get-Location).Path 'ccwrap\clang.exe'
        $wrapperClangxx = Join-Path (Get-Location).Path 'ccwrap\clang++.exe'
        $wrapperRealDir = Split-Path $clang
    }
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
if ($wrapperClang) {
    # First build PHP and all libraries with the pristine MSVC toolchain: the CC
    # override must only be visible to the cgo build of FrankenPHP itself, as
    # library build systems (e.g. OpenSSL) would otherwise pick up the wrapper
    # and pass MSVC-style flags to Clang. Already-built packages are then skipped
    # by the FrankenPHP build below.
    # pthreads4w is normally built as a dependency of frankenphp; build it in this
    # phase too, as its nmake -E build would also pick up the CC override.
    # --no-smoke-test: static-php-cli's embed smoke test links without Pathcch.lib,
    # which PHP >= 8.5 requires, and fails; FrankenPHP itself is smoke-tested below
    Invoke-Spc build:php-embed --enable-zts --no-smoke-test "--with-libs=$env:PHP_EXTENSION_LIBS,pthreads4w" "$env:PHP_EXTENSIONS"
    $env:CCWRAP_DIR = $wrapperRealDir
    $env:CC = $wrapperClang
    $env:CXX = $wrapperClangxx
}
Invoke-Spc build:frankenphp --enable-zts "--with-libs=$env:PHP_EXTENSION_LIBS" @buildArgs "$env:PHP_EXTENSIONS"

if ($env:CI) {
    Remove-Item -Recurse -Force downloads, source -ErrorAction SilentlyContinue
}

Set-Location $currentDir

$bin = "dist\frankenphp-windows-${arch}.exe"
Copy-Item 'dist\static-php-cli\buildroot\bin\frankenphp.exe' $bin
& ".\$bin" version
& ".\$bin" build-info
