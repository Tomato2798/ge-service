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

if (-not (Test-Path $ManifestPath)) {
    throw "manifest.json not found: $ManifestPath"
}

if (-not (Test-Path $PdfPath)) {
    throw "PDF not found: $PdfPath"
}

$Manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$Document = $Manifest.documents | Where-Object { $_.id -eq $DocumentId }

if (-not $Document) {
    throw "Document id not found in manifest.json: $DocumentId"
}

$PdfItem = Get-Item $PdfPath
$Sha256 = (Get-FileHash $PdfPath -Algorithm SHA256).Hash.ToLower()
$Size = $PdfItem.Length
$FileName = $PdfItem.Name

Write-Host ""
Write-Host "Document : $DocumentId"
Write-Host "Version  : $Version"
Write-Host "File     : $FileName"
Write-Host "Size     : $Size bytes"
Write-Host "SHA-256  : $Sha256"
Write-Host ""

if ($DocumentId -eq "manual_ge_240ac") {

    Write-Host "Large manual mode"

    if ([string]::IsNullOrWhiteSpace($ReleaseUrl)) {
        if ($Document.url -match "github\.com/.+/releases/download/") {
            $ReleaseUrl = $Document.url
            Write-Host "Using current Release URL:"
            Write-Host $ReleaseUrl
        }
        else {
            throw "ReleaseUrl is required for manual_ge_240ac"
        }
    }

    $Document.url = $ReleaseUrl
}
else {

    if (-not (Test-Path $FilesDir)) {
        New-Item -ItemType Directory -Path $FilesDir | Out-Null
    }

    $Destination = Join-Path $FilesDir $FileName

    if ($DryRun) {
        Write-Host "[DryRun] Copy: $PdfPath -> $Destination"
    }
    else {
        $SourceFull = [System.IO.Path]::GetFullPath($PdfItem.FullName)
        $DestinationFull = [System.IO.Path]::GetFullPath($Destination)

        if ($SourceFull -ne $DestinationFull) {
            Copy-Item $PdfPath $Destination -Force
        }

        Write-Host "PDF ready in files directory"
    }

    $Document.url = "https://tomato2798.github.io/ge-service/files/$FileName"
}

$Document.version = $Version
$Document.sha256 = $Sha256
$Document.size = $Size

$Now = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

if ($Document.PSObject.Properties.Name -contains "updatedAt") {
    $Document.updatedAt = $Now
}
else {
    $Document | Add-Member -NotePropertyName "updatedAt" -NotePropertyValue $Now
}

if ($Document.searchTextUrl) {
    $SearchName = [System.IO.Path]::GetFileName(([uri]$Document.searchTextUrl).AbsolutePath)
    $SearchPath = Join-Path $FilesDir $SearchName

    if (Test-Path $SearchPath) {
        $SearchHash = (Get-FileHash $SearchPath -Algorithm SHA256).Hash.ToLower()
        $SearchSize = (Get-Item $SearchPath).Length

        if ($Document.PSObject.Properties.Name -contains "searchTextSha256") {
            $Document.searchTextSha256 = $SearchHash
        }
        else {
            $Document | Add-Member -NotePropertyName "searchTextSha256" -NotePropertyValue $SearchHash
        }

        if ($Document.PSObject.Properties.Name -contains "searchTextSize") {
            $Document.searchTextSize = $SearchSize
        }
        else {
            $Document | Add-Member -NotePropertyName "searchTextSize" -NotePropertyValue $SearchSize
        }
    }
}

if ($Document.wordIndexUrl) {
    $WordName = [System.IO.Path]::GetFileName(([uri]$Document.wordIndexUrl).AbsolutePath)
    $WordPath = Join-Path $FilesDir $WordName

    if (Test-Path $WordPath) {
        $WordHash = (Get-FileHash $WordPath -Algorithm SHA256).Hash.ToLower()
        $WordSize = (Get-Item $WordPath).Length

        if ($Document.PSObject.Properties.Name -contains "wordIndexSha256") {
            $Document.wordIndexSha256 = $WordHash
        }
        else {
            $Document | Add-Member -NotePropertyName "wordIndexSha256" -NotePropertyValue $WordHash
        }

        if ($Document.PSObject.Properties.Name -contains "wordIndexSize") {
            $Document.wordIndexSize = $WordSize
        }
        else {
            $Document | Add-Member -NotePropertyName "wordIndexSize" -NotePropertyValue $WordSize
        }
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] manifest.json and Git were not changed."
    exit 0
}

$Json = $Manifest | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText(
    $ManifestPath,
    $Json,
    (New-Object System.Text.UTF8Encoding($false))
)

Push-Location $Root

try {
    git add .

    $CommitMessage = "Update $DocumentId to $Version"
    git commit -m $CommitMessage

    if ($LASTEXITCODE -ne 0) {
        Write-Host "No Git changes to commit."
    }

    git push

    if ($LASTEXITCODE -ne 0) {
        throw "git push failed"
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "DONE"
Write-Host "Document : $DocumentId"
Write-Host "Version  : $Version"
Write-Host "Size     : $Size bytes"
Write-Host "SHA-256  : $Sha256"