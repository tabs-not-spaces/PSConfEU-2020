#region functions
function Expand-Intunewin {
    param (
        [parameter(Mandatory = $true)]
        [ValidateScript( {
                if (-Not ($_ | Test-Path) ) {
                    throw "File not found.."
                }
                if ($_ -notmatch "(\.intunewin)") {
                    throw "Must be an *.intunewin file.."
                }
                return $true
            })]
        [System.IO.FileInfo]$intunewinFile,

        [parameter(Mandatory = $true)]
        $outputPath
    )
    if (!(Get-Module -ListAvailable -Name 7Zip4Powershell)) {
        Install-Module -Name 7Zip4Powershell -Scope CurrentUser -Force
    }
    try {
        #region unzip intunewin file
        $tmpLoc = "$env:TMP\$(new-guid)"
        Write-Verbose "Dumping contents to: $tmpLoc"
        Expand-7Zip -ArchiveFileName $intunewinFile -TargetPath $tmpLoc
        #endregion
        #region grab encryption keys
        [xml]$metadata = Get-Content "$tmpLoc\IntuneWinPackage\Metadata\Detection.XML" -raw
        $encKeys = $metadata.ApplicationInfo.EncryptionInfo
        $decKeys = [PSCustomObject]@{
            EncryptionKey        = [system.convert]::FromBase64String($encKeys.EncryptionKey)
            MacKey               = [system.convert]::FromBase64String($encKeys.MacKey)
            InitializationVector = [system.convert]::FromBase64String($encKeys.InitializationVector)
            Mac                  = [system.convert]::FromBase64String($encKeys.Mac)
            ProfileIdentifier    = $encKeys.ProfileIdentifier
            FileDigest           = [system.convert]::FromBase64String($encKeys.FileDigest)
            FileDigestAlgorithm  = $encKeys.FileDigestAlgorithm
        }
        #endregion
        #region generate crypto and decrypt objects
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $decKeys.EncryptionKey
        $aes.IV = $decKeys.InitializationVector
        $decryptor = $aes.CreateDecryptor($decKeys.EncryptionKey, $decKeys.InitializationVector)
        #endregion
        #region decrypt the target file
        $file = Get-Item "$tmpLoc\IntuneWinPackage\Contents\*.intunewin"
        $destinationFile = "$(Split-Path -Path $file.FullName -Parent)\$($file.name -replace '.intunewin').zip"
        $fileStreamReader = New-Object System.IO.FileStream($File.FullName, [System.IO.FileMode]::Open)
        $fileStreamWriter = New-Object System.IO.FileStream($destinationFile, [System.IO.FileMode]::Create)
        $cryptoStream = New-Object System.Security.Cryptography.CryptoStream($fileStreamWriter, $decryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)
        $fileStreamReader.CopyTo($cryptoStream)
        Expand-7zip -ArchiveFileName $destinationFile -TargetPath "$outputPath\$($file.name -replace '.intunewin')"
        #endregion
    }
    catch {
        Write-Warning $_.Exception.Message
    }
    finally {
        #region dispose of all open objects
        Write-Verbose "Cleaning everything up.."
        $cryptoStream.FlushFinalBlock()
        $cryptoStream.Dispose()
        $fileStreamReader.Dispose()
        $fileStreamWriter.Dispose()
        $aes.Dispose()
        Remove-Item $tmpLoc -Recurse -Force
        #endregion
    }
}
function Test-AppInstallByGUID {
    param(
        [string]$GUID
    )
    $GUIDKeys = Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\
    if (Test-Path HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\) {
        $GUIDKeys += Get-ChildItem HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\
    }
    if ($GUIDKeys | Where-Object {$_ -like "*$GUID"}) {
        return $true
    }
    else {
        return $false
    }
}
function Test-AppInstallByFile {
    param (
        [string]$filePath,
        [string]$fileVersion
    )
    try {
        if (Test-Path $filePath) {
            if ($fileVersion) {
                $app = Get-Command $filePath
                if ($fileVersion -eq $app.Version) {
                    Write-Verbose "File found and version matches"
                    return $true
                }
                else {
                    Write-Verbose "File found but version doesnt match"
                    return $false
                }
            }
            else {
                Write-Verbose "File found not checking version"
                return $true
            }

        }
        else {
            Write-Verbose "File not found"
            return $false
        }
    }
    catch {
        Write-Verbose "An error occurred during testing"
        return $false
    }
}
#endregion
#region get all the app files..
$appsToInstall = Get-ChildItem $PSScriptRoot -Include "*.intunewin" -Recurse
foreach ($app in $appsToInstall) {
    try {

        $appRoot = $app.Directory.FullName
        Write-Host "Installing application $($app.Name)"
        Expand-Intunewin $app.FullName -outputPath $appRoot
        #grab app config
        $appConfig = Get-Content "$appRoot\app.json" -raw | ConvertFrom-Json
        Set-Location "$appRoot\IntunePackage"
        #trigger the install..
        start-process cmd -ArgumentList "/C $($appconfig.application.installCmdLine)" -Wait

        #now lets do detection
        switch ($appConfig.detection.detectionType) {
            "MSI" {
                Write-Host "Detecting installation against MSI GUID.."
            }
            "File" {
                Write-Host "Detecting installation against file existing.."
                $filePath = Join-Path -Path $($appConfig.detection.file.path) -ChildPath $($appConfig.detection.file.fileOrFolderName)
                @{
                    DetectionResult = Test-AppInstallByFile -filePath $filePath
                } | ConvertTo-Json | Out-File $PSScriptRoot\detectionresult.json

            }
            default {
                "Needs work - come back later..."
            }
        }
    }
    catch {
        Write-Warning $_
    }
}
#endregion