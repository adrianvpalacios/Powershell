# This function will use the template file, and replace [ResourceGroup] and [Prefix] values to generate a JSON you can upload in Azure Dashboards.
Function New-JSONTemplate() {
    $template = Get-Content -Path "$PSScriptRoot\Templates\Server Stats.json"
    $new_json = "$($lookuptable['[Prefix]']) Server Stats.json"
    $template | ForEach-Object {
        $line = $_
        $lookupTable.GetEnumerator() | ForEach-Object {
            if ($line -match $_.Key)
            {
                $line = $line.Replace($_.Key, $_.Value)
            }
        }
        $line
    } | Set-Content -Path $new_json
}

# Prompt for the Resource Group and generate our lookup table
$resourceGroup = (Read-Host "What is the resource group name?").ToUpper()

$lookupTable = @{
    '[ResourceGroup]' = $resourceGroup
    '[Prefix]' = $resourceGroup.SubString(0,$resourceGroup.Length-5)
}

# Invoke the main function
New-JSONTemplate