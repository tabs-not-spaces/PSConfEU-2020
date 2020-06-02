param (
    [Parameter(Mandatory = $true)]
    [ValidateScript( { Test-Path $_ })]
    [System.IO.FileInfo]$appConfig
)
#region load functions
. $PSScriptRoot\build.functions.ps1
#endregion
if (Test-Path $appConfig -ErrorAction SilentlyContinue) {
    $appRoot = Split-Path $appConfig -Parent
    $config = get-content $appConfig -raw | ConvertFrom-Yaml
    $param = @{
        applicationName = $config.application.appName
        installFilePath = $appRoot
        setupFile       = $config.application.installFile
        outputDirectory = $appRoot
    }
    Push-Location $appRoot
    New-IntunePackage @param
    Pop-Location
}