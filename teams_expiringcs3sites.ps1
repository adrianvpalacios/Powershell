<# 
.SYNOPSIS 
A scheduled script to check the certs on IIS servers for expiration dates. It also checks external 

.DESCRIPTION 
This script grabs all of the IIS01 servers in AD, and then connects to each and checks the certs in the local cert manager. They need to be imported there for IIS to bind sites, and should be fairly accurate.
This is meant to supplement the master list which is in Sharepoint.

.EXAMPLE 
.\teams_expiringcs3sites.ps1

.NOTES 
This script is designed to be self-contained and, aside from setting AD variables in the header, should require
no interaction from the user.

Ideally will be run as a scheduled task.
#>
# Set maximum number of jobs to run in parralel
$maxJobs = 50
# Set the namefilter to IIS servers
$namefilter = "*IIS01"
# Set how many days out to alert on expiration
$daysToExpiration = 20
# External URIs to check cert expiration
$uri = @(
    "https:\\website1.com"
    "https:\\website2.com"
    "https:\\website3.com"
    "https:\\website4.com"
)
$webhookurl = "{redacted}"
$json = New-Object PSCustomObject

# Create a function to check cert expirations for sites we don't have backend access to
Function Check-ExternalCerts() {
    Param ($uri)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Set the expiration date for certs
    $expirationDate = (Get-Date).AddDays($daysToExpiration)
    
    # Loop through each of our URIs
    $certs = @(foreach ($u in $uri) {
        # Create a new web request in .NET and request just the HEAD; this limits the size of response we need to handle, as we are
        # going to just dispose of it anyway.
        $request = [Net.HttpWebRequest]::Create($u)
        $request.Method = "HEAD"
        try {
            # Dispose of the response, we don't need it
            $request.GetResponse().Dispose()
        }
        # Catch any exceptions
        catch [System.Net.WebException] {
            if ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::TrustFailure) {
                # We want to notate a trust failure, because this should never happen
                [PSCustomObject] @{
                    Site = $u
                    Expiration = "(NotTrusted) $($request.ServicePoint.Certificate.GetExpirationDateString())"
                }
            }
            else {
                #Note that this site errored, then continue
                [PSCustomObject] @{
                    Site = $u
                    Expiration = "No response (bad site url?)"
                }
                Continue
            }
        }
        # If cert expires in the next several days, add to PSObject
        if ([datetime]$request.ServicePoint.Certificate.GetExpirationDateString() -lt $expirationDate) {
            [PSCustomObject]@{
                Site = $u
                Expiration = $request.ServicePoint.Certificate.GetExpirationDateString()
            }
        }
    })
    $certs
}

# Create a function to check cert expirations from the IIS backend servers directly
Function Get-ExpiringCerts() {
    $expiration = @()
    $daysToExpiration = 20
    # Need to import this module to interact with the IIS: PSDrive
    Import-Module WebAdministration
    
    # We only want to get certs for sites that are running. There may be sites which are not running that we don't care about.
    $sites = Get-Website | Where-Object { $_.State -eq "Started" } | ForEach-Object { $_.Name }
    $certs = Get-ChildItem IIS:SSLBindings | Where-Object { $sites -contains $_.Sites.Value }  | ForEach-Object { $_.Thumbprint }
    $expirationDate = (Get-Date).AddDays($daysToExpiration)

    Get-ChildItem Cert:\LocalMachine/My | Where-Object { $certs -contains $_.Thumbprint  -and $_.NotAfter -lt $expirationDate } | ForEach-Object { $expiration += [PSCustomObject] @{ SiteName= $_.SubjectName.Name.Split(',')[0].TrimStart('CN='); Expiration = $_.NotAfter}}
    
    # Return our custom object so that the Job can feed the results back out
    $expiration
}

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
	"@context": "https:\\website.comensions",
	"summary": "$($summary)",	"themeColor": "ffe600",
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

#Get list of Computers from AD : filter 'Name like "SERVER*"'
$computers = Get-ADComputer -filter 'Name -like $namefilter' | Where-Object { $PSItem.name -notlike "*-*" `
    -and $PSItem.name -notlike "*SMTP*" `
    -and $PSItem.name -notlike "*PRX*" `
    -and $PSItem.name -notlike "*TOW*" `
    } | Select-Object Name | Sort-Object Name

# Create jobs for each of our IIS servers
foreach ($Computer in $computers) {

    # Have we hit the max number of concurrent jobs?
    if ( (Get-Job).Count -eq $maxJobs ) {
        Write-Host "Waiting on queued jobs to finish..." -ForegroundColor Yellow
        $jobs += Get-Job | Receive-Job -AutoRemoveJob -Wait
    }

    Write-Host "Sending job to $($Computer.name)"


    Invoke-Command -AsJob -ComputerName $computer.name -ScriptBlock ${Function:Get-ExpiringCerts}
}

# Get the results of any leftover jobs
$jobs += Get-Job | Receive-Job -AutoRemoveJob -Wait

# If jobs have returned any certs that are expiring soon, push an alert to Teams
if ($jobs.Length -ge 1) {

    $facts = ConvertTo-Json -Inputobject @( foreach($j in $jobs) {
        [PSCustomObject]@{
            Name = $j.PSComputerName
            Value = "$($j.SiteName) | $(($j.Expiration))"
        }
    })

    # Splat the parameters for the JSON Payload
    $splat = @{
        Summary = "Internal TLS Cert Expirations"
        Title = "List of TLS certs due to expire in the next $($daysToExpiration) days."
        Text = "This is a list of all internal URLs with TLS certificates coming up for expiration. Please check for new certs, or request a new one."
        Facts = $facts
    }

    # Generate the payload, and push to Teams
    $json = Generate-JsonPayload @splat
    Invoke-RestMethod -Method post -ContentType 'Application/Json' -Body $json -Uri $webhookurl
}

# Check the external URIs for expirations
$certs = Check-ExternalCerts $uri

# If any external certs are expiring soon, push an alert to Teams
if ($certs) {

    $facts = ConvertTo-Json -InputObject @( foreach($c in $certs) {
        [PSCustomObject]@{
            Name = $c.Site
            Value = $c.Expiration
        }
    }

    )

    # Splat the parameters for the JSON payload
    $splat = @{
        Summary = "External TLS Cert Expirations"
        Title = "List of External TLS Certs due to expire in the next $($daysToExpiration) days."
        Text = "This is a list of all external URLs with TLS certificates coming up for expiration. Please check Venafi for new certs, or request a new one."
        Facts = $facts
    }

    # Generate the payload, and push to Teams
    $json = Generate-JsonPayload @splat
    Invoke-RestMethod -Method post -ContentType 'Application/Json' -Body $json -Uri $webhookurl
}