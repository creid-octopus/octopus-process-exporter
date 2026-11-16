<#
.SYNOPSIS
    Creates the smallest user role and team that Export-OctopusProcesses.ps1 needs.
.DESCRIPTION
    This script WRITES to your Octopus Server, unlike the export script, which only reads.
    Run it once, as a user who can manage teams and user roles (for example a Space Manager
    plus a System Administrator for the user role). It creates:
      1. A user role with only the view permissions the export needs.
      2. A team in the one space you name, scoped to that space.
      3. Optionally, adds existing users to the team.
    It does not create users or API keys. Create the user and its API key in the Octopus UI.
    Run it again at any time. It updates what it created, and never deletes anything.
    Use -WhatIf to see what it would do without changing anything.
.PARAMETER OctopusUrl
    The address of your Octopus Server.
.PARAMETER ApiKey
    An API key for an administrator. You can also set the OCTOPUS_API_KEY environment variable.
.PARAMETER SpaceName
    The space the export will read. The team only gets access to this space.
.PARAMETER RoleName
    Name of the user role. The default is "Process Export Reader".
.PARAMETER TeamName
    Name of the team. The default is "Process Export Runners".
.PARAMETER UserName
    Usernames or email addresses of existing users to add to the team.
.PARAMETER WithoutTelemetry
    Leave out the permissions that only -IncludeTelemetry needs (DeploymentView, ReleaseView, TaskView).
.PARAMETER IncludeTemplateNames
    Add ActionTemplateView, needed only for -KeepNames Template.
.EXAMPLE
    .\New-OctopusExportRole.ps1 -OctopusUrl "https://octopus.example.com" -SpaceName "Default" -UserName "jsmith"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)] [string]$OctopusUrl,
    [string]$ApiKey = $env:OCTOPUS_API_KEY,
    [string]$SpaceName = "Default",
    [string]$RoleName = "Process Export Reader",
    [string]$TeamName = "Process Export Runners",
    [string[]]$UserName = @(),
    [switch]$WithoutTelemetry,
    [switch]$IncludeTemplateNames
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "Provide -ApiKey or set the OCTOPUS_API_KEY environment variable." }
$base = $OctopusUrl.TrimEnd("/")
$headers = @{ "X-Octopus-ApiKey" = $ApiKey }

function Send-Octopus {
    param([string]$Method, [string]$Path, $Body)
    $request = @{ Uri = "$base$Path"; Method = $Method; Headers = $headers; ContentType = "application/json" }
    if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Depth 10) }
    try { Invoke-RestMethod @request }
    catch {
        $detail = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $detail = " Octopus says: " + ($_.ErrorDetails.Message | ConvertFrom-Json).ErrorMessage } catch { $detail = " Octopus says: " + $_.ErrorDetails.Message }
        }
        throw "$Method $Path failed: $($_.Exception.Message)$detail"
    }
}
function Get-Items($Result) {
    # Some PowerShell versions hand back a whole JSON array as one nested object. Flatten it.
    $source = if ($null -ne $Result -and $null -ne $Result.PSObject.Properties["Items"]) { $Result.Items } else { $Result }
    $flat = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($source)) {
        if ($item -is [System.Array]) { foreach ($inner in $item) { $flat.Add($inner) } }
        elseif ($null -ne $item) { $flat.Add($item) }
    }
    return $flat.ToArray()
}

$spacePermissions = @(
    "ProjectView", "ProcessView", "VariableView", "VariableViewUnscoped", "EnvironmentView",
    "LifecycleView", "TenantView", "MachineView", "WorkerView", "FeedView"
)
if (-not $WithoutTelemetry) { $spacePermissions += @("DeploymentView", "ReleaseView", "TaskView") }
if ($IncludeTemplateNames) { $spacePermissions += "ActionTemplateView" }
$spacePermissions = @($spacePermissions | Sort-Object)
$systemPermissions = @("SpaceView")

$space = Get-Items (Send-Octopus GET "/api/spaces/all") | Where-Object { $_.Name -eq $SpaceName } | Select-Object -First 1
if ($null -eq $space) { throw "Space '$SpaceName' not found." }

# 1. The user role.
$role = Get-Items (Send-Octopus GET "/api/userroles/all") | Where-Object { $_.Name -eq $RoleName } | Select-Object -First 1
if ($null -eq $role) {
    if ($PSCmdlet.ShouldProcess($RoleName, "Create user role with $($spacePermissions.Count) space permissions")) {
        $role = Send-Octopus POST "/api/userroles" ([ordered]@{
                Name = $RoleName
                Description = "View-only access for Export-OctopusProcesses.ps1"
                GrantedSpacePermissions = $spacePermissions
                GrantedSystemPermissions = $systemPermissions
            })
        Write-Host "Created user role '$RoleName' ($($role.Id))."
    }
}
else {
    $same = (($role.GrantedSpacePermissions | Sort-Object) -join ",") -eq ($spacePermissions -join ",") -and
        (($role.GrantedSystemPermissions | Sort-Object) -join ",") -eq ($systemPermissions -join ",")
    if ($same) { Write-Host "User role '$RoleName' ($($role.Id)) already has the right permissions." }
    elseif ($PSCmdlet.ShouldProcess($RoleName, "Set permissions to the export's minimum")) {
        $role.GrantedSpacePermissions = $spacePermissions
        $role.GrantedSystemPermissions = $systemPermissions
        $role = Send-Octopus PUT "/api/userroles/$($role.Id)" $role
        Write-Host "Updated user role '$RoleName' ($($role.Id))."
    }
}

# 2. The team, in one space.
$team = Get-Items (Send-Octopus GET "/api/$($space.Id)/teams/all") | Where-Object { $_.Name -eq $TeamName } | Select-Object -First 1
if ($null -eq $team) {
    if ($PSCmdlet.ShouldProcess("$TeamName in $SpaceName", "Create team")) {
        $team = Send-Octopus POST "/api/teams" ([ordered]@{
                Name = $TeamName
                SpaceId = $space.Id
                MemberUserIds = @()
                ExternalSecurityGroups = @()
            })
        Write-Host "Created team '$TeamName' ($($team.Id)) in space '$SpaceName'."
    }
}
else { Write-Host "Team '$TeamName' ($($team.Id)) already exists." }

# 3. Give the team the role for this space.
if ($null -ne $team -and $null -ne $role) {
    $scoped = Get-Items (Send-Octopus GET "/api/teams/$($team.Id)/scopeduserroles") | Where-Object { $_.UserRoleId -eq $role.Id -and $_.SpaceId -eq $space.Id }
    if (@($scoped).Count -eq 0) {
        if ($PSCmdlet.ShouldProcess("$TeamName", "Grant '$RoleName' in space '$SpaceName'")) {
            [void](Send-Octopus POST "/api/scopeduserroles" ([ordered]@{
                        TeamId = $team.Id
                        UserRoleId = $role.Id
                        SpaceId = $space.Id
                        ProjectIds = @(); EnvironmentIds = @(); TenantIds = @(); ProjectGroupIds = @()
                    }))
            Write-Host "Granted '$RoleName' to '$TeamName' in space '$SpaceName'."
        }
    }
    else { Write-Host "Team already has '$RoleName' in space '$SpaceName'." }
}

# 4. Optional members.
$unresolvedUsers = @()
if ($null -ne $team -and $UserName.Count -gt 0) {
    $members = @($team.MemberUserIds)
    $changed = $false
    foreach ($name in $UserName) {
        $found = Get-Items (Send-Octopus GET "/api/users?filter=$([uri]::EscapeDataString($name))&take=100") |
            Where-Object { $_.Username -ieq $name -or $_.EmailAddress -ieq $name } | Select-Object -First 1
        if ($null -eq $found) { Write-Warning "No user found with the username or email '$name'. Create the user first."; $unresolvedUsers += $name; continue }
        if ($members -contains $found.Id) { Write-Host "'$name' is already in the team."; continue }
        $members += $found.Id; $changed = $true
        Write-Host "Will add '$name' to the team."
    }
    if ($changed -and $PSCmdlet.ShouldProcess($TeamName, "Update team members")) {
        $team.MemberUserIds = $members
        $team = Send-Octopus PUT "/api/teams/$($team.Id)" $team
        Write-Host "Updated team members."
    }
}

Write-Host ""
Write-Host "Next steps:"
$script:stepNumber = 0
function Write-Step { param([string]$Text) $script:stepNumber++; Write-Host "  $($script:stepNumber). $Text" }
$usersGiven = $UserName.Count -gt 0
if (-not $usersGiven -or $unresolvedUsers.Count -gt 0 -or $null -eq $team) {
    # Some user still has to be created or added by hand.
    if ($unresolvedUsers.Count -gt 0) { Write-Step "Create the missing user(s) ($($unresolvedUsers -join ', ')):  $base/app#/configuration/users/create" }
    elseif (-not $usersGiven) { Write-Step "Create a user or service account to run the export:  $base/app#/configuration/users/create" }
    if ($null -ne $team) { Write-Step "Add the user to the team '$TeamName':  $base/app#/configuration/teams/$($team.Id)" }
    else { Write-Step "Add the user to the team '$TeamName' (the team is created when you run this without -WhatIf)." }
}
else {
    Write-Host "  The user(s) are in the team '$TeamName' ($($UserName -join ', '))."
}
Write-Step "Create an API key for the user (profile menu, My API Keys) and use it with Export-OctopusProcesses.ps1."
Write-Host ""
Write-Host "Permissions granted in space '$SpaceName': $($spacePermissions -join ', '). System: $($systemPermissions -join ', ')."
