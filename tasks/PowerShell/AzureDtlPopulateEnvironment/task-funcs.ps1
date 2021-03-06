function Handle-LastError {
    [CmdletBinding()]
    param(
    )

    $message = $error[0].Exception.Message
    if ($message) {
        Write-Error "`n$message"
    }
}

function ConvertTo-Array {
    [CmdletBinding()]
    param (
        [parameter(ValueFromPipeline)]
        $value,

        [switch] $RemoveNull,
        [switch] $RemoveEmpty
    )
    
    begin { 
        $array = @()
    }
    process {
        $skip = ($RemoveNull -and $value -eq $null) -or ($RemoveEmpty -and $value -eq "")
        if (-not $skip) { $array += $value }
    }
    end { 
        return , $array
    }
}

function Show-InputParameters {
    [CmdletBinding()]
    param(
    )

    Write-Host "Task called with the following parameters:"
    Write-Host "  ConnectedServiceName = $ConnectedServiceName"
    Write-Host "  LabId = $LabId"
    Write-Host "  RepositoryId = $RepositoryId"
    Write-Host "  TemplateId = $TemplateId"
    Write-Host "  EnvironmentName = $EnvironmentName"
    Write-Host "  ParameterFile = $ParameterFile"
    Write-Host "  Parameters = [not displayed for security reasons]"
    Write-Host "  TemplateOutputVariables = $TemplateOutputVariables"
}

function Show-TemplateParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $templateId,
        [Parameter(Mandatory = $true)]
        [hashtable] $parameters
    )

    if ($parameters) {
        
        Write-Host "Creating Environment with parameters"
        $templateParameters = Get-TemplateParameters -templateId $templateId

        $parameters.Keys | ForEach-Object {

            $key = $_
            $type = $templateParameters | Where-Object { ($_.Name) -eq $key } | Select-Object -First 1 -ExpandProperty Type
            
            if ($type -like "secure*") {
                Write-Host "  $key [$type] = *****"
            } else {
                Write-Host "  $key [$type] = $($parameters[$key])"
            }
        }
    }
}

function Get-TemplateParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $templateId
    )

    $template = Get-AzureRmResource -ResourceId $templateId -ApiVersion '2016-05-15'
    $parameters = @()

    $template.Properties.contents.parameters | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object {

        $parameters += New-Object -TypeName psobject |  Add-Member -MemberType NoteProperty -Name "Name" -Value "$_" -PassThru |
                                                        Add-Member -MemberType NoteProperty -Name "UnifiedName" -Value "$($_ -replace ' ', '')" -PassThru |
                                                        Add-Member -MemberType NoteProperty -Name "Type" -Value "$($template.Properties.contents.parameters.$_.type)" -PassThru        

    }

    return $parameters
}

function Get-ParameterSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $path,
        [Parameter(Mandatory = $true)]
        [string] $templateId,
        [Parameter(Mandatory = $false)]
        [string] $overrides
    )

    $parameterSet = @{}

    if (Test-Path $path -PathType Leaf) {
        # reading parameters from parameters file
        try {
            $parameterObject = Get-Content -Path $path | Out-String | ConvertFrom-Json
            if ($parameterObject | Get-Member -MemberType NoteProperty -Name parameters -ErrorAction SilentlyContinue) {
                $parameterObject.parameters | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | % {
                    $parameterSet.Set_Item([string] $_, ($parameterObject.parameters | Select-Object -ExpandProperty $_).value)
                }
            } 
        }
        catch {
            throw "Failed to read parameter file '$path'. $($error[0].Exception.Message)"
        }
    }

    if ($overrides) {
        # reading paramteres from overrides string
        try {
            [regex]::Matches($overrides, '\-(?<k>\w+)\s+(?<v>[''"].*?[''"]|\(.*?\))') | % {
                $key = $_.Groups[1].Value
                $val = $_.Groups[2].Value.Trim("`"'")
                $parameterSet.Set_Item($key, $val)
            }
        }
        catch {
            throw "Failed to parse parameter string. $($error[0].Exception.Message)"
        }
    }

    if ($parameterSet.Count) {

        Write-Host "Clean up parameters"

        $templateParameters = Get-TemplateParameters -templateId $templateId | ConvertTo-Array
        $templateParameterNames = $templateParameters | Select-Object -ExpandProperty Name | ConvertTo-Array

        # handle template parameters with spaces
        $templateParameters | Where-Object {($_.Name) -ne ($_.UnifiedName) -and $parameterSet.ContainsKey($_.UnifiedName)} | ForEach-Object {
            Write-Host "  Mapping parameter '$($_.UnifiedName)' -> '$($_.Name)'"
            $parameterSet.Add($_.Name, $parameterSet[$_.UnifiedName])
        }

        # resolve parameters given but not needed by the template
        $unusedParameterNames = $parameterSet.Keys | Where-Object { $_ -notin $templateParameterNames } | ConvertTo-Array 

        # resolve parameters provided by the lab during provisioning
        $unusedParameterNames += ('_artifactsLocation', '_artifactsLocationSasToken') | Where-Object { $parameterSet.ContainsKey([string] $_) } | ConvertTo-Array

        # remove unused parameters
        $unusedParameterNames | ForEach-Object { 
            Write-Host "  Removing parameter '$_'"
            $parameterSet.Remove($_) 
        }
    }

    return $parameterSet
}

function Get-DevTestLabContextUserId {
    [CmdletBinding()]
    param(
    )

    [string] $userId = $((Get-AzureRmADUser -UserPrincipalName (Get-AzureRmContext).Account).Id.Guid)

    if ($userId) { return $userId }

    return [string] (Get-AzureRmADServicePrincipal -ServicePrincipalName ((Get-AzureRmContext).Account.Id -split '@')[0]).Id.Guid
}

function New-DevTestLabEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $labId,
        [Parameter(Mandatory = $true)]
        [string] $templateId,
        [Parameter(Mandatory = $true)]
        [string] $environmentName,
        [Parameter(Mandatory = $true)]
        [hashtable] $environmentParameterSet
    )

    $userId = Get-DevTestLabContextUserId

    $templateParameters = $environmentParameterSet.Keys | ForEach-Object { 
        if ($environmentParameterSet[$_] -is [array]) {
            @{ "name" = "$_"; "value" = "$($environmentParameterSet[$_] | ConvertTo-Json -Compress)" } 
        }
        else {
            @{ "name" = "$_"; "value" = "$($environmentParameterSet[$_])" } 
        }
    } | ConvertTo-Array

    $templateProperties = @{ "deploymentProperties" = @{ "armTemplateId" = "$templateId"; "parameters" = $templateParameters }; } 

    $lab = Get-AzureRmResource -ResourceId $labId
    $env = New-AzureRmResource -Location $lab.Location -ResourceGroupName $lab.ResourceGroupName -Properties $templateProperties -ResourceType 'Microsoft.DevTestLab/labs/users/environments' -ResourceName "$($lab.Name)/$userId/$environmentName" -ApiVersion '2016-05-15' -Force 
    
    return [string] $env.ResourceId
}

function Get-DevTestLabEnvironmentResourceGroupId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $environmentResourceId
    )

    $environment = Get-AzureRmResource -ResourceId $environmentResourceId  -ApiVersion '2016-05-15'

    return [string] $environment.Properties.resourceGroupId
} 

function Get-DevTestLabEnvironmentResourceGroupLocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $environmentResourceId
    )

    $environment = Get-AzureRmResource -ResourceId $environmentResourceId  -ApiVersion '2016-05-15'

    return [string] $environment.Location
}

function Test-DevTestLabEnvironmentOutputIsSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $templateId,
        [Parameter(Mandatory = $true)]
        [string] $key
    )

    $template = Get-AzureRmResource -ResourceId $templateId -ApiVersion '2016-05-15'
    
    try {
        return ($template.Properties.contents.outputs.$key.type -like "secure*")
    } catch {
        return $false
    }
}

function Get-DevTestLabEnvironmentOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $environmentResourceId
    )

    $resourceGroupId = Get-DevTestLabEnvironmentResourceGroupId -environmentResourceId $environmentResourceId
    $resourceGroupName = Split-Path $resourceGroupId -Leaf

    $hashtable = @{}
    $deployment = Get-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName | Select-Object -Last 1

    if ($deployment -and $deployment.Outputs) {
        $deployment.Outputs.Keys | ForEach-Object {
            $hashtable.Set_Item($_, $deployment.Outputs[$_].Value)
        }
    }

    return [hashtable] $hashtable
}

function ConvertTo-Optionals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $overrideParameters
    )

    $splitEntries = $overrideParameters.Split("-")
    $hashtable = @{}

    foreach ($entry in $splitEntries) {
        if ($entry -ne "") {
            $hashtable.Add($($entry.Split(" ",2)[0]),$($entry.Split(" ",2)[1]))
        }
    }   

    return [hashtable] $hashtable
}