## Assign Office365 Licenses
Import-Module AzureADPreview

if (-not (Test-Path HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\Sync-AzureLicense)) {
    New-Eventlog -Logname Application -Source Sync-AzureLicense
}

Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 0 -Message "Started."
# execute manually on initial setup to store credentials
$credentialXmlPath = Join-Path (Split-Path $Profile) "assign.azure.license.cred.xml"
if (test-path $credentialXmlPath) {
    Write-Host "Found locally stored credentials, importing..."
    Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 0 -Message "Found locally stored credentials, importing..."

    $credential = Import-Clixml $credentialXmlPath
}
else {
    $credential = (Get-Credential -Message "Enter Azure AD Credentials.")
    $credential | Export-Clixml $credentialXmlPath 
}

try {
    Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 0 -Message "Connecting to Azure AD"
    Connect-AzureAD -Credential $credential -ErrorAction Stop > $null
}
catch {
    Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EntryType Error -EventID 10 -Message "Error connecting to Azure AD`n$($error[0].Exception)"
}


<# 
# get list of licenses
Get-AzureADSubscribedSku

# get list of plans to enable 
(Get-AzureADSubscribedSku | Where-Object {$_.SkuId -eq '18181a46-0d4e-45cd-891e-60aabd171b4e'}).ServicePlans

# Convert object to Json and paste the Json into the groups info/notes property
[PSCustomObject]@{
    SkuID = '18181a46-0d4e-45cd-891e-60aabd171b4e'
    # Services to enable a cumulative across all groups sharing the license skuid.
    ServicePlanNameToEnable = @(
        "MCOMEETACPEA"
    )
    # override a feature across all groups sharing the license skuid.
    ServicePlanNameToDisable = @() 
} | convertto-json
#>

$selectSplat = @{
    Property = @(
        "Name"
        @{Name="Guid";Expression={$_.ObjectGuid}}
        @{Name="LicenseDetails";Expression={$_.info | ConvertFrom-Json}}
        "StandardLicense"
        "SkuFeaturesToDisable"
        "EligibleLicensees"
    )
}
$licenseList = Get-ADGroup -f {Name -like "AAD_LIC_*"} -Properties info | Select-Object @selectSplat
foreach ($item in $licenseList) {
    Write-Host "Getting group info for $($item.Name)"
    Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 1 -Message "Getting license info for $($item.Name)"

    try {
        $item.StandardLicense = Get-AzureADSubscribedSku | Where-Object {$_.SkuId -eq $item.LicenseDetails.SkuId}
        $item.SkuFeaturesToDisable = $item.StandardLicense.ServicePlans | ForEach-Object { $_ | Where-Object {$_.AppliesTo -eq "User" -and $_.ServicePlanName -notin $item.LicenseDetails.ServicePlanNameToEnable }}
        $item.EligibleLicensees = (Get-ADGroupMember -Identity $item.Guid -Recursive).SID.Value
    }
    catch {
        $error[0]
        Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 12 -Message "Unable to get all information about object: [$($item.name)]"
    }
}

Write-Host "Getting all Azure AD Users..."
Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 1 -Message "Getting Azure AD User info."
$azureAdUsers = Get-AzureADUser -All $true

Write-Host "Checking licenses..."
Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 1 -Message "Checking licenses."

$i = 0
foreach ($azureUser in $azureAdUsers) {
    $i++
    if ($i % 100 -eq 0) {
        Write-Progress "Checking licenses..." -Status "Processed $i of $($azureAdUsers.Count)" -PercentComplete ([math]::Round( $i / $azureAdUsers.Count * 100 ))
    }
    $LicensesToAssign = New-Object -TypeName Microsoft.Open.AzureAD.Model.AssignedLicenses
    $licenseToDisable = New-Object -TypeName System.Collections.Generic.List[System.Object]
    foreach ($licenseObject in $licenseList) {
        $License = New-Object -TypeName Microsoft.Open.AzureAD.Model.AssignedLicense
        $License.SkuId = $licenseObject.StandardLicense.SkuId
        $License.DisabledPlans = $licenseObject.SkuFeaturesToDisable.ServicePlanId

        # determine whether the user needs this license added or removed
        $hasLicense = $azureUser.AssignedLicenses.SkuId -contains $licenseObject.StandardLicense.SkuID
        $isEligibleLicensee = $licenseObject.EligibleLicensees -contains $azureUser.OnPremisesSecurityIdentifier

        if ($isEligibleLicensee) {
            ## remove exchange online license from accounts that do not have a pre-existing mailbox
            ## this is dependant on us using the Active Directory "Mail" property as our UserPrincipalName
            ## Refactor
            $tenantDomain = (Get-AzureADTenantDetail).VerifiedDomains.Where{$_.Initial}.Name
            if ($azureUser.UserPrincipalName -match $tenantDomain -and $licenseObject.LicenseDetails.ServicePlanNameToEnable -Contains "EXCHANGE_S_STANDARD" ) {
                Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 20 -Message "User $($azureUser.UserPrincipalName) does not have an on-prem mailbox, removing service plan EXCHANGE_S_STANDARD from $($licenseObject.Name) "
                $License.DisabledPlans += ($licenseObject.StandardLicense.ServicePlans | Where-Object {$_.ServicePlanName -eq "EXCHANGE_S_STANDARD"}).ServicePlanId
            }
            ##  when eligible license has a feature disabled, add to collection to process on completed LicensesToAssign object
            if ($licenseObject.LicenseDetails.ServicePlanNameToDisable) {
                $licenseToDisable.Add($licenseObject)
            }

            if ($LicensesToAssign.AddLicenses.SkuId -contains $License.SkuId) {
                # License already added, take the commonly disabled features
                $compareLicense = $LicensesToAssign.AddLicenses | Where-Object {$_.SkuId -eq $License.SkuId}
                ($LicensesToAssign.AddLicenses | Where-Object {$_.SkuId -eq $License.SkuId}).DisabledPlans = (Compare-Object $compareLicense.DisabledPlans $License.DisabledPlans -ExcludeDifferent -IncludeEqual).InputObject
            }
            else {
                $LicensesToAssign.AddLicenses += $License
            }
        }
        elseif ($hasLicense -and -not $isEligibleLicensee) {
            # remove license, not eligible
            $LicensesToAssign.RemoveLicenses += $License.SkuId
        }

        Remove-Variable License
    }

    ##  explicitly disable feature, supersedes enabled features accross any eligible license group
    $disableFeatureMessages = New-Object System.Collections.Generic.List[System.Object]
    foreach ($item in $licenseToDisable) {
        $disableFeatureMessages.Add("Feature explicitly disabled in $($item.Name), removing service plan $($item.LicenseDetails.ServicePlanNameToDisable) from user $($azureUser.UserPrincipalName)")

        $forceDisableId = $item.StandardLicense.ServicePlans | Where-Object {$_.ServicePlanName -in $item.LicenseDetails.ServicePlanNameToDisable}
        $forceDisableId | ForEach-Object {
            ($LicensesToAssign.AddLicenses | Where-Object {$_.SkuId -eq $item.LicenseDetails.SkuId}).DisabledPlans.Add($_.ServicePlanId)
        }

    }

    Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 21 -Message $disableFeatureMessages

    # license removal must be unique
    $LicensesToAssign.RemoveLicenses = $LicensesToAssign.RemoveLicenses | Get-Unique

    # adding and removing the same license will error
    if ($LicensesToAssign.AddLicenses -and $LicensesToAssign.RemoveLicenses) {
        foreach ($item in $LicensesToAssign.AddLicenses.SkuId) {
            if ($item -in $LicensesToAssign.RemoveLicenses) {
                $LicensesToAssign.RemoveLicenses.Remove($item) > $null
            }
        }
    }
    
    # if user already has a matching license, remove it from the list, it doesn't need to be re-added
    if ($LicensesToAssign.AddLicenses) {
        foreach ($item in $azureUser.AssignedLicenses) {
            if ($item.SkuId -in $LicensesToAssign.AddLicenses.SkuId) {
                # check to see if the disabled plans match
                $newLicense = $LicensesToAssign.AddLicenses | Where-Object {$_.SkuId -eq $item.SkuId}
                if ((-not $newLicense.DisabledPlans -and -not $item.DisabledPlans) -or (-not (Compare-Object $newLicense.DisabledPlans $item.DisabledPlans))) {
                    # if comparison has no differences, remove license
                    $LicensesToAssign.AddLicenses.RemoveAt($LicensesToAssign.AddLicenses.SkuId.IndexOf($item.skuid))
                }
            }
        }
    }

    if ($LicensesToAssign.AddLicenses -or $LicensesToAssign.RemoveLicenses) {
        Write-Host "Syncing license for: $($azureUser.UserPrincipalName)"
        
        if (-not $azureUser.UsageLocation){
            #use default tenant location
            Set-AzureADUser -ObjectId $azureUser.ObjectId -UsageLocation (Get-AzureADTenantDetail).CountryLetterCode
        }
        
        try {
            Set-AzureADUserLicense -ObjectId $azureUser.ObjectId -AssignedLicenses $LicensesToAssign -ErrorAction Stop
            Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 2 -Message "Syncing license for: $($azureUser.UserPrincipalName)"
        }
        catch {
            Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EntryType Error -EventID 11 -Message "Error syncing license to Azure AD for user $($azureUser.UserPrincipalName)`n$($error[0].Exception)"

        }
    }
    Remove-Variable LicensesToAssign
    
}
Write-Eventlog -Logname Application -Source Sync-AzureLicense -Category 0 -EventID 0 -Message "Finished"

