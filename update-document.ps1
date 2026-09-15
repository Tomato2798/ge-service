param(
    [Parameter(Mandatory = $true)][string]$DocumentId,
    [Parameter(Mandatory = $true)][string]$PdfPath,
    [string]$DisplayName = "",
    [string]$Category = "",
    [string]$ReleaseUrl = "",
    [string]$SearchTextPath = "",
    [string]$WordIndexPath = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$PagesBaseUrl = "https://tomato2798.github.io/ge-service/files"
$LargeFileLimit = 25MB
$ManualGeId = "manual_ge_240ac"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $Root "manifest.json"
$FilesDir = Join-Path $Root "files"
$TodayVersion = Get-Date -Format "yyyy-MM-dd"
$UpdatedAt = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

function Set-Prop {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Copy-And-Hash-Index {
    param(
        [string]$SourcePath,
        [string]$Suffix,
        [string]$UrlProp,
        [string]$HashProp,
        [string]$SizeProp,
        $Document
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) { return }
    if (-not (Test-Path $SourcePath)) { throw "Index file not found: $SourcePath" }

    $DestName = "$DocumentId.$Suffix"
    $DestPath = Join-Path $FilesDir $DestName

    if (-not $DryRun) {
        $SourceFull = [System.IO.Path]::GetFullPath((Get-Item $SourcePath).FullName)
        $DestFull = [System.IO.Path]::GetFullPath($DestPath)
        if ($SourceFull -ne $DestFull) { Copy-Item $SourcePath $DestPath -Force }
    }

    $Hash = (Get-FileHash $SourcePath -Algorithm SHA256).Hash.ToLower()
    $Size = (Get-Item $SourcePath).Length

    Set-Prop $Document $UrlProp "$PagesBaseUrl/$DestName"
    Set-Prop $Document $HashProp $Hash
    Set-Prop $Document $SizeProp $Size
}

if (-not (Test-Path $ManifestPath)) { throw "manifest.json not found: $ManifestPath" }
if (-not (Test-Path $PdfPath)) { throw "PDF not found: $PdfPath" }

if (-not (Test-Path $FilesDir) -and -not $DryRun) {
    New-Item -ItemType Directory -Path $FilesDir | Out-Null
}

$PdfItem = Get-Item $PdfPath
$PdfHash = (Get-FileHash $PdfPath -Algorithm SHA256).Hash.ToLower()
$PdfSize = $PdfItem.Length
$IsLarge = ($PdfSize -ge $LargeFileLimit) -or ($DocumentId -eq $ManualGeId)

$Manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Document = $Manifest.documents | Where-Object { $_.id -eq $DocumentId } | Select-Object -First 1
$IsNew = ($null -eq $Document)

if ($IsNew) {
    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        throw "New document requires -DisplayName"
    }
    if ([string]::IsNullOrWhiteSpace($Category)) { $Category = "tech_docs" }

    $Document = [pscustomobject]@{
        id          = $DocumentId
        displayName = $DisplayName
        version     = $TodayVersion
        url         = ""
        sha256      = $PdfHash
        size        = $PdfSize
        category    = $Category
        updatedAt   = $UpdatedAt
    }
    $Manifest.documents += $Document
} else {
    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
        Set-Prop $Document "displayName" $DisplayName
    }
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        Set-Prop $Document "category" $Category
    }
}

if ($IsLarge) {
    if ([string]::IsNullOrWhiteSpace($ReleaseUrl)) {
        if (($Document.PSObject.Properties.Name -contains "url") -and
            ($Document.url -match "github\.com/.+/releases/download/")) {
            $ReleaseUrl = $Document.url
        } else {
            throw "Large PDF requires -ReleaseUrl. Upload it to GitHub Release first."
        }
    }
    Set-Prop $Document "url" $ReleaseUrl
} else {
    $DestName = "$DocumentId.pdf"

    if (-not $IsNew -and
        ($Document.PSObject.Properties.Name -contains "url") -and
        ($Document.url -match "tomato2798\.github\.io/ge-service/files/")) {
        try {
            $ExistingName = [System.IO.Path]::GetFileName(([uri]$Document.url).AbsolutePath)
            if (-not [string]::IsNullOrWhiteSpace($ExistingName)) { $DestName = $ExistingName }
        } catch {}
    }

    $DestPath = Join-Path $FilesDir $DestName

    if ($DryRun) {
        Write-Host "[DryRun] Copy: $($PdfItem.FullName) -> $DestPath"
    } else {
        $SourceFull = [System.IO.Path]::GetFullPath($PdfItem.FullName)
        $DestFull = [System.IO.Path]::GetFullPath($DestPath)
        if ($SourceFull -ne $DestFull) { Copy-Item $PdfPath $DestPath -Force }
    }

    Set-Prop $Document "url" "$PagesBaseUrl/$DestName"
}

Set-Prop $Document "version" $TodayVersion
Set-Prop $Document "sha256" $PdfHash
Set-Prop $Document "size" $PdfSize
Set-Prop $Document "updatedAt" $UpdatedAt

Copy-And-Hash-Index -SourcePath $SearchTextPath -Suffix "search.txt" `
    -UrlProp "searchTextUrl" -HashProp "searchTextSha256" -SizeProp "searchTextSize" -Document $Document

Copy-And-Hash-Index -SourcePath $WordIndexPath -Suffix "words.tsv" `
    -UrlProp "wordIndexUrl" -HashProp "wordIndexSha256" -SizeProp "wordIndexSize" -Document $Document

Write-Host ""
Write-Host "Document : $DocumentId"
Write-Host "Version  : $TodayVersion"
Write-Host "Size     : $PdfSize bytes"
Write-Host "SHA-256  : $PdfHash"
Write-Host "URL      : $($Document.url)"
if ($IsNew) { Write-Host "NEW DOCUMENT: $($Document.displayName) [$($Document.category)]" }

if ($DryRun) {
    Write-Host "[DryRun] manifest.json was not changed. Git commands were not executed."
    exit 0
}

$Json = $Manifest | ConvertTo-Json -Depth 30
[System.IO.File]::WriteAllText($ManifestPath, $Json, (New-Object System.Text.UTF8Encoding($false)))

Push-Location $Root
try {
    git add .
    git diff --cached --quiet
    $HasNoChanges = ($LASTEXITCODE -eq 0)

    if (-not $HasNoChanges) {
        if ($IsNew) { $CommitMessage = "Add $DocumentId $TodayVersion" }
        else { $CommitMessage = "Update $DocumentId to $TodayVersion" }

        git commit -m $CommitMessage
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
    }

    git push
    if ($LASTEXITCODE -ne 0) { throw "git push failed" }
}
finally {
    Pop-Location
}

Write-Host "DONE"
