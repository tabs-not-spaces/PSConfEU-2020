#region Config
$client = "MegaCorp"
$appName = "TimeSnapper"
$LogPath = "$Env:ProgramData\$client\logs"
$logFile = "$logPath\$appName.log"
$exePath = "${env:ProgramFiles(x86)}\TimeSnapper\TimeSnapper.exe"
$appVersion = "3.9.0.3"
#endregion
#region functions
function Test-AppInstallByGUID {
    param(
        [string]$GUID
    )
    $GUIDKeys = Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\
    if (Test-Path HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\) {
        $GUIDKeys += Get-ChildItem HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\
    }
    if ($GUIDKeys | Where-Object { $_ -like "*$GUID" }) {
        return $true
    }
    else {
        return $false
    }
}
function Test-AppInstallByFile {
    param (
        [string]$exePath,
        [string]$appVersion
    )
    try {
        if (Test-Path $exePath) {
            if ($appVersion) {
                $app = Get-Command $exePath
                if ($appVersion -eq $app.Version) {
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
function New-Shortcut {
    param (
        $Destination,
        $TargetPath,
        $Arguments,
        $Icon,
        $Description,
        $WorkingDirectory
    )
    try {
        if (!($Icon)) {
            $Icon = "$($TargetPath),0"
        }
        if (!($WorkingDirectory)) {
            $WorkingDirectory = $(Split-Path $TargetPath)
        }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut("$Destination")
        $Shortcut.TargetPath = "$TargetPath"
        $Shortcut.Arguments = "$Arguments"
        $Shortcut.IconLocation = "$Icon"
        $Shortcut.Description = "$Description"
        $Shortcut.WorkingDirectory = "$WorkingDirectory"
        $Shortcut.Save()
        if (Test-Path -Path $Destination) {
            $result = $true
        }
        else {
            $result = $false
        }
        $res = [PSCustomObject]@{
            Filepath = $Destination
            Created  = $result
        }
        return $res
    }
    catch {
        $result = $false
        $res = [PSCustomObject]@{
            Filepath = $Destination
            Created  = $result
        }
        return $res
    }
}
#endregion
#region environment configure
if (!(Test-Path -Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}
Start-Transcript -Path $logFile -Force
#endregion
#region dotnet 3.5
if ((Get-WindowsOptionalFeature -FeatureName "NetFx3" -Online).State -notcontains "Enabled") {
    Write-Host "Installing .net 3.5.."
    Enable-WindowsOptionalFeature -FeatureName "NetFx3" -Online -NoRestart
}
else {
    Write-Host ".Net 3.5 already installed.."
}
#endregion
#region TimeSnapper install
try {
    Write-Host "Installing $appName.."
    Start-Process -FilePath "$PSScriptRoot\bin\TimeSnapperProSetup.exe" -ArgumentList "/S" -PassThru -Wait
}
catch {
    throw $_.Exception.Message
}
#endregion
#region configure to auto start
try {
    if (Test-Path $exePath -ErrorAction SilentlyContinue) {
        $shortcutParams = @{
            Destination = "$Env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\TimeSnapper Professional.lnk"
            TargetPath  = $exePath
            Description = "TimeSnapper Professional"
        }
        $icon = New-Shortcut @shortcutParams
        if ($icon.Created -eq $true) {
            Write-Host "Shortcut for $appName created successfully"
        }
        else {
            throw "An error occurred during the creation of the shortcut"
        }
    }
}
catch {
    $errorMsg = $_.Exception.Message
}
finally {
    if ($errorMsg) {
        Write-Warning $errorMsg
        Stop-Transcript
        Throw $errorMsg
    }
    else {
        Write-Host "Installation completed successfully.."
        Stop-Transcript
    }
}
#endregion