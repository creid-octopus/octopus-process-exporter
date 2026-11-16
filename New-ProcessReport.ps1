<#
.SYNOPSIS
    Turns process-model.json into a readable Markdown report.
.DESCRIPTION
    Works offline. It reads the model that Export-OctopusProcesses.ps1 wrote, and it never
    contacts Octopus. The report holds, for each project:
      - a summary (process source, counts, lifecycle, channels)
      - a Mermaid diagram of the process, with runs of steps that share the same gating
        collapsed into one block
      - a block table and the tenant tag gating, with how many steps each tenant runs
      - the target inventory, variable structure and output variable dependencies
      - telemetry, when the export included it
      - the full step table, in a collapsible section
    Every number comes from the model. The report adds no names that the model does not hold.
.PARAMETER Model
    Path to process-model.json (or the folder that holds it).
.PARAMETER OutputPath
    Where to write the report. The default is process-report.md next to the model.
.EXAMPLE
    .\New-ProcessReport.ps1 -Model .\octopus-process-export-20261116\process-model.json
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Model,

    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
if (Test-Path -LiteralPath $Model -PathType Container) { $Model = Join-Path $Model "process-model.json" }
if (-not (Test-Path -LiteralPath $Model)) { throw "Model file not found: $Model" }
if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Model)) "process-report.md" }

$m = Get-Content -LiteralPath $Model -Raw | ConvertFrom-Json
if ($m.meta.schemaVersion -ne 1) { Write-Warning "This renderer knows model schema 1. The file says $($m.meta.schemaVersion). Some sections may be wrong." }

$out = New-Object System.Text.StringBuilder
function Add-Line { param([string]$Text = "") [void]$out.AppendLine($Text) }
function Cell { param($Value) ("$Value" -replace '\|', '\|' -replace '\r?\n', ' ') }
function Join-Or { param($Items, [string]$Empty = "none") $list = @($Items | Where-Object { "$_" -ne "" }); if ($list.Count -eq 0) { $Empty } else { $list -join ", " } }
function Get-Prop { param($Object, [string]$Name) if ($null -eq $Object) { return $null } $p = $Object.PSObject.Properties[$Name]; if ($null -eq $p) { $null } else { $p.Value } }
function Percent { param([double]$Part, [double]$Whole) if ($Whole -eq 0) { "0%" } else { ("{0:N0}%" -f (100 * $Part / $Whole)) } }
function Format-Duration {
    param($Seconds)
    if ($null -eq $Seconds) { return "n/a" }
    $s = [double]$Seconds
    if ($s -lt 90) { return ("{0:N0} s" -f $s) }
    if ($s -lt 5400) { return ("{0:N1} min" -f ($s / 60)) }
    return ("{0:N1} h" -f ($s / 3600))
}
function Get-Bar { param([double]$Value, [double]$Max, [int]$Width = 30) if ($Max -le 0) { return "" } ("#" * [int][math]::Round($Width * $Value / $Max)) }

# ---------------------------------------------------------------- gating
function Get-ActionTags { param($Step) @($Step.actions | ForEach-Object { @($_.tenantTags) } | Where-Object { $_ } | Sort-Object -Unique) }

# Same set: any of the tags (or). Different sets: all of the sets (and).
function Format-TagExpr {
    param($Tags)
    $list = @($Tags | Where-Object { $_ } | Sort-Object -Unique)
    if ($list.Count -eq 0) { return "" }
    $bySet = [ordered]@{}
    foreach ($tag in $list) {
        $set = if ($tag.Contains("/")) { $tag.Substring(0, $tag.IndexOf("/")) } else { "" }
        if (-not $bySet.Contains($set)) { $bySet[$set] = New-Object System.Collections.Generic.List[string] }
        $bySet[$set].Add($tag)
    }
    $groups = @($bySet.Keys | ForEach-Object { $g = $bySet[$_]; if ($g.Count -gt 1) { "(" + ($g -join " or ") + ")" } else { $g[0] } })
    return ($groups -join " and ")
}

function Get-StepSignature {
    param($Step)
    $actions = @($Step.actions)
    $tagsPerAction = @($actions | ForEach-Object { Format-TagExpr $_.tenantTags } | Sort-Object -Unique) -join " / "
    $envs = @($actions | ForEach-Object { (@($_.environments) | Sort-Object) -join "+" } | Sort-Object -Unique) -join " / "
    $excl = @($actions | ForEach-Object { (@($_.excludedEnvironments) | Sort-Object) -join "+" } | Sort-Object -Unique) -join " / "
    $chan = @($actions | ForEach-Object { (@($_.channels) | Sort-Object) -join "+" } | Sort-Object -Unique) -join " / "
    $runs = @($actions | ForEach-Object { $_.runsOn } | Sort-Object -Unique) -join "+"
    $roles = (@($Step.targetRoles) | Sort-Object) -join "+"
    $disabled = @($actions | Where-Object { $_.isDisabled }).Count -gt 0
    [ordered]@{
        Key  = "$($Step.runCondition)|$($Step.conditionExpression)|$tagsPerAction|$envs|$excl|$chan|$runs|$roles|$disabled"
        Cond = if ($Step.runCondition -eq "Variable") { "expression" } else { "$($Step.runCondition)" }
        Tags = $tagsPerAction; Envs = $envs; Excl = $excl; Channels = $chan; Runs = $runs; Roles = $roles; Disabled = $disabled
    }
}

# A step runs for a tenant when every tag set the step names is matched by at least one of the tenant's tags in that set.
function Test-TagsMatch {
    param([string[]]$StepTags, [string[]]$TenantTags)
    $stepTags = @($StepTags | Where-Object { $_ })
    if ($stepTags.Count -eq 0) { return $true }
    $bySet = @{}
    foreach ($tag in $stepTags) {
        $set = if ($tag.Contains("/")) { $tag.Substring(0, $tag.IndexOf("/")) } else { "" }
        if (-not $bySet.ContainsKey($set)) { $bySet[$set] = New-Object System.Collections.Generic.List[string] }
        $bySet[$set].Add($tag)
    }
    foreach ($set in $bySet.Keys) {
        $hit = $false
        foreach ($tag in $bySet[$set]) { if ($TenantTags -contains $tag) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    return $true
}

function Test-StepRunsForTenant {
    param($Step, [string[]]$TenantTags)
    foreach ($action in @($Step.actions)) { if (Test-TagsMatch @($action.tenantTags) $TenantTags) { return $true } }
    return $false
}

function Get-Blocks {
    param($Steps)
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($step in $Steps) {
        $sig = Get-StepSignature $step
        if ($null -eq $current -or $current.Sig.Key -ne $sig.Key) {
            $current = [ordered]@{ Sig = $sig; Steps = (New-Object System.Collections.Generic.List[object]) }
            $blocks.Add($current)
        }
        $current.Steps.Add($step)
    }
    return $blocks.ToArray()
}

function Get-Gating-Text {
    param($Sig)
    $parts = @()
    if ($Sig.Tags) { $parts += "tags $($Sig.Tags)" }
    if ($Sig.Envs) { $parts += "only in $($Sig.Envs)" }
    if ($Sig.Excl) { $parts += "not in $($Sig.Excl)" }
    if ($Sig.Channels) { $parts += "channels $($Sig.Channels)" }
    if ($parts.Count -eq 0) { "every tenant, every environment" } else { $parts -join "; " }
}
function Get-RunsOn-Text {
    param($Sig)
    $r = if ($Sig.Runs) { $Sig.Runs } else { "?" }
    if ($Sig.Roles) { "$r ($($Sig.Roles))" } else { $r }
}
function Esc-Mermaid { param([string]$Text) ($Text -replace '"', "'" -replace '[\[\]{}<>]', '') }

# ---------------------------------------------------------------- report
Add-Line "# Deployment process report"
Add-Line
Add-Line "Rendered from ``process-model.json``. Nothing in this report came from a live server."
Add-Line
Add-Line "| | |"
Add-Line "|---|---|"
Add-Line "| Octopus Server | $(Cell $m.meta.octopusVersion) (API $(Cell $m.meta.apiVersion)) |"
$generated = $m.meta.generatedAtUtc
if ($generated -is [datetime]) { $generated = $generated.ToUniversalTime().ToString("yyyy-MM-dd HH:mm") + "Z" }
$tz = $m.meta.timeZone
$tzText = if ($tz -is [string]) { $tz } elseif ($null -ne $tz) { "$($tz.id) (UTC$($tz.currentUtcOffset))" } else { "unknown" }
Add-Line "| Exported | $(Cell $generated) |"
Add-Line "| Time zone of deployment times | $(Cell $tzText), the time zone of the machine that ran the export |"
Add-Line "| Names | $(if ($m.meta.anonymized) { 'anonymized' + $(if (@($m.meta.keptNames).Count -gt 0) { ', kept: ' + (@($m.meta.keptNames) -join ', ') } else { '' }) } else { 'real names (not anonymized)' }) |"
Add-Line "| Projects | $($m.meta.projectCount) |"
Add-Line "| Telemetry | $(if ($m.meta.telemetry) { 'included, last ' + $m.meta.telemetryMonths + ' months' } else { 'not included' }) |"
Add-Line

$tenantItems = @()
if ($null -ne $m.tenants -and $null -ne $m.tenants.items) { $tenantItems = @($m.tenants.items) }

# Tag sets, once for the whole export.
if ($null -ne $m.tagSets -and @($m.tagSets).Count -gt 0) {
    Add-Line "## Tag sets"
    Add-Line
    Add-Line "| Tag set | Scope | Type | Tags | Tenants per tag |"
    Add-Line "|---|---|---|---|---|"
    foreach ($ts in @($m.tagSets)) {
        $tags = @($ts.tags)
        $isTenantSet = @($ts.scopes) -contains "Tenant" -or @($ts.scopes).Count -eq 0
        $counts = if ($isTenantSet) { ($tags | ForEach-Object { "$(($_.name -split '/', 2)[-1]) ($($_.tenantCount))" }) -join ", " } else { "n/a (target tags)" }
        Add-Line "| $(Cell $ts.name) | $(Cell (Join-Or $ts.scopes)) | $(Cell $ts.type) | $($tags.Count) | $(Cell $counts) |"
    }
    Add-Line
}

foreach ($project in @($m.projects)) {
    $steps = @($project.steps)
    Add-Line "## Project $($project.name)"
    Add-Line
    $c = $project.counts
    Add-Line "| | |"
    Add-Line "|---|---|"
    Add-Line "| Process source | $(Cell $project.processSource) |"
    Add-Line "| Tenanted deployments | $(Cell $project.tenantedDeploymentMode), $($project.connectedTenantCount) connected tenants |"
    Add-Line "| Steps / actions | $($c.steps) / $($c.actions) |"
    Add-Line "| Sequential waves | $($c.waves). The largest wave runs $($c.largestWave) steps in parallel |"
    Add-Line "| Lifecycle | $(Cell $project.lifecycle) |"
    Add-Line "| Guided failure | $(Cell $project.defaultGuidedFailureMode) |"
    Add-Line "| Skip unavailable targets | $(Cell $project.skipMachineBehavior) |"
    Add-Line "| Channels | $($c.channels) |"
    Add-Line

    # Collapse the process into blocks.
    $blocks = @(Get-Blocks $steps)
    $stepsWithTags = @($steps | Where-Object { (Get-ActionTags $_).Count -gt 0 }).Count
    $nonSuccess = @($steps | Where-Object { $_.runCondition -ne "Success" }).Count
    Add-Line "### Process at a glance"
    Add-Line
    Add-Line "$($steps.Count) steps collapse into **$($blocks.Count) blocks** of consecutive steps that share the same run condition, tenant tags, environment and channel scoping, and where they run. $stepsWithTags steps are gated by tenant tags and $nonSuccess run on a condition other than success."
    Add-Line

    Add-Line '```mermaid'
    Add-Line "flowchart TD"
    $i = 0
    foreach ($b in $blocks) {
        $i++
        $first = $b.Steps[0].number; $last = $b.Steps[$b.Steps.Count - 1].number
        $waves = @($b.Steps | ForEach-Object { $_.wave } | Sort-Object -Unique).Count
        $range = if ($first -eq $last) { "Step $first" } else { "Steps $first-$last" }
        $maxPar = ($b.Steps | ForEach-Object { $_.waveSize } | Measure-Object -Maximum).Maximum
        $label = "$range<br/>$($b.Steps.Count) step(s), $waves wave(s)"
        if ($maxPar -gt 1) { $label += ", up to $maxPar in parallel" }
        if ($b.Sig.Tags) { $label += "<br/>tags: $(Esc-Mermaid $b.Sig.Tags)" }
        $label += "<br/>runs on: $(Esc-Mermaid (Get-RunsOn-Text $b.Sig))"
        if ($b.Sig.Cond -ne "Success") { $label += "<br/>runs: $($b.Sig.Cond)" }
        Add-Line "  B$i[""$label""]"
    }
    for ($k = 1; $k -lt $blocks.Count; $k++) { Add-Line "  B$k --> B$($k + 1)" }
    $hasTags = @(); $hasCond = @()
    for ($k = 0; $k -lt $blocks.Count; $k++) {
        if ($blocks[$k].Sig.Tags) { $hasTags += "B$($k + 1)" }
        if ($blocks[$k].Sig.Cond -ne "Success") { $hasCond += "B$($k + 1)" }
    }
    Add-Line "  classDef tagged fill:#fde9c9,stroke:#c77700,color:#222"
    Add-Line "  classDef conditional fill:#f9d0d0,stroke:#b33,color:#222"
    if ($hasTags.Count -gt 0) { Add-Line "  class $($hasTags -join ',') tagged" }
    if ($hasCond.Count -gt 0) { Add-Line "  class $($hasCond -join ',') conditional" }
    Add-Line '```'
    Add-Line
    Add-Line "Orange blocks are gated by tenant tags. Red blocks run on a condition other than success."
    Add-Line

    Add-Line "| Block | Steps | Count | Waves | Largest wave | Runs on | Run condition | Gating |"
    Add-Line "|---|---|---|---|---|---|---|---|"
    $i = 0
    foreach ($b in $blocks) {
        $i++
        $first = $b.Steps[0].number; $last = $b.Steps[$b.Steps.Count - 1].number
        $waves = @($b.Steps | ForEach-Object { $_.wave } | Sort-Object -Unique).Count
        $maxPar = ($b.Steps | ForEach-Object { $_.waveSize } | Measure-Object -Maximum).Maximum
        Add-Line "| B$i | $first-$last | $($b.Steps.Count) | $waves | $maxPar | $(Cell (Get-RunsOn-Text $b.Sig)) | $(Cell $b.Sig.Cond) | $(Cell (Get-Gating-Text $b.Sig)) |"
    }
    Add-Line

    # Tenant tag gating.
    Add-Line "### Tenant tag gating"
    Add-Line
    if ($stepsWithTags -eq 0) {
        Add-Line "No step is gated by tenant tags."
        Add-Line
    }
    else {
        Add-Line "A step with tags runs for a tenant when, for every tag set the step names, the tenant has at least one of that set's tags (OR within a tag set, AND across tag sets)."
        Add-Line
        $combos = @{}
        foreach ($s in $steps) {
            foreach ($a in @($s.actions)) {
                $key = (@($a.tenantTags) | Sort-Object) -join " + "
                if ($key) { if (-not $combos.ContainsKey($key)) { $combos[$key] = 0 }; $combos[$key]++ }
            }
        }
        Add-Line "| Tag combination | Actions | Tenants that match |"
        Add-Line "|---|---|---|"
        foreach ($key in ($combos.Keys | Sort-Object { -$combos[$_] }, { $_ })) {
            $tags = @($key -split " \+ ")
            $matching = @($tenantItems | Where-Object { Test-TagsMatch $tags @($_.tags) }).Count
            Add-Line "| $(Cell (Format-TagExpr $tags)) | $($combos[$key]) | $matching of $($tenantItems.Count) |"
        }
        Add-Line

        if ($tenantItems.Count -gt 0) {
            $perTenant = @($tenantItems | ForEach-Object {
                    $t = $_; $tags = @($t.tags)
                    [pscustomobject]@{ Tenant = $t.name; Tags = $tags.Count; Steps = @($steps | Where-Object { Test-StepRunsForTenant $_ $tags }).Count }
                })
            $stepCounts = @($perTenant | ForEach-Object { $_.Steps } | Sort-Object)
            $median = $stepCounts[[int][math]::Floor(($stepCounts.Count - 1) / 2)]
            Add-Line "Steps that run for a tenant, out of $($steps.Count): fewest $($stepCounts[0]), median $median, most $($stepCounts[-1])."
            Add-Line
            if ($perTenant.Count -le 25) {
                Add-Line "| Tenant | Tags | Steps that run |"
                Add-Line "|---|---|---|"
                foreach ($row in $perTenant) { Add-Line "| $(Cell $row.Tenant) | $($row.Tags) | $($row.Steps) |" }
                Add-Line
            }
            else {
                $buckets = $stepCounts | Group-Object { [int][math]::Floor($_ / 10) * 10 } | Sort-Object { [int]$_.Name }
                Add-Line "| Steps that run | Tenants |"
                Add-Line "|---|---|"
                foreach ($g in $buckets) { Add-Line "| $($g.Name)-$([int]$g.Name + 9) | $($g.Count) |" }
                Add-Line
            }
        }
    }

    # Channels and lifecycle.
    Add-Line "### Channels"
    Add-Line
    Add-Line "| Channel | Default | Lifecycle | Tenant tags | Version rules |"
    Add-Line "|---|---|---|---|---|"
    foreach ($ch in @($project.channels)) {
        Add-Line "| $(Cell $ch.name) | $(if ($ch.isDefault) { 'yes' } else { '' }) | $(Cell $ch.lifecycle) | $(Cell (Format-TagExpr $ch.tenantTags)) | $(@($ch.rules).Count) |"
    }
    Add-Line

    $lifecycleNames = @($project.lifecycle) + @($project.channels | ForEach-Object { $_.lifecycle })
    foreach ($lc in @($m.lifecycles | Where-Object { $lifecycleNames -contains $_.name })) {
        Add-Line "**$($lc.name)** phases, in order:"
        Add-Line
        $n = 0
        $phaseTexts = @($lc.phases | ForEach-Object {
                $n++
                $must = if ($_.minimumEnvironmentsBeforePromotion -gt 0) { ", $($_.minimumEnvironmentsBeforePromotion) must pass" } else { "" }
                $opt = if ($_.isOptional) { ", optional" } else { "" }
                "$n. $((@($_.environments)) -join ' or ')$must$opt"
            })
        foreach ($t in $phaseTexts) { Add-Line "$t" }
        Add-Line
    }

    # Parallelism and packages.
    Add-Line "### Parallelism and packages"
    Add-Line
    $waveSizes = @($steps | Group-Object { $_.wave } | ForEach-Object { $_.Count })
    $dist = $waveSizes | Group-Object | Sort-Object { [int]$_.Name }
    Add-Line "| Steps in a wave | Waves |"
    Add-Line "|---|---|"
    foreach ($g in $dist) { Add-Line "| $($g.Name) | $($g.Count) |" }
    Add-Line
    $pkgActions = @($steps | ForEach-Object { $_.actions } | Where-Object { @($_.packages).Count -gt 0 })
    $acq = @($steps | Where-Object { $_.packageRequirement -ne "LetOctopusDecide" } | Group-Object packageRequirement | ForEach-Object { "$($_.Name): $($_.Count)" })
    Add-Line "Actions with packages: $($pkgActions.Count). Package acquisition setting other than the default: $(Join-Or $acq 'none')."
    $retries = @($steps | ForEach-Object { $_.actions } | Where-Object { $null -ne $_.autoRetry })
    Add-Line "Actions with automatic retry: $($retries.Count)."
    $kinds = @($steps | ForEach-Object { $_.actions } | Group-Object actionType | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) ($($_.Count))" })
    Add-Line "Action types: $(Join-Or $kinds)."
    $multi = @($steps | Where-Object { @($_.actions).Count -gt 1 }).Count
    if ($multi -gt 0) { Add-Line "Steps with more than one action: $multi." }
    $child = @($steps | ForEach-Object { $_.actions } | Where-Object { $_.deploysChildProject }).Count
    if ($child -gt 0) { Add-Line "Child deployments (a step that deploys another project): $child." }
    Add-Line

    # Output variables and variables.
    Add-Line "### Output variables and variables"
    Add-Line
    $ov = @($project.outputVariables)
    $cross = @($ov | Where-Object { $_.consumer -and $_.producer -ne $_.consumer })
    Add-Line "Output variable links: $($ov.Count) rows, of which $($cross.Count) connect one step to a different step. These add order dependencies."
    $vs = $project.variableStructure
    if ($null -ne $vs) {
        $scopes = @($vs.countByScopeType.PSObject.Properties | ForEach-Object { "$($_.Name) ($($_.Value))" })
        Add-Line
        Add-Line "Project variables: $($vs.projectVariableCount) ($($vs.promptedCount) prompted, $($vs.sensitiveCount) sensitive, $($vs.referencingStepOutput) referencing step output). Scoped variables: $($vs.scopedCount). Scope types used: $(Join-Or $scopes)."
    }
    Add-Line

    # Telemetry.
    $tel = if ($null -ne $m.telemetry) { Get-Prop $m.telemetry $project.name } else { $null }
    if ($null -ne $tel) {
        Add-Line "### Deployment history"
        Add-Line
        $o = $tel.outcomes
        Add-Line "Since $($tel.windowStartLocal): **$($tel.deploymentCount) deployments**. $($o.pass) passed ($(Percent $o.pass $tel.deploymentCount)), $($o.fail) failed ($(Percent $o.fail $tel.deploymentCount)), $($o.canceled) canceled, $($o.inProgress) still running."
        Add-Line
        Add-Line "- Nights with deployments: $($tel.nights.count). Nights with at least one failure: $($tel.nights.withAtLeastOneFailure). Busiest night: $($tel.nights.maxDeployments) deployments. A night runs noon to noon."
        Add-Line "- Redeployments of the same release to the same tenant and environment after a failure: $($tel.redeploysAfterFailure)."
        Add-Line "- Failures whose error text looks like a connectivity problem: $($tel.failuresLookLikeConnectivity). This is a rough keyword hint, and the error text itself is never exported."
        $d = $tel.durationSeconds
        if ($null -ne $d.allCompleted -and $d.allCompleted.count -gt 0) {
            Add-Line
            Add-Line "| Duration | Count | p50 | p90 | p99 | Max |"
            Add-Line "|---|---|---|---|---|---|"
            foreach ($row in @(@("All completed", $d.allCompleted), @("Passed", $d.pass), @("Failed", $d.fail))) {
                $x = $row[1]
                if ($null -ne $x -and $x.count -gt 0) { Add-Line "| $($row[0]) | $($x.count) | $(Format-Duration $x.p50) | $(Format-Duration $x.p90) | $(Format-Duration $x.p99) | $(Format-Duration $x.max) |" }
            }
        }
        $all = @($tel.startHourHistogram.all); $failed = @($tel.startHourHistogram.failed)
        if ($all.Count -eq 24) {
            $max = ($all | Measure-Object -Maximum).Maximum
            Add-Line
            Add-Line "Start hour (machine time zone), deployments and failures:"
            Add-Line
            Add-Line '```'
            for ($h = 0; $h -lt 24; $h++) {
                if ($all[$h] -gt 0) { Add-Line ("{0:00}:00  {1,-30} {2} ({3} failed)" -f $h, (Get-Bar $all[$h] $max), $all[$h], $failed[$h]) }
            }
            Add-Line '```'
        }
        $perTenantTel = @($tel.perTenant)
        if ($perTenantTel.Count -gt 0) {
            $worst = @($perTenantTel | Sort-Object { -$_.failures }, { -$_.deployments } | Select-Object -First 10)
            Add-Line
            Add-Line "Tenants with the most failures (top $($worst.Count) of $($perTenantTel.Count)):"
            Add-Line
            Add-Line "| Tenant | Deployments | Failures | Redeploys after failure |"
            Add-Line "|---|---|---|---|"
            foreach ($t in $worst) { Add-Line "| $(Cell $t.tenant) | $($t.deployments) | $($t.failures) | $($t.redeploysAfterFailure) |" }
        }
        Add-Line
    }

    # Full step table.
    Add-Line "<details>"
    Add-Line "<summary>Full step table ($($steps.Count) steps)</summary>"
    Add-Line
    Add-Line "| # | Step | Wave | Condition | Runs on | Tags | Environments | Channels | Packages | Flags |"
    Add-Line "|---|---|---|---|---|---|---|---|---|---|"
    foreach ($s in $steps) {
        foreach ($a in @($s.actions)) {
            $flags = @()
            if ($a.isDisabled) { $flags += "disabled" }
            if ($a.isRequired) { $flags += "required" }
            if ($s.parallelWithPrevious) { $flags += "parallel" }
            if ($null -ne $a.autoRetry) { $flags += "retry x$($a.autoRetry.maximumCount)" }
            if ($a.deploysChildProject) { $flags += "child deployment" }
            if ($a.isProcessTemplate) { $flags += "template" }
            $runs = if (@($s.targetRoles).Count -gt 0) { "$($a.runsOn) ($((@($s.targetRoles)) -join ', '))" } else { "$($a.runsOn)" }
            $cond = if ($s.runCondition -eq "Variable") { "expression" } else { $s.runCondition }
            $label = if (@($s.actions).Count -gt 1) { "$($a.label) $($a.name)" } else { "$($s.number) $($a.name)" }
            Add-Line "| $($a.label) | $(Cell $a.name) | $($s.wave) | $cond | $(Cell $runs) | $(Cell (Format-TagExpr $a.tenantTags)) | $(Cell (Join-Or $a.environments '')) | $(Cell (Join-Or $a.channels '')) | $(@($a.packages).Count) | $(Cell (Join-Or $flags '')) |"
        }
    }
    Add-Line
    Add-Line "</details>"
    Add-Line
}

# Target inventory.
$t = $m.targets
if ($null -ne $t -and $t.count -gt 0) {
    Add-Line "## Deployment targets"
    Add-Line
    $health = @($t.byHealthStatus.PSObject.Properties | ForEach-Object { "$($_.Name) ($($_.Value))" })
    $style = @($t.byCommunicationStyle.PSObject.Properties | ForEach-Object { "$($_.Name) ($($_.Value))" })
    $part = @($t.byParticipation.PSObject.Properties | ForEach-Object { "$($_.Name) ($($_.Value))" })
    Add-Line "$($t.count) targets, $($t.disabledCount) disabled. Communication: $(Join-Or $style). Participation: $(Join-Or $part). Health: $(Join-Or $health)."
    Add-Line
    Add-Line "| Role or tag | Targets |"
    Add-Line "|---|---|"
    foreach ($p in @($t.byRoleOrTag.PSObject.Properties | Sort-Object { -$_.Value }, Name)) { Add-Line "| $(Cell $p.Name) | $($p.Value) |" }
    Add-Line
    Add-Line "| Environment | Targets |"
    Add-Line "|---|---|"
    foreach ($p in @($t.byEnvironment.PSObject.Properties | Sort-Object { -$_.Value }, Name)) { Add-Line "| $(Cell $p.Name) | $($p.Value) |" }
    Add-Line
    $per = @($t.perTenant)
    if ($per.Count -gt 0) {
        $counts = @($per | ForEach-Object { $_.targets } | Sort-Object)
        $median = $counts[[int][math]::Floor(($counts.Count - 1) / 2)]
        Add-Line "Targets per tenant ($($per.Count) tenants with targets): fewest $($counts[0]), median $median, most $($counts[-1])."
        Add-Line
    }
}

Add-Line "---"
Add-Line "Generated by New-ProcessReport.ps1 from the model above. Open questions and known gaps are listed in the project README."

Set-Content -LiteralPath $OutputPath -Value $out.ToString() -Encoding utf8
Write-Host "Report written to $OutputPath"
