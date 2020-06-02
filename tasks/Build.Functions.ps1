#region Functions
function Invoke-AppBuild {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ })]
        [System.IO.FileInfo]$appConfig,

        [Parameter(Mandatory = $false)]
        [System.IO.FileInfo]$outputDirectory = $env:BUILD_STAGINGDIRECTORY
    )
    #region local build
    if (Test-Path $appConfig -ErrorAction SilentlyContinue) {
        $appRoot = Split-Path $appConfig -Parent
        $binPath = "$appRoot\bin"
        $config = Get-Content $appConfig -raw | ConvertFrom-Yaml
        if ($config.application.appUrl) {
            #assuming that if appUrl is there, we need to download something..
            if (!(Test-Path $binPath -ErrorAction SilentlyContinue)) {
                New-Item $binPath -ItemType Directory -Force | Out-Null
            }
            if (Test-Path -Path $env:temp\$($config.application.appFile) -ErrorAction SilentlyContinue) {
                Write-Host "Found install media locally - will not download.."
            }
            else {
                Get-InstallMedia -url $config.application.appUrl -downloadPath "$env:temp\$($config.application.appFile)"
            }
            if ($config.application.unpack) {
                Expand-Archive -Path "$env:temp\$($config.application.appFile)" -DestinationPath $binPath -Force
                try {
                    Rename-Item "$binPath\$($config.application.appFile -replace '.zip')"-NewName "$($config.application.appFile.Replace(' ','_') -replace '.zip')" -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Debug "Folder naming is good - no need to rename.."
                }
                $binPath = "$binPath\$($config.application.appFile.Replace(' ','_') -replace '.zip')"
            }
            else {
                Move-Item -Path "$env:temp\$($config.application.appFile)" -Destination $binPath
            }
        }
        $param = @{
            applicationName = $config.application.appName
            installFilePath = $appRoot
            setupFile       = $config.application.installFile
            outputDirectory = "$outputDirectory\$($config.application.appName)"
        }
        Push-Location $appRoot
        New-IntunePackage @param
        Pop-Location
    }
}
function Get-InstallMedia {
    param (
        $url,
        $downloadPath
    )
    try {
        Write-Host "Downloading Media: $url"
        Start-BitsTransfer $url -Destination $downloadPath
    }
    catch {
        write-host $_.exception.message
    }
}
function New-IntunePackage {
    param (
        [string]$applicationName,
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ })]
        [string]$installFilePath,
        [Parameter(Mandatory = $true)]
        [ValidateScript( { Test-Path $_ })]
        [System.IO.FileInfo]$setupFile,
        [Parameter(Mandatory = $true)]
        [string]$outputDirectory
    )
    try {
        $intunewinFileName = $setupFile.BaseName
        if (!(Test-Path $script:cliTool)) {
            throw "IntuneWinAppUtil.exe not found at expected location.."
        }
        if (!(Test-Path -Path $outputDirectory -ErrorAction SilentlyContinue)) {
            $outputDirectory
            New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
        }
        if (!($applicationName)) {
            $applicationName = "NewApplication_$(get-date -Format yyyyMMddhhmmss)"
            Write-Host "No application name given..`nGenerated name: $applicationName" -ForegroundColor Yellow
        }
        if (Test-Path -Path $installFilePath) {
            Write-Host "Creating installation media.." -ForegroundColor Yellow
            Start-Process -FilePath $script:cliTool -ArgumentList "-c `"$installFilePath`" -s `"$setupFile`" -o `"$outputDirectory`"" -Wait -WindowStyle Normal
            if (Test-Path "$outputDirectory\$intunewinFileName.intunewin") {
                Get-ChildItem -Path "$outputDirectory\$intunewinFileName.intunewin" | Rename-Item -NewName "$applicationName.intunewin" -Force
                return $(Get-ChildItem -Path "$outputDirectory\$applicationName.intunewin")
            }
            else {
                throw "*.intunewin file not found where it should be. something bad happened."
            }
        }
    }
    catch {
        Write-Warning $_.exception.message
    }
}
function Get-IntuneWinXML {
    param (
        [Parameter(Mandatory = $true)]
        $sourceFile,

        [Parameter(Mandatory = $false)]
        $fileName = "detection.xml",

        [Parameter(Mandatory = $false)]
        [switch]$removeItem
    )
    $Directory = [System.IO.Path]::GetDirectoryName("$sourceFile")
    Add-Type -Assembly System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead("$sourceFile")
    $zip.Entries | Where-Object { $_.Name -like "$filename" } | ForEach-Object {
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, "$Directory\$filename", $true)
    }
    $zip.Dispose()
    [xml]$IntuneWinXML = Get-Content "$Directory\$filename"
    if ($removeItem) {
        remove-item "$Directory\$filename"
    }
    return $IntuneWinXML
}
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
#endregion