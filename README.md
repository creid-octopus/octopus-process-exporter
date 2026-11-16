# Octopus process export

Scripts that read the structure of your Octopus Deploy deployment processes and write it to files you can review and share. The output is anonymized by default, so it is safe to hand to someone who needs to understand the shape of a process (for example, to build a realistic test copy of it) without seeing your names, scripts or variable values.

The export only reads. Every request it sends is an HTTP `GET`, and it does not change anything in Octopus.

## Contents

* [What is in this repo](#what-is-in-this-repo)
* [What you need](#what-you-need)
* [Permissions](#permissions)
* [Get the scripts](#get-the-scripts)
* [Create the view-only user role (optional)](#create-the-view-only-user-role-optional)
* [Run the export](#run-the-export)
* [What you get](#what-you-get)
* [What is and is not collected](#what-is-and-is-not-collected)
* [Review before sending](#review-before-sending)
* [Read the report](#read-the-report)
* [Known limitations](#known-limitations)
* [Revoking access](#revoking-access)

## What is in this repo

| File | What it does | Writes to Octopus? |
|---|---|---|
| `Export-OctopusProcesses.ps1` | Reads processes, tenants, tag sets, targets and (optionally) deployment history, and writes the export files | No, `GET` only |
| `New-OctopusExportRole.ps1` | Creates a user role with only the permissions the export needs, and a team in one space | **Yes**, run it as an administrator |
| `New-ProcessReport.ps1` | Turns the exported model into a readable Markdown report. Works offline | No, never contacts Octopus |
| `tests/Test-Privacy.ps1` | Checks an export for leaked names, secrets and script text | No, `GET` only |

## What you need

* PowerShell 7 or later (`pwsh`). Windows PowerShell 5.1 is not supported.
* Network access to your Octopus Server from the machine that runs the scripts.
* An API key for a user with view-only access to the space. See [Permissions](#permissions).
* Octopus Server 2025.4 or later. If you run more than one instance, run the export once for each and keep track of which export came from which.

## Permissions

Create a dedicated user, or a team with a custom user role, scoped to the one space. Give it only these permissions:

| Permission | Why the script needs it |
|---|---|
| `SpaceView` (system permission) | Find the space by name |
| `ProjectView`, `ProcessView` | Read projects, steps and channels |
| `VariableView`, `VariableViewUnscoped` | Count variables and find output variable names. Values are never exported |
| `EnvironmentView`, `LifecycleView` | Environments and promotion phases |
| `TenantView` | Tenants and tag sets (tenants are anonymized) |
| `MachineView`, `WorkerView` | Target and worker pool inventory (names and addresses are never exported) |
| `FeedView` | Package feed types |
| `ActionTemplateView` | Only with `-KeepNames Template`, to read step template names |
| `DeploymentView`, `ReleaseView`, `TaskView` | Only for `-IncludeTelemetry` |

If a permission is missing, the script reports a warning for that section and carries on. Targets, tag sets, tenants and worker pools are optional, so the export is still useful without them. Spaces, projects, the process, environments, feeds and lifecycles are required, and the script stops with an error if it cannot read them.

`New-OctopusExportRole.ps1` creates this role for you. See below.

## Get the scripts

Clone the repo, or download the files and keep the folder layout (`tests/Test-Privacy.ps1` stays in `tests/`):

```powershell
git clone <this repository's URL>
cd <repository folder>
```

## Create the view-only user role (optional)

`New-OctopusExportRole.ps1` creates a user role with only the permissions above, and a team in the one space you name. It writes to Octopus, so run it as an administrator. It does not create users or API keys. Use `-WhatIf` first to see what it would do.

```powershell
$env:OCTOPUS_API_KEY = "API-XXXXXXXX"    # an administrator's key, for this script only
$url   = "https://octopus.example.com"
$space = "Default"

./New-OctopusExportRole.ps1 -OctopusUrl $url -SpaceName $space -WhatIf
./New-OctopusExportRole.ps1 -OctopusUrl $url -SpaceName $space -UserName "jsmith"
```

`-UserName` adds an existing user (by username or email) to the team. Add `-WithoutTelemetry` to leave out the deployment permissions, or `-IncludeTemplateNames` for `-KeepNames Template`. You can run the script again at any time. It updates what it created and never deletes anything.

When it finishes, it prints whichever of these links you still need, with your server address filled in. If you pass `-UserName` for a user who exists, the script adds them to the team and only the API key step remains:

1. Create a user or service account: `https://<your-octopus>/app#/configuration/users/create`
2. Add that user to the team, on the team's page: `https://<your-octopus>/app#/configuration/teams/<team id>`
3. Create an API key for that user (profile menu, My API Keys).

## Run the export

Run it from a PowerShell 7 prompt. Running `pwsh ./Export-OctopusProcesses.ps1 ...` from another shell also works. Write list values with commas and no spaces, for example `-KeepNames Environment,Channel`.

Use the view-only user's key this time, not the administrator's:

```powershell
$env:OCTOPUS_API_KEY = "API-XXXXXXXX"    # the view-only user's key
$url   = "https://octopus.example.com"
$space = "Default"
```

**Every project in the space, no telemetry**

```powershell
./Export-OctopusProcesses.ps1 -OctopusUrl $url -SpaceName $space
```

**One project, no telemetry**

```powershell
./Export-OctopusProcesses.ps1 -OctopusUrl $url -SpaceName $space -ProjectName "Your Project Name"
```

**One project, with telemetry**

Telemetry summarizes the last 6 months of deployments: outcomes, start hours, durations and redeployments after a failure. It requires `-ProjectName`, so the script only scans the projects you choose.

```powershell
./Export-OctopusProcesses.ps1 -OctopusUrl $url -SpaceName $space -ProjectName "Your Project Name" -IncludeTelemetry
```

Change the window with `-TelemetryMonths 3`.

**Several projects**

```powershell
./Export-OctopusProcesses.ps1 -OctopusUrl $url -SpaceName $space -ProjectName "Project A","Project B" -IncludeTelemetry
```

**Keep some real names so the output is easier to read**

```powershell
./Export-OctopusProcesses.ps1 -OctopusUrl $url -SpaceName $space -ProjectName "Your Project Name" -KeepNames Environment,Channel
```

Choose from `Project`, `Step`, `Environment`, `Channel`, `Lifecycle`, `Role`, `Package`, `Feed`, `Template`, `WorkerPool` and `TagSet`.

Other options:

| Option | What it does |
|---|---|
| `-OutputFolder ./my-export` | Choose where the files go. The script prints where it wrote them |
| `-AliasMapPath ./anonymization-map.csv` | Reuse the aliases from an earlier export, so exports from different days compare cleanly |
| `-NoAnonymize` | Keep every real name. For internal use only. Do not share this output |

Telemetry is the slow part, because it pages through every deployment in the window.

## What you get

| File | In the zip? | What it holds |
|---|---|---|
| `process-model.json` | Yes | Steps, actions, run conditions, tenant tag gating, waves, channels, lifecycles, tag sets, target inventory |
| `steps.csv` | Yes | One row per step action, the same data as a spreadsheet |
| `targets.csv` | Yes | One row per target: roles, tags, environments, tenant count. No names or addresses |
| `telemetry-deployments.csv` | Yes, with `-IncludeTelemetry` | One row per deployment: outcome, start hour, duration |
| `anonymization-map.csv` | **No** | Alias to real name. Keep it, it lets you read questions about "Step-012" |
| `<output folder>.zip` | | The files to send |

## What is and is not collected

Collected: the structure of the process, and counts and timings.

Never collected: script bodies, variable values, error text, deployment logs, target names or addresses, API keys, or release notes.

Anonymized by default: project, step, tenant, environment, channel, lifecycle, role, package, feed, template, worker pool, tag set and tag names are replaced by stable aliases such as `Step-012` and `Tenant-004`. Run conditions keep their structure, and string values in them become `<literal>`.

Keep some real names if you are comfortable with that and want them to be easier to read, for example `-KeepNames Environment,Channel`. Tenant, variable and release names are always replaced.

## Review before sending

1. Optional: run `./New-ProcessReport.ps1 -Model <export folder>` to turn the model into `process-report.md`, a readable summary of exactly what is in the files. It works offline, and its output is not part of the zip. Then open `process-model.json` and `steps.csv` and read them. Search for anything you would not want shared, such as a customer name, a server name or a password.
2. If you find something, do not send the zip until it is resolved.
3. Optionally, run the privacy check: `./tests/Test-Privacy.ps1 -Export <zip> -OctopusUrl <url> -ApiKey <key> -SpaceName <space> -ScriptPath ./Export-OctopusProcesses.ps1`. It looks for your real names and common secret patterns in the zip, and with `-ScriptPath` it also checks that the export script sends only `GET` requests.
4. Send only the zip. Never send `anonymization-map.csv`.

## Read the report

`New-ProcessReport.ps1` reads `process-model.json` and writes `process-report.md` next to it:

```powershell
./New-ProcessReport.ps1 -Model ./octopus-process-export-20260101-120000
```

The report holds, for each project:

* A summary: process source, step, action and wave counts, lifecycle and channels.
* A Mermaid diagram of the process, with runs of consecutive steps that share the same gating collapsed into one block, and a table of those blocks.
* Tenant tag gating: each tag combination, how many tenants match, and how many steps each tenant runs. A step runs for a tenant when, for every tag set the step names, the tenant has at least one of that set's tags (OR within a tag set, AND across tag sets).
* Channels, lifecycle phases, parallelism, packages, output variable links and variable structure.
* Deployment history, when the export included telemetry.
* The target inventory, and a collapsible table of every step.

Every number comes from the model. The report adds no names that the model does not hold.

## Known limitations

* A step that uses a process template shows as a single `Octopus.ProcessTemplate` action. The export cannot see the steps inside.
* Scripts stored inside packages are invisible, so output variable dependencies from those scripts are missing.
* Channel version rules and pre-release tag patterns are exported as written. A pattern can reveal a name, so check them before you send.
* Releases are aliased by release ID, not version number. The alias map maps them back.
* Deployment times use the time zone of the machine that runs the export.
* Octopus does not record why a deployment failed, so the export only counts failures. A keyword check on error text gives a rough hint for connectivity problems, and the error text itself is never exported.
* Project names that contain a comma cannot be selected with `-ProjectName`, because the script splits the value on commas.
* A step that deploys another project (a child deployment) is reported but has not been tested.
* Tested against Octopus Server 2026.4 with PowerShell 7. Other versions and Windows PowerShell 5.1 are not tested.

## Revoking access

Delete the API key (or the user and the team) when you are done.
