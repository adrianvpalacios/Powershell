<# 
.SYNOPSIS 
A quick health checker to verify that IIS App Pools are running

.DESCRIPTION 
Utilising PowerShell jobs and WMIC, this script should parse IIS servers in AD,
and check the App Pools are running. Return any app pools which are stopped, and push to Teams webhook.

.EXAMPLE 
.\Get-AppPoolHealth.ps1

.NOTES 
This script is designed to be self-contained and, aside from setting AD variables in the header, should require
no interaction from the user.
#>

# Set general Script variables here
$namefilter = "*IIS*"
$maxJobs = 25
$webhookurl = "{redacted}"
$json = New-Object PSCustomObject
#Get list of Computers from AD : filter 'Name like "SERVER*"'
$computers = Get-ADComputer -filter 'Name -like $namefilter' | Where-Object { $PSItem.name -notlike "*-*" `
    -and $PSItem.name -notlike "{redacted}*" `
    -and $PSItem.name -notlike "{redacted}*" `
    -and $PSItem.name -notlike "*SMTP*" `
    -and $PSItem.name -notlike "*PRX*" `
    -and $PSItem.name -notlike "*TOW*" `
    } | `
    Select-Object Name | Sort-Object Name

#Create a function to generate the Messagecard JSON for Teams
function Generate-JsonPayload {
    Param(
        [String] $summary,
        [String] $title,
        [string] $text,
        [string] $facts
    )
    $date = "$(Get-Date -Format g) UTC"
    @"
{
	"@type": "MessageCard",
	"@context": "https://schema.org/extensions",
	"summary": "$($summary)",
	"themeColor": "ffe600",
	"title": "$($summary)",
	"sections": [
		{
            "activityTitle": "$($title)",
			"activitySubtitle": "$($date)",
            "text": "$($text)",
            "facts": $facts
        }
	]
}
"@

}

# Main logic to check the App Pools
foreach ($Computer in $computers) {

    # Have we hit the maximum number of concurrent jobs?
    if ( (Get-Job).Count -eq $maxJobs ) {
        Write-Host "Waiting on queued jobs to finish..." -ForegroundColor Yellow
        $jobs += Get-Job | Receive-Job -AutoRemoveJob -Wait
    }

    Write-Host "Sending job to $($Computer.name)"

    Invoke-Command -AsJob -ComputerName $computer.name -ScriptBlock { Get-IISAppPool | where-object { $_.name -like "R2*" -and $_.state -ne "Started"} | Select Name,State }
    
}
# Get any remaining jobs, otherwise they sit in limbo
$jobs += Get-Job | Wait-Job | Receive-Job

# If we received any App Pools, then we need to report it. Otherwise, no point creating an alert with no data.
if ($jobs.Length -ge 1) {

    $facts1 = ConvertTo-Json -Inputobject @( foreach($j in $jobs) {
        [PSCustomObject]@{
            Name = $j.PSComputerName
            Value = "$($j.Name) | $(($j.State).Value)"
        }
    })

    $splat = @{
        Summary = "App Pool health check!"
        Title = "App Pools which are stopped"
        Text = "The following IIS app pools are stopped."
        Facts = $facts1
    }
    

    $json = Generate-JsonPayload @splat

    Invoke-RestMethod -Method post -ContentType 'Application/Json' -Body $json -Uri $webhookurl
}