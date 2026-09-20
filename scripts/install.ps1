# Link skills/ into agent discovery dirs without copying files.
#
#   pwsh -File scripts/install.ps1                 # this repo + user home
#   pwsh -File scripts/install.ps1 -Project        # this repo only
#   pwsh -File scripts/install.ps1 -Global         # user home only
#   pwsh -File scripts/install.ps1 -Uninstall
#   pwsh -File scripts/install.ps1 -DryRun
#   pwsh -File scripts/install.ps1 -Status
#
# Windows uses directory junctions (no Developer Mode). Elsewhere, symlinks.

[CmdletBinding()]
param(
    [switch]$Project,
    [switch]$Global,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Status,
    [switch]$Help,
    [string]$RepoRoot,
    [string]$UserHome
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$OnWindows = $env:OS -eq 'Windows_NT'
$DiscoveryNames = @('.agents', '.claude')

function Show-Help {
    @'
Link skills/ into agent discovery directories. Author skills only under skills/<name>/SKILL.md.

  install.ps1                 this repo and user home
  install.ps1 -Project        this repo only (.agents/skills, .claude/skills)
  install.ps1 -Global         user home only (~/.agents/skills, ~/.claude/skills)
  install.ps1 -Uninstall      remove this catalog's links (same scope flags)
  install.ps1 -DryRun         print actions, change nothing
  install.ps1 -Status         show where each skill is linked

  -RepoRoot PATH              catalog root (default: parent of scripts/)
  -UserHome PATH              home for global links (default: user profile)

Links are junctions on Windows and symlinks elsewhere. Existing real
directories are left alone. Links that point at other catalogs are left alone.
'@
}

function ConvertTo-NormalizedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($OnWindows) {
        return $full.TrimEnd('\').ToLowerInvariant()
    }
    return $full.TrimEnd('/').TrimEnd('\')
}

function Test-SamePath([string]$Left, [string]$Right) {
    return (ConvertTo-NormalizedPath $Left) -eq (ConvertTo-NormalizedPath $Right)
}

function Test-PathUnder([string]$Path, [string]$Parent) {
    $pathN = ConvertTo-NormalizedPath $Path
    $parentN = ConvertTo-NormalizedPath $Parent
    if ($pathN -eq $parentN) {
        return $true
    }
    $prefix = if ($OnWindows) { "$parentN\" } else { "$parentN/" }
    return $pathN.StartsWith($prefix)
}

function Get-LinkTarget([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }
    $reparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (-not $reparse) {
        return $null
    }
    $target = $item.Target
    if ($null -eq $target) {
        return $null
    }
    if ($target -is [array]) {
        if ($target.Count -eq 0) {
            return $null
        }
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

function Test-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $false
    }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Remove-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        [IO.Directory]::Delete($item.FullName)
    } else {
        [IO.File]::Delete($item.FullName)
    }
}

function New-SkillLink([string]$LinkPath, [string]$TargetPath) {
    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ($OnWindows) {
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath | Out-Null
    }
}

function Get-CatalogSkills([string]$Root) {
    $skillsDir = Join-Path $Root 'skills'
    if (-not (Test-Path -LiteralPath $skillsDir)) {
        return @()
    }
    Get-ChildItem -LiteralPath $skillsDir -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')
    }
}

function Get-DiscoveryRoots([string]$Base) {
    foreach ($name in $DiscoveryNames) {
        Join-Path $Base (Join-Path $name 'skills')
    }
}

function Get-RelPath([string]$Path, [string]$Base) {
    $pathN = [IO.Path]::GetFullPath($Path)
    $baseN = [IO.Path]::GetFullPath($Base)
    if ($pathN.StartsWith($baseN, [StringComparison]::OrdinalIgnoreCase) -or $pathN.StartsWith($baseN)) {
        $rel = $pathN.Substring($baseN.Length).TrimStart('\', '/')
        return ($rel -replace '\\', '/')
    }
    return $pathN
}

function Write-Action([string]$Verb, [string]$LinkPath, [string]$TargetPath, [string]$Catalog) {
    $linkShow = Get-RelPath $LinkPath $Catalog
    if ((ConvertTo-NormalizedPath $LinkPath).StartsWith((ConvertTo-NormalizedPath $Catalog))) {
        # keep relative
    } else {
        $linkShow = $LinkPath
    }
    $targetShow = Get-RelPath $TargetPath $Catalog
    Write-Host ("{0,-8} {1} -> {2}" -f $Verb, $linkShow, $targetShow)
}

function Install-Link([string]$LinkPath, [string]$TargetPath, [string]$SkillsRoot, [string]$Catalog) {
    $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if (Test-ReparsePoint $LinkPath) {
            $current = Get-LinkTarget $LinkPath
            if ($current -and (Test-SamePath $current $TargetPath)) {
                Write-Action 'ok' $LinkPath $TargetPath $Catalog
                return
            }
            if ($current -and -not (Test-PathUnder $current $SkillsRoot)) {
                Write-Host "skip     $(Get-RelPath $LinkPath $Catalog) (points at another catalog)"
                return
            }
            if ($DryRun) {
                Write-Action 'would' $LinkPath $TargetPath $Catalog
                return
            }
            Remove-ReparsePoint $LinkPath
        } else {
            Write-Host "skip     $(Get-RelPath $LinkPath $Catalog) (real directory, not replaced)"
            return
        }
    }

    if ($DryRun) {
        Write-Action 'would' $LinkPath $TargetPath $Catalog
        return
    }
    New-SkillLink $LinkPath $TargetPath
    Write-Action 'link' $LinkPath $TargetPath $Catalog
}

function Remove-OurLink([string]$LinkPath, [string]$SkillsRoot, [string]$Catalog) {
    if (-not (Test-ReparsePoint $LinkPath)) {
        return
    }
    $current = Get-LinkTarget $LinkPath
    if (-not $current -or -not (Test-PathUnder $current $SkillsRoot)) {
        return
    }
    if ($DryRun) {
        Write-Action 'would-rm' $LinkPath $current $Catalog
        return
    }
    Remove-ReparsePoint $LinkPath
    Write-Action 'unlink' $LinkPath $current $Catalog
}

function Prune-DiscoveryRoot([string]$DiscoveryRoot, [string]$SkillsRoot, [System.Collections.Generic.HashSet[string]]$KeepNames, [string]$Catalog) {
    if (-not (Test-Path -LiteralPath $DiscoveryRoot)) {
        return
    }
    Get-ChildItem -LiteralPath $DiscoveryRoot -Force | ForEach-Object {
        if ($_.Name -eq 'README.md') {
            return
        }
        if (-not (Test-ReparsePoint $_.FullName)) {
            return
        }
        $current = Get-LinkTarget $_.FullName
        if (-not $current -or -not (Test-PathUnder $current $SkillsRoot)) {
            return
        }
        if ($KeepNames.Contains($_.Name.ToLowerInvariant())) {
            return
        }
        Remove-OurLink $_.FullName $SkillsRoot $Catalog
    }
}

function Show-Status([string]$Catalog, [string]$Home, [bool]$DoProject, [bool]$DoGlobal) {
    $skills = @(Get-CatalogSkills $Catalog)
    if ($skills.Count -eq 0) {
        Write-Host "No skills in $(Join-Path $Catalog 'skills')"
        return
    }
    $roots = @()
    if ($DoProject) {
        $roots += Get-DiscoveryRoots $Catalog
    }
    if ($DoGlobal) {
        $roots += Get-DiscoveryRoots $Home
    }
    foreach ($skill in $skills) {
        Write-Host $skill.Name
        foreach ($root in $roots) {
            $link = Join-Path $root $skill.Name
            $target = Get-LinkTarget $link
            if ($target -and (Test-SamePath $target $skill.FullName)) {
                Write-Host "  linked  $link"
            } else {
                Write-Host "  missing $link"
            }
        }
    }
}

if ($Help) {
    Show-Help
    exit 0
}

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
} else {
    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
}

if (-not $UserHome) {
    if ($env:USERPROFILE) {
        $UserHome = $env:USERPROFILE
    } else {
        $UserHome = $env:HOME
    }
}
$UserHome = [IO.Path]::GetFullPath($UserHome)

$doProject = [bool]($Project -or -not $Global)
$doGlobal = [bool]($Global -or -not $Project)

$skillsRoot = Join-Path $RepoRoot 'skills'
$skills = @(Get-CatalogSkills $RepoRoot)
$keep = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($skill in $skills) {
    [void]$keep.Add($skill.Name.ToLowerInvariant())
}

$bases = @()
if ($doProject) { $bases += $RepoRoot }
if ($doGlobal) { $bases += $UserHome }

if ($Status) {
    Show-Status $RepoRoot $UserHome $doProject $doGlobal
    exit 0
}

if ($Uninstall) {
    foreach ($base in $bases) {
        foreach ($root in (Get-DiscoveryRoots $base)) {
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }
            Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -eq 'README.md') {
                    return
                }
                Remove-OurLink $_.FullName $skillsRoot $RepoRoot
            }
        }
    }
    exit 0
}

if ($skills.Count -eq 0) {
    Write-Host "No skills found in $skillsRoot (need skills/<name>/SKILL.md)"
}

foreach ($base in $bases) {
    foreach ($root in (Get-DiscoveryRoots $base)) {
        if (-not $DryRun -and -not (Test-Path -LiteralPath $root)) {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
        }
        foreach ($skill in $skills) {
            $link = Join-Path $root $skill.Name
            Install-Link $link $skill.FullName $skillsRoot $RepoRoot
        }
        Prune-DiscoveryRoot $root $skillsRoot $keep $RepoRoot
    }
}

exit 0
