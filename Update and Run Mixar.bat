@echo off
REM SPDX-FileCopyrightText: 2026 Adeveda Enterprises Private Limited
REM
REM SPDX-License-Identifier: GPL-2.0-or-later

REM Double-click in Explorer: pulls the latest changes, rebuilds Mixar when the
REM checkout moved since the last successful build, then launches it.
REM macOS counterpart: "Update and Run Mixar.command".

setlocal EnableExtensions EnableDelayedExpansion
title Update and Run Mixar
cd /d "%~dp0"
set "ROOT_DIR=%CD%"

where git >nul 2>&1
if errorlevel 1 (
    set "FAIL_MSG=git was not found. Install Git for Windows from https://git-scm.com"
    goto :fail
)

if not exist ".env" (
    copy /y ".env.example" ".env" >nul
    echo Created .env from .env.example
)
set "MIXAR_ENV="
set "ENV_VERSION="
for /f "usebackq eol=# tokens=1,* delims==" %%a in (".env") do (
    if /i "%%a"=="MIXAR_ENV" set "MIXAR_ENV=%%b"
    if /i "%%a"=="MIXAR_VERSION" set "ENV_VERSION=%%b"
)
if not defined MIXAR_ENV set "MIXAR_ENV=Prod"
set "BUILD_ENV_DIR=%ROOT_DIR%\build\%MIXAR_ENV%"
set "BIN_DIR=%BUILD_ENV_DIR%\bin"
REM "<commit> <Blender version> <app version>" of the last successful build.
set "STAMP=%BUILD_ENV_DIR%\.mixar-autobuild-stamp"

set "LIB_DIR=upstream\lib\windows_x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "LIB_DIR=upstream\lib\windows_arm64"

REM The post-merge hook re-pins upstream\ after a pull (normally wired by init).
git config core.hooksPath .githooks

for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set "BRANCH=%%b"
echo == Checking for updates (!BRANCH!) ==
git rev-parse --abbrev-ref --symbolic-full-name @{u} >nul 2>&1
if errorlevel 1 (
    echo WARNING: this branch tracks no remote branch; skipping the pull.
) else (
    git pull --ff-only
    if errorlevel 1 (
        echo WARNING: could not pull updates ^(local changes or a diverged branch^).
        echo          Continuing with the current checkout.
    )
)

REM In a fork, also bring in the official repository's changes and release
REM tags (.github\workflows\sync-official.yml does the same on GitHub hourly).
set "OFFICIAL_SLUG=Mixar-AI/mixar-app"
set "OFFICIAL_BRANCH=main"
set "ORIGIN_URL="
for /f "delims=" %%u in ('git remote get-url origin 2^>nul') do set "ORIGIN_URL=%%u"
if /i "!ORIGIN_URL:~-4!"==".git" set "ORIGIN_URL=!ORIGIN_URL:~0,-4!"
if /i "!ORIGIN_URL:~-18!"=="%OFFICIAL_SLUG%" goto :after_official

set "OFFICIAL_REMOTE="
for /f "tokens=1-3" %%r in ('git remote -v') do (
    if "%%t"=="(fetch)" if not defined OFFICIAL_REMOTE (
        set "REMOTE_URL=%%s"
        if /i "!REMOTE_URL:~-4!"==".git" set "REMOTE_URL=!REMOTE_URL:~0,-4!"
        if /i "!REMOTE_URL:~-18!"=="%OFFICIAL_SLUG%" set "OFFICIAL_REMOTE=%%r"
    )
)
if not defined OFFICIAL_REMOTE (
    set "OFFICIAL_REMOTE=mixar-official"
    git remote add mixar-official https://github.com/%OFFICIAL_SLUG%.git
)
echo == Fetching official Mixar changes (!OFFICIAL_REMOTE!) ==
git fetch --tags !OFFICIAL_REMOTE! %OFFICIAL_BRANCH%
if errorlevel 1 (
    echo WARNING: could not reach the official repository; skipping its changes.
    goto :after_official
)
if /i not "!BRANCH!"=="%OFFICIAL_BRANCH%" (
    echo Note: on a feature branch; official changes merge into %OFFICIAL_BRANCH% only.
    goto :after_official
)
git merge-base --is-ancestor !OFFICIAL_REMOTE!/%OFFICIAL_BRANCH% HEAD
if not errorlevel 1 (
    echo Already includes the official %OFFICIAL_BRANCH%.
    goto :after_official
)
git merge --no-edit !OFFICIAL_REMOTE!/%OFFICIAL_BRANCH%
if errorlevel 1 (
    git merge --abort >nul 2>&1
    echo WARNING: official changes conflict with yours ^(or with uncommitted files^).
    echo          Merge !OFFICIAL_REMOTE!/%OFFICIAL_BRANCH% by hand; continuing without them.
    goto :after_official
)
git push origin %OFFICIAL_BRANCH%
if errorlevel 1 echo WARNING: merged locally but could not push to your fork.
:after_official

set "SUB_STATE="
for /f "delims=" %%s in ('git submodule status -- upstream') do set "SUB_STATE=%%s"
set "NEED_INIT="
if "!SUB_STATE:~0,1!"=="-" set "NEED_INIT=1"
if not exist "%LIB_DIR%\python" set "NEED_INIT=1"
if defined NEED_INIT (
    echo == First-time setup: downloading Blender sources and libraries ==
    call "%ROOT_DIR%\scripts\windows\init.bat"
    if errorlevel 1 (
        set "FAIL_MSG=init failed"
        goto :fail
    )
    cd /d "%ROOT_DIR%"
)

for /f "delims=" %%h in ('git rev-parse HEAD') do set "HEAD_COMMIT=%%h"
set "BLENDER_VERSION="
for /f "tokens=2 delims==" %%v in ('findstr /r /c:"BLENDER_VERSION=[0-9]" "scripts\windows\settings.bat"') do (
    if not defined BLENDER_VERSION set "BLENDER_VERSION=%%v"
)
set BLENDER_VERSION=!BLENDER_VERSION:"=!

REM VERSION is bumped by the release pipeline, not on the tagged commit, so a
REM checkout of release vX.Y.Z still says the previous version and the app would
REM keep offering the release it already contains. Build as the newest release
REM tag in this checkout when that is ahead of VERSION. An .env MIXAR_VERSION
REM still wins; it is applied here because settings.bat lets the environment
REM override .env.
set "APP_VERSION=0.0.0"
if exist "VERSION" set /p APP_VERSION=<"VERSION"
set "APP_VERSION=!APP_VERSION: =!"
set "TAG_VERSION="
REM Highest release tag reachable from HEAD; `git describe` would pick the
REM nearest one, which after a merge can be the previous release.
for /f "delims=" %%t in ('git tag --merged HEAD --sort^=-v:refname --list "v[0-9]*" ^| findstr /r /x "v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"') do (
    if not defined TAG_VERSION set "TAG_VERSION=%%t"
)
if defined TAG_VERSION (
    set "TAG_VERSION=!TAG_VERSION:~1!"
    for /f "tokens=1-3 delims=." %%a in ("!APP_VERSION!.0.0") do set /a "APP_NUM=%%a*1000000+%%b*1000+%%c"
    for /f "tokens=1-3 delims=." %%a in ("!TAG_VERSION!.0.0") do set /a "TAG_NUM=%%a*1000000+%%b*1000+%%c"
    if !TAG_NUM! gtr !APP_NUM! set "APP_VERSION=!TAG_VERSION!"
)
set "MIXAR_VERSION=!APP_VERSION!"
if defined ENV_VERSION set "MIXAR_VERSION=!ENV_VERSION!"

set "WANT=!HEAD_COMMIT! !BLENDER_VERSION! !MIXAR_VERSION!"
set "HAVE="
if exist "%STAMP%" set /p HAVE=<"%STAMP%"

set "EXE="
if exist "%BIN_DIR%\mixar-launcher.exe" (
    set "EXE=%BIN_DIR%\mixar-launcher.exe"
) else if exist "%BIN_DIR%\mixar.exe" (
    set "EXE=%BIN_DIR%\mixar.exe"
)

if defined EXE if "!WANT!"=="!HAVE!" (
    echo == Mixar !MIXAR_VERSION! is up to date ^(%MIXAR_ENV%, !HEAD_COMMIT:~0,8!^) ==
    goto :launch
)

tasklist /fi "imagename eq mixar.exe" 2>nul | find /i "mixar.exe" >nul
if not errorlevel 1 (
    echo.
    echo Mixar is running. Save your work and quit it so it can be rebuilt.
    pause
)

REM build\ cannot be reused across a Blender release change.
set "CLEAN="
if defined EXE if defined HAVE (
    for /f "tokens=2" %%p in ("!HAVE!") do if not "%%p"=="!BLENDER_VERSION!" set "CLEAN=1"
)

if defined CLEAN (
    echo == Blender version changed: clean build of Mixar ^(%MIXAR_ENV%^) ==
    call "%ROOT_DIR%\scripts\windows\build_clean.bat" --yes
) else (
    echo == Building Mixar !MIXAR_VERSION! ^(%MIXAR_ENV%^) ==
    call "%ROOT_DIR%\scripts\windows\build.bat"
)
if errorlevel 1 (
    set "FAIL_MSG=the build failed. Scroll up for the first error."
    goto :fail
)
cd /d "%ROOT_DIR%"

if not exist "%BUILD_ENV_DIR%" mkdir "%BUILD_ENV_DIR%"
> "%STAMP%" echo !WANT!

set "EXE="
if exist "%BIN_DIR%\mixar-launcher.exe" (
    set "EXE=%BIN_DIR%\mixar-launcher.exe"
) else if exist "%BIN_DIR%\mixar.exe" (
    set "EXE=%BIN_DIR%\mixar.exe"
)

:launch
if not defined EXE (
    set "FAIL_MSG=Mixar was not found in %BIN_DIR%"
    goto :fail
)
echo == Launching Mixar ==
start "" "%EXE%"
echo Done.
timeout /t 3 >nul
exit /b 0

:fail
echo.
echo ERROR: !FAIL_MSG!
echo.
pause
exit /b 1
