# Installs the custom Claude Code status line on Windows.
# Run:  powershell -ExecutionPolicy Bypass -File "$HOME\Downloads\install-statusline.ps1"
# Backs up any existing settings.json and keeps all your other settings.
$ErrorActionPreference = 'Stop'

$claudeDir = Join-Path $HOME '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
$scriptPath = Join-Path $claudeDir 'statusline.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)

# Check settings first so a bad file leaves everything untouched.
$settings = $null
if (Test-Path -LiteralPath $settingsPath) {
    $rawSettings = [IO.File]::ReadAllText($settingsPath)
    if ($rawSettings.Trim()) {
        try {
            $settings = ConvertFrom-Json -InputObject $rawSettings
        } catch {
            Write-Host "$settingsPath is not valid JSON ($($_.Exception.Message)). Nothing was changed." -ForegroundColor Red
            exit 1
        }
        if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
            Write-Host "$settingsPath does not contain a JSON object. Nothing was changed." -ForegroundColor Red
            exit 1
        }
    }
}
if (-not $settings) { $settings = New-Object PSObject }

New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null

$statusline = @'
# Claude Code status line for Windows (Windows PowerShell 5.1 or PowerShell 7).
# Example output:
# Opus 5.5 | #####/////// 42% (hourglass) 12 min | 73%^ 1:48 | libs/Dress-Code | (leaf) main | (folder) scratch
# This file is ASCII-only on purpose; symbols are built from character codes.

$ErrorActionPreference = 'Stop'

# Settings you may want to change
$BarWidth = 12
$MaxBranch = 40                # longer branch names are shortened
$MinCacheTokens = 10000        # hide the countdown when less than this is cached
$DefaultCacheTtl = 300         # used if the transcript does not reveal the TTL
$AheadMargin = 3               # percentage points before showing the up arrow
$ScratchDirs = @('scratch', '.scratch')   # relative to the project root
$TailBytes = 512KB             # how much of the transcript to scan

$LimitWindows = [ordered]@{ five_hour = 5 * 3600; seven_day = 7 * 86400 }
if ($env:STATUSLINE_LIMITS_FILE) {
    $LimitsFile = $env:STATUSLINE_LIMITS_FILE
} else {
    $LimitsFile = Join-Path $HOME '.claude\statusline-limits.json'
}

$Esc = [char]27
$Bell = [char]7
$AnsiReset = "$Esc[0m"
$AnsiGreen = "$Esc[32m"
$AnsiYellow = "$Esc[33m"
$AnsiRed = "$Esc[31m"
# (filled, unfilled) 24-bit colors for the context bar
$BarGreen = @("$Esc[38;2;110;224;138m", "$Esc[38;2;64;140;86m")
$BarYellow = @("$Esc[38;2;240;205;100m", "$Esc[38;2;150;126;60m")
$BarRed = @("$Esc[38;2;240;105;95m", "$Esc[38;2;150;66;60m")

$IconBlock = [string][char]0x2588
$IconHatch = [string][char]0x2571
$IconHourglass = [string][char]0x29D7
$IconUp = [string][char]0x2191
$IconEllipsis = [string][char]0x2026
$IconLeaf = [char]::ConvertFromUtf32(0x1F33F)
$IconFolder = [char]::ConvertFromUtf32(0x1F4C1)


function Paint($text, $color) {
    return "$color$text$AnsiReset"
}

function Get-SafeText($text, $limit = 0) {
    # Drop control characters (terminal escapes) and shorten long text.
    $text = ([string]$text) -replace '[\x00-\x1f\x7f-\x9f]', ''
    if ($limit -gt 0 -and $text.Length -gt $limit) { $text = $text.Substring(0, $limit - 1) + $IconEllipsis }
    return $text
}

function Get-Level($pct) {
    if ($pct -lt 50) { return $AnsiGreen }
    if ($pct -lt 80) { return $AnsiYellow }
    return $AnsiRed
}

function Link($text, $target) {
    try {
        $url = ([Uri]([string]$target)).AbsoluteUri
    } catch {
        return $text
    }
    return "$Esc]8;;$url$Bell$text$Esc]8;;$Bell"
}

function ConvertTo-Epoch($value) {
    # Accept epoch seconds, epoch milliseconds, a date, or an ISO 8601 string.
    if ($null -eq $value) { return $null }
    if ($value -is [datetime]) {
        return [DateTimeOffset]::new($value.ToUniversalTime()).ToUnixTimeMilliseconds() / 1000.0
    }
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
        $number = [double]$value
        if ($number -gt 1e12) { return $number / 1000.0 }
        return $number
    }
    try {
        $parsed = [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture)
        return $parsed.ToUnixTimeMilliseconds() / 1000.0
    } catch {
        return $null
    }
}

function Get-ContextSegment($data) {
    $ctx = $data.context_window
    $pct = $ctx.used_percentage
    if ($null -eq $pct -and $null -ne $ctx.remaining_percentage) {
        $pct = 100 - [double]$ctx.remaining_percentage
    }
    if ($null -eq $pct) { $pct = 0 }
    $pct = [double]$pct
    $minimum = 0.0
    if ($pct -gt 0) { $minimum = 1.0 }
    $filled = [int][Math]::Min([double]$BarWidth, [Math]::Max($minimum, [Math]::Round($pct / 100 * $BarWidth)))
    if ($pct -lt 50) { $pair = $BarGreen } elseif ($pct -lt 80) { $pair = $BarYellow } else { $pair = $BarRed }
    $bar = (Paint ($IconBlock * $filled) $pair[0]) + (Paint ($IconHatch * ($BarWidth - $filled)) $pair[1])
    return "$bar " + ('{0:0}%' -f $pct)
}

function Get-TailLines($transcript) {
    # Return the last lines of the transcript, newest first.
    $stream = [IO.File]::Open($transcript, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [Math]::Max([long]0, $stream.Length - $TailBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ($stream.Length - $start)
        $read = 0
        while ($read -lt $buffer.Length) {
            $count = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($count -le 0) { break }
            $read += $count
        }
    } finally {
        $stream.Dispose()
    }
    $lines = [Text.Encoding]::UTF8.GetString($buffer, 0, $read) -split "`r?`n"
    [array]::Reverse($lines)
    return $lines
}

function Get-CacheSegment($data, $now) {
    $transcript = $data.transcript_path
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript -PathType Leaf)) { return '' }
    $latest = $null
    $ttl = 0
    $checked = 0
    foreach ($line in (Get-TailLines $transcript)) {
        if (-not $line -or -not $line.Contains('"usage"')) { continue }
        try { $entry = ConvertFrom-Json -InputObject $line } catch { continue }
        $usage = $entry.message.usage
        if ($entry.type -ne 'assistant' -or -not $usage -or $entry.isSidechain) { continue }
        if (-not $latest) { $latest = $entry }
        $created = $usage.cache_creation
        if ($created.ephemeral_1h_input_tokens) { $ttl = 3600; break }
        if ($created.ephemeral_5m_input_tokens) { $ttl = 300; break }
        $checked += 1
        if ($checked -ge 50) { break }
    }
    if (-not $latest) { return '' }
    if (-not $ttl) { $ttl = $DefaultCacheTtl }
    $usage = $latest.message.usage
    $cached = [double]$usage.cache_read_input_tokens + [double]$usage.cache_creation_input_tokens
    $started = ConvertTo-Epoch $latest.timestamp
    if ($cached -lt $MinCacheTokens -or $null -eq $started) { return '' }
    $left = $started + $ttl - $now
    if ($left -le 0) { return (Paint "$IconHourglass cold" $AnsiRed) }
    if ($left -lt $ttl * 0.1) { $color = $AnsiRed } else { $color = $AnsiYellow }
    if ($left -lt 60) { $label = '<1 min' } else { $label = '{0} min' -f [Math]::Floor($left / 60) }
    return (Paint "$IconHourglass $label" $color)
}

function Format-Reset($seconds) {
    $seconds = [Math]::Floor([Math]::Max(0.0, [double]$seconds))
    $hours = [Math]::Floor($seconds / 3600)
    $minutes = [Math]::Floor(($seconds % 3600) / 60)
    if ($hours -ge 24) {
        return '{0}d {1}h' -f [Math]::Floor($hours / 24), ($hours % 24)
    }
    return '{0}:{1:00}' -f $hours, $minutes
}

function Get-CurrentLimits($data, $now) {
    # Use live limits and save them; before the first reply, use the saved ones.
    $live = $data.rate_limits
    if ($live) {
        try {
            $temp = "$LimitsFile.$PID"
            [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $live -Depth 5 -Compress))
            Move-Item -LiteralPath $temp -Destination $LimitsFile -Force
        } catch {
        }
        return $live
    }
    try {
        $saved = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($LimitsFile))
    } catch {
        return $null
    }
    $result = [ordered]@{}
    foreach ($name in $LimitWindows.Keys) {
        $window = $saved.$name
        if ($window) {
            $resetsAt = ConvertTo-Epoch $window.resets_at
            if ($null -ne $resetsAt -and $resetsAt -gt $now) { $result[$name] = $window }
        }
    }
    return [pscustomobject]$result
}

function Get-PlanSegment($data, $now) {
    $limits = Get-CurrentLimits $data $now
    if (-not $limits) { return '' }
    $best = $null
    foreach ($name in $LimitWindows.Keys) {
        $window = $limits.$name
        if ($window -and $null -ne $window.used_percentage) {
            $used = [double]$window.used_percentage
            if (-not $best -or $used -gt $best.Used) {
                $best = @{ Used = $used; ResetsAt = (ConvertTo-Epoch $window.resets_at); Length = $LimitWindows[$name] }
            }
        }
    }
    if (-not $best) { return '' }
    $label = '{0:0}%' -f $best.Used
    $suffix = ''
    if ($null -ne $best.ResetsAt) {
        $left = [Math]::Max(0.0, $best.ResetsAt - $now)
        $elapsed = [Math]::Max(0.0, [Math]::Min(100.0, (1 - $left / $best.Length) * 100))
        if ($best.Used -gt $elapsed + $AheadMargin) { $label += $IconUp }
        $suffix = ' ' + (Format-Reset $left)
    }
    return (Paint $label (Get-Level $best.Used)) + $suffix
}

function Get-ProjectRoot($data) {
    foreach ($candidate in @($data.workspace.project_dir, $data.workspace.current_dir, $data.cwd, (Get-Location).Path)) {
        if ($candidate) { return [string]$candidate }
    }
}

function Get-ProjectSegment($root) {
    $parts = @(([string]$root) -split '[\\/]' | Where-Object { $_ })
    $label = Get-SafeText ((@($parts | Select-Object -Last 2)) -join '/')
    return (Link $label $root)
}

function Read-Branch($gitDir) {
    # Return the branch in gitDir\HEAD, or a short commit id if detached.
    try {
        $head = ([IO.File]::ReadAllText((Join-Path $gitDir 'HEAD'))).Trim()
    } catch {
        return ''
    }
    $prefix = 'ref: refs/heads/'
    if ($head.StartsWith($prefix)) {
        $name = $head.Substring($prefix.Length)
    } else {
        $name = $head.Substring(0, [Math]::Min(7, $head.Length))
    }
    return (Get-SafeText $name $MaxBranch)
}

function Get-GitName($data, $root) {
    # The worktree name in a linked worktree, otherwise the current branch.
    $name = $data.worktree.name
    if (-not $name) { $name = $data.workspace.git_worktree }
    if ($name) { return (Get-SafeText $name $MaxBranch) }
    $folder = [string]$root
    while ($folder) {
        $marker = Join-Path $folder '.git'
        if (Test-Path -LiteralPath $marker -PathType Container) { return (Read-Branch $marker) }
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            try {
                $target = ([IO.File]::ReadAllText($marker)).Trim()
            } catch {
                return ''
            }
            $at = $target.IndexOf('gitdir:')
            if ($at -ge 0) { $target = $target.Substring($at + 7).Trim() }
            if ($target -match '[\\/]worktrees[\\/]') { return (Get-SafeText (($target -split '[\\/]') | Where-Object { $_ } | Select-Object -Last 1) $MaxBranch) }
            if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $folder $target }
            return (Read-Branch $target)   # a submodule
        }
        $parent = Split-Path -Parent $folder
        if (-not $parent -or $parent -eq $folder) { break }
        $folder = $parent
    }
    return ''
}

function Get-ScratchSegment($data, $root) {
    $candidates = New-Object System.Collections.ArrayList
    if ($data.session_id) {
        $starts = @($root, $data.workspace.current_dir, $data.cwd) | Where-Object { $_ } | Select-Object -Unique
        foreach ($start in $starts) {
            $project = [regex]::Replace([string]$start, '[^a-zA-Z0-9]', '-')
            [void]$candidates.Add((Join-Path ([IO.Path]::GetTempPath()) "claude\$project\$($data.session_id)\scratchpad"))
        }
    }
    foreach ($dirName in $ScratchDirs) { [void]$candidates.Add((Join-Path $root $dirName)) }
    foreach ($candidate in $candidates) {
        try {
            if ((Test-Path -LiteralPath $candidate -PathType Container) -and
                (Get-ChildItem -LiteralPath $candidate -Force | Select-Object -First 1)) {
                return (Link "$IconFolder scratch" $candidate)
            }
        } catch {
        }
    }
    return ''
}


try {
    $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    $data = $null
    if ($raw.Trim()) { $data = ConvertFrom-Json -InputObject $raw }
    if (-not $data) { $data = [pscustomobject]@{} }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $root = Get-ProjectRoot $data

    $model = $data.model.display_name
    if (-not $model) { $model = 'Claude' }
    $context = Get-ContextSegment $data
    $cache = Get-CacheSegment $data $now
    $git = Get-GitName $data $root
    $gitSegment = ''
    if ($git) { $gitSegment = "$IconLeaf $git" }

    $segments = @(
        $model,
        ("$context $cache").TrimEnd(),
        (Get-PlanSegment $data $now),
        (Get-ProjectSegment $root),
        $gitSegment,
        (Get-ScratchSegment $data $root)
    )
    $output = (@($segments | Where-Object { $_ })) -join ' | '
} catch {
    # Keep the bar alive and show what went wrong.
    $output = "statusline error: $($_.Exception.Message)"
}

# Write UTF-8 bytes directly so the console code page cannot garble the symbols.
$bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($output + "`n")
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
'@
[IO.File]::WriteAllText($scriptPath, $statusline, $utf8)

if (Test-Path -LiteralPath $settingsPath) {
    $backup = "$settingsPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $settingsPath -Destination $backup
    Write-Host "Backed up settings to $backup"
}
if ($settings.PSObject.Properties['statusLine']) {
    Write-Host 'Replacing your existing statusLine setting (it is in the backup).'
}
$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + ($scriptPath -replace '\\', '/') + '"'
$statusLineSetting = New-Object PSObject
$statusLineSetting | Add-Member -NotePropertyName type -NotePropertyValue 'command'
$statusLineSetting | Add-Member -NotePropertyName command -NotePropertyValue $command
$statusLineSetting | Add-Member -NotePropertyName refreshInterval -NotePropertyValue 30
$settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLineSetting -Force
$tempSettings = "$settingsPath.tmp"
[IO.File]::WriteAllText($tempSettings, (ConvertTo-Json -InputObject $settings -Depth 100), $utf8)
if (Test-Path -LiteralPath $settingsPath) {
    # Keep the existing file's access rules (ACL) instead of the folder default.
    $access = (Get-Acl -LiteralPath $settingsPath).GetSecurityDescriptorSddlForm('Access')
    $tempAcl = Get-Acl -LiteralPath $tempSettings
    $tempAcl.SetSecurityDescriptorSddlForm($access, 'Access')
    Set-Acl -LiteralPath $tempSettings -AclObject $tempAcl
}
Move-Item -LiteralPath $tempSettings -Destination $settingsPath -Force

# Show a sample of a full session, with made-up data, in this terminal.
Write-Host ''
Write-Host 'Sample of a full session, using made-up data:'
Write-Host ''
$demo = Join-Path ([IO.Path]::GetTempPath()) ('statusline-demo-' + [Guid]::NewGuid().ToString('N'))
$oldConsoleEncoding = [Console]::OutputEncoding
$oldOutputEncoding = $OutputEncoding
try {
    $project = Join-Path $demo 'libs\Dress-Code'
    New-Item -ItemType Directory -Force -Path (Join-Path $project 'scratch') | Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'scratch\notes.txt'), '')
    $transcript = Join-Path $demo 'transcript.jsonl'
    $turn = @{
        type = 'assistant'
        timestamp = [DateTime]::UtcNow.AddMinutes(-47.5).ToString('o')
        message = @{ usage = @{
            cache_read_input_tokens = 90000
            cache_creation_input_tokens = 4000
            cache_creation = @{ ephemeral_1h_input_tokens = 4000 }
        } }
    }
    [IO.File]::WriteAllText($transcript, (ConvertTo-Json -InputObject $turn -Depth 5 -Compress) + "`n", $utf8)
    $resetsAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 6510
    $sample = @{
        model = @{ display_name = 'Opus 5.5' }
        workspace = @{ project_dir = $project }
        worktree = @{ name = 'rule-fixes' }
        transcript_path = $transcript
        context_window = @{ used_percentage = 42 }
        rate_limits = @{ five_hour = @{ used_percentage = 73; resets_at = $resetsAt } }
    }
    # A separate limits file keeps the made-up numbers out of your saved ones.
    $env:STATUSLINE_LIMITS_FILE = Join-Path $demo 'limits.json'
    try { [Console]::OutputEncoding = $utf8 } catch { }
    $OutputEncoding = $utf8
    ConvertTo-Json -InputObject $sample -Depth 5 -Compress |
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
} catch {
    Write-Host "Could not show the sample: $($_.Exception.Message)" -ForegroundColor Yellow
} finally {
    Remove-Item Env:\STATUSLINE_LIMITS_FILE -ErrorAction SilentlyContinue
    try { [Console]::OutputEncoding = $oldConsoleEncoding } catch { }
    $OutputEncoding = $oldOutputEncoding
    Remove-Item -LiteralPath $demo -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Done. Use /restart in Claude Code to load it.'
