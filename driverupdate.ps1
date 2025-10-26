<#
.SYNOPSIS
    Fetch driver updates for Windows Autopatch and export to CSV.
    Excludes BIOS and Firmware items.

.DESCRIPTION
    This script retrieves driver update information from Windows Autopatch using Microsoft Graph API
    and exports the results to CSV format. It uses two collection methods:
    1. Active deployments (with device counts)
    2. Driver catalog entries (available but not yet deployed)
    
    The script specifically excludes BIOS and Firmware updates to focus only on hardware drivers.

.PARAMETER tenantId
    Azure AD Tenant ID

.PARAMETER clientId
    Azure App Registration Client ID

.PARAMETER clientSecret
    Azure App Registration Client Secret

.PARAMETER outputCsv
    Path for the CSV output file

.PARAMETER logFile
    Path for the log file

.NOTES
    Version:        1.0
    Author:         BoolServe
    Creation Date:  October 2025
    Last Updated:   October 2025
    
    Required API Permissions (Application):
    - Device.Read.All is not required by your script as written (you never call /devices). If later you resolve device details by calling /v1.0/devices/{id}, you’ll need it. Microsoft’s Autopatch programmatic guide mentions Device.Read.All if you display device info.
    - GroupMember.Read.All — to list groups with GET /v1.0/groups. (You can also use Group.Read.All, but GroupMember.Read.All is listed as the least‑privileged app permission that works for this endpoint.)
    - WindowsUpdates.ReadWrite.All — yes, even for the GET calls to the Windows Updates endpoints (deployments, update policies, audiences, catalog).

    
    Prerequisites:
    - PowerShell 5.1 or higher
    - Azure App Registration with proper permissions
    - Admin consent granted
    - Internet connectivity to Graph API endpoints

.EXAMPLE
    .\Get-AutopatchDriverUpdates.ps1
    
    Runs the script with default configuration values to fetch and export driver updates.

.LINK
    https://learn.microsoft.com/graph/api/resources/windowsupdates-updates
    https://learn.microsoft.com/windows/deployment/windows-autopatch/
#>

# ==============================
# CONFIGURATION PARAMETERS
# Change these values according to your environment
# ==============================
$tenantId = "68463846"        # Your Azure AD Tenant ID
$clientId = "97927947234"          # Azure App Registration Client ID
$clientSecret = "68368628362"    # Client Secret Value (Store securely!)
$outputCsv    = "C:\Temp\AutopatchDriverUpdates.csv"            # Output CSV file path
$logFile      = "C:\Temp\AutopatchDriverUpdates.log"              # Log file path

# LOGGING FUNCTION
# Purpose: Creates timestamped log entries to both console and file

    <#
    .SYNOPSIS
        Writes timestamped log messages to console and file
    
    .PARAMETER Message
        The message to log
    
    .EXAMPLE
        Write-Log "Script started"
    #>

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
    Write-Host "$timestamp - $Message"
}

# AUTHENTICATION FUNCTION
# Purpose: Obtains OAuth 2.0 access token using client credentials flow

<#
    .SYNOPSIS
        Authenticates to Microsoft Graph API and returns an access token
    
    .DESCRIPTION
        Uses OAuth 2.0 client credentials flow to obtain a Bearer token
        for Graph API authentication. Token is valid for 60 minutes.
    
    .OUTPUTS
        String - Bearer access token
    
    .EXAMPLE
        $token = Get-AccessToken
    #>

function Get-AccessToken {
    try {
        Write-Log " Requesting access token..."
        $body = @{
            client_id     = $clientId
            scope         = "https://graph.microsoft.com/.default"
            client_secret = $clientSecret
            grant_type    = "client_credentials"
        }
        $response = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $body -ErrorAction Stop
        Write-Log " Access token acquired successfully."
        return $response.access_token
    }
    catch {
        Write-Log " Failed to get access token: $($_.Exception.Message)"
        throw
    }
}

# ==============================
# ==============================
# GRAPH API WRAPPER FUNCTION
# Purpose: Centralized wrapper for all Microsoft Graph API calls
# ==============================
# ==============================

 <#
    .SYNOPSIS
        Makes HTTP requests to Microsoft Graph API with error handling
    
    .DESCRIPTION
        Centralized function for all Graph API calls. Handles authentication headers,
        JSON serialization, error handling, and response body capture.
    
    .PARAMETER Uri
        The Graph API endpoint URL
    
    .PARAMETER Token
        Bearer access token
    
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE). Default is GET
    
    .PARAMETER Body
        Optional request body for POST/PATCH operations
    
    .OUTPUTS
        PSObject - Deserialized JSON response or $null on failure
    
    .EXAMPLE
        $groups = Invoke-GraphRestRequest -Uri "https://graph.microsoft.com/v1.0/groups" -Token $token
    #>

function Invoke-GraphRestRequest {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$Token,
        [string]$Method = "GET",
        $Body = $null
    )

    try {
        $headers = @{ Authorization = "Bearer $Token" }
        if ($Body) {
            $jsonBody = $Body | ConvertTo-Json -Depth 10
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $jsonBody -ContentType 'application/json' -ErrorAction Stop
        }
        else {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ErrorAction Stop
        }
    }
    catch {
        Write-Log " Graph API call failed: $Uri"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $body = $reader.ReadToEnd()
            Write-Log "Response: $body"
        }
        else {
            Write-Log "Error: $($_.Exception.Message)"
        }
        return $null
    }
}

# ==============================
# MAIN
# ==============================
Write-Log " Starting Windows Autopatch Driver Update fetch process..."
$token = Get-AccessToken

# Step 1 - Get Groups
$groupsUrl = "https://graph.microsoft.com/v1.0/groups"
$groupResp = Invoke-GraphRestRequest -Uri $groupsUrl -Token $token
if (-not $groupResp -or -not $groupResp.value) {
    Write-Log " Failed to retrieve groups or none found."
    exit
}

# Step 2 - Locate Autopatch Test Ring Group
$autopatchGroup = $groupResp.value | Where-Object { $_.displayName -match "Intune Test-1" }
if (-not $autopatchGroup) {
    Write-Log " Could not locate Windows Autopatch Test Ring group."
    exit
}

Write-Log " Found Autopatch group: $($autopatchGroup.displayName) [$($autopatchGroup.id)]"

# Step 3 - Fetch Update Policies
$updatePoliciesUrl = "https://graph.microsoft.com/beta/admin/windows/updates/updatePolicies"
$policyResp = Invoke-GraphRestRequest -Uri $updatePoliciesUrl -Token $token
if (-not $policyResp -or -not $policyResp.value) {
    Write-Log " No update policies found."
    exit
}

# Step 4 - Collect driver details from deployments
$driverData = @()

# Get all deployments (this is where driver approvals are stored)
$deploymentsUrl = "https://graph.microsoft.com/beta/admin/windows/updates/deployments"
$deploymentResp = Invoke-GraphRestRequest -Uri $deploymentsUrl -Token $token

if ($deploymentResp -and $deploymentResp.value) {
    foreach ($deployment in $deploymentResp.value) {
        # Filter for driver deployments only
        if ($deployment.'@odata.type' -eq '#microsoft.graph.windowsUpdates.deployment') {
            $deploymentId = $deployment.id
            Write-Log " Checking deployment: $deploymentId"
            
            # Get deployment audience to find associated devices
            $audienceId = $deployment.audience.id
            if ($audienceId) {
                $audienceUrl = "https://graph.microsoft.com/beta/admin/windows/updates/deploymentAudiences/$audienceId/members"
                $audienceMembers = Invoke-GraphRestRequest -Uri $audienceUrl -Token $token
                
                if ($audienceMembers -and $audienceMembers.value) {
                    # Get the content information (driver details)
                    $contentUrl = "https://graph.microsoft.com/beta/admin/windows/updates/deployments/$deploymentId"
                    $deploymentDetails = Invoke-GraphRestRequest -Uri $contentUrl -Token $token
                    
                    if ($deploymentDetails.content) {
                        $catalogEntry = $deploymentDetails.content.catalogEntry
                        
                        if ($catalogEntry) {
                            $driverName = $catalogEntry.displayName
                            $driverVersion = $catalogEntry.version
                            
                            # Exclude BIOS and Firmware
                            if ($driverName -notmatch "BIOS" -and $driverName -notmatch "Firmware") {
                                $driverData += [PSCustomObject]@{
                                    GroupName     = $autopatchGroup.displayName
                                    GroupGUID     = $autopatchGroup.id
                                    DeploymentId  = $deploymentId
                                    DriverName    = if ($driverName) { $driverName } else { "N/A" }
                                    DriverVersion = if ($driverVersion) { $driverVersion } else { "N/A" }
                                    DeviceCount   = $audienceMembers.value.Count
                                }
                                Write-Log " Found driver: $driverName ($driverVersion)"
                            }
                        }
                    }
                }
            }
        }
    }
}

# Alternative Method: Get catalog entries for approved drivers
Write-Log " Fetching driver catalog entries..."
$catalogUrl = "https://graph.microsoft.com/beta/admin/windows/updates/catalog/entries?`$filter=isof('microsoft.graph.windowsUpdates.driverUpdateCatalogEntry')"
$catalogResp = Invoke-GraphRestRequest -Uri $catalogUrl -Token $token

if ($catalogResp -and $catalogResp.value) {
    Write-Log " Found $($catalogResp.value.Count) driver catalog entries"
    
    foreach ($driver in $catalogResp.value) {
        $driverName = $driver.displayName
        $driverVersion = $driver.version
        
        # Exclude BIOS and Firmware
        if ($driverName -notmatch "BIOS" -and $driverName -notmatch "Firmware") {
            # Check if this driver is already in our collection
            $exists = $driverData | Where-Object { $_.DriverName -eq $driverName -and $_.DriverVersion -eq $driverVersion }
            
            if (-not $exists) {
                $driverData += [PSCustomObject]@{
                    GroupName     = $autopatchGroup.displayName
                    GroupGUID     = $autopatchGroup.id
                    DeploymentId  = "N/A"
                    DriverName    = if ($driverName) { $driverName } else { "N/A" }
                    DriverVersion = if ($driverVersion) { $driverVersion } else { "N/A" }
                    DeviceCount   = "N/A"
                }
            }
        }
    }
}

# Step 5 - Export results
if ($driverData.Count -gt 0) {
    Write-Log " Found $($driverData.Count) driver updates. Exporting CSV..."
    $driverData | Export-Csv -Path $outputCsv -NoTypeInformation -Encoding UTF8
    Write-Log " Export complete: $outputCsv"
}
else {
    Write-Log " No applicable driver updates found (after filtering BIOS/Firmware)."
}

Write-Log " Script execution completed successfully."
rite-Log " Script execution completed  not  successfully."