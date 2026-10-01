#Requires -Version 5.1
<#
.SYNOPSIS
    Syncs this Windows computer to Snipe-IT: creates or updates the asset and assigns it to the logged-on user.

.DESCRIPTION
    Collects hardware and software inventory (serial number, model, CPU, RAM, disks, OS, MAC / IP addresses,
    antivirus, Office, AD / Entra ID join, RustDesk ID) and sends it to Snipe-IT through the REST API.
    - The asset is matched by serial number. If it doesn't exist, it is created (the model too, if needed).
    - Only fields with a detected value are sent, so data entered by hand in Snipe-IT is kept.
    - The asset is checked out to the logged-on user (skipped for local admins and assets assigned to a location).
    - The logged-on user is appended to a "users" history field.

    Windows only. Run it in the context of the logged-on user:
    - Microsoft Intune: Remediations (detection script, "Run this script using the logged-on credentials" = Yes)
    - Group Policy: User logon script

.NOTES
    Author : Dusan Priechodsky
    Source : https://github.com/DuprTECH/SnipeIT-PowerShell-Automated-Asset-Registration-and-Update
    Contact: info@duprtech.sk
    License: MIT
#>

# ============================================================================
#  CONFIGURATION - edit this section for your Snipe-IT
# ============================================================================

# Snipe-IT API URL and token (Snipe-IT: your user menu -> Manage API keys)
$SnipeItApiUrl   = "https://snipeit.example.com/api/v1"
$SnipeItApiToken = "PASTE-YOUR-API-TOKEN-HERE"

# Status label ID for new assets (Settings -> Status Labels)
$status_id = 2

# Fieldset ID assigned to newly created models (Settings -> Custom Fields -> Fieldsets), 0 = none
$fieldset_id = 1

# Category IDs for newly created models (Settings -> Categories)
$CategoryIdLaptop  = 2
$CategoryIdDesktop = 3

# Laptop detection: if set, computers whose name starts with this prefix are laptops (for example "N-").
# If empty, the chassis type reported by the BIOS is used.
$LaptopHostnamePrefix = ""

# Optional: path to a custom RustDesk executable (used with --get-id if no config file is found)
$RustDeskExePath = "C:\Program Files\RustDesk\rustdesk.exe"

# Change the model of an EXISTING asset when it differs from the detected one.
# Keep $false if you name models by hand in Snipe-IT (for example "Lenovo Yoga 9"), otherwise assets are moved to new models.
$UpdateExistingModel = $false

# Update the asset on every run ($true), or only when a value changed ($false)
$AlwaysUpdate = $true

# Don't change the assignment when the logged-on user is a local administrator (IT staff logging in to fix a PC)
$SkipAssignmentForLocalAdmins = $true

# Custom fields: Snipe-IT "DB Field" names (Settings -> Custom Fields, column "DB Field").
# Leave a value empty ("") to skip that field.
$FieldMap = @{
    EthMac          = "_snipeit_mac_address_1"       # MAC of the active Ethernet adapter
    WifiMac         = "_snipeit_mac_address_wi_fi_2" # MAC of the active Wi-Fi adapter
    EthIPv4         = "_snipeit_ipv4_3"              # IPv4 of the active Ethernet adapter
    WifiIPv4        = "_snipeit_ipv4_wi_fi_4"        # IPv4 of the active Wi-Fi adapter
    RustDeskId      = "_snipeit_rustdesk_id_5"       # RustDesk ID
    RAM             = "_snipeit_ram_6"               # "16 GB"
    CPU             = "_snipeit_cpu_7"               # CPU name
    OS              = "_snipeit_operating_system_8"  # "Microsoft Windows 11 Pro, Build: 26100"
    Storage         = "_snipeit_storage_9"           # "[SSD] 476.94 GB"
    Antivirus       = "_snipeit_antivirus_10"        # "Windows Defender 4.18... (2026-01-01)"
    Office          = "_snipeit_microsoft_office_11" # "Microsoft 365 (16.0...)"
    JoinType        = "_snipeit_ad_azure_12"         # "AD", "Azure" or "AD, Azure"
    OSInstallDate   = "_snipeit_os_install_date_13"  # "2026-01-01"
    Users           = "_snipeit_users_14"            # history of logged-on users: "user1, user2"
}

# ============================================================================
#  INVENTORY
# ============================================================================

# Function to determine if the computer is a laptop or desktop
function Get-ComputerType {
    if ($LaptopHostnamePrefix) {
        if ($env:COMPUTERNAME.StartsWith($LaptopHostnamePrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return "Laptop" }
        return "Desktop"
    }

    # Portable, Laptop, Notebook, Sub Notebook, Tablet, Convertible, Detachable, ...
    $laptopChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    try {
        $chassis = (Get-CimInstance -ClassName Win32_SystemEnclosure).ChassisTypes
        if ($chassis | Where-Object { $_ -in $laptopChassis }) { return "Laptop" }
    } catch {}
    return "Desktop"
}

# Function to get the category ID based on computer type
function Get-CategoryId {
    if ((Get-ComputerType) -eq "Laptop") { return $CategoryIdLaptop }
    return $CategoryIdDesktop
}

# Function to get the computer model
function Get-ComputerModel {
    $invalidModels = @(
        "Virtual Machine",
        "VMware Virtual Platform",
        "VM",
        "Parallels ARM Virtual Machine",
        $null
    )

    # Lenovo reports the machine type in Model (for example "83B1"),
    # the readable name (for example "Yoga 9 14IRP8") is in Win32_ComputerSystemProduct.Version
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
    $model = if ($manufacturer -match "Lenovo") {
        (Get-CimInstance -ClassName Win32_ComputerSystemProduct).Version
    } else {
        (Get-CimInstance -ClassName Win32_ComputerSystem).Model
    }

    if (-not $model) {
        Write-Warning "Model information is empty or null. Returning an empty string."
        return ""
    }

    if ($model -in $invalidModels) {
        Write-Warning "Model matches invalid list: '$model'. Returning an empty string."
        return ""
    }

    return $model.Trim()
}

# Function to get the computer serial number
function Get-ComputerSerialNumber {
    $invalidSerials = @(
        "To Be Filled By O.E.M.",
        "Default_String",
        "Default string",
        "System Serial Number",
        "0",
        "INVALID"
    )

    $serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber
    if ($serialNumber) { $serialNumber = $serialNumber.Trim() }

    if (-not $serialNumber -or $serialNumber -in $invalidSerials) {
        return ""
    }

    return $serialNumber
}

# Function to get the RAM amount in GB
function Get-RAMAmount {
    return [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
}

# Function to get the CPU information
function Get-CPUInfo {
    return "$((Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).Name)".Trim()
}

# Function to get the currently logged-on user (DOMAIN\user)
function Get-CurrentUser {
    return "$env:USERDOMAIN\$env:USERNAME"
}

# Function to get the currently logged-on user's principal name (UPN)
function Get-CurrentUserPrincipalName {
    $upn = "$(whoami /upn 2>$null)".Trim()
    if (-not $upn) { $upn = $env:USERNAME }
    return $upn
}

# Function to get the OS information
function Get-OSInfo {
    $osInfo = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption

    # Replace non-breaking spaces (U+00A0) with a normal space, then remove other non-alphanumeric characters
    $osInfo = $osInfo -replace '\u00A0', ' '
    $osInfo = ($osInfo -replace '[^\w\s]', '').Trim()

    return $osInfo
}

# Function to get the OS installation date
function Get-OSInstallDate {
    try {
        $installDate = (Get-CimInstance -ClassName Win32_OperatingSystem).InstallDate
        if ($installDate) { return $installDate.ToString("yyyy-MM-dd") }
    } catch {}
    return ""
}

# Function to get the build number
function Get-BuildNumber {
    return (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild
}

# Function to detect domain / Entra ID (Azure AD) join type
function Get-DomainJoinType {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:SystemRoot\system32\dsregcmd.exe"
        $psi.Arguments = '/status'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $output = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()

        $azureJoined  = $output -match 'AzureAdJoined\s*:\s*YES'
        $domainJoined = $output -match 'DomainJoined\s*:\s*YES'

        if ($domainJoined -and $azureJoined) { return "AD, Azure" }
        if ($domainJoined) { return "AD" }
        if ($azureJoined)  { return "Azure" }
    } catch {
        Write-Output "dsregcmd error: $_"
    }
    return ""
}

# Function to get antivirus name and signature date
function Get-AntivirusInfo {
    try {
        $mpStatus = Get-MpComputerStatus -ErrorAction Stop
        $version  = $mpStatus.AMProductVersion
        $sigDate  = $mpStatus.AntivirusSignatureLastUpdated
        $dateStr  = if ($sigDate) { $sigDate.ToString("yyyy-MM-dd") } else { "?" }
        return "Windows Defender $version ($dateStr)"
    } catch {}

    try {
        $avList = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
        if ($avList) {
            return ($avList | Select-Object -ExpandProperty displayName) -join "; "
        }
    } catch {}

    return ""
}

# Function to detect installed Microsoft Office version
function Get-OfficeInfo {
    # Click-to-Run (Microsoft 365 / Office 2016 / 2019 / 2021 / 2024)
    $c2r = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
    if (Test-Path $c2r) {
        try {
            $cfg      = Get-ItemProperty $c2r -ErrorAction Stop
            $products = $cfg.ProductReleaseIds
            $version  = $cfg.VersionToReport
            $name = switch -Regex ($products) {
                'O365'  { "Microsoft 365"; break }
                '2024'  { "Office 2024";   break }
                '2021'  { "Office 2021";   break }
                '2019'  { "Office 2019";   break }
                '2016'  { "Office 2016";   break }
                default { "Microsoft Office" }
            }
            if ($version) { return "$name ($version)" }
            return $name
        } catch {}
    }

    # MSI-based fallback - only for Office 2013 / 2010 (16.0 is shared by all newer versions)
    $msiMap = @{ "15.0" = "Office 2013"; "14.0" = "Office 2010" }
    foreach ($ver in $msiMap.Keys) {
        if ((Test-Path "HKLM:\SOFTWARE\Microsoft\Office\$ver\Common\InstallRoot") -or
            (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\$ver\Common\InstallRoot")) {
            return $msiMap[$ver]
        }
    }

    return ""
}

# Function to get storage type (SSD or HDD) and capacity
function Get-StorageInfo {
    $storageInfo = @()
    foreach ($disk in (Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $type = if ($disk.MediaType -eq 'Unspecified' -or $null -eq $disk.MediaType) { 'Unknown' } else { $disk.MediaType }
        $size = [math]::Round($disk.Size / 1GB, 2)
        $storageInfo += [PSCustomObject]@{
            Type     = $type
            Capacity = "$size GB"
        }
    }
    return $storageInfo
}

# Adapter filters
$script:NotPhysical = 'Bluetooth|Virtual|VMware|Hyper-V|TAP|Loopback|vEthernet|VPN'
$script:WifiPattern = 'Wireless|Wi-?Fi|802\.11|WLAN'

# Returns the best active adapter of the given kind ("Ethernet" or "WiFi"), preferring the one with a default gateway
function Get-ActiveAdapter {
    param([ValidateSet("Ethernet", "WiFi")][string]$Kind)

    try {
        $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration |
            Where-Object {
                $_.IPEnabled -eq $true -and
                $_.MACAddress -and
                ($_.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) -and
                $_.Description -notmatch $script:NotPhysical -and
                (($Kind -eq "WiFi") -eq ($_.Description -match $script:WifiPattern))
            }

        $best = $adapters | Where-Object { $_.DefaultIPGateway } | Select-Object -First 1
        if (-not $best) { $best = $adapters | Select-Object -First 1 }
        return $best
    } catch {
        return $null
    }
}

function Get-AdapterIPv4 {
    param($Adapter)
    if (-not $Adapter) { return "" }
    return ($Adapter.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
}

# Function to get RustDesk ID from the config file (or from the RustDesk executable)
function Get-RustDeskId {
    $configPaths = @(
        "$env:ProgramData\RustDesk\config\RustDesk.toml",
        "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk.toml",
        "C:\Windows\ServiceProfiles\NetworkService\AppData\Roaming\RustDesk\config\RustDesk.toml",
        "C:\Windows\system32\config\systemprofile\AppData\Roaming\RustDesk\config\RustDesk.toml"
    )
    foreach ($path in $configPaths) {
        if (Test-Path $path) {
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            if ($content -match '(?m)^id\s*=\s*[''"]?([^\s''"]+)[''"]?') {
                return $matches[1]
            }
        }
    }

    if ($RustDeskExePath -and (Test-Path $RustDeskExePath)) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $RustDeskExePath
            $psi.Arguments = '--get-id'
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = Split-Path $RustDeskExePath
            $proc = [System.Diagnostics.Process]::Start($psi)
            $id = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit()
            if ($id) { return $id.Trim() }
        } catch {}
    }
    return ""
}

# Gather information for custom fields
function Get-CustomFields {
    try {
        $ethAdapter  = Get-ActiveAdapter -Kind Ethernet
        $wifiAdapter = Get-ActiveAdapter -Kind WiFi
        $storageInfo = Get-StorageInfo
        $storageType     = ($storageInfo | ForEach-Object { $_.Type }) -join ", "
        $storageCapacity = ($storageInfo | ForEach-Object { $_.Capacity }) -join ", "
        $ramAmount   = Get-RAMAmount
        $osInfo      = Get-OSInfo

        $values = @{
            EthMac        = if ($ethAdapter)  { $ethAdapter.MACAddress }  else { "" }
            WifiMac       = if ($wifiAdapter) { $wifiAdapter.MACAddress } else { "" }
            EthIPv4       = Get-AdapterIPv4 -Adapter $ethAdapter
            WifiIPv4      = Get-AdapterIPv4 -Adapter $wifiAdapter
            RustDeskId    = Get-RustDeskId
            RAM           = if ($ramAmount) { "$ramAmount GB" } else { "" }
            CPU           = Get-CPUInfo
            OS            = if ($osInfo) { "$osInfo, Build: $(Get-BuildNumber)" } else { "" }
            Storage       = if ($storageCapacity) { "[$storageType] $storageCapacity" } else { "" }
            Antivirus     = Get-AntivirusInfo
            Office        = Get-OfficeInfo
            JoinType      = Get-DomainJoinType
            OSInstallDate = Get-OSInstallDate
        }

        # Only include mapped fields with a detected value - empty values are skipped so manually entered data is kept
        $dbFields = @{}
        foreach ($name in $values.Keys) {
            $dbField = $FieldMap[$name]
            if ($dbField -and $values[$name]) { $dbFields[$dbField] = "$($values[$name])" }
        }
        return $dbFields
    } catch {
        Write-Error "An error occurred while gathering custom fields: $_"
        return @{}
    }
}

# ============================================================================
#  SNIPE-IT API
# ============================================================================

Add-Type -AssemblyName "System.Web"

function Get-SnipeItHeaders {
    param([switch]$Json)
    $h = @{
        "Authorization" = "Bearer $SnipeItApiToken"
        "accept"        = "application/json"
    }
    if ($Json) { $h["content-type"] = "application/json" }
    return $h
}

# Wraps Invoke-RestMethod with retry/backoff on 429 (Too Many Requests) responses,
# reading the wait time from the Retry-After header or the response body's retryAfter field.
function Invoke-SnipeItRequest {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        [string]$Method = "Get",
        [byte[]]$BodyBytes = $null,
        [int]$MaxRetries = 3
    )

    $attempt = 0
    while ($true) {
        try {
            if ($BodyBytes) {
                return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method $Method -Body $BodyBytes -UseBasicParsing
            } else {
                return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method $Method -UseBasicParsing
            }
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}

            if ($statusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $retryAfter = 10
                try {
                    $retryHeaderValue = $_.Exception.Response.Headers["Retry-After"]
                    if ($retryHeaderValue) { $retryAfter = [int]$retryHeaderValue }
                } catch {}
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = [System.IO.StreamReader]::new($stream)
                    $errBody = $reader.ReadToEnd()
                    $reader.Close()
                    $errJson = $errBody | ConvertFrom-Json
                    if ($errJson.retryAfter) { $retryAfter = [int]$errJson.retryAfter }
                } catch {}

                $attempt++
                Write-Output "Rate limited (429) on $Uri. Waiting $retryAfter second(s) before retry $attempt/$MaxRetries."
                Start-Sleep -Seconds ($retryAfter + 1)
                continue
            }

            throw
        }
    }
}

# Reads the response body of a failed request (Snipe-IT error message)
function Get-ErrorResponseBody {
    param($ErrorRecord)
    try {
        $stream = $ErrorRecord.Exception.Response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        return $body
    } catch {
        return ""
    }
}

# Function to search for a model in Snipe-IT
function Search-ModelInSnipeIt {
    param ([string]$ModelName)

    if (-not $ModelName) {
        Write-Warning "ModelName is null or empty. Cannot search for a model."
        return $null
    }

    $encodedModelName = [System.Web.HttpUtility]::UrlEncode($ModelName)
    $url = "$SnipeItApiUrl/models?limit=50&offset=0&search=$encodedModelName&sort=created_at&order=asc"

    try {
        $response = Invoke-SnipeItRequest -Uri $url -Headers (Get-SnipeItHeaders) -Method Get

        if (-not $response -or -not $response.total -or $response.total -eq 0) {
            Write-Warning "No models found for ModelName: '$ModelName'."
            return $null
        }

        foreach ($model in $response.rows) {
            if ($model.name -eq $ModelName) {
                Write-Output "Model found with ID: $($model.id)"
                return $model.id
            }
        }

        Write-Warning "No exact match found for ModelName: '$ModelName'."
        return $null
    } catch {
        Write-Error "An error occurred during the model search: $_"
        return $null
    }
}

# Function to create a model in Snipe-IT
function Create-ModelInSnipeIt {
    param (
        [string]$ModelName,
        [int]$CategoryId
    )

    if (-not $ModelName) {
        Write-Warning "ModelName is null or empty. Cannot create a model."
        return $null
    }
    if (-not $CategoryId -or $CategoryId -le 0) {
        Write-Warning "Invalid CategoryId provided. Cannot create a model."
        return $null
    }

    $body = @{
        category_id = $CategoryId
        name        = $ModelName
    }
    if ($fieldset_id) { $body.fieldset_id = $fieldset_id }

    $bodyJson = $body | ConvertTo-Json -Depth 10
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

    try {
        $response = Invoke-SnipeItRequest -Uri "$SnipeItApiUrl/models" -Headers (Get-SnipeItHeaders -Json) -Method Post -BodyBytes $bodyBytes

        if ($response -and $response.payload -and $response.payload.id) {
            Write-Output "Model created with ID: $($response.payload.id)"
            return $response.payload.id
        }
        Write-Warning "Model creation response is missing expected fields. Response: $($response | ConvertTo-Json -Depth 10)"
        return $null
    } catch {
        Write-Error "An error occurred during model creation: $_ $(Get-ErrorResponseBody $_)"
        return $null
    }
}

# Finds the Snipe-IT user ID for a UPN or DOMAIN\user (matched by username or e-mail)
function Get-SnipeUserId {
    param([string]$UserName)

    if ([string]::IsNullOrWhiteSpace($UserName)) { return $null }

    # DOMAIN\user -> user
    $u = $UserName
    if ($u -match "\\") { $u = $u.Split("\")[-1] }
    $short = $u.Split("@")[0]

    $url = "$SnipeItApiUrl/users?limit=50&offset=0&search=$([System.Web.HttpUtility]::UrlEncode($u))"

    try {
        $res = Invoke-SnipeItRequest -Uri $url -Headers (Get-SnipeItHeaders) -Method Get
        if ($res -and $res.total -gt 0) {
            $match = $res.rows | Where-Object { $_.username -ieq $u -or $_.email -ieq $u } | Select-Object -First 1
            if (-not $match) { $match = $res.rows | Where-Object { $_.username -ieq $short } | Select-Object -First 1 }
            if ($match) {
                $id = @($match.id) | Select-Object -First 1
                if ($null -ne $id) { return [int]$id }
            }
        }
    } catch {
        Write-Output "Error during user search: $_"
    }

    return $null
}

function Checkin-AssetInSnipeIt {
    param(
        [Parameter(Mandatory=$true)][int]$AssetId,
        [string]$Note = "Auto-checkin (reassign)"
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ note = $Note } | ConvertTo-Json -Depth 5))

    try {
        return Invoke-SnipeItRequest -Uri "$SnipeItApiUrl/hardware/$AssetId/checkin" -Headers (Get-SnipeItHeaders -Json) -Method Post -BodyBytes $bodyBytes
    } catch {
        Write-Output "Error during asset checkin: $_"
        return $null
    }
}

function Checkout-AssetToUserInSnipeIt {
    param(
        [Parameter(Mandatory=$true)][int]$AssetId,
        [Parameter(Mandatory=$true)]$UserId,
        [string]$Note = "Auto-checkout (reassign to current user)"
    )

    # UserId may arrive as a single-element collection from an upstream lookup; always coerce to a scalar int
    $userIdInt = [int](@($UserId) | Select-Object -First 1)

    $body = @{
        checkout_to_type = "user"
        assigned_user    = $userIdInt
        assigned_to      = $userIdInt
        note             = $Note
    } | ConvertTo-Json -Depth 5
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    try {
        return Invoke-SnipeItRequest -Uri "$SnipeItApiUrl/hardware/$AssetId/checkout" -Headers (Get-SnipeItHeaders -Json) -Method Post -BodyBytes $bodyBytes
    } catch {
        Write-Output "Error during asset checkout: $_"
        return $null
    }
}

function Get-AssetDetailsFromSnipeIt {
    param([Parameter(Mandatory=$true)][int]$AssetId)

    try {
        return Invoke-SnipeItRequest -Uri "$SnipeItApiUrl/hardware/$AssetId" -Headers (Get-SnipeItHeaders) -Method Get
    } catch {
        Write-Output "Error during asset detail load: $_"
        return $null
    }
}

# Recursively checks membership in a local group (including nested groups)
function Search-AdminGroupMembership {
    param(
        [string]$GroupPath,
        [string]$Username,
        [System.Collections.Generic.HashSet[string]]$Visited
    )
    if (-not $Visited.Add($GroupPath)) { return $false }
    try {
        $group = [ADSI]$GroupPath
        foreach ($memberRef in $group.Invoke("Members")) {
            $member      = [ADSI]$memberRef
            $memberName  = $member.Properties["Name"].Value
            $schemaClass = $member.SchemaClassName
            if ($schemaClass -eq "Group") {
                if (Search-AdminGroupMembership -GroupPath $member.Path -Username $Username -Visited $Visited) {
                    return $true
                }
            } elseif ($memberName -ieq $Username) {
                return $true
            }
        }
    } catch {}
    return $false
}

function Test-IsLocalAdmin {
    try {
        # Builtin Administrators group by SID, so it works on localized Windows too
        $adminGroup = (New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([System.Security.Principal.NTAccount]).Value.Split("\")[-1]
        $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        return Search-AdminGroupMembership -GroupPath "WinNT://./$adminGroup,group" -Username $env:USERNAME -Visited $visited
    } catch {
        return $false
    }
}

function Ensure-AssetAssignedToMe {
    param(
        [Parameter(Mandatory=$true)][int]$AssetId,
        [object]$AssetDetails = $null
    )

    $me = Get-CurrentUserPrincipalName
    $myUserId = Get-SnipeUserId -UserName $me

    if (-not $myUserId) {
        Write-Output "Snipe-IT user not found for '$me'. Skipping assignment."
        return
    }

    $details = if ($AssetDetails) { $AssetDetails } else { Get-AssetDetailsFromSnipeIt -AssetId $AssetId }
    if (-not $details) { return }

    # assigned_to is null, or an object with type / id
    $assigned = $details.assigned_to

    if (-not $assigned) {
        Write-Output "Asset $AssetId is not assigned. Checking out to me (userId=$myUserId)."
        Checkout-AssetToUserInSnipeIt -AssetId $AssetId -UserId $myUserId -Note "Auto-checkout to $me" | Out-Null
        return
    }

    $assignedType = $assigned.type
    $assignedId   = $assigned.id

    if ($assignedType -eq "location") {
        Write-Output "Asset $AssetId is assigned to a location - keeping location assignment."
        return
    }

    if ($assignedType -ne "user") {
        Write-Output "Asset $AssetId is assigned to a non-user target (type=$assignedType). Skipping reassignment."
        return
    }

    if ($assignedId -eq $myUserId) {
        Write-Output "Asset $AssetId is already assigned to me ($me)."
        return
    }

    Write-Output "Asset $AssetId is assigned to another user (id=$assignedId). Reassigning to me ($me)."

    Checkin-AssetInSnipeIt -AssetId $AssetId -Note "Auto-checkin for reassignment to $me" | Out-Null
    Start-Sleep -Milliseconds 300
    Checkout-AssetToUserInSnipeIt -AssetId $AssetId -UserId $myUserId -Note "Auto-checkout to $me" | Out-Null
}

# Function to search for an asset in Snipe-IT by serial number
function Search-AssetInSnipeIt {
    param ([string]$SerialNumber)

    $encodedSerialNumber = [System.Web.HttpUtility]::UrlEncode($SerialNumber)
    $url = "$SnipeItApiUrl/hardware?limit=50&offset=0&search=$encodedSerialNumber&sort=created_at&order=asc"

    try {
        $response = Invoke-SnipeItRequest -Uri $url -Headers (Get-SnipeItHeaders) -Method Get

        if ($response.total -gt 0) {
            foreach ($asset in $response.rows) {
                if ($asset.serial -eq $SerialNumber) {
                    return $asset
                }
            }
        }
    } catch {
        Write-Output "Error during asset search: $_"
    }

    return $null
}

# Function to create an asset in Snipe-IT
function Create-AssetInSnipeIt {
    param (
        [string]$ModelId,
        [string]$SerialNumber,
        [string]$AssetName,
        [hashtable]$CustomFields
    )

    if (-not $ModelId)      { Write-Warning "ModelId is null or empty. Cannot create an asset.";      return $null }
    if (-not $SerialNumber) { Write-Warning "SerialNumber is null or empty. Cannot create an asset."; return $null }
    if (-not $AssetName)    { Write-Warning "AssetName is null or empty. Cannot create an asset.";    return $null }

    $body = @{
        model_id  = $ModelId
        serial    = $SerialNumber
        name      = $AssetName
        status_id = $status_id
    } + $CustomFields | ConvertTo-Json -Depth 10
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    try {
        $response = Invoke-SnipeItRequest -Uri "$SnipeItApiUrl/hardware" -Headers (Get-SnipeItHeaders -Json) -Method Post -BodyBytes $bodyBytes

        if ($response -and $response.payload -and $response.payload.id) {
            return $response.payload.id
        }
        Write-Warning "Asset creation response is missing expected fields. Response: $($response | ConvertTo-Json -Depth 10)"
        return $null
    } catch {
        Write-Error "An error occurred during asset creation: $_ $(Get-ErrorResponseBody $_)"
        return $null
    }
}

# Function to update an asset in Snipe-IT
function Update-AssetInSnipeIt {
    param (
        [string]$AssetId,
        [string]$AssetName,
        [hashtable]$CustomFields
    )

    if (-not $AssetId)   { Write-Warning "AssetId is null or empty. Cannot update an asset.";   return $null }
    if (-not $AssetName) { Write-Warning "AssetName is null or empty. Cannot update an asset."; return $null }

    $body = @{
        name = $AssetName
    } + $CustomFields | ConvertTo-Json -Depth 10
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    try {
        $response = Invoke-SnipeItRequest -Uri "$SnipeItApiUrl/hardware/$AssetId" -Headers (Get-SnipeItHeaders -Json) -Method Patch -BodyBytes $bodyBytes

        if ($response -and $response.payload -and $response.payload.id) {
            return $response.payload.id
        }
        Write-Warning "Asset update response is missing expected fields. Response: $($response | ConvertTo-Json -Depth 10)"
        return $null
    } catch {
        Write-Error "An error occurred during asset update: $_ $(Get-ErrorResponseBody $_)"
        return $null
    }
}

# Returns the current value of a custom field from an asset object
function Get-AssetCustomFieldValue {
    param($Asset, [string]$FieldKey)
    foreach ($prop in $Asset.custom_fields.PSObject.Properties) {
        if ($prop.Value.field -eq $FieldKey) { return $prop.Value.value }
    }
    return ""
}

# Appends the username to the users field; returns $null if no change is needed.
# If the last entry is only a surname that the username ends with (for example "Smith" vs "jsmith"), it is replaced.
function Get-UserFieldAppended {
    param([string]$CurrentValue, [string]$RawUsername)
    $username = $RawUsername
    if ($username -match "\\") { $username = $username.Split("\")[-1] }
    $username = $username.Trim()
    if ([string]::IsNullOrWhiteSpace($username)) { return $null }
    if ([string]::IsNullOrWhiteSpace($CurrentValue)) { return $username }

    # Deduplicate existing entries (case-insensitive, keep first occurrence order)
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($p in ($CurrentValue -split ",")) {
        $p = $p.Trim()
        if ($p -and -not ($unique | Where-Object { $_ -ieq $p })) { $unique.Add($p) }
    }
    if (-not ($unique | Where-Object { $_ -ieq $username })) {
        $last = if ($unique.Count -gt 0) { $unique[$unique.Count - 1] } else { "" }
        if ($last.Length -gt 0 -and $username.EndsWith($last, [System.StringComparison]::OrdinalIgnoreCase)) {
            $unique[$unique.Count - 1] = $username
        } else {
            $unique.Add($username)
        }
    }
    $newValue = $unique -join ", "
    if ($newValue -eq $CurrentValue) { return $null }
    return $newValue
}

# ============================================================================
#  MAIN
# ============================================================================

if ($SnipeItApiToken -eq "PASTE-YOUR-API-TOKEN-HERE" -or $SnipeItApiUrl -like "*snipeit.example.com*") {
    Write-Output "Snipe-IT URL / API token is not configured. Edit the CONFIGURATION section of the script."
    exit 0
}

$computerModel = Get-ComputerModel
$serialNumber  = Get-ComputerSerialNumber

if (-not $serialNumber) {
    Write-Output "No serial number found on this computer."
    exit 0
}

$asset        = Search-AssetInSnipeIt -SerialNumber $serialNumber
$assetName    = $env:COMPUTERNAME
$customFields = Get-CustomFields
$assignToMe   = -not ($SkipAssignmentForLocalAdmins -and (Test-IsLocalAdmin))

if ($asset) {
    $assetId = $asset.id
    $updateRequired = $false

    # Append the current user to the users field
    if ($FieldMap.Users) {
        $existingUserField = Get-AssetCustomFieldValue -Asset $asset -FieldKey $FieldMap.Users
        $newUserFieldValue = Get-UserFieldAppended -CurrentValue $existingUserField -RawUsername (Get-CurrentUser)
        if ($newUserFieldValue) { $customFields[$FieldMap.Users] = $newUserFieldValue }
    }

    if ($asset.name -ne $assetName) {
        Write-Output "Asset name requires update: '$($asset.name)' -> '$assetName'"
        $updateRequired = $true
    }

    foreach ($key in $customFields.Keys) {
        $current = Get-AssetCustomFieldValue -Asset $asset -FieldKey $key
        if ($current -ne $customFields[$key]) {
            Write-Output "Custom field '$key' requires update: '$current' -> '$($customFields[$key])'"
            $updateRequired = $true
        }
    }

    # Change the model of an existing asset if it differs from the detected one (only with $UpdateExistingModel)
    if ($UpdateExistingModel -and $computerModel -and $asset.model.name -ne $computerModel) {
        $correctModelId = Search-ModelInSnipeIt -ModelName $computerModel | Select-Object -Last 1
        if (-not $correctModelId) {
            $correctModelId = Create-ModelInSnipeIt -ModelName $computerModel -CategoryId (Get-CategoryId) | Select-Object -Last 1
        }
        if ($correctModelId -and $correctModelId -ne $asset.model.id) {
            Write-Output "Asset model requires update: '$($asset.model.name)' -> '$computerModel' (model ID $correctModelId)"
            $customFields["model_id"] = [int]$correctModelId
            $updateRequired = $true
        }
    }

    # Assign the asset to the logged-on user (not for local admins)
    if ($assignToMe) {
        Ensure-AssetAssignedToMe -AssetId $assetId -AssetDetails $asset
    } else {
        Write-Output "Current user is a local admin - skipping asset assignment."
    }

    if ($AlwaysUpdate -or $updateRequired) {
        $updatedAssetId = Update-AssetInSnipeIt -AssetId $assetId -AssetName $assetName -CustomFields $customFields
        Write-Output "Asset updated with ID: $updatedAssetId"
    } else {
        Write-Output "No update required for asset with ID: $assetId"
    }
} else {
    if (-not $computerModel) {
        Write-Output "Computer model could not be determined."
        exit 0
    }

    $modelId = Search-ModelInSnipeIt -ModelName $computerModel | Select-Object -Last 1
    if (-not $modelId) {
        $modelId = Create-ModelInSnipeIt -ModelName $computerModel -CategoryId (Get-CategoryId) | Select-Object -Last 1
    }

    if ($FieldMap.Users) {
        $newUserFieldValue = Get-UserFieldAppended -CurrentValue "" -RawUsername (Get-CurrentUser)
        if ($newUserFieldValue) { $customFields[$FieldMap.Users] = $newUserFieldValue }
    }

    $newAssetId = Create-AssetInSnipeIt -ModelId $modelId -SerialNumber $serialNumber -AssetName $assetName -CustomFields $customFields
    Write-Output "New asset ID: $newAssetId"

    if ($newAssetId -and $assignToMe) {
        Ensure-AssetAssignedToMe -AssetId $newAssetId
    } elseif ($newAssetId) {
        Write-Output "Current user is a local admin - skipping asset assignment after creation."
    }
}

exit 0
