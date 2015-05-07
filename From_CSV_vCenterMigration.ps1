<#
.SYNOPSIS
Migrate ESXi host from vcenter servers keeping VDS if exists, folder and permissions

.DESCRIPTION
Designed to run from Powershell ISE
STEPS:
Check that everytihg is available and locations ready
Export folder structure, vm locations. cluster configurations and permisions (cluster,hosts,vm)
Export VDS configuration
Convert VDS switches to VSS switches
Move all vms from VDS portgroups to VSS portgroups
Migrate Host to the new vcenter
Import all information
Create VDS with the exported configuration
Move vms to VDS portgroups


.PARAMETER createcsv
Generates a blank csv file - Migrate_VC.csv

.EXAMPLE
.\vcenterMigration.ps1
Runs

.EXAMPLE
.\vcenterMigration.ps1 -createcsv
Creates a new/blank ENV.csv file in same directory as script

.NOTES
Original V1.0 Author Mark Chuman Date 7-17-2014
include new funtions from Glenn Sizemore, Luc Dekens & Alan Renouf
V2.0 Author JJ Vidanez Date $SaveDate()

#>
#requires -Version 3

#Parameters
Param(
    [Parameter(Mandatory=$false)]
    [switch]$createcsv
    )

#Denote function that allows Export-Folders usage.
. .\Functions\create-dvswitch-dvportgroup.ps1
. .\Functions\export_folder_function.ps1
. .\Functions\export_permissions_function.ps1
. .\Functions\get-distributedswitch.ps1
. .\Functions\interaction_functions.ps1
. .\Functions\get_folder_path_function.ps1
. .\Functions\import_folder_function.ps1
. .\Functions\import_permissions_function.ps1
. .\Functions\move-vm-to.ps1

#Check and if not add powershell snapin
if (-not (Get-PSSnapin VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) {
	Add-PSSnapin VMware.VimAutomation.Core}

#Change powercliconfiguration so SSL cert errors will be ignored
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false

#Set variables in order to check parameters
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$exportpath = $scriptDir + "\Migrate_VC.csv"
$headers = "" | Select-Object SourceVC, destinationVC, Sourcecluster, SourceDC, DestinationDC

#If requested, create Migrate_VC.csv and exit
If ($createcsv) {
    If (Test-Path $exportpath) {
        Out-Log "`n$exportpath Already Exists!`n" "Red"
        Exit
    } Else {
        Out-Log "`nCreating $exportpath`n" "Yellow"
        $headers | Export-Csv $exportpath -NoTypeInformation
		Out-Log "Done!`n"
        Exit
    }
}

#Set script to inquire with user if an error is encountered.
$ErrorActionPreference = "Inquire"

#Gather information from user
$VCCred = Get-Credential -message  "Enter SOURCE vcenter credentials"
$VCgreen = Get-Credential -message  "Enter DESTINATION vcenter credentials"

$credential = Get-Credential -message  "Enter the password for Root on the ESXi servers" -UserName Root
$esxpass = $credential.GetNetworkCredential().password

#Prompt user for csv containing migration data
Write-Host " "
Write-Host "At the next windows, browse to the csv containing your migration information"
$FileLocation = Read-OpenFileDialog "Locate Migrate_VC.csv" "C:\" "Migrate_VC.csv|Migrate_VC.csv"
If ($FileLocation -eq "" -or !(Test-Path $FileLocation) -or !$FileLocation.EndsWith("Migrate_VC.csv")) {
    Out-Log "`nStill can't find it...I give up" "Red"
    Out-Log "Exiting..." "Red"
    Exit
}

#Importing csv with overall migration data
$MIGRATIONDATA = Import-Csv $FileLocation

Foreach ($MIGRATION in $MIGRATIONDATA) {

    #Source vCenter
    $SourcevCenter = $MIGRATION.SourceVC

    #Destination vCenter
    $DestinationvCenter = $MIGRATION.destinationVC

    #Cluster being migrated
    $Cluster = $MIGRATION.Sourcecluster

    #Datacenter in the source vCenter that cluster will be migrated from
    $SourceDatacenter = $MIGRATION.SourceDC

    #Datacenter in the new vCenter cluster will be migrated to
    $DestinationDatacenter = $MIGRATION.DestinationDC

    #Create working directory
    Write-Host " "
    If ((Test-Path ./$SourcevCenter/$Cluster) -eq 0) {mkdir ./$SourcevCenter/$Cluster | Out-Null}
    If ((Test-Path ./$SourcevCenter/"Archive") -eq 0) {mkdir ./$SourcevCenter/"Archive" | Out-Null}

    #Start transcript of script activities and set transcript location variable
    start-transcript -append -path .\$SourcevCenter\$Cluster\transcript.txt | Out-Null

    #Confirm information with user
    Write-Host " "
    Write-Host "Please confirm your information before proceeding"
    Write-Host " "
    Write-Host "Target cluster         - " -NoNewline
    Write-Host $Cluster  -ForegroundColor Green
    Write-Host " "
    Write-Host "Source vCenter         - " -NoNewline
    Write-Host $SourcevCenter  -ForegroundColor Green
    Write-Host "Source Datacenter      - " -NoNewline
    Write-Host $SourceDatacenter  -ForegroundColor Green
    Write-Host " "
    Write-Host "Destination vCenter    - " -NoNewline
    Write-Host $DestinationvCenter -ForegroundColor Green
    Write-Host "Destination datacenter - " -NoNewline
    Write-Host $DestinationDatacenter  -ForegroundColor Green

    #Check integrity of information with user
    Write-Host " "
    Write-Host -NoNewline "Please confirm that the above information is correct"
    #$host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
    Write-Host " "
    $continue = Read-Host "`nContinue (y/n)?"
        If ($continue -notmatch "y") {
            Out-Log "Exiting..." "Red"
            Exit
        }
    #Start of actual QA test for information provided
    Write-Host " "
    Write-Host "Running QA tests against the information provided"
    Write-Host " "
    #Check that the source cluster exists
    Connect-VIserver -Server $SourcevCenter -credential $VCCred | Out-Null
    $ClusterCheck = Get-Cluster -Name $Cluster
    If ($ClusterCheck = $Cluster) {
        Write-Host "Cluster " -NoNewline
        Write-Host $Cluster -ForegroundColor Green -NoNewline
        Write-Host " DOES exist in " -NoNewline
        Write-Host $SourcevCenter -ForegroundColor Green
    }
    else
    {
        Write-Host "Cluster " -NoNewline
        Write-Host $Cluster -ForegroundColor Green -NoNewline
        Write-Host "does NOT exist in " -NoNewline
        Write-Host $SourcevCenter -ForegroundColor Green
    }

    #Set script to inquire with user if an error is encountered.
    $ErrorActionPreference = "Stop"

    #Check connection to the hosts in the source cluster.  (Checking the root credentials)
    Write-Host " "
    Write-Host "Checking connection to the ESX hosts with the root password provided" -ForegroundColor Red -BackgroundColor White
    Write-Host "*Script will halt if incorrect password is detected                 " -ForegroundColor Red -BackgroundColor White
    Write-Host " "
    $esxcheck = foreach ($vmhost in get-cluster -name $Cluster | get-vmhost | select Name) `
    {Connect-VIServer -Server $vmhost.name -User root -Password $esxpass}
    foreach ($vmhost in get-cluster -name $Cluster | get-vmhost | select Name) `
    {disconnect-viserver $vmhost.name -confirm:$false}

    #Disconnect from source vCenter
    disconnect-viserver * -confirm:$false

    #Set script to inquire with user if an error is encountered.
    $ErrorActionPreference = "Inquire"

    #Check that destination datacenter exists
    Connect-VIserver -Server $DestinationvCenter -credential $VCgreen | Out-Null
    $DataCenterCheck = Get-Datacenter -Name $DestinationDatacenter
    If ($DataCenterCheck = $DestinationDatacenter) {
        Write-Host "Datacenter " -NoNewline
        Write-Host $DestinationDatacenter -ForegroundColor Green -NoNewline
        Write-Host " DOES exist in " -NoNewline
        Write-Host $DestinationvCenter -ForegroundColor Green
    }
    else
    {
        Write-Host "Datacenter " -NoNewline
        Write-Host $DestinationDatacenter -ForegroundColor Green -NoNewline
        Write-Host " does NOT exist in " -NoNewline
        Write-Host $DestinationvCenter -ForegroundColor Green
    }
    #End actual QA test for information provided

    #Disconnect from destination vCenter
    disconnect-viserver * -confirm:$false

    #Start section for export/import of folders
    Write-Host " "
    Write-Host -NoNewline "Normally, this step is needed during the first migration for each datacenter but, you may want to run it if folders were created since the last migration run.  Process will take more time depending on number of folders.

        Click Yes to export/import the folders or No to not export/import the folders.
        
        Export and Import Folders?"
    Write-Host " "
    $continue = Read-Host "(y/n)?"
    If ($continue -match "y") {
        Write-Host "You decided to export/import folders." -ForegroundColor Red -BackgroundColor White
    } 
    else 
    {
        Write-Host "You decided not to export/import folders." -ForegroundColor Red -BackgroundColor White
    }

    If ($continue -match "y") {
	    Write-Host " "
	    Write-Host "Exporting folders in source datacenter " -NoNewline
	    Write-Host $SourceDatacenter -ForegroundColor Green
	    Write-Host " "
	    #Need to use static vCenter connetions as get folder path function fails when designating a certain vc in multi-mode
	    Connect-VIserver -Server $SourcevCenter -credential $VCCred | Out-Null
	    Export-Folders -FolderType "Blue" -DC $SourceDatacenter -Server $SourcevCenter -Filename ".\$SourcevCenter\$Cluster\folderexport.csv"
	    disconnect-viserver * -confirm:$false
	    Write-Host "Importing folders to destination datacenter " -NoNewline
	    Write-Host $DestinationDatacenter -ForegroundColor Green
	    Connect-VIserver -Server $DestinationvCenter -credential $VCgreen| Out-Null
	    Import-Folders -FolderType "Blue" -DC $DestinationDatacenter -Server $DestinationvCenter -Filename ".\$SourcevCenter\$Cluster\folderexport.csv"
	    disconnect-viserver * -confirm:$false
                         } else {
	    Write-Host "Skipping the exporting of folders in source datacenter " -NoNewline
	    Write-Host $SourceDatacenter -ForegroundColor Green
    }
    #End section for export/import of folders

    #Begin section for exporting the folder locations for VMs in the cluster
    Write-Host " "
    Write-Host "Exporting VM " -NoNewline
    Write-host "folder locations" -ForegroundColor Green
    Write-Host " "
    Connect-VIserver -Server $SourcevCenter -credential $VCCred | Out-Null
    $VMFolderLocation = Get-Cluster $Cluster | Get-VM | Select-Object Name,Folder
    $VMFolderLocation | Export-Csv ".\$SourcevCenter\$Cluster\folderlocation_export_vms.csv"
    disconnect-viserver * -confirm:$false
    #End section for exporting VM folder locations

    #Begin export of other items
    #Export of DRS rules
    Write-Host "Exporting DRS rules in " -NoNewline
    Write-Host $Cluster -ForegroundColor Green
    Write-Host " "
    Start-Sleep -Seconds 1
    Connect-VIserver -Server $SourcevCenter -credential $VCCred | Out-Null
    $drsrulesexport = "./$SourcevCenter/$Cluster/drsrulesexport.txt"
    $rules = get-cluster -Name $Cluster | Get-DrsRule

    if($rules){
         foreach($rule in $rules){
              $line = (Get-View -Id $rule.ClusterId).Name
              $line += ("," + $rule.Name + "," + $rule.Enabled + "," + $rule.KeepTogether)
              foreach($vmId in $rule.VMIds){
                   $line += ("," + (Get-View -Id $vmId).Name)
              }
              $line | Out-File -Append $drsrulesexport
         }
    }
    #End DRS rules export

    #Begin permissions export
    Write-Host "Exporting " -NoNewline
    Write-Host "permissions" -ForegroundColor Green
    Write-Host
    Start-Sleep -Seconds 1
    #Export permissions for folders from the source datacenter - .5 to .75 seconds per folder.
    Get-Datacenter $SourceDatacenter | Get-Folder | Get-VIPermission | `
    Where-Object{($_.Entity.Name -ne "Datacenters") -and ($_.Entity.ID -like "*Folder*")}`
    | Export-Csv -NoTypeInformation -UseCulture -Path ./$SourcevCenter/$Cluster/perms_export_folders.csv

    #Export permissions from source datacenter - export time is neglible.
    Get-Datacenter $SourceDatacenter | Get-VIPermission | Where-Object{$_.Entity.Name -eq $SourceDatacenter} `
    | Export-Csv -NoTypeInformation -UseCulture -Path ./$SourcevCenter/$Cluster/perms_export_datacenter.csv

    #Export permissions from source cluster - export time is neglible.
    Get-Cluster $Cluster | Get-VIPermission | Where-Object{$_.Entity.Name -eq $Cluster} `
    | Export-Csv -NoTypeInformation -UseCulture -Path ./$SourcevCenter/$Cluster/perms_export_cluster.csv

    #Export permissions for esx servers from source cluster - export time is neglible.
    Get-Cluster $Cluster | Get-VMHost | Get-VIPermission | Where-Object{$_.EntityId -like "*Host*"} `
    | Export-Csv -NoTypeInformation -UseCulture -Path ./$SourcevCenter/$Cluster/perms_export_vmhosts.csv

    #Export virtual machine permissions from source cluster - .5 to .75 seconds per VM.
    get-cluster $Cluster | Get-VM | Get-VIPermission | Where-Object{$_.EntityId -like "*VirtualMachine*"} `
    | Export-Csv -NoTypeInformation -UseCulture -Path ./$SourcevCenter/$Cluster/perms_export_vms.csv
    #End permissions export

    #Begin custom attributes export
    Write-Host "Exporting " -NoNewline
    Write-Host "Custom Attributes" -ForegroundColor Green
    Write-Host " "
    $startdir = ".\$SourcevCenter\$Cluster\"
    $exportfile = "$startdir\attributes_export_vm.csv"

    $vms = Get-Cluster  $Cluster | Get-VM
    $Report =@()
    foreach ($vm in $vms) {
        $row = "" | Select Name, Notes, DR, "DR Value", DRStorage, "DRStorage Value"
        $row.name = $vm.Name
        $row.Notes = $vm.Notes
        $customattribs = $vm | select -ExpandProperty CustomFields
        $row.DR = $customattribs[0].Key
        $row."DR Value" = $customattribs[0].value
        $row.DRStorage = $customattribs[1].Key
        $row."DRStorage Value" = $customattribs[1].value
        $Report += $row
    }

    $report | Export-Csv "$exportfile" -NoTypeInformation
    #End custom attributes export

    disconnect-viserver * -confirm:$false
    #End export of of other items

    #Begin exporting cluster information
    Connect-VIServer $SourcevCenter -Credential $VCCred | Out-Null

    Write-Host ".....Exporting information for " -NoNewline
    Write-Host $Cluster -ForegroundColor Green

    #Creating csv with cluster information
    Get-Cluster -name $Cluster | Select Name, HAEnabled, HAAdmissionControlEnabled, HAFailoverLevel, HARestartPriority, `
    HAIsolationResponse, DrsEnabled, DrsAutomationLevel, EVCMode | `
    Export-Csv -NoTypeInformation -UseCulture -Path .\$SourcevCenter\$Cluster\$Cluster.csv

    #Creating csv with hosts in the cluster
    get-cluster -name $Cluster | get-vmhost | select Name | `
    Export-Csv -NoTypeInformation -UseCulture -Path .\$SourcevCenter\$Cluster\VMHost.csv

    #Disconnect from vCenter
    disconnect-viserver * -confirm:$false
    #End exporting cluster information

    #Start the process to migrate from VDS to VSS
    Write-Host "Do you want to migrate a dvSwitch with cluster "$Cluster
    $VDSmigrate = Read-Host "`n(y/n)?"
    If ($VDSmigrate -match "y") {
        #Get dvswitch 
        $OlddvSwitch = Read-Host "What is the name of the distributed vSwitch (dvSwitch) you want to move: "
        #Check that the source dvswitch exists
        #Make the connection to vCenter
        Connect-VIServer -Server $SourcevCenter -Credential $VCCred | Out-Null
        #Get the hosts from the datacenter to move
        $ListHost = get-cluster -name $Cluster | get-vmhost
        #Read the dvSwitch and dvPortGroups
        $dvSwitch = Get-dvSwitch $SourceDatacenter $OlddvSwitch
        $dvPG = Get-dvSwPg $dvSwitch 
        Write-Host "dvSwitch " -NoNewline
        Write-Host $dvSwitch -ForegroundColor Green -NoNewline
        Write-Host " DOES exist in " -NoNewline
        Write-Host $SourcevCenter -ForegroundColor Green
        #Create the loop in order to take care of all servers in the datacenter
        foreach ($MovingHost in $ListHost ) {
            #Report will be used to store the changes
            $report=@()
            #Now create a (temporary) standard vSwitch with 256 ports. Remember, each VM needs one port and 256 might not be enough for you.
            #The name of this temporary standard vSwitch will be 'vSwitch-Migrate'
            New-VirtualSwitch -Name 'vSwitch-Migrate' -NumPorts 256 -VMHost $MovingHost.name
            $vSwitch = Get-VirtualSwitch -VMHost $MovingHost.name -Name 'vSwitch-Migrate'
            foreach( $dvPGroup in $dvPG ){
                $VLANID = $dvPGroup.Config.DefaultPortConfig.Vlan.VlanId
                # Somehow the first line in $dvPGroup is some kind of header with 'VMware.Vim.NumericRange' in it. So I skip it
        	        if( $VLANID -notmatch 'VMware.Vim.NumericRange') {
           		            # I want the new standard Portgroup to be named 'Mig-VLAN100' instead of 'VLAN100'
        		            $NewPG = 'Mig-' + $dvPGroup.Name
           		            # Create a New standard portgroup
        		            Get-VirtualSwitch -VMHost $MovingHost.name -Name 'vSwitch-Migrate' | New-VirtualPortGroup -Name $NewPG -VLanId $VLANID
           		            # Just to always know what was what, I keep track of old and new names
        		            # This is where you could add more settings from the olddvPG, like load balancing, number of ports, etc.
        		            $Conversion = "" | Select olddvSwitch, olddvPG, tmpvSwitch, tmpvPG, VLANID
        		            $Conversion.olddvswitch = $dvSwitch.Name
                            Write-Host $dvSwitch.Name
        		            $Conversion.olddvPG = $dvPGroup.Name
                            Write-Host $dvPGroup.Name
        		            $Conversion.tmpvSwitch = Get-VirtualSwitch -VMHost $MovingHost.name -Name 'vSwitch-Migrate'
        		            $Conversion.tmpvPG = $NewPG
        		            $Conversion.VLANID = $VLANID
        		            $report += $Conversion
        		        }
        	        }
                # Writing the info to CSV file
                $report | Export-Csv ".\$SourcevCenter\$Cluster\switch-list-$MovingHost.name.csv" -NoTypeInformation

                Write-Host "The dvSwitch and dvPortGroups have been exported to CSV file and a standard vSwitch with portgroups has been created." $MovingHost.name
                Write-Host "Next Step is to manually move one interface on the host from distributed to standard vSwitches in order to have connectivity at both"
                Write-Host "Move on host" $MovingHost.name "one interface and hit yes"
                $continue = Read-Host "`nContinue (y/n)?"
                    If ($continue -notmatch "y") {
                        Out-Log "Exiting..." "Red"
                        Exit
                    }
                }
                # Now import the csv file with the switch info
                foreach ($MovingHost in $ListHost ) {
                    $report=@()
                    $report = Import-Csv ".\$SourcevCenter\$Cluster\switch-list-$MovingHost.name.csv"
            
                    Foreach( $row in $report){
        	            #     Set all VMs where dvPortGroup is equal to olddvPG to new standard (temporary) tmpvPG
        	            Write-Host "Switching VMs from dvPortGroups to standard PortGroup: " $row.olddvPG $row.tmpvPG "on" $MovingHost.name
                        Get-VMHost $MovingHost.name | Get-VM | Get-dvSwitchNetworkAdapter | Where-object{$_.NetworkName -eq $row.olddvPG } | Set-dvSwitchNetworkAdapter -NetworkName $row.tmpvPG
        	            }
                    Write-Host "All VMs have now been moved from the dvSwitches to the standard vSwitches."
                    }
             disconnect-viserver * -confirm:$false     
    }
    #End the process to migrate VDS




    #Begin creating cluster in destination vCenter
    Write-Host ".....Connecting to destination vCenter - " -NoNewline
    Write-Host $DestinationvCenter -ForegroundColor Green

    Connect-VIServer $DestinationvCenter -Credential $VCgreen| Out-Null

    Write-Host ".....Creating cluster " -NoNewline
    Write-Host $Cluster -ForegroundColor Green -NoNewline
    Write-Host "in vCenter " -NoNewline
    Write-Host $DestinationvCenter -ForegroundColor Green -NoNewline
    Write-Host " under datacenter " -NoNewline
    Write-Host $DestinationDatacenter -ForegroundColor Green -NoNewline
    Write-Host " "

    #Importing csv information that was gathered earlier
    $CSV = Import-Csv .\$SourcevCenter\$Cluster\$Cluster.csv
    $CSVhosts = Import-Csv .\$SourcevCenter\$Cluster\VMHost.csv

    #Create the new cluster using splat
    $CSV | %{
       $splat = @{
          Name = $_.Name
	      HAEnabled = If ($_.HAEnabled -eq "False") {$False} else {[Boolean]$_.HAEnabled}
	      DrsEnabled = If ($_.DrsEnabled -eq "False") {$False} else {[Boolean]$_.DrsEnabled}
          Confirm = $false
       }
       New-Cluster -Location $DestinationDatacenter @splat
    }

    #Adjust HA settings for new cluster if HA was showing as enabled in the csv
    If ($CSV.HAEnabled -eq "False") {
        Write-Host " "
        Write-Host "HA is not enabled on " -NoNewline
        Write-Host $Cluster -ForegroundColor Green -NoNewline
        Write-Host ". HA configuration will not take place"
        Write-Host " "
    }
    else
    {
        Write-Host ".....Configuring HA settings for cluster $Cluster in vCenter $DestinationvCenter under datacenter $DestinationDatacenter"
        $CSV | %{
            $splat = @{
                HAAdmissionControlEnabled = If ($_.HAAdmissionControlEnabled -eq "False") {$False} else {[Boolean]$_.HAAdmissionControlEnabled}
                HAFailoverLevel = $_.HAFailoverLevel
                HARestartPriority = $_.HARestartPriority
                HAIsolationResponse = $_.HAIsolationResponse
                Confirm = $false
            }
        Set-Cluster -Cluster $Cluster @splat
        }
    }

    #Adjust DRS settings for new cluster if DRS was showing as enabled in the csv
    If ($CSV.DrsEnabled -eq "False") {
        Write-Host "DRS is not in use on " -NoNewline
        Write-Host $Cluster -ForegroundColor Green -NoNewline
        Write-Host ".  DRS configuration will not take place"
        Write-Host " "
    }
    else
    {
        Write-Host ".....Configuring DRS settings for cluster $Cluster in vCenter $DestinationvCenter under datacenter $DestinationDatacenter    "
        $CSV | %{
            $splat = @{
                DrsAutomationLevel = $_.DrsAutomationLevel
                Confirm = $false
            }
        Set-Cluster -Cluster $Cluster @splat
        }
    }
    #EVC mode is captured, but EVC in new cluster will not be set by the script going forward - http://kb.vmware.com/selfservice/microsites/search.do?language=en_US&cmd=displayKC&externalId=1012864.
    #Adjust EVC settings for new cluster if DRS was showing as enabled in the csv

    #If ($CSV.EVCMode -eq "") {Write-Host "EVC is not in use on $Cluster.  EVC configuration will not take place"} else {

    #Write-Host "

    #.....Configuring EVC settings for cluster $Cluster in vCenter $DestinationvCenter under datacenter $DestinationDatacenter

    #"

    #$CSV | %{

    #   $splat = @{

    #	  EVCMode = $_.EVCMode

    #      Confirm = $false

    #   }

    #   Set-Cluster -Cluster $Cluster @splat

    #  }

    #}


    # Start the process if necessary to create VDSwitch in the new cluster
    Write-Host "Do you want to create a dvSwitch" $OlddvSwitch "with migration cluster" $Cluster
    $VDScreate = Read-Host "`n(y/n)?"
    If ($VDScreate -match "y") {
        #Report will be used to store the changes
        $report=@()
                # Any of the save host configuration files from the oldcluster will be enough to create the VDS, getting the last one set
        $report = Import-Csv ".\$SourcevCenter\$Cluster\switch-list-$MovingHost.name.csv" | Select olddvSwitch -Unique

        foreach( $row in $report)
            {
            Write-Host "Creating dvSwitch: " $row.olddvSwitch
            # Creating the new dvSwitch. You may want to change the baseUplink and nrUplink values to your needs
            New-dvSwitch -dcName $DestinationDatacenter -dvSwName $row.olddvSwitch -baseUplink 4 -nrUplink 4
            }
        #Report will be used to store the changes
        $report=@()
        # dvPortGroups will be created on the new vCenter
        # Reading CSV file
        $report = Import-Csv ".\$SourcevCenter\$Cluster\switch-list-$MovingHost.name.csv"
        foreach( $row in $report)
            {
            $dvSwitchFromCSV = $row.olddvSwitch
            $dvSw = Get-dvSwitch -DatacenterName $DestinationDatacenter -dvSwitchName $dvSwitchFromCSV
            Write-Host "Creating dvPortGroup " $row.olddvPG " with VLANID " $row.VLANID " on dvSwitch " $row.olddvSwitch
            New-dvSwPortgroup -dvSw $dvSw -PgName $row.olddvPG -PgVLANType "vlan" -PgVLANId $row.VLANID
            }
        Write-Host "The new dvSwitch and dvPortGroups have been created"
    }
    #Disconnect from new vCenter
    disconnect-viserver * -confirm:$false

    #Confirming user wants to move forward with migrating the ESX servers
    Write-Host 'Press any y to proceed with the next step of migrating the ESX hosts in' $Cluster -ForegroundColor Green
    $continue = Read-Host "`nContinue (y/n)?"
        If ($continue -notmatch "y") {
            Out-Log "Exiting..." "Red"
            Exit
        }

    #Connect to source vCenter
    Write-Host " "
    Write-Host ".....Connecting to source vCenter - " -NoNewline
    Write-Host $SourcevCenter -ForegroundColor Green

    Connect-VIServer $SourcevCenter -Credential $VCCred |Out-Null

    #Importing host csv information that was gathered earlier
    $CSVhosts = Import-Csv .\$SourcevCenter\$Cluster\VMHost.csv

    #Disconnect hosts from source cluster/vCenter
    Write-Host "Disconnecting the hosts in " -NoNewline
    Write-Host $Cluster -ForegroundColor Green -NoNewline
    Write-Host " on " -NoNewline
    Write-Host $SourcevCenter -ForegroundColor Green
    foreach ($vmhost in $CSVhosts) {set-vmhost -VMhost $vmhost.name -state "disconnected" -RunAsync}

    #Pausing script with progress bar, to allow for host disconnect
    $x = 1*15
    $length = $x / 100
    while($x -gt 0) {
        $min = [int](([string]($x/60)).split('.')[0])
        $text = " " + $min + " minutes " + ($x % 60) + " seconds left"
        Write-Progress "Pausing Script to allow for host disconnect.  Host disconnect check will proceed next" -status $text -perc ($x/$length)
        start-sleep -s 1
        $x--
    }

    Write-Progress "Done" "Done" -completed

    #Checking the host connection state before proceeding
    foreach ($vmhost in $CSVhosts) {
        Do {
	        [string]$status = (get-vmhost -Name $vmhost.name | select ConnectionState)
		    Write-Host "Connection state of " $vmhost.name " = " $status " - Process will proceed if status is disconnected"
		    Start-Sleep -Seconds 1
		    }
		    While ($status -ne "@{ConnectionState=Disconnected}")
	    }

    #Removing hosts from source cluster
    Write-Host " "
    Write-Host "Removing the hosts in " -NoNewline
    Write-Host $Cluster -ForegroundColor Green -NoNewline
    Write-Host " on " -NoNewline
    Write-Host $SourcevCenter -ForegroundColor Green

    Import-Csv .\$SourcevCenter\$Cluster\VMHost.csv | %{
       $esx = Get-VMHost -Name $_.name
       $esx.ExtensionData.Destroy_Task()
    }

    #Pausing script with progress bar, to allow for host removal
    $x = 1*90
    $length = $x / 100
    while($x -gt 0) {
      $min = [int](([string]($x/60)).split('.')[0])
      $text = " " + $min + " minutes " + ($x % 60) + " seconds left"
      Write-Progress "Pausing Script to allow for host removal.  Empty cluster check will proceed next" -status $text -perc ($x/$length)
      start-sleep -s 1
      $x--
    }

    Write-Progress "Done" "Done" -completed

    #Checking for empty cluster prior to moving on
        Do {
	        $ClusterCheck = (Get-Cluster -Name $Cluster | get-vmhost | select Name)
		    Write-Host "If all the hosts are gone from the source cluster " -NoNewline
		    Write-Host $Cluster  -ForegroundColor Green -NoNewline
		    Write-Host " the process will continue.  Hosts still connected to " -NoNewline
		    Write-Host $Cluster  -ForegroundColor Green -NoNewline
		    Write-Host " (if blank, no hosts are connected)"
		    Write-Host $ClusterCheck -ForegroundColor Green
		    Start-Sleep -Seconds 2
		    }
		    While ($ClusterCheck -ne $Null)

    #Renaming the old cluster to note that it's been migrated

    Set-Cluster -Cluster $Cluster -Name $Cluster" - Migrated "$DestinationvCenter -Confirm:$false
    Write-Host "Finished removing.  Disconnecting from the source vCenter " -NoNewline
    Write-Host $SourcevCenter -ForegroundColor Green
    Write-Host " "
    disconnect-viserver * -confirm:$false

    #Adding hosts to new cluster
    Write-Host "Adding the hosts into tne new cluster " -NoNewline
    Write-Host $Cluster -ForegroundColor Green -NoNewline
    Write-Host " on " -NoNewline
    Write-Host $DestinationvCenter -ForegroundColor Green

    #Connecting to the destination vCenter
    Connect-VIServer $DestinationvCenter -Credential $VCgreen| Out-Null

    #Adding the hosts.  Picking up root password from variable set in the beginning of script
    foreach ($vmhost in $CSVhosts) {
        Add-VMHost $vmhost.name -Location $Cluster -User root -Password $esxpass -confirm:$false -Force -RunAsync
    }
    #Sleeping with progress bar, to allow the hosts to be added
    #Write-Host "Sleeping for 35 seconds for host addition.  Host connection check will take place next"
    #Start-Sleep -Seconds 35
    $x = 1*60
    $length = $x / 100
    while($x -gt 0) {
      $min = [int](([string]($x/60)).split('.')[0])
      $text = " " + $min + " minutes " + ($x % 60) + " seconds left"
      Write-Progress "Pausing Script to allow for host addition.  Host connection check will proceed next" -status $text -perc ($x/$length)
      start-sleep -s 1
      $x--
    }
    Write-Progress "Done" "Done" -completed

    #Checking that the the hosts are connected before proceeding
    $waitForThese = "Connected","Maintenance"

    #Checking that the the hosts are connected before proceeding
    foreach ($vmhost in $CSVhosts) {
      Do {
          $status = Get-VMHost -Name $vmhost.name | Select -ExpandProperty ConnectionState
          Write-Output "Connection state of $($vmhost.name) = $status - Process will proceed when host status is connected or maintenance mode"
          Start-Sleep -Seconds 1
      }
      While ($waitForThese -notcontains $status)
    }

    #Import of permissions
    Write-Host "Importing" -ForegroundColor Green -NoNewline
    Write-Host " permissions for the folders, hosts, virtual machines, datacenter and cluster
    "
    Start-Sleep -Seconds 1
    #Import folder permissions.  Will be executed at operator's discretion.
    #Note that the $folder value is narrowed down to the destinationcenter as a duplicate folder in another datacenter will cause an error.
    $folderperms = Import-Csv "./$SourcevCenter/$Cluster./perms_export_folders.csv"
    foreach ($fpm in $folderperms) {
		    $svcgroup = $fpm.Principal
		    $folder = Get-Datacenter $DestinationDatacenter | Get-Folder -Name $fpm.Entity
		    $authMgr = Get-View AuthorizationManager
		    $perm = New-Object VMware.Vim.Permission
		    $perm.principal = $svcgroup
		    $perm.group = if ($fpm.IsGroup -eq "TRUE") {$true} else {$null}
		    $perm.propagate = if ($fpm.Propagate -eq "TRUE") {$true} else {$null}
		    $perm.roleid = ($authMgr.RoleList | where{$_.Name -eq $fpm.Role}).RoleId
		    $authMgr.SetEntityPermissions(($folder | Get-View).MoRef, $perm)
    }

    #Import for ESX host permissions.  Will be executed at every script run.
    $esxiperms = Import-Csv "./$SourcevCenter/$Cluster/perms_export_vmhosts.csv"
    foreach ($hpm in $esxiperms) {
 		    $svcgroup = $hpm.Principal
		    $VMHost = Get-VMHost -Name $hpm.Entity
		    $authMgr = Get-View AuthorizationManager
		    $perm = New-Object VMware.Vim.Permission
		    $perm.principal = $svcgroup
		    $perm.group = if ($hpm.IsGroup -eq "TRUE") {$true} else {$null}
		    $perm.propagate = if ($hpm.Propagate -eq "TRUE") {$true} else {$null}
		    $perm.roleid = ($authMgr.Rolelist | where{$_.Name -eq $hpm.Role}).RoleId
		    $authMgr.SetEntityPermissions(($VMHost | Get-View).MoRef, $perm)
		    }

    #Import for virtual machine permissions
    $vmperms = Import-Csv "./$SourcevCenter/$Cluster/perms_export_vms.csv"
    foreach ($vpm in $vmperms) {
		    $svcgroup = $vpm.Principal
		    $vm = Get-VM -Name $vpm.Entity
		    $authMgr = Get-View AuthorizationManager
		    $perm = New-Object VMware.Vim.Permission
		    $perm.principal = $svcgroup
		    $perm.group = if ($vpm.IsGroup -eq "TRUE") {$true} else {$null}
		    $perm.propagate = if ($vpm.Propagate -eq "TRUE") {$true} else {$null}
		    $perm.roleid = ($authMgr.Rolelist | where{$_.Name -eq $vpm.Role}).RoleId
		    $authMgr.SetEntityPermissions(($vm | Get-View).MoRef, $perm)
		    }

    #Import datacenter permissions. Note $dc is calling the destination datacenter.  This protects against the DC name being different.
    $dperms = Import-Csv "./$SourcevCenter/$Cluster/perms_export_datacenter.csv"
    foreach ($dpm in $dperms) {
		    $svcgroup = $dpm.Principal
		    $dc = Get-Datacenter -Name $DestinationDatacenter
		    $authMgr = Get-View AuthorizationManager
		    $perm = New-Object VMware.Vim.Permission
		    $perm.principal = $svcgroup
		    $perm.group = if ($dpm.IsGroup -eq "TRUE") {$true} else {$null}
		    $perm.propagate = if ($dpm.Propagate -eq "TRUE") {$true} else {$null}
		    $perm.roleid = ($authMgr.Rolelist | where{$_.Name -eq $dpm.Role}).RoleId
		    $authMgr.SetEntityPermissions(($dc | Get-View).MoRef, $perm)
		    }

    #Import cluster permissions
    $cperms = Import-Csv "./$SourcevCenter/$Cluster/perms_export_cluster.csv"
    foreach ($cpm in $cperms) {
		    $svcgroup = $cpm.Principal
		    $cl = Get-Cluster -Name $cpm.Entity
		    $authMgr = Get-View AuthorizationManager
		    $perm = New-Object VMware.Vim.Permission
		    $perm.principal = $svcgroup
		    $perm.group = if ($cpm.IsGroup -eq "TRUE") {$true} else {$null}
		    $perm.propagate = if ($cpm.Propagate -eq "TRUE") {$true} else {$null}
		    $perm.roleid = ($authMgr.Rolelist | where{$_.Name -eq $cpm.Role}).RoleId
		    $authMgr.SetEntityPermissions(($cl | Get-View).MoRef, $perm)
		    }

    #Begin import of DRS rules
    Write-Host "Importing" -ForegroundColor Green -NoNewline
    Write-Host " DRS rules (if any were exported)"
    $ChkFile = "./$SourcevCenter/$Cluster/drsrulesexport.txt"
    $FileExists = Test-Path $ChkFile

    If ($FileExists -eq $true) {
    $drsrulesexport = "./$SourcevCenter/$Cluster/drsrulesexport.txt"
    $rules = Get-Content $drsrulesexport

    foreach($rule in $rules){
      $ruleArr = $rule.Split(",")
      if($ruleArr[2] -eq "True"){$rEnabled = $true} else {$rEnabled = $false}
      if($ruleArr[3] -eq "True"){$rTogether = $true} else {$rTogether = $false}
      get-cluster $Cluster | `
        New-DrsRule -Name $ruleArr[1] -Enabled $rEnabled -KeepTogether $rTogether -VM (Get-VM -Name ($ruleArr[4..($ruleArr.Count - 1)]))
    }
    } else { }

    #Begin import of virtual machine folder locations
    $VMFolderLocationImport = Import-Csv .\$SourcevCenter\$Cluster\folderlocation_export_vms.csv
    Write-Host " "
    Write-Host "Importing" -ForegroundColor Green -NoNewline
    Write-Host " VM folder locations"
    foreach ($vm in $VMFolderLocationImport) { 
        If (($vm.Folder -Like "Discovered virtual machine") -or ($vm.Folder -Like "vm"))  { 
        } 
        else {
        Move-VM -VM $vm.Name -Destination $vm.Folder -RunAsync
        }
    }
    
    #End import of virtual machine folder locations

    #Begin import of virtual machine custom attributes
    Write-Host " "
    Write-Host "Importing" -ForegroundColor Green -NoNewline
    Write-Host " VM custom attributes"
    Write-Host " "
    $startdir = ".\$SourcevCenter\$Cluster\"
    $importfile = "$startdir\attributes_export_vm.csv"

    $NewAttributes = Import-Csv $importfile

    ForEach ($vm in $NewAttributes){
            if(!$vm."DR Value" -and !$vm."DRSTorage Value") { } else {
       Write-Host "Custom " -NoNewline
       Write-Host "attributes" -ForegroundColor Green -NoNewLine
       Write-Host " and " -NoNewline
       Write-Host "notes" -ForegroundColor Green -NoNewLine
       Write-Host " for " -NoNewline
       Write-Host $vm.Name -ForegroundColor Green -NoNewLine
       Write-Host " are being imported now..."
       Set-Annotation -Entity (get-vm $vm.Name) -CustomAttribute $vm.DR -Value $vm."DR Value" -confirm:$false
       Set-Annotation -Entity (get-vm $vm.Name) -CustomAttribute $vm.DRStorage -Value $vm."DRStorage Value" -confirm:$false
       Write-Host " "
     }
    }
    #End import of virtual machine custom attributes
    # Moving Back vms to dvswitch
    Write-Host "Do you want to migrate vms from vswitch a dvSwitch on cluster "$Cluster
    $VDSmigvms = Read-Host "`n(y/n)?"
    If ($VDSmigvms -match "y") {
        Write-Host "Next Step is to manully move one interface on the host from standard to distributed vSwitches in order to have connectivity at both"
            Write-Host "Move on host all one interface and hit yes"
            $continue = Read-Host "`nContinue (y/n)?"
                If ($continue -notmatch "y") {
                    Out-Log "Exiting..." "Red"
                    Exit
                }

        foreach ($MovingHost in $ListHost ) {
        #Report will be used to store the changes
        $report=@()
        #Now impport the csv file with the switch info
        $report = Import-Csv ".\$SourcevCenter\$Cluster\switch-list-$MovingHost.name.csv"
        Foreach( $row in $report)
    	    {
    	    #Set all VMs where dvPortGroup is equal to tmpvPG to it's original portgroup olddvPG
    	    Write-Host "Switching VMs from temporary PortGroup " $row.tmpvPG " to dvPortGroup " $row.olddvPG "on" $MovingHost.name
            #(Get-VMhost $vmHost.name | Get-View).VM | Get-VIObjectByVIView | Get-dvSwitchNetworkAdapter | Where-object{$_.NetworkName -eq $row.tmpvPG }| Set-dvSwitchNetworkAdapter -NetworkName $row.olddvPG
        	#Get-VM -location $vmHost.name | Get-dvSwitchNetworkAdapter | Where-object{$_.NetworkName -eq $row.tmpvPG }| Set-dvSwitchNetworkAdapter -NetworkName $row.olddvPG
      	    Get-VMHost $MovingHost.name | Get-VM | Get-dvSwitchNetworkAdapter | Where-object{$_.NetworkName -eq $row.tmpvPG }| Set-dvSwitchNetworkAdapter -NetworkName $row.olddvPG
            #Get-VM | Get-dvSwitchNetworkAdapter | Where-object{$_.NetworkName -eq $row.tmpvPG }| Set-dvSwitchNetworkAdapter -NetworkName $row.olddvPG
            }
        Write-Host "All VMs have now been moved from the dvSwitches to the standard vSwitches."
        }
    }

    disconnect-viserver * -confirm:$false

    #Notify others of migration activities
    $CSVhosts = Import-Csv .\$SourcevCenter\$Cluster\VMHost.csv | out-string
    #Send-MailMessage -To "SOMEONE1 <someone1@somewhere.com>", "SOMEONE2 <SOMEONE2@somewhere.com>" `
    #-From "SENDER <SENDER@somewhere.com>" -subject "Notice - ESXi Servers Migrated" `
    #-smtp smtp.SOMEWHERE.com -body "$CSVhosts Source vCenter 	$SourcevCenter
    #Destination vCenter 	$DestinationvCenter" | out-null

    #Stop transcript
    Stop-Transcript | Out-Null

    #Archive working folder for cluster
    $Random = Get-Random
    Move-Item ./$SourcevCenter/$Cluster ./$SourcevCenter/"Archive"
    Move-Item ./$SourcevCenter/"Archive"/$Cluster ./$SourcevCenter/"Archive"/$Cluster-$Random

    #Final response
    $Location = "./$SourcevCenter/Archive/$Cluster-$Random"
    Write-Host " "
    Write-Host "Script has completed.  Find output here - "$Location

    #Check that the user is ready to proceed to the migration of the next cluster
    Write-Host " "
    Write-Host -NoNewline "Proceed to the migration of the next cluster.  If there is not a next cluster the script will exit. . . . " -ForegroundColor Green
    
}
