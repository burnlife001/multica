#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Multica Sync Manager — pull upstream, build, push to feature branch.
.DESCRIPTION
  Interactive menu or CLI mode:
    .\__multica-sync.ps1              Interactive menu
    .\__multica-sync.ps1 pull         Fetch upstream/main, merge to local, push to fork
    .\__multica-sync.ps1 build        Rebuild desktop app (NSIS installer)
    .\__multica-sync.ps1 push         Push current branch to feature/burnlife001
.PARAMETER Action
  Optional: pull | build | push
#>

$ErrorActionPreference = "Stop"
$REPO_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $REPO_ROOT

# ── Config ──────────────────────────────────────────────────────────────────
$FORK  = "origin"                     # git@github.com:burnlife001/multica.git
$UPSTREAM_REMOTE = "upstream"        # git@github.com:multica-ai/multica.git
$FEATURE_BRANCH = "feature/burnlife001"
$MAIN_BRANCH = "main"
$DESKTOP_DIR = Join-Path $REPO_ROOT "apps\desktop"
$DESKTOP_FILTER = "@multica/desktop"
$BUILDER = Join-Path $DESKTOP_DIR "node_modules\.bin\electron-builder.cmd"

# Remote dev server (set empty or $null to use local defaults)
$REMOTE_DEV_HOST = "192.168.1.123"

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Red    { Write-Host $args -ForegroundColor Red }
function Write-Green  { Write-Host $args -ForegroundColor Green }
function Write-Yellow { Write-Host $args -ForegroundColor Yellow }
function Write-Cyan   { Write-Host $args -ForegroundColor Cyan }

function Invoke-Git {
    param([string[]]$Arguments)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red "git $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
        if ($out) { Write-Red $out }
        throw "Git command failed"
    }
    return $out
}

function Ensure-Upstream {
    $remotes = git remote
    if ($UPSTREAM_REMOTE -notin $remotes) {
        Write-Cyan "Adding remote '$UPSTREAM_REMOTE' → git@github.com:multica-ai/multica.git ..."
        git remote add $UPSTREAM_REMOTE git@github.com:multica-ai/multica.git
        Write-Green "  upstream remote added."
    }
}

function Get-Status {
    $branch = git branch --show-current
    $dirty = ""
    if (git status --porcelain) { $dirty = " (DIRTY)" }
    $lastCommit = git log --oneline -1 2>$null
    return @{
        Branch = $branch
        Dirty  = $dirty
        Commit = $lastCommit
    }
}

# ── Version derivation ──────────────────────────────────────────────────────
# Derives a version like "0.2.30-dev" from the latest local tag.
# Does NOT fetch from upstream to keep menu startup fast.
function Get-DevVersion {
    $latestTag = git tag --sort=-v:refname | Select-Object -First 1
    if (-not $latestTag) {
        $hash = git rev-parse --short HEAD
        return "0.0.0-$hash-dev"
    }

    $version = $latestTag -replace '^v', ''
    return "$version-dev"
}

# ── Pull ─────────────────────────────────────────────────────────────────────
function Invoke-Pull {
    Write-Cyan "==> Pull: fetch upstream + merge + push to fork =================="
    Ensure-Upstream

    $status = Get-Status
    Write-Yellow "  Current branch: $($status.Branch)$($status.Dirty)"
    Write-Yellow "  Last commit:    $($status.Commit)"

    # Stash if dirty
    $stashed = $false
    if ($status.Dirty) {
        $msg = "auto: sync upstream $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Yellow "  Stashing dirty working tree..."
        git stash push -m $msg
        $stashed = $true
    }

    $originalBranch = $status.Branch

    try {
        # Switch to main
        if ($originalBranch -ne $MAIN_BRANCH) {
            Write-Cyan "  Switching to $MAIN_BRANCH..."
            git checkout $MAIN_BRANCH
        }

        # Fetch upstream (including tags)
        Write-Cyan "  Fetching $UPSTREAM_REMOTE + tags..."
        git fetch $UPSTREAM_REMOTE --tags

        # Merge upstream/main
        Write-Cyan "  Merging $UPSTREAM_REMOTE/$MAIN_BRANCH → $MAIN_BRANCH..."
        git merge "$UPSTREAM_REMOTE/$MAIN_BRANCH" --no-edit

        # Push to fork
        Write-Cyan "  Pushing $MAIN_BRANCH to $FORK..."
        git push $FORK $MAIN_BRANCH

        Write-Green "==> Pull complete: upstream/main synced to fork =================="
    }
    catch {
        Write-Red "==> Pull FAILED: $_"
        throw
    }
    finally {
        # Return to original branch
        if ($originalBranch -ne (git branch --show-current)) {
            Write-Cyan "  Returning to $originalBranch..."
            git checkout $originalBranch
        }

        # Pop stash
        if ($stashed) {
            Write-Cyan "  Popping stash..."
            git stash pop
        }
    }
}

# ── Build Desktop (Full — .exe installer) ───────────────────────────────────
function Invoke-Buildexe {
    Write-Cyan "==> Build: desktop app (FULL — .exe installer) ===================="

    # Step 1: derive version from latest upstream tag
    $version = Get-DevVersion
    Write-Cyan "  Desktop version → $version"

    # Step 2: electron-vite build (produces out/ bundles)
    Write-Cyan "  Step 1/3: pnpm --filter $DESKTOP_FILTER build ..."
    $buildResult = pnpm --filter $DESKTOP_FILTER build 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red $buildResult
        throw "pnpm build failed"
    }
    Write-Green "  electron-vite build OK"

    # Step 3: electron-builder — invoked directly (not via `pnpm package`)
    # so we can pass the exact flags needed to survive Windows winCodeSign
    # cache corruption.  Every flag below was discovered through failures
    # in earlier conversations — do not remove them casually.
    #
    #   -c.win.signAndEditExecutable=false   skip winCodeSign DLL signing
    #   -c.forceCodeSigning=false            don't fail on missing cert
    #   -c.publish.releaseType=draft         publish as draft (no auto-update)
    #   -c.publish.publishAutoUpdate=false   suppress auto-update metadata
    #
    Write-Cyan "  Step 2/3: clearing electron-builder caches that may be corrupt..."
    $cacheDir = "$env:LOCALAPPDATA\electron-builder\Cache"
    if (Test-Path "$cacheDir\winCodeSign") {
        Remove-Item -Recurse -Force "$cacheDir\winCodeSign"
        Write-Yellow "    cleared winCodeSign cache"
    }

    # Custom NSIS installer: set default install path via a helper script.
    # electron-builder does not have a direct config key for the default
    # install directory — it must be injected via an NSIS include script.
    $nsisScript = Join-Path $DESKTOP_DIR "build\installer.nsh"
    $nsisContent = @'
!macro preInit
  ; Set default install directory before the directory page
  StrCpy $INSTDIR "E:\soft\green\@multicadesktop"
!macroend
!macro customInstall
  ; Reserve for future use
!macroend
'@
    if (-not (Test-Path (Join-Path $DESKTOP_DIR "build"))) {
        New-Item -ItemType Directory -Path (Join-Path $DESKTOP_DIR "build") -Force | Out-Null
    }
    Set-Content -Path $nsisScript -Value $nsisContent
    Write-Yellow "    NSIS install script written → build\installer.nsh"

    Write-Cyan "  Step 3/3: electron-builder --win x64 (version=$version) ..."
    $builderArgs = @(
        "--win", "--x64",
        "-c.win.signAndEditExecutable=false",
        "-c.forceCodeSigning=false",
        "-c.publish.provider=github",
        "-c.publish.releaseType=draft",
        "-c.publish.publishAutoUpdate=false",
        "-c.extraMetadata.version=$version",
        "-c.nsis.oneClick=false",
        "-c.nsis.allowToChangeInstallationDirectory=true",
        "-c.nsis.include=build/installer.nsh"
    )

    $env:CSC_IDENTITY_AUTO_DISCOVERY = "false"
    Push-Location $DESKTOP_DIR
    try {
        $packageResult = & $BUILDER @builderArgs 2>&1
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Red $packageResult
        throw "electron-builder failed (exit $LASTEXITCODE)"
    }

    # Find output
    $dist = Join-Path $DESKTOP_DIR "dist"
    $exe = Get-ChildItem $dist -Filter "multica-desktop-*-windows-x64.exe" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($exe) {
        Write-Green "==> Build complete: dist\$($exe.Name) ($([math]::Round($exe.Length/1MB, 0)) MB) =="
    } else {
        Write-Yellow "==> Build complete, but could not locate .exe in dist\ ============="
    }
}

# ── Build Desktop (Fast — dev mode, no .exe) ────────────────────────────────
function Invoke-BuildDev {
    Write-Cyan "==> Build: desktop app (FAST — dev mode, no installer) ============"

    Write-Cyan "  Step 1/2: pnpm --filter $DESKTOP_FILTER build ..."
    $buildResult = pnpm --filter $DESKTOP_FILTER build 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red $buildResult
        throw "pnpm build failed"
    }
    Write-Green "  electron-vite build OK"

    # Auto-detect remote dev server; fall back to local defaults if not configured
    if ($REMOTE_DEV_HOST) {
        Write-Cyan "  Remote dev host configured: $REMOTE_DEV_HOST"
        $env:VITE_API_URL = "http://${REMOTE_DEV_HOST}:8080"
        $env:VITE_WS_URL  = "ws://${REMOTE_DEV_HOST}:8080/ws"
        $env:VITE_APP_URL = "http://${REMOTE_DEV_HOST}:3000"
        Write-Yellow "    VITE_API_URL = $env:VITE_API_URL"
        Write-Yellow "    VITE_WS_URL  = $env:VITE_WS_URL"
        Write-Yellow "    VITE_APP_URL = $env:VITE_APP_URL"
    } else {
        Write-Yellow "  No REMOTE_DEV_HOST set; using local defaults (localhost)"
    }

    Write-Cyan "  Step 2/2: launching electron-vite preview ..."
    Write-Yellow "    (Press Ctrl+C to stop preview server)"
    Write-Host ""

    Push-Location $DESKTOP_DIR
    try {
        pnpm preview
    } finally {
        Pop-Location
    }

    Write-Green "==> Fast build / preview finished ================================="
}

# ── Ensure on feature branch ────────────────────────────────────────────────
function Switch-ToFeatureBranch {
    param([string]$BaseBranch = $MAIN_BRANCH)

    $current = git branch --show-current
    if ($current -eq $FEATURE_BRANCH) {
        return $FEATURE_BRANCH
    }

    Write-Yellow "  Switching to $FEATURE_BRANCH (based on $BaseBranch)..."
    git checkout -B $FEATURE_BRANCH $BaseBranch
    return $FEATURE_BRANCH
}

# ── Push to feature branch ──────────────────────────────────────────────────
function Invoke-PushFeature {
    Write-Cyan "==> Push: current branch → $FEATURE_BRANCH on $FORK ==============="

    $status = Get-Status
    Write-Yellow "  Current branch: $($status.Branch)$($status.Dirty)"
    Write-Yellow "  Last commit:    $($status.Commit)"

    if ($status.Dirty) {
        Write-Yellow "  Working tree is dirty — staging and committing changes..."
        git add -A
        Switch-ToFeatureBranch
        git commit -m "wip: auto commit before push to $FEATURE_BRANCH"
    }

    try {
        Write-Cyan "  Pushing $FEATURE_BRANCH → $FEATURE_BRANCH (force-with-lease)..."
        git push $FORK "${FEATURE_BRANCH}:${FEATURE_BRANCH}" --force-with-lease
        Write-Green "==> Push complete: $FEATURE_BRANCH updated ========================"
    }
    catch {
        Write-Red "==> Push FAILED: $_"
        throw
    }
}

# ── Menu ─────────────────────────────────────────────────────────────────────
function Show-Menu {
    Clear-Host
    $status = Get-Status
    $version = Get-DevVersion
    Write-Host ""
    Write-Host "========== Multica Sync Manager ==========" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Version : $version  (desktop build target)"
    Write-Host "  Branch  : $($status.Branch)$($status.Dirty)"
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) Pull   — fetch upstream → merge main → push to fork"
    Write-Host ""
    Write-Host "  2) Build exe  — rebuild desktop app (NSIS .exe installer)"
    Write-Host "  3) Build dev  — fast build + preview (no .exe, much faster)"
    Write-Host ""
    Write-Host "  4) Push   — commit and push current branch → $FEATURE_BRANCH"
    Write-Host ""
    Write-Host "  0) Exit"
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Cyan
    $choice = Read-Host "  Select [0-4]"
    switch ($choice) {
        "1" { try { Invoke-Pull } catch { Write-Red "Pull failed: $_" } }
        "2" { try { Invoke-Buildexe } catch { Write-Red "Build failed: $_" } }
        "3" { try { Invoke-BuildDev } catch { Write-Red "Fast build failed: $_" } }
        "4" { try { Invoke-PushFeature } catch { Write-Red "Push failed: $_" } }
        "0" { Write-Host "Bye."; exit 0 }
        default { Write-Red "  Invalid choice: $choice" }
    }

    if ($choice -ne "0") {
        Write-Host ""
        Read-Host "Press Enter to continue..."
    }
}

# ── Main ─────────────────────────────────────────────────────────────────────
function Main {
    param([string]$Action)

    switch ($Action) {
        "pull"  { try { Invoke-Pull } catch { Write-Red "Pull failed: $_"; exit 1 } }
        "build" { try { Invoke-Buildexe } catch { Write-Red "Build failed: $_"; exit 1 } }
        "fast" { try { Invoke-BuildDev } catch { Write-Red "Fast build failed: $_"; exit 1 } }
        "push"  { try { Invoke-PushFeature } catch { Write-Red "Push failed: $_"; exit 1 } }
        default {
            while ($true) { Show-Menu }
        }
    }
}

Main @args
