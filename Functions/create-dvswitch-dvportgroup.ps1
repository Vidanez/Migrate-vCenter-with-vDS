# Migrating distributed vSwitch configurations from one vCenter to a new vCenter
# Written by: Gabrie van Zanten
# http://www.GabesVirtualWorld.com

function New-dvSwitch{
	param($dcName, $dvSwName, $baseUplink, $nrUplink)

	$dc = Get-View -ViewType Datacenter -Filter @{"Name"=$dcName}
	$net = Get-View -Id $dc.NetworkFolder
	$spec = New-Object VMware.Vim.DVSCreateSpec
	$spec.configSpec = New-Object VMware.Vim.DVSConfigSpec
	$spec.configspec.name = $dvSwName
	$spec.configspec.uplinkPortPolicy = New-Object VMware.Vim.DVSNameArrayUplinkPortPolicy
	$spec.configspec.uplinkPortPolicy.UplinkPortName = (1..$nrUplink | % {$baseUplink + $_})

	$taskMoRef = $net.CreateDVS_Task($spec)

	$task = Get-View $taskMoRef
	while("running","queued" -contains $task.Info.State)
		{
		$task.UpdateViewData("Info")
		}
	$task.Info.Result
}

function New-dvSwPortgroup{

	# This function was written by Luc Dekens
	# See: http://www.lucd.info/2009/10/12/dvswitch-scripting-part-2-dvportgroup/
	# As you can see, many parameters have been included in the function, but are not being used when creating the dvPortGroup
	# You can change the script to your likings, make sure the extra items you want to import are exported in Step01-Get-DistributedSwitch.ps1

	param([parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][VMware.Vim.VmwareDistributedVirtualSwitch]$dvSw,
	[parameter(Position = 1, Mandatory = $true)][string]$PgName,
	[int]$PgNumberPorts = 256,
	[string]$PgBinding = "earlyBinding",
	[string]$PgVLANType = "none",
	[int[]]$PgVLANId,
	[switch]$SecPolPromiciousMode = $false,
	[switch]$SecPolMacChanges = $true,
	[switch]$SecPolForgedTransmits = $true,
	[switch]$TeamingCheckDuplex = $false,
	[switch]$TeamingCheckErrorPercent = $false,
	[string]$TeamingCheckSpeed = $false,
	[switch]$TeamingFullDuplex = $true,
	[int]$TeamingPercentage,
	[int]$TeamingSpeed,
	[string]$TeamingPolicy = "loadbalance_srcid",
	[switch]$TeamingNotifySwitches = $true,
	[switch]$TeamingRollingOrder = $false,
	[switch]$TeamingReversePolicy = $true,
	[string[]]$TeamingActiveUplink,
	[string[]]$TeamingStandbyUplink
	)
	process{
		$teamingPolicies = "loadbalance_ip",
						"loadbalance_srcmac",
						"loadbalance_srcid",
						"failover_explicit",
						"loadbalance_loadbased"

		$spec = New-Object VMware.Vim.DVPortgroupConfigSpec
		$spec.Name = $PgName
		$spec.Type = $PgBinding
		$spec.numPorts = $PgNumberPorts
		$spec.defaultPortConfig = New-Object VMware.Vim.VMwareDVSPortSetting
		switch($PgVLANType.ToLower()){
			"vlan" {
				$spec.defaultPortConfig.VLAN = New-Object VMware.Vim.VmwareDistributedVirtualSwitchVlanIdSpec
				$spec.defaultPortConfig.VLAN.vlanId = $PgVLANId[0]
			}
			"vlan trunking" {
				$spec.defaultPortConfig.VLAN = New-Object VMware.Vim.VmwareDistributedVirtualSwitchTrunkVlanSpec
				$spec.defaultPortConfig.VLAN.vlanId = Get-VLANRanges $PgVLANId
			}
			"private vlan" {
				$spec.defaultPortConfig.VLAN = New-Object VMware.Vim.VmwareDistributedVirtualSwitchPvlanSpec
				$spec.defaultPortConfig.VLAN.pvlanId = $PgVLANId[0]
			}
			Default{}
		}

		$spec.defaultPortConfig.securityPolicy = New-Object VMware.Vim.DVSSecurityPolicy
		$spec.defaultPortConfig.securityPolicy.allowPromiscuous = New-Object VMware.Vim.BoolPolicy
		$spec.defaultPortConfig.securityPolicy.allowPromiscuous.Value = $SecPolPromiciousMode
		$spec.defaultPortConfig.securityPolicy.forgedTransmits = New-Object VMware.Vim.BoolPolicy
		$spec.defaultPortConfig.securityPolicy.forgedTransmits.Value = $SecPolForgedTransmits
		$spec.defaultPortConfig.securityPolicy.macChanges = New-Object VMware.Vim.BoolPolicy
		$spec.defaultPortConfig.securityPolicy.macChanges.Value = $SecPolMacChanges

		$spec.defaultPortConfig.uplinkTeamingPolicy = New-Object VMware.Vim.VmwareUplinkPortTeamingPolicy
		$spec.defaultPortConfig.uplinkTeamingPolicy.failureCriteria = New-Object VMware.Vim.DVSFailureCriteria
		if($TeamingCheckDuplex){
			$spec.defaultPortConfig.uplinkTeamingPolicy.failureCriteria.checkDuplex = $TeamingCheckDuplex
			$spec.defaultPortConfig.uplinkTeamingPolicy.failureCriteria.fullDuplex = $TeamingFullDuplex
		}
		if($TeamingCheckErrorPercent){
			$spec.defaultPortConfig.uplinkTeamingPolicy.failureCriteria.checkErrorPercent = $TeamingCheckErrorPercent
			$spec.defaultPortConfig.uplinkTeamingPolicy.failureCriteria.percentage = $TeamingPercentage
		}
		if("exact","minimum" -contains $TeamingCheckSpeed){
			$spec.defaultPortConfig.uplinkTeamingPolicy.failureCriteria.checkSpeed = $TeamingCheckSpeed
			$spec.defaultPortConfig.uplinkTeamingPolicy.failureCriteria.speed = $TeamingSpeed
		}
		$spec.defaultPortConfig.uplinkTeamingPolicy.notifySwitches = New-Object VMware.Vim.BoolPolicy
		$spec.defaultPortConfig.uplinkTeamingPolicy.notifySwitches.Value = $TeamingNotifySwitches
		if($teamingPolicies -contains $TeamingPolicy){
			$spec.defaultPortConfig.uplinkTeamingPolicy.policy = New-Object VMware.Vim.StringPolicy
			$spec.defaultPortConfig.uplinkTeamingPolicy.policy.Value = $TeamingPolicy
		}
		$spec.defaultPortConfig.uplinkTeamingPolicy.reversePolicy = New-Object VMware.Vim.BoolPolicy
		$spec.defaultPortConfig.uplinkTeamingPolicy.reversePolicy.Value = $TeamingReversePolicy
		$spec.defaultPortConfig.uplinkTeamingPolicy.rollingOrder = New-Object VMware.Vim.BoolPolicy
		$spec.defaultPortConfig.uplinkTeamingPolicy.rollingOrder.Value = $TeamingRollingOrder
		$spec.defaultPortConfig.uplinkTeamingPolicy.uplinkPortOrder = New-Object VMware.Vim.VMwareUplinkPortOrderPolicy
		$spec.defaultPortConfig.uplinkTeamingPolicy.uplinkPortOrder.activeUplinkPort = $TeamingActiveUplink
		$spec.defaultPortConfig.uplinkTeamingPolicy.uplinkPortOrder.standbyUplinkPort = $TeamingStandbyUplink

		$taskMoRef = $dvSw.AddDVPortgroup_Task($spec)
		$task = Get-View $taskMoRef
		while("running","queued" -contains $task.Info.State){
			$task.UpdateViewData("Info")
		}
		$task.Info.Result
	}
}
