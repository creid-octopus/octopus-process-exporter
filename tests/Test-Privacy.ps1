<#
.SYNOPSIS
    Checks an export for leaked names, secrets, and script text. Read-only. Stands alone.

.DESCRIPTION
    This script never runs or reads the export script, and it never reads the alias map.
    It judges the export purely from its output and from the live Octopus instance:

      1. It asks the instance (GET requests only) for the real names in the space:
         projects, steps, environments, tenants, tag sets, packages, roles, and so on.
      2. It searches every file in the export for those names.
      3. It searches for patterns that should never appear: API keys, email addresses,
         URLs, IP addresses, private key headers, long text, and script marker strings.
      4. It checks which files are in the zip. Only known file names are allowed.
      5. Optionally, it checks that the export script sends only GET requests.

    Names that collide with the export's own vocabulary (for example a step named
    "Success") cannot be judged by text search. They are listed as ambiguous, never
    counted as leaks, so the check does not fail at random.

    Kinds of names that the export kept on purpose (model.meta.keptNames) are skipped.

    Exit code 0 means no leaks were found. Exit code 1 means at least one problem.

.PARAMETER Export
    Path to the export zip, or to the folder that holds the same files.

.PARAMETER OctopusUrl
    The Octopus Server address.

.PARAMETER ApiKey
    A view-only API key. Defaults to the OCTOPUS_API_KEY environment variable.

.PARAMETER SpaceName
    The space the export was made from. Default: "Default".

.PARAMETER ScriptPath
    Optional. Path to the export script, for the GET-only check.

.PARAMETER MarkerPattern
    Regular expression for strings planted in script bodies and variable values.
    Default: SCRIPT-MARKER.

.PARAMETER MinLength
    Names shorter than this are not searched, because they match by chance. Default 4.

.PARAMETER AllowedFiles
    File names allowed in the zip. Default: process-model.json, steps.csv, targets.csv, telemetry-deployments.csv.
#>
param(
    [Parameter(Mandatory = $true)][string]$Export,
    [Parameter(Mandatory = $true)][string]$OctopusUrl,
    [string]$ApiKey = $env:OCTOPUS_API_KEY,
    [string]$SpaceName = "Default",
    [string]$ScriptPath,
    [string]$MarkerPattern = "SCRIPT-MARKER",
    [int]$MinLength = 4,
    [string[]]$AllowedFiles = @("process-model.json", "steps.csv", "targets.csv", "telemetry-deployments.csv")
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "No API key. Pass -ApiKey or set OCTOPUS_API_KEY." }
$OctopusUrl = $OctopusUrl.TrimEnd('/')

$failures = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[string]
function Fail([string]$text) { $script:failures.Add($text) }

# ---------------------------------------------------------------------------
# Load the export
# ---------------------------------------------------------------------------
$work = $null
if (Test-Path -LiteralPath $Export -PathType Leaf) {
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("privacy-check-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work | Out-Null
    Expand-Archive -LiteralPath $Export -DestinationPath $work -Force
    $folder = $work
    $zipEntries = @(Get-ChildItem -LiteralPath $work -Recurse -File | ForEach-Object { $_.FullName.Substring($work.Length + 1) })
}
else {
    $folder = $Export
    $zipEntries = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object { $_.Name })
}

try {
    # 4. File allow list
    foreach ($entry in $zipEntries) {
        if ($AllowedFiles -notcontains $entry) { Fail "Unexpected file in export: $entry" }
    }
    if ($zipEntries.Count -eq 0) { Fail "The export holds no files." }

    $texts = @{}
    foreach ($entry in $zipEntries) {
        $full = Join-Path $folder $entry
        if (Test-Path -LiteralPath $full) { $texts[$entry] = [System.IO.File]::ReadAllText($full) }
    }

    # Model meta
    $keptKinds = @()
    $model = $null
    if ($texts.ContainsKey("process-model.json")) {
        $model = $texts["process-model.json"] | ConvertFrom-Json
        $keptKinds = @($model.meta.keptNames)
        if (-not $model.meta.anonymized) { Fail "The model says the export is NOT anonymized (-NoAnonymize was used)." }
    }
    else { Fail "process-model.json is missing." }

    # -----------------------------------------------------------------------
    # 1. Harvest real names from the instance. GET only.
    # -----------------------------------------------------------------------
    $headers = @{ "X-Octopus-ApiKey" = $ApiKey }
    function Get-Json([string]$Path) {
        # Only GET requests are ever sent.
        $r = Invoke-RestMethod -Method Get -Uri "$OctopusUrl$Path" -Headers $headers
        $flat = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($r)) { if ($item -is [System.Array]) { foreach ($i in $item) { $flat.Add($i) } } else { $flat.Add($item) } }
        return $flat.ToArray()
    }
    function TryGet([string]$Path) {
        try { return (Get-Json $Path) } catch { $script:notes.Add("Could not read $Path : $($_.Exception.Message)"); return @() }
    }

    $names = New-Object System.Collections.Generic.List[object]   # @{Kind; Name}
    function AddName([string]$Kind, $Name) {
        if ($null -eq $Name) { return }
        $text = "$Name".Trim()
        if ($text.Length -ge $script:MinLength) { $script:names.Add([pscustomobject]@{ Kind = $Kind; Name = $text }) }
    }

    $spaces = Get-Json "/api/spaces/all"
    $space = $spaces | Where-Object { $_.Name -eq $SpaceName } | Select-Object -First 1
    if ($null -eq $space) { throw "Space '$SpaceName' not found." }
    $sid = $space.Id
    AddName "Space" $space.Name

    foreach ($x in (TryGet "/api/$sid/environments/all")) { AddName "Environment" $x.Name }
    foreach ($x in (TryGet "/api/$sid/lifecycles/all")) { AddName "Lifecycle" $x.Name }
    foreach ($x in (TryGet "/api/$sid/feeds/all")) { AddName "Feed" $x.Name }
    foreach ($x in (TryGet "/api/$sid/workerpools/all")) { AddName "WorkerPool" $x.Name }
    foreach ($x in (TryGet "/api/$sid/workers/all")) { AddName "Worker" $x.Name }
    foreach ($x in (TryGet "/api/$sid/tenants/all")) { AddName "Tenant" $x.Name; foreach ($tag in @($x.TenantTags)) { } }
    foreach ($ts in (TryGet "/api/$sid/tagsets/all")) {
        AddName "TagSet" $ts.Name
        foreach ($tag in @($ts.Tags)) { AddName "TagSet" $tag.Name }
    }
    foreach ($x in (TryGet "/api/$sid/machines/all")) {
        AddName "Machine" $x.Name
        foreach ($r in @($x.Roles)) { AddName "Role" $r }
    }
    foreach ($x in (TryGet "/api/$sid/actiontemplates/all")) { AddName "Template" $x.Name }
    foreach ($x in (TryGet "/api/$sid/libraryvariablesets/all")) { AddName "Variable" $x.Name }

    $projects = TryGet "/api/$sid/projects/all"
    foreach ($p in $projects) {
        AddName "Project" $p.Name
        foreach ($c in @((TryGet "/api/$sid/projects/$($p.Id)/channels?take=1000" | ForEach-Object { $_.Items }) | Where-Object { $_ })) { AddName "Channel" $c.Name }

        $isGit = ($null -ne $p.PersistenceSettings) -and ($p.PersistenceSettings.Type -eq "VersionControlled")
        $process = $null; $vars = @()
        if ($isGit) {
            $ref = [uri]::EscapeDataString($p.PersistenceSettings.DefaultBranch)
            $process = (TryGet "/api/$sid/projects/$($p.Id)/$ref/deploymentprocesses") | Select-Object -First 1
            $vars = @(TryGet "/api/$sid/projects/$($p.Id)/$ref/variables")
        }
        else {
            $process = (TryGet "/api/$sid/deploymentprocesses/$($p.DeploymentProcessId)") | Select-Object -First 1
        }
        $vars = @($vars) + @(TryGet "/api/$sid/variables/$($p.VariableSetId)")

        foreach ($step in @($process.Steps)) {
            AddName "Step" $step.Name
            foreach ($rn in @(("$($step.Properties.'Octopus.Action.TargetRoles')" -split ','))) { AddName "Role" $rn }
            foreach ($a in @($step.Actions)) {
                AddName "Step" $a.Name
                foreach ($pk in @($a.Packages)) { AddName "Package" $pk.PackageId; AddName "Package" $pk.Name }
            }
        }
        foreach ($set in $vars) { foreach ($v in @($set.Variables)) { AddName "Variable" $v.Name } }
    }

    if ($names.Count -lt 5) { Fail "Harvested only $($names.Count) names from the instance. The check cannot be trusted." }

    # Output vocabulary: JSON property names and the script's own enum values.
    $vocab = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($w in @("Default", "Success", "Failure", "Always", "Variable", "Server", "Worker", "Targets", "Unknown", "Git", "Database", "Tenanted", "Untenanted",
            "TenantedOrUntenanted", "String", "Sensitive", "Healthy", "Pass", "Fail", "Canceled", "Inline", "Package", "GitRepository", "Octopus.Script",
            "Octopus.Manual", "Octopus.DeployRelease", "LetOctopusDecide", "StartAfterPrevious", "StartWithPrevious", "NotAcquired", "ExecutionTarget",
            "BuiltIn", "Docker", "NuGet", "EnvironmentDefault", "Octopus.ProcessTemplate")) { [void]$vocab.Add($w) }
    foreach ($m in [regex]::Matches($texts["process-model.json"], '"([A-Za-z][A-Za-z0-9]*)"\s*:')) { [void]$vocab.Add($m.Groups[1].Value) }
    if ($texts.ContainsKey("steps.csv")) { foreach ($h in ((($texts["steps.csv"] -split "`n")[0]) -split ',')) { [void]$vocab.Add($h.Trim('"', "`r")) } }
    if ($texts.ContainsKey("telemetry-deployments.csv")) { foreach ($h in ((($texts["telemetry-deployments.csv"] -split "`n")[0]) -split ',')) { [void]$vocab.Add($h.Trim('"', "`r")) } }

    # Kinds the export kept on purpose are not leaks.
    $skipKinds = @()
    foreach ($k in $keptKinds) { $skipKinds += $k; if ($k -eq "TagSet") { $skipKinds += "TagSet" } }

    # -----------------------------------------------------------------------
    # 2. Search for real names
    # -----------------------------------------------------------------------
    # Names the export kept on purpose can contain other names (a kept step called
    # "Lab Only Diagnostic" holds the lifecycle name "Lab only"). Remove the kept names
    # from the text first, longest first, then search what is left.
    $searchTexts = @{}
    $keptList = @($names | Where-Object { $skipKinds -contains $_.Kind } | ForEach-Object { $_.Name } | Select-Object -Unique | Sort-Object -Property Length -Descending)
    foreach ($entry in $texts.Keys) {
        $t = $texts[$entry]
        foreach ($kn in $keptList) { $t = [regex]::Replace($t, [regex]::Escape($kn), "<kept>", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        $searchTexts[$entry] = $t
    }

    $checkedCount = 0
    $ambiguous = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $names) {
        if ($skipKinds -contains $n.Kind) { continue }
        if (-not $seen.Add("$($n.Kind)|$($n.Name)")) { continue }
        if ($vocab.Contains($n.Name)) { $ambiguous.Add("$($n.Kind): $($n.Name)"); continue }
        $checkedCount++
        $pattern = "(?<![A-Za-z0-9])" + [regex]::Escape($n.Name) + "(?![A-Za-z0-9])"
        foreach ($entry in $searchTexts.Keys) {
            if ([regex]::IsMatch($searchTexts[$entry], $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                Fail "Real $($n.Kind) name found in ${entry}: '$($n.Name)'"
            }
        }
    }

    # -----------------------------------------------------------------------
    # 3. Patterns that should never appear
    # -----------------------------------------------------------------------
    $patterns = [ordered]@{
        "API key"          = 'API-[A-Za-z0-9]{20,}'
        "email address"    = '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'
        "URL"              = 'https?://[^\s",]+'
        "IPv4 address"     = '(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9.])'
        "private key"      = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        "bearer token"     = 'Bearer\s+[A-Za-z0-9._\-]{20,}'
        "script marker"    = $MarkerPattern
        "GUID"             = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    }
    foreach ($entry in $texts.Keys) {
        foreach ($label in $patterns.Keys) {
            $found = [regex]::Matches($texts[$entry], $patterns[$label])
            if ($found.Count -gt 0) { Fail "$label pattern found in ${entry}: $($found.Count) match(es), first: '$($found[0].Value)'" }
        }
    }
    # Long or multi-line text values suggest script bodies or error text.
    if ($texts.ContainsKey("process-model.json")) {
        foreach ($m in [regex]::Matches($texts["process-model.json"], ':\s*"((?:[^"\\]|\\.){200,})"')) { Fail "Very long text value in process-model.json (length $($m.Groups[1].Length))" }
        if ($texts["process-model.json"] -match '\\n[^"]{40,}\\n') { Fail "Multi-line text value in process-model.json" }
    }
    foreach ($entry in ($texts.Keys | Where-Object { $_ -like "*.csv" })) {
        try {
            foreach ($row in ($texts[$entry] | ConvertFrom-Csv)) {
                foreach ($prop in $row.PSObject.Properties) {
                    if ("$($prop.Value)".Length -gt 200 -or "$($prop.Value)" -match "[\r\n]") { Fail "Long or multi-line cell in $entry, column $($prop.Name)" }
                }
            }
        }
        catch { Fail "Could not parse $entry as CSV: $($_.Exception.Message)" }
    }
    # Forbidden column names
    foreach ($entry in ($texts.Keys | Where-Object { $_ -like "*.csv" })) {
        $header = ($texts[$entry] -split "`n")[0]
        foreach ($bad in @("ErrorMessage", "Error", "Description", "Script", "Value", "Password", "Url", "Uri", "Thumbprint")) {
            if ($header -match "(^|,)""?$bad""?(,|$)") { Fail "Forbidden column '$bad' in $entry" }
        }
    }

    # -----------------------------------------------------------------------
    # 5. GET-only check on the export script (optional)
    # -----------------------------------------------------------------------
    $getOnlyNote = "skipped (no -ScriptPath)"
    if ($ScriptPath) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        $webCalls = 0
        foreach ($c in $commands) {
            $cmdName = $c.GetCommandName()
            if ($cmdName -notmatch '^(Invoke-RestMethod|Invoke-WebRequest|irm|iwr|curl|wget)$') { continue }
            $webCalls++
            $elements = @($c.CommandElements)
            $method = $null; $hasBody = $false
            for ($i = 0; $i -lt $elements.Count; $i++) {
                if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $pn = $elements[$i].ParameterName
                    if ($pn -eq "Method" -and ($i + 1) -lt $elements.Count) { $method = $elements[$i + 1].Extent.Text.Trim("'", '"') }
                    if ($pn -in @("Body", "InFile")) { $hasBody = $true }
                }
            }
            if ($method -ne "Get") { Fail "Web call without an explicit -Method Get at line $($c.Extent.StartLineNumber) of the export script" }
            if ($hasBody) { Fail "Web call with a body at line $($c.Extent.StartLineNumber) of the export script" }
        }
        $scriptText = [System.IO.File]::ReadAllText($ScriptPath)
        foreach ($m in [regex]::Matches($scriptText, '(?i)-Method\s+["'']?(Post|Put|Delete|Patch)\b|\.(PostAsync|PutAsync|DeleteAsync|UploadString|UploadData|UploadFile)\b|New-Object\s+System\.Net\.WebClient|HttpClient')) {
            Fail "Possible non-GET request pattern in the export script: '$($m.Value)'"
        }
        if ($webCalls -eq 0) { Fail "The GET-only check found no web calls in the script. The check may not understand it." }
        $getOnlyNote = "$webCalls web call(s), all GET"
    }

    # -----------------------------------------------------------------------
    # Report
    # -----------------------------------------------------------------------
    Write-Host ("Files checked:           {0}" -f ($texts.Keys -join ", "))
    Write-Host ("Names harvested:         {0} ({1} searched, {2} ambiguous, kept kinds skipped: {3})" -f $names.Count, $checkedCount, $ambiguous.Count, $(if ($skipKinds.Count) { $skipKinds -join "," } else { "none" }))
    Write-Host ("GET-only check:          {0}" -f $getOnlyNote)
    if ($ambiguous.Count -gt 0) { Write-Host ("Ambiguous (not judged):  {0}" -f (($ambiguous | Select-Object -First 12) -join "; ")) }
    foreach ($n in $notes) { Write-Host "Note: $n" }
}
finally {
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -eq 0) { Write-Host "PASS: no privacy problems found."; exit 0 }
Write-Host ("FAIL: {0} problem(s)" -f $failures.Count) -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  $_" }
exit 1
