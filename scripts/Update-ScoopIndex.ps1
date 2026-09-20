<#
.SYNOPSIS
    Builds and refreshes pkgmngr's Scoop manifest index.
.DESCRIPTION
    Scans the local Scoop buckets and writes a JSON index shaped as
    bucket -> @{ hash = <git commit>; packages = @{ name = version } }, which
    scripts/Get-Catalog.py reads directly. Buckets whose git hash is unchanged
    since the last run are skipped, so repeat runs are nearly free; a missing
    index makes every bucket look new and triggers one full scan.
.NOTES
    Not a standalone search tool - fzf does the searching, this only builds the
    catalog data. The index always lives at <repo>\cache\scoop-index.json, which
    is where scripts/Get-Catalog.py reads it from.
#>
[CmdletBinding()]
param()

$repoRoot = Split-Path $PSScriptRoot -Parent
$indexFile = Join-Path (Join-Path $repoRoot 'cache') 'scoop-index.json'

$scoopDir = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$script:BucketsDir = Join-Path $scoopDir 'buckets'

function Read-PkgIndex {
    <# Loads the grouped index; an absent or corrupt file simply yields an empty one. #>
    if (Test-Path -LiteralPath $indexFile) {
        try {
            return ([System.IO.File]::ReadAllText($indexFile) | ConvertFrom-Json -AsHashtable)
        } catch {
            Write-Verbose "Index unreadable, rebuilding: $_"
        }
    }
    return @{}
}

function Write-PkgIndex {
    <# Persists the index as BOM-free UTF-8 so python's json.load accepts it. #>
    param([hashtable]$Index)
    $dir = Split-Path -Parent $indexFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($indexFile, ($Index | ConvertTo-Json -Depth 4 -Compress))
}

function Get-PkgBucketHash {
    <# HEAD commit of a bucket, read straight from .git to avoid spawning git. #>
    param([string]$Path)

    $gitDir = Join-Path $Path '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) { return $null }

    try {
        $headPath = Join-Path $gitDir 'HEAD'
        if (-not [System.IO.File]::Exists($headPath)) { return $null }

        $head = [System.IO.File]::ReadAllText($headPath).Trim()
        if (-not $head.StartsWith('ref: ')) { return $head }

        $refName = $head.Substring(5).Trim()
        $refPath = Join-Path $gitDir ($refName -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if ([System.IO.File]::Exists($refPath)) {
            return [System.IO.File]::ReadAllText($refPath).Trim()
        }

        # Detached or packed refs
        $packedPath = Join-Path $gitDir 'packed-refs'
        if ([System.IO.File]::Exists($packedPath)) {
            foreach ($line in [System.IO.File]::ReadLines($packedPath)) {
                if ($line.EndsWith($refName)) { return ($line -split ' ')[0] }
            }
        }
    } catch {
        Write-Verbose "Direct HEAD read failed for ${Path}: $_"
    }

    # Last resort
    $rev = @(git -C $Path rev-parse HEAD 2>$null)
    if ($rev.Count) { return $rev[0].Trim() }
    return $null
}

function Get-PkgBucketManifests {
    <# name -> version for every parseable manifest in one bucket. #>
    param([string]$Path)

    # Buckets keep manifests in <bucket>/bucket, but some lay them at the root
    $manifestDir = Join-Path $Path 'bucket'
    if (-not (Test-Path -LiteralPath $manifestDir)) { $manifestDir = $Path }

    $packages = @{}
    foreach ($file in [System.IO.Directory]::EnumerateFiles($manifestDir, '*.json')) {
        try {
            $manifest = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
        } catch {
            Write-Verbose "Unparseable manifest: $file"
            continue
        }
        if (-not $manifest.version) { continue }

        $version = $manifest.version
        if ($version -isnot [string]) {
            # Object versions (nightlies) carry the printable form in .original
            $version = if ($version.original) { [string]$version.original } else { '' }
        }
        $packages[[System.IO.Path]::GetFileNameWithoutExtension($file)] = [string]$version
    }
    return $packages
}

if (-not (Test-Path -LiteralPath $script:BucketsDir)) {
    Write-Warning "No Scoop buckets found at '$script:BucketsDir' - index not built."
    return
}

$index = Read-PkgIndex
$observed = [System.Collections.Generic.HashSet[string]]::new()
$rescanned = 0
$total = 0

foreach ($bucketDir in [System.IO.Directory]::EnumerateDirectories($script:BucketsDir)) {
    $bucket = [System.IO.Path]::GetFileName($bucketDir)
    [void] $observed.Add($bucket)

    $hash = Get-PkgBucketHash -Path $bucketDir
    $stale = -not $index.ContainsKey($bucket) -or $index[$bucket].hash -ne $hash

    if ($stale) {
        $rescanned++
        $index[$bucket] = @{ hash = $hash; packages = (Get-PkgBucketManifests -Path $bucketDir) }
    }

    $total += $index[$bucket].packages.Count
}

# Drop buckets the user removed since the last run
foreach ($gone in @($index.Keys) | Where-Object { -not $observed.Contains($_) }) {
    $index.Remove($gone)
}

Write-PkgIndex -Index $index
Write-Host ("Scoop index: {0} packages in {1} buckets ({2} rescanned)" -f $total, $index.Count, $rescanned)
