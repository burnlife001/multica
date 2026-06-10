#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Multica Sync Manager — pull upstream, build, push to feature branch.
.DESCRIPTION
  Interactive menu or CLI mode:
    .\__multica-sync.ps1              Interactive menu
    .\__multica-sync.ps1 pull         Fetch upstream/main, merge to local, push to fork
    .\__multica-sync.ps1 build        Rebuild desktop app (NSIS installer)
    .\__multica-sync.ps1 fast         Fast build + preview (no installer)
    .\__multica-sync.ps1 push         Push current branch to feature/burnlife001
    .\__multica-sync.ps1 sync         Rsync server/ to remote and rebuild+restart
    .\__multica-sync.ps1 login        Authenticate remote daemon (one-time)
    .\__multica-sync.ps1 code [email] Fetch latest dev verification code for an email
.PARAMETER Action
  Optional: pull | build | fast | push | sync | login | code [email]
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
$REMOTE_SSH_USER = "yg"
$REMOTE_PROJECT_DIR = "~/__work/multica"

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

# ── Desktop Runtime Config ───────────────────────────────────────────────────
# Writes ~/.multica/desktop.json so the packaged app connects to the right
# server instead of falling back to https://api.multica.ai.
function Write-DesktopConfig {
    $configHost = if ($REMOTE_DEV_HOST) { $REMOTE_DEV_HOST } else { "localhost" }
    $configDir = Join-Path $env:USERPROFILE ".multica"
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    $configContent = @"
{
  "schemaVersion": 1,
  "apiUrl": "http://${configHost}:8080",
  "wsUrl": "ws://${configHost}:8080/ws",
  "appUrl": "http://${configHost}:3000"
}
"@
    Set-Content -Path (Join-Path $configDir "desktop.json") -Value $configContent -NoNewline
    Write-Yellow "    wrote $configDir\desktop.json → $configHost"
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

        # Rebase feature branch onto latest main
        if ($originalBranch -ne $MAIN_BRANCH) {
            Write-Cyan "  Rebasing $originalBranch onto $MAIN_BRANCH..."
            git rebase $MAIN_BRANCH
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

    # Step 2: ensure Go CLI binary is built (needed by bundle-cli.mjs inside
    # the pnpm build script).  Go is not in PATH by default on Windows;
    # if it is absent from PATH we try D:\programs\go\bin before failing.
    Write-Cyan "  Step 1/4: building multica CLI (Go) for desktop bundling ..."
    $goBin = (Get-Command go -ErrorAction SilentlyContinue).Source
    if (-not $goBin) {
        $goCandidate = "D:\programs\go\bin\go.exe"
        if (Test-Path $goCandidate) { $goBin = $goCandidate }
    }
    if ($goBin) {
        # Add Go to PATH so that the bundle-cli.mjs called inside `pnpm build`
        # can find it too (pnpm spawns a separate Node process).
        $goDir = Split-Path -Parent $goBin
        if ($env:PATH -notlike "*$goDir*") {
            $env:PATH = "$goDir;$env:PATH"
        }
        $env:GOPATH = "D:\programs\go\gopath"
        $env:GOPROXY = "https://goproxy.cn,direct"
        $env:GONOSUMCHECK = "*"
        $env:GONOSUMDB = "*"
        $bundleScript = Join-Path $DESKTOP_DIR "scripts\bundle-cli.mjs"
        $bundleResult = & node $bundleScript 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Red $bundleResult
            throw "bundle-cli failed — CLI binary not built"
        }
        Write-Green "  CLI bundle OK"
    } else {
        Write-Yellow "  Go not found — skipping CLI build. Install Go to D:\programs\go for full build."
    }

    # Step 3: electron-vite build (produces out/ bundles)
    Write-Cyan "  Step 2/4: pnpm --filter $DESKTOP_FILTER build ..."
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
    Write-Cyan "  Step 3/4: clearing electron-builder caches that may be corrupt..."
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
    if (-not (Test-Path $nsisScript)) {
        if (-not (Test-Path (Join-Path $DESKTOP_DIR "build"))) {
            New-Item -ItemType Directory -Path (Join-Path $DESKTOP_DIR "build") -Force | Out-Null
        }
        Set-Content -Path $nsisScript -Value $nsisContent
        Write-Yellow "    NSIS install script written → build\installer.nsh"
    } else {
        Write-Yellow "    NSIS install script already exists, skipping → build\installer.nsh"
    }

    # Ensure node_modules exist before electron-builder runs
    $desktopNodeModules = Join-Path $DESKTOP_DIR "node_modules"
    if (-not (Test-Path $desktopNodeModules) -or -not (Test-Path $BUILDER)) {
        Write-Yellow "    node_modules or electron-builder missing — running pnpm install..."
        Push-Location $REPO_ROOT
        try {
            $installResult = pnpm install 2>&1
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Red $installResult
            throw "pnpm install failed"
        }
        Write-Green "    pnpm install OK"
    }

    # Clean up stale installers so we never ship an old artefact by accident.
    $dist = Join-Path $DESKTOP_DIR "dist"
    $staleExes = Get-ChildItem $dist -Filter "multica-desktop-*-windows-x64.exe" -ErrorAction SilentlyContinue
    $staleBlockmaps = Get-ChildItem $dist -Filter "multica-desktop-*-windows-x64.exe.blockmap" -ErrorAction SilentlyContinue
    if ($staleExes -or $staleBlockmaps) {
        Write-Yellow "    removing stale .exe / .blockmap in dist\ ..."
        $staleExes | Remove-Item -Force -ErrorAction SilentlyContinue
        $staleBlockmaps | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-Cyan "  Step 4/4: electron-builder --win x64 (version=$version) ..."
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

    # Route Electron + electron-builder asset downloads through the
    # npmmirror.com mirror. The default GitHub release URL
    # (release-assets.githubusercontent.com) is blocked on networks that
    # can't reach GitHub — that is what made the previous build fail with
    # "dial tcp [::1]:443: connectex: No connection could be made".
    # The mirror URL layout matches what electron-download expects:
    #   ${ELECTRON_MIRROR}/v<version>/electron-v<version>-<platform>-<arch>.zip
    # The same pattern is used elsewhere in this script for Go modules
    # (GOPROXY=https://goproxy.cn,direct), since pnpm itself already
    # points at https://registry.npmmirror.com.
    $env:ELECTRON_MIRROR                  = "https://npmmirror.com/mirrors/electron/"
    $env:ELECTRON_BUILDER_BINARIES_MIRROR = "https://npmmirror.com/mirrors/electron-builder-binaries/"
    Write-Yellow "    ELECTRON_MIRROR = $env:ELECTRON_MIRROR"
    Write-Yellow "    ELECTRON_BUILDER_BINARIES_MIRROR = $env:ELECTRON_BUILDER_BINARIES_MIRROR"

    # electron-builder detects the package manager by looking for a lock file
    # in the app directory. The real pnpm-lock.yaml lives at the repo root
    # (monorepo). Without this copy, electron-builder falls back to npm,
    # which then fails with ELSPROBLEMS on pnpm workspace symlinks.
    $rootLock   = Join-Path $REPO_ROOT "pnpm-lock.yaml"
    $desktopLock = Join-Path $DESKTOP_DIR "pnpm-lock.yaml"
    $cleanupLock = $false
    if ((Test-Path $rootLock) -and -not (Test-Path $desktopLock)) {
        Copy-Item $rootLock $desktopLock
        $cleanupLock = $true
        Write-Yellow "    copied pnpm-lock.yaml → apps/desktop/ (pnpm detection)"
    }

    $env:CSC_IDENTITY_AUTO_DISCOVERY = "false"
    Push-Location $DESKTOP_DIR
    try {
        $packageResult = & $BUILDER @builderArgs 2>&1
    } finally {
        Pop-Location
        if ($cleanupLock) {
            Remove-Item $desktopLock -ErrorAction SilentlyContinue
            Write-Yellow "    removed temporary pnpm-lock.yaml from apps/desktop/"
        }
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

# ── Sync Remote Server ───────────────────────────────────────────────────────
# Uses rsync to push local server/ code to the remote dev machine,
# then rebuilds and restarts the multica server process there.
function Invoke-SyncRemoteServer {
    Write-Cyan "==> Sync: local server/ → $REMOTE_SSH_USER@$REMOTE_DEV_HOST =========="

    if (-not $REMOTE_DEV_HOST) {
        Write-Red "  REMOTE_DEV_HOST is empty — cannot sync."
        return
    }

    $localServer = Join-Path $REPO_ROOT "server"
    if (-not (Test-Path $localServer)) {
        Write-Red "  Local server/ directory not found at $localServer"
        return
    }

    $remoteTarget = "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}:${REMOTE_PROJECT_DIR}"

    # Step 1: compute a fingerprint of the entire local server/ tree
    Write-Cyan "  Step 1/4: checking remote code status..."
    $localFingerprint = Get-ChildItem -Recurse -File $localServer |
        Sort-Object FullName |
        ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc)" } |
        Join-String -Separator "`n" |
        ForEach-Object { [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($_)
            )
        ).Replace("-", "").ToLower() }

    # Use a single-quoted string so PowerShell does NOT interpolate $variables.
    # awk command uses double quotes so no nested single-quote escaping is needed.
    $remoteCmd = '
        if [ -d ~/__work/multica/server ]; then
            find ~/__work/multica/server -type f | sort | while read f; do
                stat -c "%n|%s|%Y" "$f"
            done | sha256sum | awk "{print \$1}"
        else
            echo MISSING
        fi
    '
    $remoteFingerprint = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" ($remoteCmd -replace '\r') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red "  SSH fingerprint check failed (exit $LASTEXITCODE): $remoteFingerprint"
        throw "SSH connection to remote failed"
    }

    if ($remoteFingerprint -match $localFingerprint) {
        Write-Yellow "  Remote server/ matches local — no changes detected."
        Write-Green "==> Sync skipped: remote is already up to date ====================="
        return
    }

    Write-Yellow "  Remote code differs from local — syncing..."

    # Step 2: zip + scp local server/ to remote (Windows has no rsync)
    Write-Cyan "  Step 2/4: zip + scp local server/ → remote..."
    $tmpZip = Join-Path $env:TEMP "multica-server-sync.zip"

    # Use .NET ZipFile so it works on Windows without external tools
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $tmpZip) { Remove-Item $tmpZip }

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $localServer,
        $tmpZip,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    Write-Yellow "  Zip size: $([math]::Round((Get-Item $tmpZip).Length/1KB, 0)) KB"

    # Remove stale code first so deleted local files don't linger remotely
    ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" "rm -rf ${REMOTE_PROJECT_DIR}/server"
    if ($LASTEXITCODE -ne 0) {
        Write-Red "  SSH rm -rf failed (exit $LASTEXITCODE)"
        Remove-Item $tmpZip
        throw "Failed to remove remote stale server/ directory"
    }

    scp $tmpZip "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}:/tmp/multica-server-sync.zip"
    if ($LASTEXITCODE -ne 0) {
        Write-Red "  scp failed (exit $LASTEXITCODE)"
        Remove-Item $tmpZip
        throw "scp upload failed"
    }
    $unzipResult = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" "unzip -o /tmp/multica-server-sync.zip -d ${REMOTE_PROJECT_DIR} && rm /tmp/multica-server-sync.zip" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red "  Remote unzip failed (exit $LASTEXITCODE): $unzipResult"
        Remove-Item $tmpZip
        throw "Remote unzip failed"
    }
    Remove-Item $tmpZip
    Write-Green "  Code synced."

    # Step 3: remote build (server + daemon)
    Write-Cyan "  Step 3/4: remote build..."
    $buildScript = @'
set -e
export GONOSUMCHECK='*' GONOSUMDB='*' GOPROXY=https://goproxy.cn,direct GOTOOLCHAIN=go1.26.1
cd ~/__work/multica/server
mkdir -p bin
start_time=$(date +%s)
go build -o bin/multica-server ./cmd/server/
go build -o bin/multica ./cmd/multica/
end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "BUILD OK (${elapsed}s)"
'@
    $buildResult = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" ($buildScript -replace '\r') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red "  Remote build failed (exit $LASTEXITCODE):"
        Write-Host $buildResult
        throw "Remote go build failed"
    }
    Write-Host $buildResult
    Write-Green "  Build OK."

    # Step 3.5: ensure systemd service files exist and are up to date
    Write-Cyan "  Step 3.5/5: ensuring systemd services..."
    $serviceScript = @'
set -e
SERVER_SERVICE="/etc/systemd/system/multica-server.service"
DAEMON_SERVICE="/etc/systemd/system/multica-daemon.service"
LOCAL_SERVER="/home/yg/__work/multica/server/deploy/systemd/multica-server.service"
LOCAL_DAEMON="/home/yg/__work/multica/server/deploy/systemd/multica-daemon.service"

# Copy from version-controlled files if they differ or don't exist
if [ ! -f "$SERVER_SERVICE" ] || ! diff -q "$LOCAL_SERVER" "$SERVER_SERVICE" > /dev/null 2>&1; then
    sudo cp "$LOCAL_SERVER" "$SERVER_SERVICE"
    echo 'SERVER_SERVICE_UPDATED'
fi

if [ ! -f "$DAEMON_SERVICE" ] || ! diff -q "$LOCAL_DAEMON" "$DAEMON_SERVICE" > /dev/null 2>&1; then
    sudo cp "$LOCAL_DAEMON" "$DAEMON_SERVICE"
    echo 'DAEMON_SERVICE_UPDATED'
fi

sudo systemctl daemon-reload
sudo systemctl enable multica-server.service
sudo systemctl enable multica-daemon.service
echo 'SERVICES_OK'
'@
    $serviceResult = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" ($serviceScript -replace '\r') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red "  Service setup failed (exit $LASTEXITCODE):"
        Write-Host $serviceResult
        throw "Remote service setup failed"
    }
    Write-Host $serviceResult
    Write-Green "  Services OK."

    # Step 4: stop + start service and verify
    Write-Cyan "  Step 4/5: restart service and verify..."
    $restartScript = @'
set -e
sudo systemctl stop multica-server.service || true
sudo systemctl stop multica-daemon.service || true
sleep 2
sudo fuser -k 8080/tcp 2>/dev/null || true
sudo systemctl start multica-server.service
sleep 1
sudo systemctl start multica-daemon.service
echo 'RESTART OK'
sleep 3
# Server (8080) is the critical piece for the desktop app — it MUST be up.
if ! systemctl is-active --quiet multica-server.service; then
    echo 'RESTART FAILED: multica-server not active'
    systemctl status multica-server.service --no-pager -l
    exit 1
fi
if ! ss -tlnp | grep -q ':8080'; then
    echo 'RESTART FAILED: port 8080 not listening'
    exit 1
fi
echo 'VERIFY OK (server)'

# Daemon (local agent runtime) is OPTIONAL — the desktop app's critical
# dependency is the multica-server (8080) above. The daemon only matters
# for local-runtime workflows, and it can fail for reasons that have
# nothing to do with the deploy itself:
#   - not authenticated (needs a one-time `multica login` on the remote)
#   - no agent CLI on PATH (claude/codex/etc. not installed)
# Treat any daemon failure as a soft warning, surface the actual reason
# from its log file (stdout/stderr go to ~/__work/multica/logs/daemon.log,
# not the journal, per the systemd unit), and let sync report success
# as long as the server is healthy.
if ! systemctl is-active --quiet multica-daemon.service; then
    DAEMON_LOG="$HOME/__work/multica/logs/daemon.log"
    DAEMON_REASON="(no log found at $DAEMON_LOG)"
    if [ -r "$DAEMON_LOG" ]; then
        DAEMON_REASON="$(tail -50 "$DAEMON_LOG" | grep -E 'Error:|ERR ' | tail -3 | tr '\n' ' ')"
    fi
    echo 'DAEMON_SKIP: multica-daemon is not running.'
    echo "             Latest error: ${DAEMON_REASON:-unknown}"
    echo '             The server is up and the desktop app can connect. To enable local'
    echo '             agent runtime, fix the daemon on the remote (commonly: run'
    echo "             'multica login' once on $(hostname -s)) — the systemd unit is"
    echo '             still enabled and will auto-restart on success.'
    exit 0
fi
echo 'VERIFY OK (daemon)'
'@
    $restartResult = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" ($restartScript -replace '\r') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red "  Service restart or verification failed (exit $LASTEXITCODE):"
        Write-Host $restartResult
        throw "Remote service restart failed"
    }
    Write-Host $restartResult

    # Distinguish a fully-green verify from a soft skip on the daemon.
    if ($restartResult -match 'DAEMON_SKIP') {
        Write-Yellow "==> Remote server synced + restarted. Daemon (local agent runtime) is unavailable."
        Write-Yellow "    Install an agent CLI on the remote to enable it."
    } else {
        Write-Green "==> Remote server synced + restarted + verified ==================="
    }

    Write-DesktopConfig
}

# ── Login Remote (one-time daemon auth) ─────────────────────────────────────
# The local agent runtime (multica-daemon) requires a `mul_xxx` personal
# access token to talk to the server. This routine mints one end-to-end
# from the .ps1 script, then installs it on the remote:
#
#   1. POST /auth/send-code              → server prints [DEV] code to log
#   2. POST /auth/verify-code (888888)   → JWT (dev bypass; works whenever
#                                          APP_ENV != production and the
#                                          server's .env has the dev code)
#   3. POST /api/tokens (Bearer JWT)     → mul_xxx PAT
#   4. SSH + pipe PAT into `multica login --token ''` (stdin path keeps the
#      token out of argv / shell history / `ps`)
#   5. sudo systemctl restart multica-daemon, verify active
#
# The user only supplies the email; everything else is automatic.
function Invoke-LoginRemote {
    Write-Cyan "==> Login: authenticate remote daemon ($REMOTE_SSH_USER@$REMOTE_DEV_HOST) ==="

    if (-not $REMOTE_DEV_HOST) {
        Write-Red "  REMOTE_DEV_HOST is empty — cannot login."
        return
    }

    $apiBase = "http://${REMOTE_DEV_HOST}:8080"

    # Sanity-check the server is actually up before we burn an email.
    try {
        $cfg = Invoke-RestMethod -Uri "$apiBase/api/config" -TimeoutSec 5
    } catch {
        Write-Red "  Cannot reach $apiBase — is the multica-server running?"
        Write-Red "  $_"
        return
    }

    $defaultEmail = "yg@local"
    $email = (Read-Host "  Email to register/login as [default: $defaultEmail]").Trim()
    if (-not $email) { $email = $defaultEmail }
    if ($email -notmatch '^[^@\s]+@[^@\s]+$') {
        Write-Red "  '$email' is not a valid email (must contain '@' and a domain)."
        return
    }

    # Step 1: send-code. Server logs the code in dev mode (no SMTP needed);
    # the verify step uses the static 888888 dev code so we never need to
    # scrape the log here.
    Write-Cyan "  Step 1/4: requesting verification code..."
    try {
        $sendResp = Invoke-RestMethod -Uri "$apiBase/auth/send-code" `
            -Method Post -ContentType "application/json" `
            -Body (ConvertTo-Json @{email = $email} -Compress) `
            -TimeoutSec 15
    } catch {
        Write-Red "  send-code failed: $_"
        return
    }
    Write-Yellow "    server: $($sendResp.message)"

    # Step 2: verify-code with the dev bypass.
    Write-Cyan "  Step 2/4: verifying with dev code..."
    try {
        $verifyResp = Invoke-RestMethod -Uri "$apiBase/auth/verify-code" `
            -Method Post -ContentType "application/json" `
            -Body (ConvertTo-Json @{email = $email; code = "888888"} -Compress) `
            -TimeoutSec 15
    } catch {
        $msg = $_.Exception.Message
        try { $msg = ($_.ErrorDetails | ConvertFrom-Json).message } catch {}
        Write-Red "  verify-code failed: $msg"
        Write-Yellow "  (Is MULTICA_DEV_VERIFICATION_CODE=888888 set on the remote .env?"
        Write-Yellow "   Is APP_ENV != production? See deploy/systemd/install.sh.)"
        return
    }
    $jwt = $verifyResp.token
    if (-not $jwt) {
        Write-Red "  verify-code did not return a token. Got: $($verifyResp | ConvertTo-Json -Compress)"
        return
    }
    Write-Yellow "    authenticated as $($verifyResp.user.email) ($($verifyResp.user.name))"

    # Step 3: mint a mul_ PAT. The handler at /api/tokens is what the web UI
    # uses for "Personal Access Tokens" — same endpoint.
    Write-Cyan "  Step 3/4: minting personal access token..."
    try {
        $patResp = Invoke-RestMethod -Uri "$apiBase/api/tokens" `
            -Method Post -ContentType "application/json" `
            -Headers @{Authorization = "Bearer $jwt"} `
            -Body (ConvertTo-Json @{name = "daemon-auto-sync"} -Compress) `
            -TimeoutSec 15
    } catch {
        $msg = $_.Exception.Message
        try { $msg = ($_.ErrorDetails | ConvertFrom-Json).message } catch {}
        Write-Red "  mint PAT failed: $msg"
        return
    }
    $pat = $patResp.token
    if (-not $pat -or $pat -notmatch '^mul_') {
        Write-Red "  PAT response missing or malformed mul_ token. Got: $($patResp | ConvertTo-Json -Compress)"
        return
    }
    $patPreview = if ($pat.Length -gt 12) { $pat.Substring(0, 12) + '...' } else { $pat }
    Write-Yellow "    minted: $patPreview"

    # Step 4: install on remote. Token goes through stdin (`multica login`
    # prompts on stdin when --token is empty), keeping it out of argv,
    # /proc, and shell history. We also need to use TTY allocation for
    # the daemon restart; `sudo` may prompt for the password on first call
    # in a session, so we add a small grace period.
    Write-Cyan "  Step 4/4: applying token on remote and restarting daemon..."
    $remoteCmd = @'
set -e
# Pipe the token (already on stdin from PowerShell) into multica login's
# interactive prompt. multica login --token '' reads from stdin when the
# value is empty — see runAuthLoginToken in cmd_auth.go.
multica login --token '' < /dev/stdin
sudo systemctl restart multica-daemon.service
sleep 4
if systemctl is-active --quiet multica-daemon.service; then
    echo 'LOGIN_VERIFY_OK'
else
    echo 'LOGIN_VERIFY_FAILED'
    sudo systemctl status multica-daemon.service --no-pager -l
    tail -20 ~/__work/multica/logs/daemon.log 2>/dev/null
    exit 1
fi
'@
    # ssh -T disables pseudo-tty allocation; stdin is forwarded directly.
    # The PAT goes to a unique temp file via scp, then `multica login` reads
    # it via stdin redirect. The remote file is rm'd immediately after use.
    $tmpLocal = [System.IO.Path]::GetTempFileName()
    $tmpRemote = "/tmp/.multica-pat-$([System.Guid]::NewGuid().ToString('N'))"
    try {
        Set-Content -Path $tmpLocal -Value $pat -NoNewline -Encoding UTF8
        scp $tmpLocal "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}:$tmpRemote" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "scp upload failed (exit $LASTEXITCODE)" }

        $applyScript = @"
set -e
# Use the absolute path the systemd unit uses — interactive SSH sessions
# don't inherit the unit's PATH override.
$REMOTE_PROJECT_DIR/server/bin/multica login --token '' < '$tmpRemote'
rm -f '$tmpRemote'
sudo systemctl restart multica-daemon.service
sleep 4
if systemctl is-active --quiet multica-daemon.service; then
    echo 'LOGIN_VERIFY_OK'
else
    echo 'LOGIN_VERIFY_FAILED'
    sudo systemctl status multica-daemon.service --no-pager -l
    tail -20 \$HOME/__work/multica/logs/daemon.log 2>/dev/null
    exit 1
fi
"@
        $applyResult = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" ($applyScript -replace '\r') 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Red "  Remote login/restart failed (exit $LASTEXITCODE):"
            Write-Host $applyResult
            ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" "rm -f '$tmpRemote'" 2>&1 | Out-Null
            return
        }
        Write-Host $applyResult
    } finally {
        Remove-Item $tmpLocal -ErrorAction SilentlyContinue
    }

    Write-Green "==> Login complete: local agent runtime is now available =========="
}

# ── Fetch Verification Code ─────────────────────────────────────────────────
# The dev server prints the 6-digit code to stdout (no SMTP configured).
# systemd redirects multica-server's stdout to ~/__work/multica/logs/server.log,
# so we just SSH in and grep for the latest [DEV] line for the given email.
#
# Flow:
#   1. Trigger POST /auth/send-code so a fresh code is generated.
#      Falls through gracefully if rate-limited (60s window) and reuses
#      whatever code is already pending.
#   2. grep the server log for the most recent code for that email.
#   3. Print the last 3 codes (so the user can see whether the latest was
#      already used and pick a different one if so) and copy the latest
#      to the Windows clipboard for paste into the desktop app.
function Invoke-FetchVerificationCode {
    param([string]$Email = "")

    if (-not $Email) {
        $default = if ($env:USERNAME) { "$env:USERNAME@local" } else { "yg@local" }
        $Email = (Read-Host "  Email to fetch code for [default: $default]").Trim()
        if (-not $Email) { $Email = $default }
    }

    if (-not $REMOTE_DEV_HOST) {
        Write-Red "  REMOTE_DEV_HOST is empty — cannot fetch."
        return
    }

    $apiBase = "http://${REMOTE_DEV_HOST}:8080"
    $remoteLog = '$HOME/__work/multica/logs/server.log'

    Write-Cyan "==> Code: latest verification code for $Email ===================="

    Write-Cyan "  Step 1/3: requesting fresh code..."
    try {
        $sendResp = Invoke-RestMethod -Uri "$apiBase/auth/send-code" `
            -Method Post -ContentType "application/json" `
            -Body (ConvertTo-Json @{email = $Email} -Compress) `
            -TimeoutSec 15
        Write-Yellow "    server: $($sendResp.message)"
    } catch {
        $msg = $_.Exception.Message
        try { $msg = ($_.ErrorDetails | ConvertFrom-Json).message } catch {}
        if ($msg -match 'please wait') {
            Write-Yellow "    rate-limited (60s window); reusing the most recent code"
        } else {
            Write-Red "    send-code failed: $msg"
            return
        }
    }

    Write-Cyan "  Step 2/3: reading code from server log..."
    $sshCmd = "grep '\[DEV\] Verification code for $Email' $remoteLog | tail -1"
    $raw = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" $sshCmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Red "    grep failed (exit $LASTEXITCODE): $raw"
        return
    }

    if ($raw -notmatch '\[DEV\] Verification code for [^:]+:\s*(\d{6})') {
        Write-Red "    no [DEV] code found for $Email in $remoteLog"
        return
    }
    $code = $matches[1]
    Write-Green "    latest code: $code"

    Write-Cyan "  Step 3/3: last 3 codes for $Email..."
    $recent = ssh "${REMOTE_SSH_USER}@${REMOTE_DEV_HOST}" `
        "grep '\[DEV\] Verification code for $Email' $remoteLog | tail -3" 2>&1
    $recent | ForEach-Object { Write-Yellow "    $_" }

    # Copy to clipboard for quick paste into the desktop app.
    try {
        Set-Clipboard -Value $code -ErrorAction Stop
        Write-Green "==> Latest code: $code  (copied to clipboard) =================="
    } catch {
        try { $code | & clip.exe; Write-Green "==> Latest code: $code  (copied to clipboard) ==================" }
        catch { Write-Green "==> Latest code: $code ==========================================" }
    }
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
    Write-Host "  5) Sync   — sync server/ to remote ($REMOTE_DEV_HOST), build, restart, verify"
    Write-Host ""
    Write-Host "  6) Login  — authenticate remote daemon (one-time, uses dev code if set)"
    Write-Host ""
    Write-Host "  7) GetCode — fetch latest verification code for an email (dev server prints to log)"
    Write-Host ""
    Write-Host "  0) Exit"
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Cyan
    $choice = Read-Host "  Select [0-7]"
    switch ($choice) {
        "1" { try { Invoke-Pull } catch { Write-Red "Pull failed: $_" } }
        "2" { try { Invoke-Buildexe } catch { Write-Red "Build failed: $_" } }
        "3" { try { Invoke-BuildDev } catch { Write-Red "Fast build failed: $_" } }
        "4" { try { Invoke-PushFeature } catch { Write-Red "Push failed: $_" } }
        "5" { try { Invoke-SyncRemoteServer } catch { Write-Red "Sync failed: $_" } }
        "6" { try { Invoke-LoginRemote } catch { Write-Red "Login failed: $_" } }
        "7" { try { Invoke-FetchVerificationCode } catch { Write-Red "Fetch code failed: $_" } }
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
        "fast"  { try { Invoke-BuildDev } catch { Write-Red "Fast build failed: $_"; exit 1 } }
        "push"  { try { Invoke-PushFeature } catch { Write-Red "Push failed: $_"; exit 1 } }
        "sync"  { try { Invoke-SyncRemoteServer } catch { Write-Red "Sync failed: $_"; exit 1 } }
        "login" { try { Invoke-LoginRemote } catch { Write-Red "Login failed: $_"; exit 1 } }
        "code"  {
            $email = if ($args.Count -gt 0) { [string]$args[0] } else { "" }
            try { Invoke-FetchVerificationCode -Email $email } catch { Write-Red "Fetch code failed: $_"; exit 1 }
        }
        default {
            while ($true) { Show-Menu }
        }
    }
}

Main @args
