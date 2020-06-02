[cmdletbinding()]
param (
    [Parameter(Mandatory = $false)]
    [System.IO.FileInfo]$outputDirectory = $env:BUILD_STAGINGDIRECTORY
)
$script:cliTool = "$PSScriptRoot\bin\IntuneWinAppUtil.exe"
. $PSScriptRoot\build.functions.ps1
#endregion
#region ascii fun
$b = "IF9fX19fXyAgIF9fICBfXyAgIF9fICAgX18gICAgICAgX19fX18gICAKL1wgID09IFwgL1wgXC9cIFwgL1wgXCAvXCBcICAgICAvXCAgX18tLiAKXCBcICBfXzwgXCBcIFxfXCBcXCBcIFxcIFwgXF9fX19cIFwgXC9cIFwKIFwgXF9fX19fXFwgXF9fX19fXFwgXF9cXCBcX19fX19cXCBcX19fXy0KICBcL19fX19fLyBcL19fX19fLyBcL18vIFwvX19fX18vIFwvX19fXy8K"
Write-Host $([system.text.encoding]::UTF8.GetString([system.convert]::FromBase64String($b)))
#endregion

$changes = (git log -1 --name-only --oneline) | Where-Object {$_ -match 'applications/*'} | ForEach-Object {
    Split-Path $_ -Parent
} | Get-Unique

Write-Host "Found $($changes.count) updated application.."
$changes
$projectRoot = Split-Path $PSScriptRoot -Parent
if ($changes) {
    foreach ($c in $changes) {
        $appConfig = Resolve-Path "$projectRoot\$c\app.yaml"
        if ($appConfig) {
            $packagedApp = Invoke-AppBuild -appConfig $appConfig.Path -outputDirectory $outputDirectory
            Get-Content $appConfig.Path -raw | ConvertFrom-Yaml | ConvertTo-Json | Out-File "$($packagedApp.Directory.FullName)\app.json" -Encoding ascii -Force
        }
    }
    Copy-Item $PSScriptRoot\invoke.installation.ps1 -Destination $outputDirectory -Force
}