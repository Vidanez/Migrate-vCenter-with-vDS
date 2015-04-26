# Migrating distributed vSwitch configurations from one vCenter to a new vCenter
# Written by: Gabrie van Zanten
# http://www.GabesVirtualWorld.com

function Get-dvSwitch{

	# This function was written by Luc Dekens
	# See: http://www.lucd.info/2009/10/12/dvswitch-scripting-part-2-dvportgroup/

	param([parameter(Position = 0, Mandatory = $true)][string]$DatacenterName,
	[parameter(Position = 1, Mandatory = $true)][string]$dvSwitchName)

	$dcNetFolder = Get-View (Get-Datacenter $DatacenterName | Get-View).NetworkFolder
	$found = $null
	foreach($net in $dcNetFolder.ChildEntity){
		if($net.Type -eq "VmwareDistributedVirtualSwitch"){
			$temp = Get-View $net
			if($temp.Name -eq $dvSwitchName){
				$found = $temp
			}
		}
	}
	$found
}

function Set-dvSwPgVLAN{

	# This function was written by Luc Dekens
	# See: http://www.lucd.info/2009/10/12/dvswitch-scripting-part-2-dvportgroup/

	param($dvSw, $dvPg, $vlanNr)

	$spec = New-Object VMware.Vim.DVPortgroupConfigSpec
	$spec.defaultPortConfig = New-Object VMware.Vim.VMwareDVSPortSetting
	$spec.DefaultPortConfig.vlan = New-Object VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec
	$spec.defaultPortConfig.vlan.vlanId = $vlanNr

	$dvPg.UpdateViewData()
	$spec.ConfigVersion = $dvPg.Config.ConfigVersion

	$taskMoRef = $dvPg.ReconfigureDVPortgroup_Task($spec)

	$task = Get-View $taskMoRef
	while("running","queued" -contains $task.Info.State){
		$task.UpdateViewData("Info")
	}
}

function Get-dvSwPg{
	param($dvSw )

# Search for Portgroups
	$dvSw.Portgroup | %{Get-View -Id $_}

}
