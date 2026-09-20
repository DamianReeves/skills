# Requires install.ps1. Run from anywhere:
#   pwsh -File scripts/test-install.ps1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$InstallPs1 = Join-Path $PSScriptRoot 'install.ps1'
$failures = 0
$passes = 0

function Get-LinkTarget([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    $reparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (-not $reparse) {
        return $null
    }
    $target = $item.Target
    if ($null -eq $target) {
        return $null
    }
    if ($target -is [array]) {
        $target = $target[0]
    }
    if (-not $target) {
        return $null
    }
    if (-not [IO.Path]::IsPathRooted($target)) {
        $parent = Split-Path -Parent $item.FullName
        $target = Join-Path $parent $target
    }
    return [IO.Path]::GetFullPath($target)
}

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) {
        $script:passes++
        Write-Host "  ok  $Message"
    } else {
        $script:failures++
        Write-Host "  FAIL  $Message"
    }
}

function New-Fixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("skills-install-test-" + [guid]::NewGuid().ToString('N'))
    $catalog = Join-Path $root 'repo'
    $testHome = Join-Path $root 'home'
    New-Item -ItemType Directory -Path (Join-Path $catalog 'skills\hello') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $catalog 'skills\world') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $catalog 'skills\not-a-skill') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $catalog 'scripts') | Out-Null
    New-Item -ItemType Directory -Path $testHome | Out-Null
    Set-Content -LiteralPath (Join-Path $catalog 'skills\hello\SKILL.md') -Value "---`nname: hello`ndescription: test`n---`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $catalog 'skills\world\SKILL.md') -Value "---`nname: world`ndescription: test`n---`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $catalog 'skills\not-a-skill\README.md') -Value 'ignore me' -NoNewline
    Copy-Item -LiteralPath $InstallPs1 -Destination (Join-Path $catalog 'scripts\install.ps1')
    [pscustomobject]@{
        Root = $root
        Catalog = $catalog
        Home = $testHome
        Install = Join-Path $catalog 'scripts\install.ps1'
    }
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [string[]]$InstallArgs = @()
    )
    $pwshArgs = @(
        '-NoProfile'
        '-File'
        $Fixture.Install
        '-RepoRoot'
        $Fixture.Catalog
        '-UserHome'
        $Fixture.Home
    ) + $InstallArgs
    & pwsh @pwshArgs
    if ($LASTEXITCODE -ne 0) {
        throw "install.ps1 exited $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath $InstallPs1)) {
    Write-Host "FAIL  $InstallPs1 does not exist"
    exit 1
}

# --- project install creates links for skills with SKILL.md ---
$fx = New-Fixture
try {
    Write-Host 'project install'
    Invoke-Installer $fx -InstallArgs @('-Project')
    $helloSkill = [IO.Path]::GetFullPath((Join-Path $fx.Catalog 'skills\hello'))
    $worldSkill = [IO.Path]::GetFullPath((Join-Path $fx.Catalog 'skills\world'))
    foreach ($root in @('.agents\skills', '.claude\skills')) {
        Assert-True ((Get-LinkTarget (Join-Path $fx.Catalog "$root\hello")) -eq $helloSkill) "$root/hello -> skills/hello"
        Assert-True ((Get-LinkTarget (Join-Path $fx.Catalog "$root\world")) -eq $worldSkill) "$root/world -> skills/world"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Catalog "$root\not-a-skill"))) "$root does not link folders without SKILL.md"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Home '.agents\skills\hello'))) 'project-only does not write user home'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- global install writes user home, not the repo ---
$fx = New-Fixture
try {
    Write-Host 'global install'
    Invoke-Installer $fx -InstallArgs @('-Global')
    $helloSkill = [IO.Path]::GetFullPath((Join-Path $fx.Catalog 'skills\hello'))
    Assert-True ((Get-LinkTarget (Join-Path $fx.Home '.agents\skills\hello')) -eq $helloSkill) 'global ~/.agents/skills/hello'
    Assert-True ((Get-LinkTarget (Join-Path $fx.Home '.claude\skills\hello')) -eq $helloSkill) 'global ~/.claude/skills/hello'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Catalog '.agents\skills\hello'))) 'global-only does not write the repo'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- default is project + global ---
$fx = New-Fixture
try {
    Write-Host 'default scope is project and global'
    Invoke-Installer $fx
    $helloSkill = [IO.Path]::GetFullPath((Join-Path $fx.Catalog 'skills\hello'))
    Assert-True ((Get-LinkTarget (Join-Path $fx.Catalog '.claude\skills\hello')) -eq $helloSkill) 'default links project'
    Assert-True ((Get-LinkTarget (Join-Path $fx.Home '.claude\skills\hello')) -eq $helloSkill) 'default links global'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- idempotent re-run ---
$fx = New-Fixture
try {
    Write-Host 'idempotent re-run'
    Invoke-Installer $fx -InstallArgs @('-Project')
    Invoke-Installer $fx -InstallArgs @('-Project')
    $helloSkill = [IO.Path]::GetFullPath((Join-Path $fx.Catalog 'skills\hello'))
    Assert-True ((Get-LinkTarget (Join-Path $fx.Catalog '.agents\skills\hello')) -eq $helloSkill) 'second run keeps the same link'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- does not clobber a real directory ---
$fx = New-Fixture
try {
    Write-Host 'refuse to clobber a real directory'
    $real = Join-Path $fx.Catalog '.claude\skills\hello'
    New-Item -ItemType Directory -Path $real -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $real 'keep.txt') -Value 'do not delete'
    Invoke-Installer $fx -InstallArgs @('-Project')
    Assert-True (Test-Path -LiteralPath (Join-Path $real 'keep.txt')) 'real directory contents survive'
    Assert-True ($null -eq (Get-LinkTarget $real)) 'real directory was not replaced with a link'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- uninstall removes our links and leaves foreign links ---
$fx = New-Fixture
try {
    Write-Host 'uninstall is scoped to this catalog'
    Invoke-Installer $fx -InstallArgs @('-Global')
    $foreignSkill = Join-Path $fx.Root 'other-skill'
    New-Item -ItemType Directory -Path $foreignSkill | Out-Null
    $foreignLink = Join-Path $fx.Home '.claude\skills\foreign'
    New-Item -ItemType Junction -Path $foreignLink -Target $foreignSkill | Out-Null
    Invoke-Installer $fx -InstallArgs @('-Global', '-Uninstall')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Home '.claude\skills\hello'))) 'uninstall removes our global hello link'
    Assert-True (Test-Path -LiteralPath $foreignLink) 'uninstall leaves links that point elsewhere'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- prune stale links for deleted skills ---
$fx = New-Fixture
try {
    Write-Host 'prune stale links'
    Invoke-Installer $fx -InstallArgs @('-Project')
    Remove-Item -LiteralPath (Join-Path $fx.Catalog 'skills\hello') -Recurse -Force
    Invoke-Installer $fx -InstallArgs @('-Project')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Catalog '.agents\skills\hello'))) 'stale hello link is removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $fx.Catalog '.agents\skills\world')) 'world link remains'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- dry-run makes no changes ---
$fx = New-Fixture
try {
    Write-Host 'dry-run'
    Invoke-Installer $fx -InstallArgs @('-Project', '-DryRun')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fx.Catalog '.agents\skills\hello'))) 'dry-run does not create links'
} finally {
    Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$passes passed, $failures failed"
if ($failures -gt 0) {
    exit 1
}
exit 0
