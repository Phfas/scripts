# Azure AD License Groups (AAD_LIC)
These Active Directory groups are used to assign Azure AD licenses to users based on Active Directory group membership. Group based licensing in Azure Active Directory is a premium licensed feature. Members of this group will have their Azure AD licenses synchronized to the Active Directory groups license definition by a scheduled script.

## Group Properties 

|Property| Definition |
|--------|------------|
| Name               | AAD_LIC_DepartmentShortName_LicenseName |
| Description        | What the group is used to license. Plans or features should be described. |
| Group Scope        | Global |
| Group Type         | Security |
| Members            | Users or Groups  |
| Notes/Info         | JSON formatted string containing a License SkuId, ServicePlanNameToEnable and ServicePlanNameToDisable(Optional)     |

### Example 
|Property| Definition |
|--------|------------|
| Name               | AAD_LIC_TSC_Office365 E1 Application Testing License |
| Description        | Members of this group will be assigned the Office 365 E1 Licenses related to new applications. |
| Group Scope        | Global |
| Group Type         | Security |
| Members            | Average Joe; Average Jane |
| ManagedBy          | John_Doe  |
| Notes              | `{ "SkuID": "18181a46-0d4e-45cd-891e-60aabd171b4e", "ServicePlanNameToEnable": [ "FORMS_PLAN_E1", "STREAM_O365_E1", "PROJECTWORKMANAGEMENT"]}` |

> **Note:** For a list of service plans see: [Product names and service plan identifiers for licensing](https://docs.microsoft.com/en-us/azure/active-directory/users-groups-roles/licensing-service-plan-reference)

## Get License Information
These commands will present up to date license information from Azure.

```powershell
# get list of licenses
Get-AzureADSubscribedSku
# get list of plans to enable 
(Get-AzureADSubscribedSku | Where-Object {$_.SkuId -eq '18181a46-0d4e-45cd-891e-60aabd171b4e'}).ServicePlans
```

Convert a powershell object to Json and paste the Json into the groups info/notes property. Add the `-Compress` switch if the JSON string gets too long. 

```powershell
[PSCustomObject]@{
    SkuID = '18181a46-0d4e-45cd-891e-60aabd171b4e'
    # Services to enable a cumulative across all groups sharing the license skuid.
    ServicePlanNameToEnable = @(
        "MCOMEETACPEA"
    )
    # override a feature across all groups sharing the license skuid.
    ServicePlanNameToDisable = @() 
} | convertto-json
```
