param (
    [Alias("AppId")]
    [String] $ApplicationId = "None",
    [Switch] $Force,
	[Switch] $All,
    [Switch] $NoDelete,
    [Switch] $Repair
)

# Modules required:
# powershell-yaml
# IntuneWin32App
# Selenium
Import-Module powershell-yaml
Import-Module IntuneWin32App
Import-Module Selenium
Import-Module TUN.CredentialManager
$CustomModules = Get-ChildItem -Path .\Scripts\*.psm1
foreach ($Module in $CustomModules) {
    # Force allows us to reload them for testing
    Import-Module "$($Module.FullName)" -Global -Force
}

# Constants
$Global:LOG_LOCATION = "$PSScriptRoot"
$Global:LOG_FILE = "YLog.log"

# So we can pop at the end
Push-Location

# Initialize the log file
Write-Log -Init

if ("None" -eq $ApplicationId -and $All -eq $false) {
    Write-Log "Please provide parameter -ApplicationId"
    exit 1
}
$applications = [System.Collections.ArrayList]::new()
$Global:testApps = "$PSScriptRoot\TestApps"
$Global:buildSpace = "$PSScriptRoot\BuildSpace"
$Global:scriptSpace = "$PSScriptRoot\Scripts"
$Global:publishedApps = "$PSScriptRoot\Apps"
$Global:autoPackagerRecipes = "$PSScriptRoot\Recipes"
$Global:iconPath = "$PSScriptRoot\Icons"
$Global:toolsDir = "$PSScriptRoot\Tools"
$Global:tempDir = "$PSScriptRoot\Temp"
$Global:secretsDir = "$PSScriptRoot\Secrets"

# Import preferences file:
$prefs = Get-Content $PSScriptRoot\Preferences.yaml | ConvertFrom-Yaml
$Global:tenantId = $prefs.tenantId
$Global:clientId = $prefs.clientId
$Global:clientSecret = $prefs.clientSecret

# $scopeTags = $prefs.scopeTags

if ($ApplicationId -ne "None") {
    if (-not (Test-Path "$autoPackagerRecipes\$ApplicationId.yaml")) {
        Write-Log "Application $ApplicationId not found in $autoPackagerRecipes"
        exit 1
    }
}


# Start updating each application if all are selected
if ($All) {
	$ApplicationFullNames = $(Get-ChildItem $autoPackagerRecipes -File).Name
	foreach ($Application in $ApplicationFullNames) {
		$Applications.Add($($Application -split ".yaml")[0]) | Out-Null
	}
}
else {
    # Just do the one specified if -All is not specified
    $Applications.Add($ApplicationId) | Out-Null
}


foreach ($ApplicationId in $Applications) {
    Write-Log "Starting update for $ApplicationId..."
    # Refresh token if necessary
    Connect-AutoMSIntuneGraph
    
    # Clear the temp file
    Write-Log "Clearing the temp directory..."
    Get-ChildItem $TempDir -Exclude ".gitkeep" -Recurse | Remove-Item -Recurse -Force

    # Open the YAML file and collect all necessary attributes
    $Global:parameters = Get-Content "$autoPackagerRecipes\$ApplicationId.yaml" | ConvertFrom-Yaml
    $Global:url = if ($parameters.urlRedirects) {Get-RedirectedUrl $parameters.url} else {$parameters.url}
    $Global:id = $parameters.id
    $Global:version = $parameters.version
    $Global:fileDetectionVersion = $parameters.fileDetectionVersion
    $Global:displayName = $parameters.displayName
    $Global:displayVersion = $parameters.displayVersion
    $Global:fileName = $parameters.fileName
    $Global:fileDetectionPath = $parameters.fileDetectionPath
    $Global:preDownloadScript = $parameters.preDownloadScript
    $Global:postDownloadScript = $parameters.postDownloadScript
    $Global:downloadScript = $parameters.downloadScript
    $Global:installScript = $parameters.installScript
    $Global:uninstallScript = $parameters.uninstallScript
    $Global:scopeTags = if($parameters.scopeTags) {$parameters.scopeTags} else {$prefs.defaultScopeTags}
    $Global:owner = if($parameters.owner) {$parameters.owner} else {$prefs.defaultOwner}
    $Global:maximumInstallationTimeInMinutes = if($parameters.maximumInstallationTimeInMinutes) {$parameters.maximumInstallationTimeInMinutes} else {$prefs.defaultMaximumInstallationTimeInMinutes}
    $Global:minOSVersion = if($parameters.minOSVersion) {$parameters.minOSVersion} else {$prefs.defaultMinOSVersion}
    $Global:installExperience = if($parameters.installExperience) {$parameters.installExperience} else {$prefs.defaultInstallExperience}
    $Global:restartBehavior = if($parameters.restartBehavior) {$parameters.restartBehavior} else {$prefs.defaultRestartBehavior}
    $Global:availableGroups = if($parameters.availableGroups) {$parameters.availableGroups} else {$prefs.defaultAvailableGroups}
    $Global:requiredGroups = if($parameters.requiredGroups) {$parameters.requiredGroups} else {$prefs.defaultRequiredGroups}
    $Global:detectionType = $parameters.detectionType
    $Global:fileDetectionVersion = $parameters.fileDetectionVersion
    $Global:fileDetectionMethod = $parameters.fileDetectionMethod
    $Global:fileDetectionName = $parameters.fileDetectionName
    $Global:fileDetectionOperator = $parameters.fileDetectionOperator
    $Global:fileDetectionDateTime = $parameters.fileDetectionDateTime
    $Global:fileDetectionValue = $parameters.fileDetectionValue
    $Global:registryDetectionMethod = $parameters.registryDetectionMethod
    $Global:registryDetectionKey = $parameters.registryDetectionKey
    $Global:registryDetectionValueName = $parameters.registryDetectionValueName
    $Global:registryDetectionValue = $parameters.registryDetectionValue
    $Global:registryDetectionOperator = $parameters.registryDetectionOperator
    $Global:detectionScript = $parameters.detectionScript
    $Global:DetectionScriptFileExtension = if($parameters.detectionScriptFileExtension) {$parameters.detectionScriptFileExtension} else {$prefs.defaultDetectionScriptFileExtension}
    $Global:detectionScriptRunAs32Bit = if($parameters.detectionScriptRunAs32Bit) {$parameters.detectionScriptRunAs32Bit} else {$prefs.defaultdetectionScriptRunAs32Bit}
    $Global:detectionScriptEnforceSignatureCheck = if($parameters.detectionScriptEnforceSignatureCheck) {$parameters.detectionScriptEnforceSignatureCheck} else {$prefs.defaultdetectionScriptEnforceSignatureCheck}
    $Global:allowUserUninstall = if($parameters.allowUserUninstall) {$parameters.allowUserUninstall} else {$prefs.defaultAllowUserUninstall}
    $Global:iconFile = $parameters.iconFile
    $Global:description = $parameters.description
    $Global:publisher = $parameters.publisher
    $Global:is32BitApp = if($parameters.is32BitApp) {$parameters.is32BitApp} else {$prefs.defaultIs32BitApp}
    $Global:numVersionsToKeep = if($parameters.numVersionsToKeep) {$parameters.numVersionsToKeep} else {$prefs.defaultNumVersionsToKeep}


    if ($Repair) {
        # Correct any naming discrepancies before we continue
        # Rename any apps if they are named incorrectly
        $CurrentApps = Get-SameAppAllVersions $DisplayName | Sort-Object displayVersion -descending
        for ($i = 1; $i -lt $CurrentApps.Count; $i++) {
            if ($CurrentApps[$i].DisplayName -ne "$displayName (N-$i)") {
                Write-Log "Setting name for $displayName (N-$i)"
                Set-IntuneWin32App -Id $CurrentApps[$i].Id -DisplayName "$displayName (N-$i)"
            }
        }
    }


    # Run the pre-download script
    if ($preDownloadScript) {
        Write-Log "Running pre-download script..."
        Invoke-Expression $preDownloadScript | Out-Null

        if (!$?) {
                Write-Error "Error while running pre-download PowerShell script"
                continue
        }
        else {
            Write-Log "Pre-download script ran successfully."
        }
    }


    # Check if there is an up-to-date version in the repo already
    Write-Log "Checking if $displayName $version is a new version..."
    $ExistingVersions = Get-SameAppAllVersions $DisplayName
    if ($ExistingVersions.displayVersion -contains $version) {
        if ($force) {
            Write-Log "Package up-to-date. -Force applied. Recreating package."
        }
        else {
            Write-Log "$id already up-to-date!"
            continue
        }
    }


    # See if this has been run before. If there are previous files, move them to a folder called "Old"
    if (Test-Path $buildSpace\$id) {
        if (-not (Test-Path $buildSpace\Old)) {
            New-Item -Path $buildSpace -ItemType Directory -Name "Old"
        }
        Write-Log "Removing old buildspace..."
        Move-Item -Path $buildSpace\$id $buildSpace\Old\$id-$(Get-Date -Format "MMddyyhhmmss")
    }
    if (Test-Path $scriptSpace\$id) {
        if (-not (Test-Path $scriptSpace\Old)) {
            New-Item -Path $scriptSpace -ItemType Directory -Name "Old"
        }
        Write-Log "Removing old script space..."
        Move-Item -Path $scriptSpace\$id $scriptSpace\Old\$id-$(Get-Date -Format "MMddyyhhmmss")
    }

    # Make the new buildspace directory
    New-Item -Path $buildSpace\$id -ItemType Directory -Name $version
    Set-Location $buildSpace\$id\$version

    # Download the new installer
    Write-Log "Starting download..."
    Write-Log "URL: $url"
    if (!$url) {
        Write-Error "URL is empty - cannot continue."
        break
    }
    if ($downloadScript) {
        Invoke-Expression $downloadScript | Out-Null
        if (!$?) {
            Write-Error "Error while running download PowerShell script"
            break
        }
        else {
            Write-Log "Download script ran successfully."
        }
    }
    else {
        Start-BitsTransfer -Source $url -Destination $buildSpace\$id\$version\$fileName
    }


    # Run the post-download script
    if ($postDownloadScript) {
        Write-Log "Running post download script..."
        Invoke-Expression $postDownloadScript | Out-Null
        if (!$?) {
                Write-Error "Error while running post download PowerShell script"
                break
        }
        else {
            Write-Log "Post download script ran successfully."
        }
    }
    
    # Script Files:
    # Replace the <filename> placeholder with the actual filename
    $installScript = $installScript.replace("<filename>", $fileName)
    $uninstallScript = $uninstallScript.replace("<filename>", $fileName)

    # Replace the <productcode> placeholder with the actual product code
    if ($filename -match "\.msi$") {
        $ProductCode = Get-MSIProductCode $buildSpace\$id\$version\$fileName
        Write-Log "Product Code: $ProductCode"
        $installScript = $installScript.replace("<productcode>", $ProductCode)
        $uninstallScript = $uninstallScript.replace("<productcode>", $ProductCode)
    }

    # Replace <version> placeholder with the actual version
    $installScript = $installScript.replace("<version>", $version)
    $uninstallScript = $uninstallScript.replace("<version>", $version)  
    
    if ($registryDetectionKey) {
        $registryDetectionKey = $registryDetectionKey.replace("<filename>", $fileName)
        $registryDetectionKey = $registryDetectionKey.replace("<version>", $version)
        if ($ProductCode) {
            $registryDetectionKey = $registryDetectionKey.replace("<productcode>", $productCode)
        }
    }

    # Generate the .intunewin file
    Set-Location $PSScriptRoot
    Write-Log "Generating .intunewin file..."
    $app = New-IntuneWin32AppPackage -SourceFolder $buildSpace\$id\$version -SetupFile $filename -OutputFolder $publishedApps -Force

    # Upload .intunewin file to Intune
    # Detection Types
    $Icon = New-IntuneWin32AppIcon -FilePath "$($iconPath)\$($iconFile)"
    if ( -not ($fileDetectionVersion)) {
        $fileDetectionVersion = $version
    }

    if ($detectionType -eq "file") {
        if ($fileDetectionMethod -eq "exists") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleFile -Existence -DetectionType "exists" -Path $fileDetectionPath -FileOrFolder $fileDetectionName
        }
        elseif ($fileDetectionMethod -eq "modified") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleFile -DateModified -Path $fileDetectionPath -FileOrFolder $fileDetectionName -Operator $fileDetectionOperator -DateTimeValue $fileDetectionDateTime
        }
        elseif ($fileDetectionMethod -eq "created") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleFile -DateCreated -Path $fileDetectionPath -FileOrFolder $fileDetectionName -Operator $fileDetectionOperator -DateTimeValue (Get-Date $fileDetectionDateTime)
        }
        elseif ($fileDetectionMethod -eq "version") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleFile -Version -Path $fileDetectionPath -FileOrFolder $fileDetectionName -Operator $fileDetectionOperator -VersionValue $fileDetectionVersion
        }
        elseif ($fileDetectionMethod -eq "size") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleFile -Size -Path $fileDetectionPath -FileOrFolder $fileDetectionName -Operator $fileDetectionOperator -SizeinMBValue $fileDetectionValue
        }
    }
    elseif ($detectionType -eq "msi") {
        $DetectionRule = New-IntuneWin32AppDetectionRuleMsi -ProductCode "$ProductCode" -ProductVersion $fileDetectionVersion 
    }
    elseif ($detectionType -eq "registry") {
        if($registryDetectionMethod -eq "exists") {
            if ($registryDetectionValue) {
                $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -Existence -KeyPath $registryDetectionKey -ValueName $registryDetectionValueName -DetectionType "exists"
            }
            else {
                $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -Existence -KeyPath $registryDetectionKey -DetectionType "exists"
            }
        }
        elseif($registryDetectionMethod -eq "version") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -VersionComparison -KeyPath $registryDetectionKey -ValueName $registryDetectionValueName -Check32BitOn64System $is32BitApp -VersionComparisonOperator $registryDetectionOperator -VersionComparisonValue $registryDetectionValue
        }
        elseif($registryDetectionMethod -eq "integer") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -IntegerComparison -KeyPath $registryDetectionKey -ValueName $registryDetectionValue -Check32BitOn64System $is32BitApp -IntegerComparisonOperator $registryDetectionOperator -IntegerComparisonValue $registryDetectionValue
        }
        elseif($registryDetectionMethod -eq "string") {
            $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -StringComparison -KeyPath $registryDetectionKey -ValueName $registryDetectionValue -Check32BitOn64System $is32BitApp -StringComparisonOperator $registryDetectionOperator -StringComparisonValue $registryDetectionValue
        }
    }
    elseif ($detectionType -eq "script") {
        if (!(Test-Path $scriptSpace\$id)) {
            New-Item -Name $id -ItemType Directory -Path $scriptSpace
        }
        $ScriptLocation = "$scriptSpace\$id\$version.$detectionScriptFileExtension"
        Write-Output $detectionScript | Out-File $ScriptLocation
        $DetectionRule = New-IntuneWin32AppDetectionRuleScript -ScriptFile $ScriptLocation -EnforceSignatureCheck $detectionScriptEnforceSignatureCheck -RunAs32Bit $detectionScriptRunAs32Bit
    }

    # Generate the min OS requirement rule
    $RequirementRule = New-IntuneWin32AppRequirementRule -Architecture "All" -MinimumSupportedWindowsRelease $minOSVersion



    # Create the Intune App
    Write-Log "Uploading $displayName to Intune..."
    Connect-AutoMSIntuneGraph
    if ($allowUserUninstall) {
        $Win32App = Add-IntuneWin32App -FilePath $app.path -DisplayName $DisplayName -Description $description -Publisher $publisher -InstallExperience $installExperience -RestartBehavior $restartBehavior -DetectionRule $DetectionRule -RequirementRule $RequirementRule -InstallCommandLine $InstallScript -UninstallCommandLine $UninstallScript -Icon $Icon -AppVersion "$Version" -ScopeTagName $ScopeTags -Owner $owner -MaximumInstallationTimeInMinutes $maximumInstallationTimeInMinutes -AllowAvailableUninstall
    }
    else {
        $Win32App = Add-IntuneWin32App -FilePath $app.path -DisplayName $DisplayName -Description $description -Publisher $publisher -InstallExperience $installExperience -RestartBehavior $restartBehavior -DetectionRule $DetectionRule -RequirementRule $RequirementRule -InstallCommandLine $InstallScript -UninstallCommandLine $UninstallScript -Icon $Icon -AppVersion "$Version" -ScopeTagName $ScopeTags -Owner $owner -MaximumInstallationTimeInMinutes $maximumInstallationTimeInMinutes
    }



    ###################################################
    # MIGRATE OLD DEPLOYMENTS
    ###################################################


    # Check if any existing applications have the same version so we can delete them
    $ToRemove = $ExistingVersions | where-object displayVersion -eq $version
    if ($ToRemove) {
        # Remove conflicting versions
        Write-Log "Removing conflicting versions"
        $CurrentApp = Get-IntuneWin32App -Id $Win32App.id
        foreach ($removeapp in $ToRemove) {
            Write-Log "Moving assignments before removal..."
            Move-Assignments -From $removeapp -To $CurrentApp
            Write-Log "Removing App with ID $($removeapp.id)"
            Remove-IntuneWin32App -Id $removeapp.id
        }
    }

    # Define the current version, the version that is one older but shares the same name, and all the ones older than that
    Write-Log "Updating local application manifest..."
    $AllMatchingApps = Get-SameAppAllVersions $DisplayName | Sort-Object DisplayVersion -Descending
    $CurrentApp = $AllMatchingApps | Where-Object id -eq $Win32App.Id
    $AllOldApps = $AllMatchingApps | Where-Object id -ne $CurrentApp.Id
    $NMinusOneApp = $AllOldApps | Where-Object displayName -eq $displayName
    $NMinusTwoAndOlderApps = $AllOldApps | Where-Object displayName -ne $displayName

    

    # Start with the N-1 app first and move all its deployments to the newest one
    if ($NMinusOneApp) {
        Write-Log "Moving assignments from $($NMinusOneApp.id) to $($CurrentApp.id)"
        Move-Assignments -From $NMinusOneApp -To $CurrentApp
        for ($i = 0; $i -lt $NMinusTwoAndOlderApps.count; $i++) {
            # Move all the deployments up one number
            if ($i -eq 0) {
                # Move the app assignments in the 0 position to the nminusoneapp
                Move-Assignments -From $NMinusTwoAndOlderApps[$i] -To $NMinusOneApp
            }
            else {
                Move-Assignments -From $NMinusTwoAndOlderApps[$i] -To $NMinusTwoAndOlderApps[$i - 1]
            }
        }
    }
    # Rename all the old applications to have the appropriate N-<versions behind> in them
    for ($i = 1; $i -lt $AllMatchingApps.count; $i++) {
        Set-IntuneWin32App -Id $AllMatchingApps[$i].Id -DisplayName "$($displayName) (N-$i)"
        if ($?) {
            Write-Log "Successfully set Application Name to $($displayName) (N-$i)"
        }
        else {
            Write-Log "ERROR: Failed to update display name to $($displayName) (N-$i)"
        }
    }
    
    # Remove all the old versions 
    if (!$NoDelete) {
        for ($i = $numVersionsToKeep; $i -lt $AllMatchingApps.count; $i++) {
            Write-Log "Removing old app with id $($AllMatchingApps[$i].id)"
            Remove-IntuneWin32App -Id $AllMatchingApps[$i].id
        }
    }
    Write-Log "Updates complete for $displayName"
}   

# Clean up
# Write-Log "Cleaning up the buildspace..."
# Get-ChildItem $buildSpace -Exclude ".gitkeep" -Recurse | Remove-Item -Recurse -Force
# Write-Log "Removing .intunewin files..."
# Get-ChildItem $publishedApps -Exclude ".gitkeep" -Recurse | Remove-Item -Recurse -Force

# Return to the original directory
Pop-Location
