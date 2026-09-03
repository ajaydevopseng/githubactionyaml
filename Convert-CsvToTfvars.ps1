<#
.SYNOPSIS
    Converts a CSV file describing resource groups into a terraform.tfvars file.

.DESCRIPTION
    Expected CSV columns (case-insensitive):
        name       - required. Resource group name.
        location   - required. Region/location.
        tags       - optional. Semicolon-separated key=value pairs,
                     e.g. "env=prod;owner=platform-team"

    Any additional columns are passed through as extra string attributes
    on each resource group object.

.PARAMETER CsvPath
    Path to the input CSV file.

.PARAMETER OutputPath
    Path to the output tfvars file. Defaults to .\terraform.tfvars

.EXAMPLE
    .\Convert-CsvToTfvars.ps1 -CsvPath .\resource_groups.csv -OutputPath .\terraform.tfvars
#>

[CmdletBinding()]
param(
    # Default input CSV path (absolute). EDIT THIS to match your setup,
    # or override at runtime with -CsvPath.
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "D:\devops\ado_classic_pipeline_31082026\poweshell%20script\resource_groups.csv",

    # Default output tfvars path (absolute). EDIT THIS to match your setup,
    # or override at runtime with -OutputPath.
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "D:\devops\ado_classic_pipeline_31082026\poweshell%20script\terraform.tfvars"
)

function ConvertTo-HclString {
    param([string]$Value)
    $escaped = $Value -replace '\\', '\\\\' -replace '"', '\"'
    return "`"$escaped`""
}

function ConvertFrom-TagString {
    param([string]$Raw)
    $tags = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $tags
    }
    foreach ($pair in $Raw -split ';') {
        $pair = $pair.Trim()
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        if ($pair -notmatch '=') {
            throw "Malformed tag entry (expected key=value): '$pair'"
        }
        $parts = $pair -split '=', 2
        $tags[$parts[0].Trim()] = $parts[1].Trim()
    }
    return $tags
}

# --- Validate input file ---
if (-not (Test-Path -Path $CsvPath -PathType Leaf)) {
    Write-Error "Input file '$CsvPath' does not exist."
    exit 1
}

$rows = Import-Csv -Path $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
    Write-Error "CSV file has a header but no data rows (or is empty)."
    exit 1
}

# Normalize column names (case-insensitive lookup)
$columns = $rows[0].PSObject.Properties.Name
$colMap = @{}
foreach ($c in $columns) { $colMap[$c.ToLower()] = $c }

if (-not $colMap.ContainsKey('name') -or -not $colMap.ContainsKey('location')) {
    Write-Error "CSV must contain at least 'name' and 'location' columns. Found columns: $($columns -join ', ')"
    exit 1
}

$nameCol     = $colMap['name']
$locationCol = $colMap['location']
$tagsCol     = if ($colMap.ContainsKey('tags')) { $colMap['tags'] } else { $null }

$skipCols = @($nameCol, $locationCol)
if ($tagsCol) { $skipCols += $tagsCol }

$entries = @()
$rowNum = 1
foreach ($row in $rows) {
    $rowNum++

    $name     = ($row.$nameCol     | Out-String).Trim()
    $location = ($row.$locationCol | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($location)) {
        Write-Error "Row $rowNum : 'name' and 'location' cannot be empty."
        exit 1
    }

    $attrs = [ordered]@{
        name     = $name
        location = $location
    }

    if ($tagsCol) {
        $attrs['tags'] = ConvertFrom-TagString -Raw $row.$tagsCol
    }

    foreach ($col in $columns) {
        if ($skipCols -contains $col) { continue }
        $val = ($row.$col | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($val)) { continue }
        $attrs[$col.ToLower()] = $val
    }

    $entries += , $attrs
}

# --- Build HCL output ---
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("resource_groups = {")

foreach ($attrs in $entries) {
    $key = $attrs['name']
    $lines.Add("  $(ConvertTo-HclString $key) = {")

    foreach ($k in $attrs.Keys) {
        $v = $attrs[$k]
        if ($v -is [System.Collections.Specialized.OrderedDictionary] -or $v -is [hashtable]) {
            if ($v.Count -eq 0) {
                $lines.Add("    $k = {}")
            } else {
                $lines.Add("    $k = {")
                foreach ($tk in $v.Keys) {
                    $lines.Add("      $(ConvertTo-HclString $tk) = $(ConvertTo-HclString $v[$tk])")
                }
                $lines.Add("    }")
            }
        } else {
            $lines.Add("    $k = $(ConvertTo-HclString $v)")
        }
    }

    $lines.Add("  }")
}

$lines.Add("}")

Set-Content -Path $OutputPath -Value ($lines -join "`n") -Encoding UTF8

Write-Host "Wrote $OutputPath"