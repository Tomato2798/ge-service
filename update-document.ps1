param(
    [Parameter(Mandatory = $true)]
    [string]$DocumentId,

    [Parameter(Mandatory = $true)]
    [string]$PdfPath,

    [string]$ReleaseUrl,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $Root "manifest.json"
$FilesDir = Join-Path $Root "files"
$Version = Get-Date -Format "yyyy-MM-dd"
$Now = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

function Set-OrAddProperty($Object, $Name, $Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

if (-not (Test-Path $ManifestPath)) { throw "manifest.json not found: $ManifestPath" }
if (-not (Test-Path $PdfPath)) { throw "PDF not found: $PdfPath" }
if (-not (Test-Path $FilesDir)) { New-Item -ItemType Directory -Path $FilesDir | Out-Null }

$Manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Document = $Manifest.documents | Where-Object { $_.id -eq $DocumentId } | Select-Object -First 1
if (-not $Document) { throw "Document id not found in manifest.json: $DocumentId" }

$PdfItem = Get-Item $PdfPath
$Sha256 = (Get-FileHash $PdfItem.FullName -Algorithm SHA256).Hash.ToLower()
$Size = [int64]$PdfItem.Length

Write-Host ""
Write-Host "GE SERVICE document update"
Write-Host "Document : $DocumentId"
Write-Host "Version  : $Version"
Write-Host "Source   : $($PdfItem.FullName)"
Write-Host "Size     : $Size bytes"
Write-Host "SHA-256  : $Sha256"
Write-Host ""

$isLargeManual = $DocumentId -eq "manual_ge_240ac"

if ($isLargeManual) {
    Write-Host "Large MANUAL GE 240AC mode (GitHub Release)."
    if ([string]::IsNullOrWhiteSpace($ReleaseUrl)) {
        if ($Document.url -match "github\.com/.+/releases/download/") {
            $ReleaseUrl = $Document.url
            Write-Host "Using current Release URL: $ReleaseUrl"
        } else {
            throw "ReleaseUrl is required. Upload the PDF to GitHub Release first, then pass -ReleaseUrl."
        }
    }
    if ($ReleaseUrl -notmatch '^https://') { throw "ReleaseUrl must use HTTPS" }
    $Document.url = $ReleaseUrl
} else {
    # Keep the stable server file name from the current URL when possible.
    $TargetName = $null
    try {
        if ($Document.url) {
            $TargetName = [System.IO.Path]::GetFileName(([uri]$Document.url).AbsolutePath)
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($TargetName)) { $TargetName = $PdfItem.Name }

    $Destination = Join-Path $FilesDir $TargetName
    $SourceFull = [System.IO.Path]::GetFullPath($PdfItem.FullName)
    $DestinationFull = [System.IO.Path]::GetFullPath($Destination)

    if ($DryRun) {
        Write-Host "[DryRun] Copy: $SourceFull -> $DestinationFull"
    } elseif ($SourceFull -ne $DestinationFull) {
        Copy-Item $SourceFull $DestinationFull -Force
        Write-Host "Copied PDF to files/$TargetName"
    } else {
        Write-Host "PDF already located at files/$TargetName"
    }

    $Document.url = "https://tomato2798.github.io/ge-service/files/$TargetName"
}

$Document.version = $Version
$Document.sha256 = $Sha256
$Document.size = $Size
Set-OrAddProperty $Document "updatedAt" $Now

# Refresh hashes/sizes for optional search indexes already present on disk.
if ($Document.searchTextUrl) {
    try {
        $SearchName = [System.IO.Path]::GetFileName(([uri]$Document.searchTextUrl).AbsolutePath)
        $SearchPath = Join-Path $FilesDir $SearchName
        if (Test-Path $SearchPath) {
            Set-OrAddProperty $Document "searchTextSha256" ((Get-FileHash $SearchPath -Algorithm SHA256).Hash.ToLower())
            Set-OrAddProperty $Document "searchTextSize" ([int64](Get-Item $SearchPath).Length)
        }
    } catch { Write-Warning "Could not refresh searchText metadata: $($_.Exception.Message)" }
}

if ($Document.wordIndexUrl) {
    try {
        $WordName = [System.IO.Path]::GetFileName(([uri]$Document.wordIndexUrl).AbsolutePath)
        $WordPath = Join-Path $FilesDir $WordName
        if (Test-Path $WordPath) {
            Set-OrAddProperty $Document "wordIndexSha256" ((Get-FileHash $WordPath -Algorithm SHA256).Hash.ToLower())
            Set-OrAddProperty $Document "wordIndexSize" ([int64](Get-Item $WordPath).Length)
        }
    } catch { Write-Warning "Could not refresh wordIndex metadata: $($_.Exception.Message)" }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] manifest.json was not changed. Git commands were not executed."
    exit 0
}

$Json = $Manifest | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($ManifestPath, $Json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "manifest.json updated."

Push-Location $Root
try {
    git add .
    if ($LASTEXITCODE -ne 0) { throw "git add failed" }

    $CommitMessage = "Update $DocumentId to $Version"
    git commit -m $CommitMessage
    if ($LASTEXITCODE -ne 0) {
        Write-Host "No new Git commit was created (possibly no content changes)."
    }

    git push
    if ($LASTEXITCODE -ne 0) { throw "git push failed" }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "DONE"
Write-Host "Document : $DocumentId"
Write-Host "Version  : $Version"
Write-Host "Size     : $Size bytes"
Write-Host "SHA-256  : $Sha256"
Write-Host "URL      : $($Document.url)"
