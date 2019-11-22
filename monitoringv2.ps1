<# 
.SYNOPSIS 
A quick, job-based(hopefully) method of gathering metrics from member servers in AD.

.DESCRIPTION 
Utilising PowerShell jobs and WMIC, this script should parse servers in AD which begin with USSPFIDSK*,
and return CPU usage, Memory usage, disk response time, and other metrics.

.EXAMPLE 
.\monitoring.ps1

.NOTES 
This script is designed to be self-contained and, aside from setting AD variables in the header, should require
no interaction from the user.
#>


# Set maximum number of jobs to run in parralel
$maxJobs = 50
$maxLogSize = 10MB
# Define the main worker function
Function Get-ServerStats() {
    # This function uses a customobject to store various statistics for the server, and then returns a string for output to csv
    $stats = [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        Uptime = ""
        CpuIdle = ""
        MemFree = ""
        MemUtil = ""
        CDriveRemaining = ""
        CDrivePercent = ""
        FDriveRemaining = ""
        FDrivePercent = ""
        GDriveRemaining = ""
        GDrivePercent = ""
    }


    #Find and format the system uptime
    $stats.uptime = "{0:dd}d {0:hh}h {0:mm}m" -f ((Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime).LastBootUpTime)

    # Get CPU usage information
    #Get-WmiObject win32_processor | Measure-Object -property LoadPercentage -Average | Select Average
    $stats.CpuIdle = (Get-Counter '\Process(idle)\% Processor Time' | Select-Object -ExpandProperty countersamples | `
            Select-Object -Property instancename, cookedvalue| Sort-Object -Property cookedvalue -Descending| `
            Select-Object -First 20| Select-Object InstanceName,@{L='CPU';E={(($_.Cookedvalue/100/(Get-CimInstance -ClassName Win32_ComputerSystem).NumberOfLogicalProcessors)).toString('P')}}).Cpu
    

    # Memory usage
    $stats.MemFree = "{0:f2}" -f ((Get-Counter '\Memory\Available MBytes' | Select-Object -ExpandProperty CounterSamples).CookedValue / 1024)

    $totalRam = [math]::Round((Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $stats.MemUtil = "{0:n1}" -f (($totalRam - $stats.MemFree) / $totalRam)

    # Get free space for C:, F:, and G: drives
    $drives = Get-WmiObject win32_logicaldisk | select-object Name, FreeSpace, Size
    $CDrive = $drives | Where-Object Name -eq "C:"
    $stats.CDriveRemaining = "{0:f2}" -f ($CDrive.FreeSpace / 1GB)
    $stats.CDrivePercent = "{0:n1}" -f ($CDrive.FreeSpace / $CDrive.Size * 100)

    # This has to reference the first element in an array. Some of the SQL servers are returning multiple
    # drives for an unknown reason, when there is only one drive on the VM itself.
    # We use try because you can't index a null value, for when there isn't an F: drive
    try {
        $FDrive = ($drives | Where-Object Name -eq "F:")[0]
        $stats.FDriveRemaining = "{0:f2}" -f ($FDrive.FreeSpace / 1GB)
        $stats.FDrivePercent = "{0:n1}" -f ($FDrive.FreeSpace / $FDrive.Size * 100)
    }
    catch {
        $stats.FDriveRemaining = 'NotAttached'
        $stats.FDrivePercent = 'NotAttached'
    }

    try {
        $GDrive = ($drives | Where-Object Name -eq "G:" )[0]
        $stats.GDriveRemaining = "{0:f2}" -f ($GDrive.FreeSpace / 1GB)
        $stats.GDrivePercent = "{0:n1}" -f ($GDrive.FreeSpace / $GDrive.Size * 100)

    }
    catch {
        $stats.GDriveRemaining = 'NotAttached'
        $stats.GDrivePercent = 'NotAttached'

    }


    # Create my variables for adding to the CSV

    #Create string to add to our CSV
    $csvline = "{0},{1},{2},{3},{4:f2},{5:n1},{6:f2},{7:n1},{8:f2},{9:n1},{10:f2},{11:n1}"  -f (Get-Date -Format MM/dd/yyyy), $stats.ComputerName, $stats.Uptime, $stats.CpuIdle, `
    $stats.MemFree, $stats.MemUtil, $stats.CDriveRemaining, $stats.CDrivePercent, $stats.FDriveRemaining, $stats.FDrivePercent, $stats.GDriveRemaining, $stats.GDrivePercent

    $csvline
}

# Check the log file, and archive it if it's starting to get too large.
Function Check-LogFile() {
    Param (
        [ValidateNotNullOrEmpty()] $file
    )
    
    if (Test-Path $file) {
        if ($file.Length -ge $maxLogSize) {
            $oldmon = "C:\{redacted}\{0}_{1}{2}" -f $file.BaseName, (Get-Date -format MMddyyyy), $file.Extension
            if (-not (Test-Path C:\{redacted})) {
                New-Item "C:\{redacted}" -ItemType Directory -InformationAction SilentlyContinue | Out-Null
            }
            Move-Item $file $oldmon -Force
            $monitor.Add("date,serverName,upTime,cpuIdle%,memoryAvailable(GB),memoryUsage%,cDriveFree(GB),cDriveFree%,fDriveFree(GB),fDriveFree%,gDriveFree(GB),gDriveFree%")
        }
    }
    else {
        $monitor.Add("date,serverName,upTime,cpuIdle%,memoryAvailable(GB),memoryUsage%,cDriveFree(GB),cDriveFree%,fDriveFree(GB),fDriveFree%,gDriveFree(GB),gDriveFree%")
    }    
}
# Set variables
[System.Io.FileInfo]$outfile = "C:\{redacted}\monitoring.CSV"
$namefilter = "*"
$monitor = New-Object System.Collections.Generic.List

Check-LogFile $outfile

#Get list of Computers from AD : filter 'Name like "USSPFIDSK*"'
$computers = Get-ADComputer -filter 'Name -like $namefilter' | Where-Object { $PSItem.name -notlike "*-*" `
    -and $PSItem.name -notlike "{redacted}*" `
    -and $PSItem.name -notlike "{redacted}*" `
    -and $PSItem.name -notlike "*SMTP*" `
    -and $PSItem.name -notlike "*PRX*" `
    -and $PSItem.name -notlike "*TOW*" `
    } | `
    Select-Object Name | Sort-Object Name

# Start a PSJob for each computer in the array
foreach ($Computer in $computers) {

    # Have we hit the job limit? Wait for existing jobs to finish and gather the values if so
    if ( (Get-Job).Count -eq $maxJobs ) {
        Write-Host "Waiting on queued jobs to finish..." -ForegroundColor Yellow
        $csvline = Get-Job | Receive-Job -AutoRemoveJob -Wait
        $monitor.Add($csvline)
    }

    Write-Host "Sending job to $($Computer.name)"

    if ($computer.name -eq $env:COMPUTERNAME) {
        $monitor.add($(Get-ServerStats))
    }
    else {
    Invoke-Command -AsJob -ComputerName $computer.name -ScriptBlock ${Function:Get-ServerStats}
    }
}

# Gather the remaining job results
$csvline = Get-Job | Wait-Job | Receive-Job
$monitor.Add($csvline)
#Output into a CSV.
$monitor | Out-File -FilePath $outfile -force -Append

