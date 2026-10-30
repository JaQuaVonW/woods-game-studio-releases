# What a new user gets, on a machine that has never seen Woods Game Studio: a fresh Windows VM
# with Python removed, anonymous downloads from the public release and feed, no source and no
# credentials. Installs the previous release when there is one and updates it online to the
# latest; otherwise installs the latest. Then MCP, the app, and uninstalling.
$ErrorActionPreference = 'Stop'
$Repo = $env:GITHUB_REPOSITORY
$Feed = $env:FEED_URL.TrimEnd('/')
$Root = Join-Path $env:LOCALAPPDATA 'Programs\Woods Game Studio'
$Data = Join-Path $env:APPDATA 'Woods Game Studio'
$Shots = Join-Path $env:RUNNER_TEMP 'shots'
New-Item -ItemType Directory -Force $Shots | Out-Null
function Say($m) { Write-Host "== $m" }
function Fail($m) { throw "FAILED: $m" }
function Until-True($what, $seconds, [scriptblock]$test) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = & $test; if ($r) { return $r } } catch { }
        Start-Sleep -Milliseconds 700
    }
    Fail "timed out after ${seconds}s waiting for $what"
}
function Shot($name) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = [System.Drawing.Bitmap]::new($b.Width, $b.Height)
    [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $Shots "$name.png"))
}

# ------------------------------------------------------------------ no Python on this machine
Say 'removing Python from this machine'
$env:PATH = ($env:PATH -split ';' | Where-Object { $_ -notmatch '(?i)python|pypy|pipx' }) -join ';'
foreach ($p in 'C:\hostedtoolcache\windows\Python', 'C:\hostedtoolcache\windows\PyPy', 'C:\Windows\py.exe', 'C:\Windows\pyw.exe') {
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}
foreach ($c in 'python', 'python3', 'py') {
    $found = $false
    try { $v = & $c --version 2>&1; if ($LASTEXITCODE -eq 0 -and "$v" -match 'Python \d') { $found = $true } } catch { }
    if ($found) { Fail "$c still runs" }
}
Say 'no python, python3 or py on this machine'
if (Test-Path $Root) { Fail 'this machine already has an install' }
if (Test-Path $Data) { Fail 'this machine already has user data' }

# -------------------------------------------------------------------- what the public can see
$stable = Until-True 'the public feed' 120 { Invoke-RestMethod "$Feed/stable.json?t=$(Get-Random)" }
$latest = $stable.version
$tags = git ls-remote --tags --refs "https://github.com/$Repo.git" | ForEach-Object { ($_ -split 'refs/tags/v')[1] } |
    Where-Object { $_ -and $_ -notmatch '-' } | Sort-Object { [version]$_ }
$from = $tags | Where-Object { [version]$_ -lt [version]$latest } | Select-Object -Last 1
$start = if ($from) { $from } else { $latest }
Say "latest $latest; starting from $start"

# --------------------------------------------------------- Claude Code, the way a user has it
Say 'installing Claude Code'
npm install -g @anthropic-ai/claude-code 2>&1 | Select-Object -Last 2

# ---------------------------------------------------------------------------------- installer
$setup = Join-Path $env:RUNNER_TEMP "WoodsGameStudioSetup-$start.exe"
Invoke-WebRequest -UseBasicParsing "https://github.com/$Repo/releases/download/v$start/WoodsGameStudioSetup-$start.exe" -OutFile $setup
Say "downloaded the installer anonymously: $((Get-Item $setup).Length) bytes"
$t0 = Get-Date
Start-Process -Wait -FilePath $setup -ArgumentList '/S', '/DESKTOP', '/MCP', '/NOLAUNCH'
Say ("installed in {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds)
$v = & (Join-Path $Root 'current\wgs.exe') version
if ("$v".Trim() -ne $start) { Fail "wgs.exe says $v" }
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Woods Game Studio.lnk'
if (-not (Test-Path $lnk)) { Fail 'no Start menu entry' }
if (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Woods Game Studio.lnk'))) { Fail 'no desktop shortcut' }
if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WoodsGameStudio')) { Fail 'no uninstall entry' }
Say 'junction, shortcuts and uninstall entry are in place'

$claude = Join-Path $env:USERPROFILE '.claude.json'
if (-not (Test-Path $claude) -or -not ((Get-Content $claude -Raw | ConvertFrom-Json).mcpServers.'woods-game-studio')) { Fail 'the installer did not register the MCP server with Claude Code' }
Say 'Claude Code has woods-game-studio registered:'
claude mcp list 2>&1 | Select-String 'woods' | ForEach-Object { Write-Host "   $($_.Line)" }

# ---------------------------------------------------------------------- MCP, as Claude Code does
function Test-Mcp {
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $Root 'current\wgs.exe'), 'mcp')
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.BeginErrorReadLine()
    $rpc = {
        param($id, $method, $params)
        $p.StandardInput.WriteLine((@{ jsonrpc = '2.0'; id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress))
        $p.StandardInput.Flush()
        $line = $p.StandardOutput.ReadLineAsync()
        if (-not $line.Wait(60000)) { Fail "no MCP answer to $method" }
        $line.Result | ConvertFrom-Json -Depth 30
    }
    $init = & $rpc 1 'initialize' @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'clean-install-test'; version = '1' } }
    $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}'); $p.StandardInput.Flush()
    $tools = (& $rpc 2 'tools/list' @{}).result.tools
    $call = & $rpc 3 'tools/call' @{ name = 'projects_list'; arguments = @{} }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(15000)) { $p.Kill() }
    if ($call.result.isError) { Fail 'projects_list failed over MCP' }
    if ($tools.Count -lt 50) { Fail "only $($tools.Count) MCP tools" }
    Say "MCP: $($init.result.serverInfo.name) $($init.result.serverInfo.version), $($tools.Count) tools, projects_list ok"
    return $init.result.serverInfo.version
}
if ((Test-Mcp) -ne $start) { Fail 'the MCP server reports another version' }

# ---------------------------------------------------------------------------------- the app
function App-Base { (Select-String -Path (Join-Path $Data 'studio.log') -Pattern 'http://127\.0\.0\.1:\d+' | Select-Object -Last 1).Matches[0].Value }
function Wait-Version($want) {
    Until-True "the app on $want" 90 {
        $b = App-Base
        if ((Invoke-RestMethod -TimeoutSec 5 "$b/api/home").app.version -eq $want) { $b }
    }
}
Start-Process -FilePath (Get-Item $lnk).FullName
$base = Wait-Version $start
$hdr = @{ Origin = $base }
Say "the app opened at $base"
$sample = Join-Path $env:RUNNER_TEMP 'Sample Game'
New-Item -ItemType Directory -Force $sample | Out-Null
'{"format":"wgs-project/1.0","id":"sample","name":"Sample Game","style":"topdown","units":{"tile":16,"pixelsPerStud":8},"scenes":"scenes"}' |
    Set-Content -Encoding utf8NoBOM (Join-Path $sample 'woods.project.json')
$post = { param($path, $body) Invoke-RestMethod -Method Post -Headers $hdr -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 6 -Compress) "$base$path" }
$null = & $post '/api/projects/add' @{ path = $sample }
$made = & $post '/api/op/scene_create' @{ project = 'sample'; id = 'first'; width = 64; height = 64 }
if (-not $made.ok) { Fail 'could not create a world' }
$null = & $post '/api/ui-state' @{ project = 'sample'; state = @{ scene = 'first'; section = 'worlds' } }
if ((Invoke-RestMethod "$base/api/home").projects.name -notcontains 'Sample Game') { Fail 'the project is not on Home' }
Say 'added a project, made a world'
Start-Sleep -Seconds 3
Shot 'home'

$u = Until-True 'the update check on start' 60 {
    $s = Invoke-RestMethod "$base/api/update"
    if ($s.state -in 'available', 'ready', 'current', 'error', 'unavailable') { $s }
}
Say "update check on start: $($u.state) $($u.error) (feed $($u.feed))"
if ($from) {
    if ($u.state -notin 'available', 'ready' -or $u.available.version -ne $latest) { Fail "$start did not find $latest by itself" }
    $null = Invoke-RestMethod -Method Post -Headers $hdr "$base/api/update/download"
    $u = Until-True 'the download' 300 { $s = Invoke-RestMethod "$base/api/update"; if ($s.state -in 'ready', 'error') { $s } }
    if ($u.state -ne 'ready') { Fail "download: $($u.error)" }
    Say 'downloaded and verified over the internet'
    Shot 'ready'
    $null = Invoke-RestMethod -Method Post -Headers $hdr "$base/api/update/install"
    Until-True "install.json on $latest" 180 { (Get-Content (Join-Path $Root 'install.json') -Raw | ConvertFrom-Json).current -eq $latest } | Out-Null
    $base = Wait-Version $latest
    $hdr = @{ Origin = $base }
    $res = Get-Content (Join-Path $Data 'update-result.json') -Raw | ConvertFrom-Json
    if (-not $res.ok) { Fail "update result: $($res.error)" }
    if ((Invoke-RestMethod "$base/api/home").projects.name -notcontains 'Sample Game') { Fail 'the project was lost in the update' }
    if ((Invoke-RestMethod "$base/api/ui-state?project=sample").scene -ne 'first') { Fail 'the view state was lost in the update' }
    Say "updated online from $start to $latest; the app reopened; projects and view state kept"
    if ((Test-Mcp) -ne $latest) { Fail 'the MCP server reports another version after updating' }
    if ((& (Join-Path $Root 'current\wgs.exe') version).Trim() -ne $latest) { Fail 'wgs.exe was not updated' }
} else {
    if ($u.state -ne 'current') { Fail "expected up to date, got $($u.state): $($u.error)" }
}
Start-Sleep -Seconds 2
Shot 'final'

# ---------------------------------------------------------------------------------- uninstall
Get-Process 'Woods Game Studio' -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*Woods Game Studio*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
& (Join-Path $Root 'WGS Updater.exe') --uninstall --quiet
Until-True 'the program folder to go' 60 { -not (Test-Path (Join-Path $Root 'install.json')) } | Out-Null
Start-Sleep -Seconds 2
if (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WoodsGameStudio') { Fail 'the uninstall entry remains' }
if (Test-Path $lnk) { Fail 'the Start menu entry remains' }
if (-not (Test-Path (Join-Path $Data 'projects.json'))) { Fail 'uninstalling removed user data' }
if (-not (Test-Path (Join-Path $sample 'woods.project.json'))) { Fail 'uninstalling touched a project' }
Say 'uninstalled; settings and the project remain'
Say 'CLEAN-MACHINE TEST PASSED'
