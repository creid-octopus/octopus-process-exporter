<#
.SYNOPSIS
    Exports the structure of Octopus Deploy deployment processes for review.

.DESCRIPTION
    This script only reads data. Every call is an HTTP GET to the Octopus REST API.
    The script does not change anything on your Octopus Server.

    The script writes these files and a zip file that holds the shareable ones:

      process-model.json           Full model of each project. This is the source of truth.
      steps.csv                    One row for each step action. Works as a build sheet.
      targets.csv                  One row for each deployment target. Structure only.
      telemetry-deployments.csv    One row for each deployment. Only with -IncludeTelemetry.
      anonymization-map.csv        Alias to original name map. NOT in the zip. Keep it.

    Names are replaced by stable aliases such as Step-012, Tenant-004 and
    TagSet-1/Tag-2 unless you pass -NoAnonymize. Use -KeepNames to keep
    selected kinds of names, for example environments or channels.

    The script NEVER exports script bodies, variable values, or error text.
    The script scans scripts and variables only in memory, to find output variable
    names and to count things.

    Works with Octopus Server 2025.4 and later.
    Tested on PowerShell 7.

.PARAMETER OctopusUrl
    The address of your Octopus Server. Example: https://octopus.example.com

.PARAMETER ApiKey
    An API key for a user with view-only permissions.
    You can also set the OCTOPUS_API_KEY environment variable instead.

.PARAMETER SpaceName
    The space that holds the projects. The default is "Default".

.PARAMETER ProjectName
    One or more project names to export. Leave empty to export every project in the space.
    Telemetry requires this switch, so the script only scans deployments for the projects you choose.

.PARAMETER OutputFolder
    Where to write the files. The default is a new folder in the current directory.

.PARAMETER NoAnonymize
    Keep every real name. For internal testing only. Do not send this output outside your company.

.PARAMETER KeepNames
    Kinds of names to keep instead of replacing with aliases. Choose from:
    Project, Step, Environment, Channel, Lifecycle, Role, Package, Feed, Template, WorkerPool, TagSet.
    Tenant, variable and release names are always replaced.

.PARAMETER AliasMapPath
    Path to an earlier anonymization-map.csv. Names found in the file keep their old aliases.
    New names get the next free number. Use this to compare exports from different days.

.PARAMETER IncludeTelemetry
    Also scan recent deployments of the selected project. Off by default.
    The script counts deployments, results, start times, durations and redeployments.
    The script does not export error text.

.PARAMETER TelemetryMonths
    How many months of deployments to scan. The default is 6.

.EXAMPLE
    .\Export-OctopusProcesses.ps1 -OctopusUrl "https://octopus.example.com" -ApiKey "API-XXXX" -ProjectName "My Project"

.EXAMPLE
    $env:OCTOPUS_API_KEY = "API-XXXX"
    .\Export-OctopusProcesses.ps1 -OctopusUrl "https://octopus.example.com" -ProjectName "My Project" -IncludeTelemetry -KeepNames Environment,Channel
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [string]$OctopusUrl,

    [string]$ApiKey = $env:OCTOPUS_API_KEY,

    [string]$SpaceName = "Default",

    [string[]]$ProjectName = @(),

    [string]$OutputFolder = (Join-Path (Get-Location) ("octopus-process-export-" + (Get-Date -Format "yyyyMMdd-HHmmss"))),

    [switch]$NoAnonymize,

    [string[]]$KeepNames = @(),

    [string]$AliasMapPath,

    [switch]$IncludeTelemetry,

    [ValidateRange(1, 36)]
    [int]$TelemetryMonths = 6,

    # Catches the pieces of a comma list that a shell split apart. See below.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments = @()
)

# `pwsh ./script.ps1 -KeepNames "Environment", "Channel"` run from another shell splits the list
# at the space, so the script receives "Environment," and then "Channel" as a stray argument.
# Put the pieces back together instead of failing.
$validKeepKinds = @("Project", "Step", "Environment", "Channel", "Lifecycle", "Role", "Package", "Feed", "Template", "WorkerPool", "TagSet")
$strays = @($RemainingArguments | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($strays.Count -gt 0) {
    if (@($KeepNames).Count -gt 0 -and "$(@($KeepNames)[-1])".EndsWith(",")) { $KeepNames = @($KeepNames) + $strays }
    elseif (@($ProjectName).Count -gt 0 -and "$(@($ProjectName)[-1])".EndsWith(",")) {
        $ProjectName = @($ProjectName[0..($ProjectName.Count - 2)]) + @("$(@($ProjectName)[-1])".TrimEnd(",")) + $strays
    }
    else { throw "Unexpected argument(s): $($strays -join ' '). Join list values with commas and no spaces, for example -KeepNames Environment,Channel." }
}
$KeepNames = @($KeepNames | ForEach-Object { "$_" -split "[,\s]+" } | Where-Object { $_ })
$badKinds = @($KeepNames | Where-Object { $validKeepKinds -notcontains $_ })
if ($badKinds.Count -gt 0) { throw "Unknown -KeepNames value(s): $($badKinds -join ', '). Choose from: $($validKeepKinds -join ', ')." }
$ProjectName = @($ProjectName | ForEach-Object { "$_".TrimEnd(",") } | Where-Object { $_ })

$ErrorActionPreference = "Stop"
$ScriptVersion = "2.0"
$ModelSchemaVersion = 1

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "No API key found. Pass -ApiKey or set the OCTOPUS_API_KEY environment variable."
}

# Accept "Project A,Project B" as well as @("Project A", "Project B").
$ProjectName = @($ProjectName | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($IncludeTelemetry -and $ProjectName.Count -eq 0) {
    throw "-IncludeTelemetry needs -ProjectName so the script only scans deployments for the project you choose."
}

# Windows PowerShell 5.1 does not always turn on TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$OctopusUrl = $OctopusUrl.TrimEnd('/')
$headers = @{ "X-Octopus-ApiKey" = $ApiKey }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-OctopusGet {
    param([string]$Path)
    $uri = "$OctopusUrl$Path"
    Write-Verbose "GET $uri"
    for ($attempt = 1; ; $attempt++) {
        try {
            # Read-only: this script only ever sends GET requests.
            return Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        }
        catch {
            $status = $null
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
            }
            $retryable = ($null -eq $status) -or ($status -eq 429) -or ($status -ge 500)
            if (-not $retryable -or $attempt -ge 4) { throw }
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Get-OctopusAll {
    param([string]$Collection)
    $result = $null
    try {
        $result = Invoke-OctopusGet "/api/$script:SpaceId/$Collection/all"
    }
    catch {
        $page = Invoke-OctopusGet "/api/$script:SpaceId/$($Collection)?take=100000"
        $result = $page.Items
    }
    return (Expand-Items $result)
}

function Expand-Items {
    # Some PowerShell versions hand back a whole JSON array as one object. Flatten it.
    param($Items)
    # Some servers answer list requests with a wrapper, { "Items": [...] }. Unwrap that too.
    $flat = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($item in @($Items)) { $queue.Enqueue($item) }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($null -eq $item) { continue }
        if ($item -is [System.Array]) { foreach ($inner in $item) { $queue.Enqueue($inner) } }
        elseif ($null -ne $item.PSObject.Properties["Items"] -and $null -eq $item.PSObject.Properties["Id"]) {
            foreach ($inner in @($item.Items)) { $queue.Enqueue($inner) }
        }
        else { $flat.Add($item) }
    }
    return $flat.ToArray()
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function ToList {
    param($Items)
    return @($Items | Where-Object { $null -ne $_ -and "$_" -ne "" })
}

function Join-List {
    param($Items)
    return ((ToList $Items) -join "; ")
}

function Convert-ToLocalTime {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq "") { return $null }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value.ToLocalTime() }
        if ($Value -is [datetime]) { return ([DateTimeOffset]$Value).ToLocalTime() }
        return ([DateTimeOffset]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture)).ToLocalTime()
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Anonymization
# ---------------------------------------------------------------------------

$script:KeepKinds   = @($KeepNames)
$script:AliasMap    = @{}   # "Kind|Scope" -> hashtable of original name -> short alias
$script:AliasCounter = @{}  # "Kind|Scope" -> last number used
$script:TagCanonical = @{}  # "TagSet/Tag" -> full alias

function Get-Alias {
    param([string]$Kind, [string]$Name, [string]$Scope = "")
    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    if ($NoAnonymize -or ($script:KeepKinds -contains $Kind)) { return $Name }

    $key = "$Kind|$Scope"
    if (-not $script:AliasMap.ContainsKey($key)) { $script:AliasMap[$key] = @{} }
    if (-not $script:AliasCounter.ContainsKey($key)) { $script:AliasCounter[$key] = 0 }

    $map = $script:AliasMap[$key]
    if (-not $map.ContainsKey($Name)) {
        $script:AliasCounter[$key] = $script:AliasCounter[$key] + 1
        $n = $script:AliasCounter[$key]
        if ($Kind -eq "TagSet" -or $Kind -eq "Tag") {
            $map[$Name] = "$Kind-$n"
        }
        else {
            $map[$Name] = ("{0}-{1:000}" -f $Kind, $n)
        }
    }
    return $map[$Name]
}

function Get-TagAlias {
    param([string]$Canonical)
    if ([string]::IsNullOrEmpty($Canonical)) { return $Canonical }
    if ($NoAnonymize -or ($script:KeepKinds -contains "TagSet")) { return $Canonical }
    if ($script:TagCanonical.ContainsKey($Canonical)) { return $script:TagCanonical[$Canonical] }
    $slash = $Canonical.IndexOf('/')
    if ($slash -lt 0) { return (Get-Alias "TagSet" $Canonical) }
    $setName = $Canonical.Substring(0, $slash)
    $tagName = $Canonical.Substring($slash + 1)
    return ((Get-Alias "TagSet" $setName) + "/" + (Get-Alias "Tag" $tagName $setName))
}

function Get-AliasList {
    param([string]$Kind, $Names, [string]$Scope = "")
    return @((ToList $Names) | ForEach-Object { Get-Alias $Kind "$_" $Scope })
}

function Import-AliasMap {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Alias map '$Path' not found." }
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $key = "$($row.Kind)|$($row.Scope)"
        if (-not $script:AliasMap.ContainsKey($key)) { $script:AliasMap[$key] = @{} }
        $script:AliasMap[$key][$row.Original] = $row.Alias
        $number = 0
        if ($row.Alias -match '-(\d+)$') { $number = [int]$Matches[1] }
        if (-not $script:AliasCounter.ContainsKey($key) -or $script:AliasCounter[$key] -lt $number) {
            $script:AliasCounter[$key] = $number
        }
    }
}

# Reduce a run condition or similar expression to structure.
# Names become aliases. String literals become <literal>. Octopus built-in variables stay.
$ExpressionKeywords = @("if", "unless", "else", "elseif", "each", "in", "true", "false", "and", "or", "not", "null")
$ExpressionPattern  = '"[^"]*"|''[^'']*''|Octopus\.Action\[[^\]]*\](?:\.[A-Za-z0-9_\-\.]+)?|[A-Za-z_][A-Za-z0-9_\-\.]*'

function Convert-Expression {
    param([string]$Text, [string]$ProjectScope)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($NoAnonymize) { return $Text }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $token = $m.Value
        if ($token.StartsWith('"') -or $token.StartsWith("'")) { return "<literal>" }
        if ($token -match '^Octopus\.Action\[([^\]]*)\](.*)$') {
            $stepAlias = Get-Alias "Step" $Matches[1].Trim() $ProjectScope
            $rest = $Matches[2]
            if ($rest -match '^\.Output\.(.+)$') {
                $rest = ".Output." + (Get-Alias "Variable" $Matches[1].TrimEnd('.'))
            }
            return "Octopus.Action[$stepAlias]$rest"
        }
        if ($ExpressionKeywords -contains $token.ToLowerInvariant()) { return $token }
        if ($token.StartsWith("Octopus.", [StringComparison]::OrdinalIgnoreCase)) { return $token }
        return (Get-Alias "Variable" $token)
    }
    return [regex]::Replace($Text, $ExpressionPattern, $evaluator)
}

# ---------------------------------------------------------------------------
# Output variable detection and misc analysis
# ---------------------------------------------------------------------------

# Patterns that SET an output variable in a script.
$SetPatterns = @(
    'Set-OctopusVariable\s+(?:-Name\s+)?["'']?([A-Za-z0-9_\-\.]+)',
    'set_octopusvariable\s*\(?\s*["'']?([A-Za-z0-9_\-\.]+)',
    'SetVariable\s*\(\s*["'']([A-Za-z0-9_\-\.]+)'
)

# Pattern that READS an output variable from an earlier step.
$ReadPattern = 'Octopus\.Action\[([^\]]+)\]\.Output\.([A-Za-z0-9_\-\.]+)'

$RegexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

function Find-SetVariables {
    param([string]$Text)
    $found = @()
    if ([string]::IsNullOrEmpty($Text)) { return $found }
    foreach ($pattern in $SetPatterns) {
        foreach ($m in [regex]::Matches($Text, $pattern, $RegexOptions)) {
            $found += $m.Groups[1].Value.TrimEnd('.')
        }
    }
    return ($found | Sort-Object -Unique)
}

function Find-ReadVariables {
    param([string]$Text)
    $found = @()
    if ([string]::IsNullOrEmpty($Text)) { return $found }
    foreach ($m in [regex]::Matches($Text, $ReadPattern, $RegexOptions)) {
        $found += [pscustomobject]@{
            Producer = $m.Groups[1].Value.Trim()
            Variable = $m.Groups[2].Value.TrimEnd('.')
        }
    }
    return $found
}

function Get-TemplateName {
    param([string]$TemplateId)
    if ([string]::IsNullOrWhiteSpace($TemplateId)) { return "" }
    if (-not $script:TemplateCache.ContainsKey($TemplateId)) {
        try {
            $script:TemplateCache[$TemplateId] = (Invoke-OctopusGet "/api/$script:SpaceId/actiontemplates/$TemplateId").Name
        }
        catch {
            $script:TemplateCache[$TemplateId] = $TemplateId
        }
    }
    return $script:TemplateCache[$TemplateId]
}

function Get-RunsOn {
    param($Action, $ActionProps, $StepProps)
    $runOnServer = "$(Get-Prop $ActionProps 'Octopus.Action.RunOnServer')"
    $workerPoolId = Get-Prop $Action "WorkerPoolId"
    if (-not $workerPoolId) { $workerPoolId = Get-Prop $ActionProps "Octopus.Action.WorkerPoolId" }
    $workerPoolVariable = Get-Prop $Action "WorkerPoolVariable"
    if (-not $workerPoolVariable) { $workerPoolVariable = Get-Prop $ActionProps "Octopus.Action.WorkerPoolVariable" }
    $roles = "$(Get-Prop $StepProps 'Octopus.Action.TargetRoles')"

    $serverTypes = @("Octopus.Manual", "Octopus.Email", "Octopus.DeployRelease", "Octopus.ProcessTemplate", "Octopus.TerraformPlan", "Octopus.TerraformApply")
    if ($runOnServer -eq "true") {
        if ($workerPoolId -or $workerPoolVariable) { return "Worker" }
        return "Server"
    }
    if ($serverTypes -contains $Action.ActionType) { return "Server" }
    if ($roles) { return "Targets" }
    if ($runOnServer -eq "false") { return "Targets" }
    return "Unknown"
}

function Get-Percentile {
    param([double[]]$Sorted, [double]$P)
    if ($Sorted.Count -eq 0) { return $null }
    $rank = [math]::Ceiling(($P / 100.0) * $Sorted.Count)
    if ($rank -lt 1) { $rank = 1 }
    return [math]::Round($Sorted[[int]$rank - 1], 1)
}

function Get-DurationStats {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    return [ordered]@{
        count = $sorted.Count
        p50   = Get-Percentile $sorted 50
        p75   = Get-Percentile $sorted 75
        p90   = Get-Percentile $sorted 90
        p95   = Get-Percentile $sorted 95
        p99   = Get-Percentile $sorted 99
        max   = if ($sorted.Count -gt 0) { [math]::Round($sorted[-1], 1) } else { $null }
    }
}

# Rough hint only. The text is checked in memory and never exported.
$ConnectivityPattern = 'timed? ?out|time-out|unable to connect|cannot connect|could not connect|connection (was )?(refused|reset|closed|lost|forcibly)|no such host|name resolution|unreachable|offline|not responding|actively refused|network|socket|tentacle .*(unavailable|communicat)|unavailable|unhealthy|health check'

# ---------------------------------------------------------------------------
# Connect, check the version, look up the space and shared lookups
# ---------------------------------------------------------------------------

Write-Host "Connecting to $OctopusUrl"

$serverVersion = "unknown"
$apiVersion = "unknown"
try {
    $root = Invoke-OctopusGet "/api"
    $v = Get-Prop $root "Version"
    $a = Get-Prop $root "ApiVersion"
    if ($v) { $serverVersion = "$v" }
    if ($a) { $apiVersion = "$a" }
}
catch {
    Write-Warning "Could not read the server version from /api: $($_.Exception.Message)"
}
Write-Host "Octopus Server version: $serverVersion (API $apiVersion)"
try {
    if ($serverVersion -ne "unknown") {
        $parsed = [version]($serverVersion -replace '^(\d+\.\d+(\.\d+)?).*$', '$1')
        if ($parsed -lt [version]"2025.4") {
            Write-Warning "This script was written for Octopus Server 2025.4 and later. Some fields may be missing."
        }
    }
}
catch { Write-Verbose "Could not parse the server version '$serverVersion'." }

try {
    $spaces = Expand-Items (Invoke-OctopusGet "/api/spaces/all")
}
catch {
    throw "Could not read spaces. Check the Octopus URL and API key. Details: $($_.Exception.Message)"
}

$space = $spaces | Where-Object { $_.Name -eq $SpaceName } | Select-Object -First 1
if ($null -eq $space) {
    throw "Space '$SpaceName' not found. Spaces you can see: $((ToList $spaces.Name) -join ', ')"
}
$script:SpaceId = $space.Id
$script:TemplateCache = @{}

if ($AliasMapPath) {
    Import-AliasMap $AliasMapPath
    Write-Host "Loaded aliases from $AliasMapPath"
}

$environmentMap = @{}
foreach ($item in (Get-OctopusAll "environments")) { $environmentMap[$item.Id] = $item.Name }

$feedMap = @{}
$feedTypeMap = @{}
foreach ($item in (Get-OctopusAll "feeds")) {
    $feedMap[$item.Id] = $item.Name
    $feedTypeMap[$item.Id] = Get-Prop $item "FeedType"
}

$lifecycleList = Get-OctopusAll "lifecycles"
$lifecycleMap = @{}
foreach ($item in $lifecycleList) { $lifecycleMap[$item.Id] = $item.Name }

$workerPoolMap = @{}
try {
    foreach ($item in (Get-OctopusAll "workerpools")) { $workerPoolMap[$item.Id] = $item.Name }
}
catch { Write-Verbose "Could not read worker pools: $($_.Exception.Message)" }

$allProjects = Get-OctopusAll "projects"
$projectMap = @{}
foreach ($item in $allProjects) { $projectMap[$item.Id] = $item.Name }

# Tag sets and tenants. Register tag sets in API order so aliases stay stable.
$tagSets = @()
try { $tagSets = @(Get-OctopusAll "tagsets") } catch { Write-Warning "Could not read tag sets: $($_.Exception.Message)" }
foreach ($tagSet in $tagSets) {
    foreach ($tag in (ToList $tagSet.Tags)) {
        $canonical = Get-Prop $tag "CanonicalTagName"
        if (-not $canonical) { $canonical = "$($tagSet.Name)/$($tag.Name)" }
        $alias = if ($NoAnonymize -or ($script:KeepKinds -contains "TagSet")) { $canonical }
                 else { (Get-Alias "TagSet" $tagSet.Name) + "/" + (Get-Alias "Tag" $tag.Name $tagSet.Name) }
        $script:TagCanonical[$canonical] = $alias
    }
}

$tenants = @()
try { $tenants = @(Get-OctopusAll "tenants") } catch { Write-Warning "Could not read tenants: $($_.Exception.Message)" }
$tenantAliasById = @{}
foreach ($tenant in $tenants) { $tenantAliasById[$tenant.Id] = Get-Alias "Tenant" $tenant.Name }

if ($ProjectName.Count -gt 0) {
    $projects = @($allProjects | Where-Object { $ProjectName -contains $_.Name })
    foreach ($name in $ProjectName) {
        if ((ToList $allProjects.Name) -notcontains $name) {
            Write-Warning "Project '$name' not found in space '$SpaceName'. Skipping."
        }
    }
}
else {
    $projects = $allProjects
}

if ($projects.Count -eq 0) {
    throw "No projects to export."
}

# ---------------------------------------------------------------------------
# Export each project
# ---------------------------------------------------------------------------

$script:ChannelLifecycleIds = @{}
$modelProjects = New-Object System.Collections.Generic.List[object]
$telemetryRows = New-Object System.Collections.Generic.List[object]
$telemetryByProject = @{}

$projectIndex = 0
foreach ($project in $projects) {
    $projectIndex++
    Write-Host ("[{0}/{1}] {2}" -f $projectIndex, $projects.Count, $project.Name)
    $scope = $project.Name   # Step aliases are numbered inside each project.
    $projectAlias = Get-Alias "Project" $project.Name

    try {
        # Version-controlled (Config as Code) projects keep the process in Git.
        $persistence = Get-Prop $project "PersistenceSettings"
        $isGit = ($null -ne $persistence) -and ((Get-Prop $persistence "Type") -eq "VersionControlled")
        $gitRef = $null

        if ($isGit) {
            $branch = Get-Prop $persistence "DefaultBranch"
            $gitRef = [uri]::EscapeDataString($branch)
            $process = Invoke-OctopusGet "/api/$script:SpaceId/projects/$($project.Id)/$gitRef/deploymentprocesses"
            $source = "Git"
        }
        else {
            $process = Invoke-OctopusGet "/api/$script:SpaceId/deploymentprocesses/$($project.DeploymentProcessId)"
            $source = "Database"
        }

        # Assign step aliases in process order before anything refers to a step.
        $steps = ToList $process.Steps
        foreach ($step in $steps) {
            [void](Get-Alias "Step" $step.Name $scope)
            foreach ($action in (ToList $step.Actions)) { [void](Get-Alias "Step" $action.Name $scope) }
        }

        # Channels first, so steps can show channel names instead of IDs.
        $channelAliasById = @{}
        $channels = @()
        try {
            $channels = @((Invoke-OctopusGet "/api/$script:SpaceId/projects/$($project.Id)/channels?take=1000").Items)
        }
        catch {
            Write-Warning "  Could not read channels: $($_.Exception.Message)"
        }

        $modelChannels = @()
        foreach ($channel in (ToList $channels)) {
            $channelAliasById[$channel.Id] = Get-Alias "Channel" $channel.Name
            if ($channel.LifecycleId) { $script:ChannelLifecycleIds[$channel.LifecycleId] = $true }
            $lifecycleAlias = if ($channel.LifecycleId) { Get-Alias "Lifecycle" $lifecycleMap[$channel.LifecycleId] } else { "(project default)" }
            $rules = @()
            foreach ($rule in (ToList $channel.Rules)) {
                $rules += [ordered]@{
                    versionRange  = $rule.VersionRange
                    preReleaseTag = $rule.Tag
                    appliesTo     = @(foreach ($ap in (ToList $rule.ActionPackages)) {
                        [ordered]@{
                            step             = Get-Alias "Step" $ap.DeploymentAction $scope
                            packageReference = if ($ap.PackageReference) { Get-Alias "Package" $ap.PackageReference } else { "(primary)" }
                        }
                    })
                }
            }
            $modelChannels += [ordered]@{
                name       = Get-Alias "Channel" $channel.Name
                isDefault  = [bool]$channel.IsDefault
                lifecycle  = $lifecycleAlias
                tenantTags = @((ToList $channel.TenantTags) | ForEach-Object { Get-TagAlias $_ })
                rules      = $rules
            }
        }

        # Steps and actions
        $actionLabels = @{}          # action name -> step label
        $setters      = @{}          # action name -> variables the action sets
        $reads        = New-Object System.Collections.Generic.List[object]
        $modelSteps   = @()
        $actionByName = @{}

        $stepNumber = 0
        $actionTotal = 0
        $wave = 0
        $waveSizes = @{}
        $previousStepHadActions = $false

        foreach ($step in $steps) {
            $stepNumber++
            $stepProps = Get-Prop $step "Properties"
            $actions = ToList $step.Actions
            $actionNumber = 0

            $startTrigger = "$($step.StartTrigger)"
            $parallelWithPrevious = ($startTrigger -eq "StartWithPrevious") -and ($stepNumber -gt 1)
            if (-not $parallelWithPrevious) { $wave++ }
            if (-not $waveSizes.ContainsKey($wave)) { $waveSizes[$wave] = 0 }
            $waveSizes[$wave] = $waveSizes[$wave] + 1

            $modelActions = @()
            foreach ($action in $actions) {
                $actionNumber++
                $actionTotal++
                $label = if ($actions.Count -gt 1) { "$stepNumber.$actionNumber" } else { "$stepNumber" }
                $actionProps = Get-Prop $action "Properties"
                $actionLabels[$action.Name] = $label

                $childProjectId = Get-Prop $actionProps "Octopus.Action.DeployRelease.ProjectId"
                $templateId = Get-Prop $actionProps "Octopus.Action.Template.Id"
                $workerPoolId = Get-Prop $action "WorkerPoolId"
                if (-not $workerPoolId) { $workerPoolId = Get-Prop $actionProps "Octopus.Action.WorkerPoolId" }
                $workerPoolVariable = Get-Prop $action "WorkerPoolVariable"
                if (-not $workerPoolVariable) { $workerPoolVariable = Get-Prop $actionProps "Octopus.Action.WorkerPoolVariable" }
                $container = Get-Prop $action "Container"
                $usesContainer = ($null -ne $container) -and ($null -ne (Get-Prop $container "Image") -or $null -ne (Get-Prop $container "FeedId"))

                # Process template parameters: names only, never values.
                $templateParameters = @()
                if ($action.ActionType -eq "Octopus.ProcessTemplate" -and $null -ne $actionProps) {
                    foreach ($prop in $actionProps.PSObject.Properties) {
                        if ($prop.Name.StartsWith("Octopus.")) { continue }
                        $templateParameters += Get-Alias "TemplateParameter" $prop.Name
                    }
                }

                $packages = @()
                foreach ($package in (ToList $action.Packages)) {
                    $packageProps = Get-Prop $package "Properties"
                    $feedId = "$($package.FeedId)"
                    $feedIsVariable = $feedId.Contains("#{")
                    $packageIdText = "$($package.PackageId)"
                    $packages += [ordered]@{
                        reference           = if ($package.Name) { Get-Alias "Package" $package.Name } else { "(primary)" }
                        packageId           = Get-Alias "Package" $packageIdText
                        packageIdIsVariable = $packageIdText.Contains("#{")
                        feed                = if ($feedIsVariable) { "(variable)" } else { Get-Alias "Feed" $feedMap[$feedId] }
                        feedType            = $feedTypeMap[$feedId]
                        acquisitionLocation = $package.AcquisitionLocation
                        extract             = Get-Prop $packageProps "Extract"
                    }
                }

                $modelAction = [ordered]@{
                    label                = $label
                    name                 = Get-Alias "Step" $action.Name $scope
                    actionType           = $action.ActionType
                    isProcessTemplate    = ($action.ActionType -eq "Octopus.ProcessTemplate")
                    processTemplateParameters = $templateParameters
                    stepTemplate         = if ($templateId) { Get-Alias "Template" (Get-TemplateName "$templateId") } else { "" }
                    isDisabled           = [bool]$action.IsDisabled
                    isRequired           = [bool]$action.IsRequired
                    runsOn               = Get-RunsOn $action $actionProps $stepProps
                    workerPool           = if ($workerPoolId) { Get-Alias "WorkerPool" $workerPoolMap["$workerPoolId"] } elseif ($workerPoolVariable) { "(variable)" } else { "" }
                    usesContainer        = $usesContainer
                    autoRetry            = if ($null -ne (Get-Prop $actionProps "Octopus.Action.AutoRetry.MaximumCount")) {
                        [ordered]@{
                            maximumCount   = [int](Get-Prop $actionProps "Octopus.Action.AutoRetry.MaximumCount")
                            minimumBackoff = [int](Get-Prop $actionProps "Octopus.Action.AutoRetry.MinimumBackoff")
                        }
                    } else { $null }
                    scriptSource         = Get-Prop $actionProps "Octopus.Action.Script.ScriptSource"
                    tenantTags           = @((ToList $action.TenantTags) | ForEach-Object { Get-TagAlias $_ })
                    environments         = @((ToList $action.Environments) | ForEach-Object { Get-Alias "Environment" $environmentMap["$_"] })
                    excludedEnvironments = @((ToList $action.ExcludedEnvironments) | ForEach-Object { Get-Alias "Environment" $environmentMap["$_"] })
                    channels             = @((ToList $action.Channels) | ForEach-Object { if ($channelAliasById.ContainsKey("$_")) { $channelAliasById["$_"] } else { "$_" } })
                    deploysChildProject  = if ($childProjectId) { Get-Alias "Project" $projectMap["$childProjectId"] } else { "" }
                    packages             = $packages
                    outputVariablesSet   = @()
                    dependsOnSteps       = @()
                }
                $modelActions += $modelAction
                $actionByName[$action.Name] = $modelAction

                # Scan every text property for output variables.
                # Only names are kept. Script bodies are never written out.
                $setNames = @()
                foreach ($prop in (ToList $actionProps.PSObject.Properties)) {
                    if ($prop.Value -isnot [string]) { continue }
                    $setNames += Find-SetVariables $prop.Value
                    foreach ($read in (Find-ReadVariables $prop.Value)) {
                        $reads.Add([pscustomobject]@{
                            Producer         = $read.Producer
                            Variable         = $read.Variable
                            ConsumerLabel    = $label
                            Consumer         = $action.Name
                            ConsumerProperty = $prop.Name
                        })
                    }
                }
                foreach ($prop in (ToList $stepProps.PSObject.Properties)) {
                    if ($prop.Value -isnot [string]) { continue }
                    foreach ($read in (Find-ReadVariables $prop.Value)) {
                        $reads.Add([pscustomobject]@{
                            Producer         = $read.Producer
                            Variable         = $read.Variable
                            ConsumerLabel    = $label
                            Consumer         = $action.Name
                            ConsumerProperty = $prop.Name
                        })
                    }
                }
                $setters[$action.Name] = @($setNames | Sort-Object -Unique)
            }

            $roles = @(("$(Get-Prop $stepProps 'Octopus.Action.TargetRoles')" -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $maxParallelism = Get-Prop $stepProps "Octopus.Action.MaxParallelism"
            $conditionExpression = Get-Prop $stepProps "Octopus.Step.ConditionVariableExpression"

            $modelSteps += [ordered]@{
                number               = $stepNumber
                name                 = Get-Alias "Step" $step.Name $scope
                startTrigger         = $startTrigger
                parallelWithPrevious = $parallelWithPrevious
                wave                 = $wave
                runCondition         = "$($step.Condition)"
                conditionExpression  = Convert-Expression "$conditionExpression" $scope
                packageRequirement   = "$($step.PackageRequirement)"
                maxParallelism       = if ($maxParallelism) { Convert-Expression "$maxParallelism" $scope } else { $null }
                targetRoles          = @($roles | ForEach-Object { Get-Alias "Role" $_ })
                actions              = $modelActions
            }
        }

        # Fill in wave sizes now that every step is placed.
        foreach ($modelStep in $modelSteps) { $modelStep["waveSize"] = $waveSizes[$modelStep["wave"]] }
        $largestWave = 0
        foreach ($size in $waveSizes.Values) { if ($size -gt $largestWave) { $largestWave = $size } }

        # Project variables. Values stay private: only counts and structure leave this block.
        $variableSets = @()
        try {
            $variableSets += Invoke-OctopusGet "/api/$script:SpaceId/variables/$($project.VariableSetId)"
        }
        catch {
            Write-Verbose "  Could not read database variables: $($_.Exception.Message)"
        }
        if ($isGit) {
            try {
                $variableSets += Invoke-OctopusGet "/api/$script:SpaceId/projects/$($project.Id)/$gitRef/variables"
            }
            catch {
                Write-Verbose "  Could not read Git variables: $($_.Exception.Message)"
            }
        }

        $varTotal = 0; $varSensitive = 0; $varPrompted = 0; $varScoped = 0; $varStepOutput = 0
        $scopeTypeCounts = @{}
        $varTypeCounts = @{}
        foreach ($variableSet in (ToList $variableSets)) {
            foreach ($variable in (ToList $variableSet.Variables)) {
                $varTotal++
                if ($variable.IsSensitive) { $varSensitive++ }
                if ($null -ne (Get-Prop $variable "Prompt")) { $varPrompted++ }

                $type = "$(Get-Prop $variable 'Type')"
                if (-not $type) { $type = "String" }
                if (-not $varTypeCounts.ContainsKey($type)) { $varTypeCounts[$type] = 0 }
                $varTypeCounts[$type] = $varTypeCounts[$type] + 1

                $variableScope = Get-Prop $variable "Scope"
                $hasScope = $false
                if ($null -ne $variableScope) {
                    foreach ($scopeProp in $variableScope.PSObject.Properties) {
                        if ((ToList $scopeProp.Value).Count -gt 0) {
                            $hasScope = $true
                            if (-not $scopeTypeCounts.ContainsKey($scopeProp.Name)) { $scopeTypeCounts[$scopeProp.Name] = 0 }
                            $scopeTypeCounts[$scopeProp.Name] = $scopeTypeCounts[$scopeProp.Name] + 1
                        }
                    }
                }
                if ($hasScope) { $varScoped++ }

                if (-not $variable.IsSensitive -and $variable.Value -is [string]) {
                    $variableReads = @(Find-ReadVariables $variable.Value)
                    if ($variableReads.Count -gt 0) {
                        $varStepOutput++
                        foreach ($read in $variableReads) {
                            $reads.Add([pscustomobject]@{
                                Producer         = $read.Producer
                                Variable         = $read.Variable
                                ConsumerLabel    = "(variable)"
                                Consumer         = "(project variable)"
                                ConsumerProperty = "Value"
                            })
                        }
                    }
                }
            }
        }

        # Build the output variable map.
        $matchedSets = @{}
        $outputVariables = @()
        foreach ($read in $reads) {
            $producerSets = $false
            if ($setters.ContainsKey($read.Producer)) {
                $producerSets = (@($setters[$read.Producer]) -contains $read.Variable)
            }
            if ($producerSets) { $matchedSets["$($read.Producer)|$($read.Variable)"] = $true }

            $note = if (-not $actionLabels.ContainsKey($read.Producer)) {
                "Producer step not found in this project"
            }
            elseif ($producerSets) {
                "Set in producer script"
            }
            else {
                "Built-in or set by a script in a package"
            }

            $outputVariables += [ordered]@{
                producerLabel    = if ($actionLabels.ContainsKey($read.Producer)) { $actionLabels[$read.Producer] } else { "" }
                producer         = Get-Alias "Step" $read.Producer $scope
                variable         = Get-Alias "Variable" $read.Variable
                consumerLabel    = $read.ConsumerLabel
                consumer         = if ($read.Consumer -eq "(project variable)") { $read.Consumer } else { Get-Alias "Step" $read.Consumer $scope }
                consumerProperty = if ("$($read.ConsumerProperty)".StartsWith("Octopus.") -or "$($read.ConsumerProperty)" -eq "Value" -or $NoAnonymize) { $read.ConsumerProperty } else { Get-Alias "Property" "$($read.ConsumerProperty)" }
                note             = $note
            }

            if ($actionByName.ContainsKey($read.Consumer) -and $actionLabels.ContainsKey($read.Producer)) {
                $producerAlias = Get-Alias "Step" $read.Producer $scope
                $consumerAction = $actionByName[$read.Consumer]
                if ($consumerAction["dependsOnSteps"] -notcontains $producerAlias) {
                    $consumerAction["dependsOnSteps"] = @($consumerAction["dependsOnSteps"]) + $producerAlias
                }
            }
        }

        # Output variables that are set but never read by this project.
        foreach ($actionName in ($setters.Keys | Sort-Object)) {
            foreach ($variableName in (ToList $setters[$actionName])) {
                $actionByName[$actionName]["outputVariablesSet"] = @($actionByName[$actionName]["outputVariablesSet"]) + (Get-Alias "Variable" $variableName)
                if ($matchedSets.ContainsKey("$actionName|$variableName")) { continue }
                $outputVariables += [ordered]@{
                    producerLabel    = $actionLabels[$actionName]
                    producer         = Get-Alias "Step" $actionName $scope
                    variable         = Get-Alias "Variable" $variableName
                    consumerLabel    = ""
                    consumer         = ""
                    consumerProperty = ""
                    note             = "Set but not read in this project"
                }
            }
        }

        $policy = Get-Prop $project "ProjectConnectivityPolicy"
        $connectedTenants = 0
        foreach ($tenant in $tenants) {
            $connections = Get-Prop $tenant "ProjectEnvironments"
            if ($null -ne $connections -and $null -ne $connections.PSObject.Properties[$project.Id]) { $connectedTenants++ }
        }

        $modelProjects.Add([ordered]@{
            name                        = $projectAlias
            processSource               = $source
            tenantedDeploymentMode      = "$($project.TenantedDeploymentMode)"
            defaultGuidedFailureMode    = "$($project.DefaultGuidedFailureMode)"
            defaultToSkipIfInstalled    = [bool]$project.DefaultToSkipIfAlreadyInstalled
            skipMachineBehavior         = "$(Get-Prop $policy 'SkipMachineBehavior')"
            skipMachineRoles            = @((ToList (Get-Prop $policy "TargetRoles")) | ForEach-Object { Get-Alias "Role" "$_" })
            excludeUnhealthyTargets     = [bool](Get-Prop $policy "ExcludeUnhealthyTargets")
            allowDeploymentsToNoTargets = [bool](Get-Prop $policy "AllowDeploymentsToNoTargets")
            lifecycle                   = Get-Alias "Lifecycle" $lifecycleMap[$project.LifecycleId]
            libraryVariableSetCount     = (ToList $project.IncludedLibraryVariableSetIds).Count
            connectedTenantCount        = $connectedTenants
            counts                      = [ordered]@{
                steps           = $steps.Count
                actions         = $actionTotal
                waves           = $waveSizes.Count
                largestWave     = $largestWave
                channels        = (ToList $channels).Count
            }
            channels                    = $modelChannels
            steps                       = $modelSteps
            outputVariables             = $outputVariables
            variableStructure           = [ordered]@{
                projectVariableCount     = $varTotal
                sensitiveCount           = $varSensitive
                promptedCount            = $varPrompted
                scopedCount              = $varScoped
                referencingStepOutput    = $varStepOutput
                countByScopeType         = $scopeTypeCounts
                countByType              = $varTypeCounts
            }
        })

        # -------------------------------------------------------------------
        # Telemetry (optional)
        # -------------------------------------------------------------------
        if ($IncludeTelemetry) {
            $cutoff = (Get-Date).AddMonths(-$TelemetryMonths)
            Write-Host ("  Telemetry: scanning deployments since {0:yyyy-MM-dd}" -f $cutoff)
            $take = 200

            # Deployments carry tenant, release, environment and channel. Newest first.
            $deployments = New-Object System.Collections.Generic.List[object]
            $skip = 0
            $done = $false
            while (-not $done) {
                $page = Invoke-OctopusGet "/api/$script:SpaceId/deployments?projects=$($project.Id)&skip=$skip&take=$take"
                $items = @($page.Items)
                foreach ($d in $items) {
                    $created = Convert-ToLocalTime $d.Created
                    if ($null -ne $created -and $created.DateTime -lt $cutoff) { $done = $true; continue }
                    $deployments.Add([pscustomobject]@{
                        DeploymentId  = $d.Id
                        TaskId        = $d.TaskId
                        ReleaseId     = $d.ReleaseId
                        TenantId      = $d.TenantId
                        EnvironmentId = $d.EnvironmentId
                        ChannelId     = $d.ChannelId
                        Created       = $created
                    })
                }
                $skip += $take
                if ($items.Count -lt $take) { $done = $true }
                if ($deployments.Count -gt 0 -and ($deployments.Count % 2000) -lt $take) { Write-Host ("    {0} deployments read" -f $deployments.Count) }
            }

            # Tasks carry the result and timing.
            $cutoffText = [uri]::EscapeDataString($cutoff.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
            $taskById = @{}
            $skip = 0
            $done = $false
            while (-not $done) {
                $page = Invoke-OctopusGet "/api/tasks?spaces=$script:SpaceId&project=$($project.Id)&name=Deploy&fromQueueDate=$cutoffText&skip=$skip&take=$take"
                $items = @($page.Items)
                foreach ($t in $items) {
                    $started = Convert-ToLocalTime $t.StartTime
                    $completed = Convert-ToLocalTime $t.CompletedTime
                    $seconds = $null
                    if ($null -ne $started -and $null -ne $completed) { $seconds = ($completed - $started).TotalSeconds }
                    $looksLikeConnectivity = $false
                    $errorText = "$(Get-Prop $t 'ErrorMessage')"
                    if ($errorText -and ($errorText -match $ConnectivityPattern)) { $looksLikeConnectivity = $true }
                    $taskById[$t.Id] = [pscustomobject]@{
                        State           = "$($t.State)"
                        Started         = $started
                        DurationSeconds = $seconds
                        Warnings        = [bool](Get-Prop $t "HasWarningsOrErrors")
                        Connectivity    = $looksLikeConnectivity
                    }
                }
                $skip += $take
                if ($items.Count -lt $take) { $done = $true }
            }

            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($d in $deployments) {
                $task = $taskById["$($d.TaskId)"]
                $state = if ($null -ne $task) { $task.State } else { "Unknown" }
                $outcome = switch ($state) {
                    "Success"   { "Pass" }
                    "Failed"    { "Fail" }
                    "TimedOut"  { "Fail" }
                    "Canceled"  { "Canceled" }
                    "Cancelling" { "Canceled" }
                    "Unknown"   { "Unknown" }
                    default     { "InProgress" }
                }
                $when = $d.Created
                if ($null -ne $task -and $null -ne $task.Started) { $when = $task.Started }
                $night = $null
                $hour = $null
                if ($null -ne $when) {
                    $night = $when.DateTime.AddHours(-12).ToString("yyyy-MM-dd")
                    $hour = $when.Hour
                }
                $tenantAlias = if ($d.TenantId) { if ($tenantAliasById.ContainsKey("$($d.TenantId)")) { $tenantAliasById["$($d.TenantId)"] } else { Get-Alias "Tenant" "$($d.TenantId)" } } else { "(untenanted)" }
                $rows.Add([pscustomobject]@{
                    Project                 = $projectAlias
                    Release                 = Get-Alias "Release" "$($d.ReleaseId)"
                    Channel                 = if ($channelAliasById.ContainsKey("$($d.ChannelId)")) { $channelAliasById["$($d.ChannelId)"] } else { "$($d.ChannelId)" }
                    Environment             = Get-Alias "Environment" $environmentMap["$($d.EnvironmentId)"]
                    Tenant                  = $tenantAlias
                    StartedLocal            = if ($null -ne $when) { $when.ToString("yyyy-MM-ddTHH:mm:sszzz") } else { "" }
                    Night                   = $night
                    StartHour               = $hour
                    State                   = $state
                    Outcome                 = $outcome
                    DurationSeconds         = if ($null -ne $task -and $null -ne $task.DurationSeconds) { [math]::Round($task.DurationSeconds, 1) } else { $null }
                    IsRedeployAfterFailure  = $false
                    ErrorLooksLikeConnectivity = if ($outcome -eq "Fail" -and $null -ne $task) { $task.Connectivity } else { "" }
                    _Sort                   = $when
                })
            }

            # Redeploys: the previous deployment of the same release to the same tenant and environment failed.
            $groups = $rows | Group-Object -Property Release, Tenant, Environment
            foreach ($group in $groups) {
                $ordered = @($group.Group | Sort-Object -Property _Sort)
                for ($i = 1; $i -lt $ordered.Count; $i++) {
                    if ($ordered[$i - 1].Outcome -eq "Fail") { $ordered[$i].IsRedeployAfterFailure = $true }
                }
            }

            foreach ($row in ($rows | Sort-Object -Property _Sort)) { $telemetryRows.Add($row) }

            # Summary
            $rowArray = $rows.ToArray()
            $completedRows = @($rowArray | Where-Object { $_.Outcome -eq "Pass" -or $_.Outcome -eq "Fail" })
            $passRows = @($rowArray | Where-Object { $_.Outcome -eq "Pass" })
            $failRows = @($rowArray | Where-Object { $_.Outcome -eq "Fail" })

            $nightGroups = @($rowArray | Where-Object { $_.Night } | Group-Object -Property Night | Sort-Object -Property Name)
            $nights = @(foreach ($g in $nightGroups) {
                $failures = @($g.Group | Where-Object { $_.Outcome -eq "Fail" }).Count
                [ordered]@{
                    night          = $g.Name
                    deployments    = $g.Count
                    failures       = $failures
                    tenantsTouched = @($g.Group | Select-Object -ExpandProperty Tenant -Unique).Count
                }
            })

            $hourAll = @(0) * 24
            $hourFail = @(0) * 24
            foreach ($row in $rowArray) {
                if ($null -ne $row.StartHour) {
                    $hourAll[[int]$row.StartHour]++
                    if ($row.Outcome -eq "Fail") { $hourFail[[int]$row.StartHour]++ }
                }
            }

            $perRelease = @($rowArray | Group-Object -Property Release | ForEach-Object {
                [ordered]@{
                    release     = $_.Name
                    deployments = $_.Count
                    failures    = @($_.Group | Where-Object { $_.Outcome -eq "Fail" }).Count
                }
            })
            $perTenant = @($rowArray | Group-Object -Property Tenant | ForEach-Object {
                [ordered]@{
                    tenant                = $_.Name
                    deployments           = $_.Count
                    failures              = @($_.Group | Where-Object { $_.Outcome -eq "Fail" }).Count
                    redeploysAfterFailure = @($_.Group | Where-Object { $_.IsRedeployAfterFailure }).Count
                }
            })

            $nightCounts = @($nights | ForEach-Object { $_.deployments })
            $telemetryByProject[$projectAlias] = [ordered]@{
                windowStartLocal    = $cutoff.ToString("yyyy-MM-dd")
                deploymentCount     = $rowArray.Count
                outcomes            = [ordered]@{
                    pass       = $passRows.Count
                    fail       = $failRows.Count
                    canceled   = @($rowArray | Where-Object { $_.Outcome -eq "Canceled" }).Count
                    inProgress = @($rowArray | Where-Object { $_.Outcome -eq "InProgress" }).Count
                    unknown    = @($rowArray | Where-Object { $_.Outcome -eq "Unknown" }).Count
                }
                nights              = [ordered]@{
                    count                 = $nights.Count
                    withAtLeastOneFailure = @($nights | Where-Object { $_.failures -gt 0 }).Count
                    averageDeployments    = if ($nightCounts.Count -gt 0) { [math]::Round(($nightCounts | Measure-Object -Average).Average, 1) } else { $null }
                    maxDeployments        = if ($nightCounts.Count -gt 0) { ($nightCounts | Measure-Object -Maximum).Maximum } else { $null }
                    detail                = $nights
                }
                startHourHistogram  = [ordered]@{ all = $hourAll; failed = $hourFail }
                durationSeconds     = [ordered]@{
                    allCompleted = Get-DurationStats @($completedRows | Where-Object { $null -ne $_.DurationSeconds } | ForEach-Object { [double]$_.DurationSeconds })
                    pass         = Get-DurationStats @($passRows | Where-Object { $null -ne $_.DurationSeconds } | ForEach-Object { [double]$_.DurationSeconds })
                    fail         = Get-DurationStats @($failRows | Where-Object { $null -ne $_.DurationSeconds } | ForEach-Object { [double]$_.DurationSeconds })
                }
                redeploysAfterFailure       = @($rowArray | Where-Object { $_.IsRedeployAfterFailure }).Count
                failuresLookLikeConnectivity = @($failRows | Where-Object { $_.ErrorLooksLikeConnectivity -eq $true }).Count
                perRelease          = $perRelease
                perTenant           = $perTenant
            }
        }
    }
    catch {
        Write-Warning "  Skipped '$($project.Name)': $($_.Exception.Message)"
        Write-Verbose $_.ScriptStackTrace
    }
}

# ---------------------------------------------------------------------------
# Shared (non-project) structure
# ---------------------------------------------------------------------------

$tagUsage = @{}
foreach ($tenant in $tenants) {
    foreach ($tag in (ToList $tenant.TenantTags)) {
        $alias = Get-TagAlias "$tag"
        if (-not $tagUsage.ContainsKey($alias)) { $tagUsage[$alias] = 0 }
        $tagUsage[$alias] = $tagUsage[$alias] + 1
    }
}

$modelTagSets = @(foreach ($tagSet in $tagSets) {
    [ordered]@{
        name   = Get-Alias "TagSet" $tagSet.Name
        scopes = @(ToList (Get-Prop $tagSet "Scopes"))
        type   = "$(Get-Prop $tagSet 'Type')"
        tags   = @(foreach ($tag in (ToList $tagSet.Tags)) {
            $canonical = Get-Prop $tag "CanonicalTagName"
            if (-not $canonical) { $canonical = "$($tagSet.Name)/$($tag.Name)" }
            $alias = Get-TagAlias $canonical
            [ordered]@{
                name        = $alias
                tenantCount = if ($tagUsage.ContainsKey($alias)) { $tagUsage[$alias] } else { 0 }
            }
        })
    }
})

$modelTenants = @(foreach ($tenant in $tenants) {
    [ordered]@{
        name                  = $tenantAliasById[$tenant.Id]
        isDisabled            = [bool](Get-Prop $tenant "IsDisabled")
        tags                  = @((ToList $tenant.TenantTags) | ForEach-Object { Get-TagAlias "$_" })
        connectedProjectCount = @((Get-Prop $tenant "ProjectEnvironments").PSObject.Properties).Count
    }
})

# ---------------------------------------------------------------------------
# Deployment targets. Structure only. Names, addresses, thumbprints, and URIs are never read
# into the output. A target gets an alias, roles and tags, environments, tenant links, and state.
# ---------------------------------------------------------------------------

function ConvertTo-SortedMap {
    param($Map)
    $sorted = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object)) { $sorted[$key] = $Map[$key] }
    return $sorted
}

function Add-Count {
    param($Map, [string]$Key)
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = 0 }
    $Map[$Key] = $Map[$Key] + 1
}

$machines = @()
try { $machines = @(Get-OctopusAll "machines") }
catch { Write-Warning "Could not read deployment targets: $($_.Exception.Message)" }

$targetItems = New-Object System.Collections.Generic.List[object]
$byStyle = @{}; $byHealth = @{}; $byParticipation = @{}; $byRole = @{}; $byEnvironment = @{}
$perTenantTargets = @{}; $perTenantRoles = @{}
$disabledTargets = 0

foreach ($machine in $machines) {
    $plainRoles = @(); $tagAliases = @()
    foreach ($role in (ToList (Get-Prop $machine "Roles"))) {
        if ("$role".Contains("/")) { $tagAliases += (Get-TagAlias "$role") }
        else { $plainRoles += (Get-Alias "Role" "$role") }
    }
    $envAliases = @((ToList (Get-Prop $machine "EnvironmentIds")) | ForEach-Object { Get-Alias "Environment" $environmentMap["$_"] })
    $tenantAliases = @((ToList (Get-Prop $machine "TenantIds")) | ForEach-Object { if ($tenantAliasById.ContainsKey("$_")) { $tenantAliasById["$_"] } else { "(unknown tenant)" } })
    $style = "$(Get-Prop (Get-Prop $machine 'Endpoint') 'CommunicationStyle')"
    $health = "$(Get-Prop $machine 'HealthStatus')"
    $participation = "$(Get-Prop $machine 'TenantedDeploymentParticipation')"
    $isDisabled = [bool](Get-Prop $machine "IsDisabled")

    Add-Count $byStyle $style
    Add-Count $byHealth $health
    Add-Count $byParticipation $participation
    if ($isDisabled) { $disabledTargets++ }
    foreach ($r in ($plainRoles + $tagAliases)) { Add-Count $byRole $r }
    foreach ($e in $envAliases) { Add-Count $byEnvironment $e }
    foreach ($t in $tenantAliases) {
        Add-Count $perTenantTargets $t
        if (-not $perTenantRoles.ContainsKey($t)) { $perTenantRoles[$t] = @{} }
        foreach ($r in ($plainRoles + $tagAliases)) { Add-Count $perTenantRoles[$t] $r }
    }

    $targetItems.Add([ordered]@{
        name                  = Get-Alias "Target" "$($machine.Name)"
        communicationStyle    = $style
        roles                 = $plainRoles
        tags                  = $tagAliases
        environments          = $envAliases
        tenantedParticipation = $participation
        tenants               = $tenantAliases
        tenantTags            = @((ToList (Get-Prop $machine "TenantTags")) | ForEach-Object { Get-TagAlias "$_" })
        isDisabled            = $isDisabled
        healthStatus          = $health
        status                = "$(Get-Prop $machine 'Status')"
    })
}

$modelTargets = [ordered]@{
    count               = $targetItems.Count
    disabledCount       = $disabledTargets
    byCommunicationStyle = ConvertTo-SortedMap $byStyle
    byHealthStatus      = ConvertTo-SortedMap $byHealth
    byParticipation     = ConvertTo-SortedMap $byParticipation
    byRoleOrTag         = ConvertTo-SortedMap $byRole
    byEnvironment       = ConvertTo-SortedMap $byEnvironment
    perTenant           = @(foreach ($t in ($perTenantTargets.Keys | Sort-Object)) {
        [ordered]@{ tenant = $t; targets = $perTenantTargets[$t]; byRoleOrTag = ConvertTo-SortedMap $perTenantRoles[$t] }
    })
    items               = $targetItems.ToArray()
}

$usedLifecycles = @{}
foreach ($project in $projects) { if ($project.LifecycleId) { $usedLifecycles[$project.LifecycleId] = $true } }
foreach ($lifecycleId in $script:ChannelLifecycleIds.Keys) { $usedLifecycles[$lifecycleId] = $true }
$modelLifecycles = @(foreach ($lifecycle in $lifecycleList) {
    if (-not $usedLifecycles.ContainsKey($lifecycle.Id)) { continue }
    [ordered]@{
        name   = Get-Alias "Lifecycle" $lifecycle.Name
        phases = @(foreach ($phase in (ToList $lifecycle.Phases)) {
            [ordered]@{
                isOptional                         = [bool](Get-Prop $phase "IsOptionalPhase")
                minimumEnvironmentsBeforePromotion = Get-Prop $phase "MinimumEnvironmentsBeforePromotion"
                environments                       = @((ToList ((ToList $phase.AutomaticDeploymentTargets) + (ToList $phase.OptionalDeploymentTargets))) | ForEach-Object { Get-Alias "Environment" $environmentMap["$_"] })
                automaticEnvironments              = @((ToList $phase.AutomaticDeploymentTargets) | ForEach-Object { Get-Alias "Environment" $environmentMap["$_"] })
            }
        })
    }
})

# ---------------------------------------------------------------------------
# Write the files
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

$localZone = [TimeZoneInfo]::Local
$model = [ordered]@{
    meta = [ordered]@{
        schemaVersion   = $ModelSchemaVersion
        scriptVersion   = $ScriptVersion
        generatedAtUtc  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        octopusVersion  = $serverVersion
        apiVersion      = $apiVersion
        timeZone        = [ordered]@{ id = $localZone.Id; currentUtcOffset = $localZone.GetUtcOffset((Get-Date)).ToString(); note = "Telemetry times use the time zone of the machine that ran the script." }
        anonymized      = (-not $NoAnonymize)
        keptNames       = @($KeepNames)
        telemetry       = [bool]$IncludeTelemetry
        telemetryMonths = if ($IncludeTelemetry) { $TelemetryMonths } else { $null }
        nightDefinition = "A night runs from 12:00 to 11:59 the next day, so a 02:00 deployment counts toward the previous calendar day's night."
        projectCount    = $modelProjects.Count
    }
    tagSets    = $modelTagSets
    tenants    = [ordered]@{
        count = $tenants.Count
        items = $modelTenants
    }
    lifecycles = $modelLifecycles
    projects   = $modelProjects.ToArray()
    targets    = $modelTargets
}
if ($IncludeTelemetry) { $model["telemetry"] = $telemetryByProject }

$modelPath = Join-Path $OutputFolder "process-model.json"
$model | ConvertTo-Json -Depth 20 | Set-Content -Path $modelPath -Encoding UTF8

# steps.csv: one row for each action. Flattened from the model so the two never disagree.
$stepRows = New-Object System.Collections.Generic.List[object]
foreach ($modelProject in $modelProjects) {
    foreach ($modelStep in $modelProject["steps"]) {
        foreach ($a in $modelStep["actions"]) {
            $packageSummary = (@($a["packages"]) | ForEach-Object { "$($_.reference):$($_.acquisitionLocation)" }) -join "; "
            $stepRows.Add([pscustomobject]@{
                Project              = $modelProject["name"]
                StepNumber           = $a["label"]
                Step                 = $modelStep["name"]
                Action               = $a["name"]
                ActionType           = $a["actionType"]
                StepTemplate         = $a["stepTemplate"]
                IsProcessTemplate    = $a["isProcessTemplate"]
                TemplateParameterCount = @($a["processTemplateParameters"]).Count
                IsDisabled           = $a["isDisabled"]
                IsRequired           = $a["isRequired"]
                AutoRetryMax         = if ($a["autoRetry"]) { $a["autoRetry"]["maximumCount"] } else { "" }
                AutoRetryBackoff     = if ($a["autoRetry"]) { $a["autoRetry"]["minimumBackoff"] } else { "" }
                RunsOn               = $a["runsOn"]
                WorkerPool           = $a["workerPool"]
                TargetRoles          = ($modelStep["targetRoles"] -join "; ")
                StartTrigger         = $modelStep["startTrigger"]
                ParallelWithPrevious = $modelStep["parallelWithPrevious"]
                Wave                 = $modelStep["wave"]
                WaveSize             = $modelStep["waveSize"]
                MaxParallelism       = $modelStep["maxParallelism"]
                RunCondition         = $modelStep["runCondition"]
                ConditionExpression  = $modelStep["conditionExpression"]
                PackageRequirement   = $modelStep["packageRequirement"]
                TenantTags           = ($a["tenantTags"] -join "; ")
                Environments         = ($a["environments"] -join "; ")
                ExcludedEnvironments = ($a["excludedEnvironments"] -join "; ")
                Channels             = ($a["channels"] -join "; ")
                ScriptSource         = $a["scriptSource"]
                DeploysChildProject  = $a["deploysChildProject"]
                PackageCount         = @($a["packages"]).Count
                Packages             = $packageSummary
                OutputVariablesSet   = ($a["outputVariablesSet"] -join "; ")
                DependsOnSteps       = ($a["dependsOnSteps"] -join "; ")
            })
        }
    }
}
$stepsPath = Join-Path $OutputFolder "steps.csv"
$stepRows | Export-Csv -Path $stepsPath -Encoding UTF8

# targets.csv: one row for each target, flattened from the model.
$targetRows = foreach ($item in $targetItems) {
    [pscustomobject]@{
        Target                = $item["name"]
        CommunicationStyle    = $item["communicationStyle"]
        Roles                 = ($item["roles"] -join "; ")
        Tags                  = ($item["tags"] -join "; ")
        Environments          = ($item["environments"] -join "; ")
        TenantedParticipation = $item["tenantedParticipation"]
        TenantCount           = @($item["tenants"]).Count
        Tenants               = ($item["tenants"] -join "; ")
        TenantTags            = ($item["tenantTags"] -join "; ")
        IsDisabled            = $item["isDisabled"]
        HealthStatus          = $item["healthStatus"]
        Status                = $item["status"]
    }
}
$targetsPath = Join-Path $OutputFolder "targets.csv"
if ($targetItems.Count -gt 0) { $targetRows | Export-Csv -Path $targetsPath -Encoding UTF8 }

$shareFiles = @($modelPath, $stepsPath)
if ($targetItems.Count -gt 0) { $shareFiles += $targetsPath }

if ($IncludeTelemetry) {
    $telemetryPath = Join-Path $OutputFolder "telemetry-deployments.csv"
    $telemetryRows | Select-Object -Property * -ExcludeProperty _Sort | Export-Csv -Path $telemetryPath -Encoding UTF8
    $shareFiles += $telemetryPath
}

# The alias map stays with the customer. It is not added to the zip.
$mapPath = $null
if (-not $NoAnonymize) {
    $mapRows = New-Object System.Collections.Generic.List[object]
    foreach ($key in ($script:AliasMap.Keys | Sort-Object)) {
        $parts = $key -split '\|', 2
        $kind = $parts[0]
        $mapScope = $parts[1]
        $aliasKey = $key
        $ordered = $script:AliasMap[$aliasKey].Keys | Sort-Object -Property @(
            @{ Expression = { $digits = "$($script:AliasMap[$aliasKey][$_])" -replace '\D', ''; if ($digits) { [int]$digits } else { 0 } } },
            @{ Expression = { "$_" } })
        foreach ($original in $ordered) {
            $alias = $script:AliasMap[$key][$original]
            $full = $alias
            if ($kind -eq "Tag") { $full = (Get-Alias "TagSet" $mapScope) + "/" + $alias }
            $mapRows.Add([pscustomobject]@{
                Kind      = $kind
                Scope     = $mapScope
                Alias     = $alias
                Original  = $original
                FullAlias = $full
            })
        }
    }
    $mapPath = Join-Path $OutputFolder "anonymization-map.csv"
    $mapRows | Export-Csv -Path $mapPath -Encoding UTF8
}

$zipPath = "$OutputFolder.zip"
Compress-Archive -Path $shareFiles -DestinationPath $zipPath -Force

$totalSteps = 0
foreach ($p in $modelProjects) { $totalSteps += $p["counts"]["steps"] }

Write-Host ""
Write-Host "Export complete."
Write-Host ("  Projects:          {0}" -f $modelProjects.Count)
Write-Host ("  Steps:             {0}" -f $totalSteps)
Write-Host ("  Action rows:       {0}" -f $stepRows.Count)
Write-Host ("  Tenants:           {0}" -f $tenants.Count)
Write-Host ("  Targets:           {0}" -f $targetItems.Count)
if ($IncludeTelemetry) { Write-Host ("  Deployments:       {0}" -f $telemetryRows.Count) }
Write-Host ""
Write-Host "Review the files in $OutputFolder before you send anything."
if ($mapPath) {
    Write-Host "Keep this file. It is NOT in the zip: $mapPath"
}
else {
    Write-Warning "-NoAnonymize was used. The output holds real names. Do not send it outside your company."
}
Write-Host "Send this file back: $zipPath"
