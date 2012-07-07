<#
Updated Script to remediate VMware vSphere VDS/sVmotion Issue
Originally written by Alan Renouf at http://www.virtu-al.net
Also Updated by LucD - http://www.lucd.info/

.Purpose
This script fixes a known bug in VMware vSphere version 5. There is no official patch to correct the issue so running
this script on a regular basis will remediate the issue. 

.Requirements
PowerCLI 5.0.1 - http://vmware.com/downloads/download.do?downloadGroup=PCLI501

.Usage
# Example code to check all VMs attached to vCenter for the issue:
# Get-VM | Test-VDSVMIssue

# Example code to fix all VMs attached to vCenter:
# Get-VM | Test-VDSVMIssue -Fix

# Example code to fix all VMs in Cluster01 for the issue:
# Get-Cluster01 | Get-VM | Test-VDSVMIssue

# Example code to fix all VMs in Cluster01:
# Get-Cluster01 | Get-VM | Test-VDSVMIssue -Fix

#>

Function Get-FreeVDSPort ($VDSPG) {
	$nicTypes = "VirtualE1000","VirtualE1000e","VirtualPCNet32","VirtualVmxnet","VirtualVmxnet2","VirtualVmxnet3"
	$ports = @{}

	# Get all the portkeys on the portgroup
	$VDSPG.ExtensionData.PortKeys | Foreach {
		$ports.Add($_,$VDSPG.Name)
	}

	# Remove the portkeys in use  Get-View
	$VDSPG.ExtensionData.Vm | Foreach {
	    $VMView = Get-View $_
		$nic = $VMView.Config.Hardware.Device | where {$nicTypes -contains $_.GetType().Name -and $_.Backing.GetType().Name -match "Distributed"}
	    $nic | where {$_.Backing.Port.PortKey} | Foreach {$ports.Remove($_.Backing.Port.PortKey)}
	}

	# Assign the first free portkey
	if ($ports.Count -eq 0) {
		$null
	} Else {
		$ports.Keys | Select -First 1
	}
}

Function Set-VDSPGNumPorts ($VDSPG, $NumPorts) {
	$spec = New-Object VMware.Vim.DVPortgroupConfigSpec
    $spec.numPorts = $NumPorts
	$spec.ConfigVersion = $VDSPG.ExtensionData.Config.Configversion
    $VDSPG.ExtensionData.ReconfigureDVPortgroup($spec)
}

Function Test-VDSVMIssue {
	Param (
		[parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [PSObject[]]$VM,
		[switch]$Fix
	)
	Process {
		Foreach ($VMachine in $VM){
			Foreach ($NA in ($VMachine | Get-NetworkAdapter)) {
				$VMName = $VMachine.Name
				If (($NA.ExtensionData.Backing.GetType()).Name -eq "VirtualEthernetCardDistributedVirtualPortBackingInfo") {
					$PortKey = $NA.ExtensionData.Backing.Port.PortKey
					$vSwitchID = $NA.ExtensionData.Backing.Port.SwitchUUID
					$Datastore = (($VMachine.ExtensionData.Config.Files.VmPathName).split("]")[0]).Replace("[","")
					$filename = "$($datastore):\.dvsData\$vSwitchID\$PortKey"
					if (-not (Get-PSDrive $datastore -ErrorAction SilentlyContinue)) {
						$NewDrive = New-PSDrive -Name $Datastore -Location (Get-Datastore $Datastore) -PSProvider VimDatastore -Root '\'
					}
					$filecheck = Get-ChildItem -Path $filename -ErrorAction SilentlyContinue
					if ($filecheck) {
						Write-Host -ForegroundColor Green "$VMName $($NA.Name) is OK"
					} Else {
						Write-Host -ForegroundColor Red "Problem found with $VMName $($NA.Name)"
						If ($Fix) {
							Write-Host -ForegroundColor Yellow "Fixing issue..."
							$VDSPG = Get-VirtualPortGroup -Distributed -Name $NA.NetworkName
							$DVPort = $null
							Write-Host -ForegroundColor Yellow "..Finding free port on $($NA.NetworkName)"
							$DVPort = Get-FreeVDSPort $VDSPG
							$Move = $True
							if (-not $DVPort) {
								Write-Host -ForegroundColor Yellow "..No free ports found on $($VDSPG.Name), adding an additional port"
								If (($VDSPG.ExtensionData.Config.Type -ne "lateBinding") -and ($VDSPG.ExtensionData.Config.Type -ne "earlyBinding")) {
									Write "Unable to add a port to $($NA.NetworkName) since dvportgroup is configured as $($VDSPG.PortBinding)"
									Write-Host -ForegroundColor Red "Problem still exists with $VMName please resolve manually"
									$Move = $false
								} Else {
									$CurrentPorts = $VDSPG.NumPorts
									$NewTotalPorts = $VDSPG.NumPorts + 1
									Set-VDSPGNumPorts -VDSPG $VDSPG -NumPorts $NewTotalPorts
									$PGAdded = $true
									$VDSPG = Get-VirtualPortGroup -Distributed -Name $NA.NetworkName
									$DVPort = Get-FreeVDSPort $VDSPG
								}
							}
							If ($Move){
								Write-Host -ForegroundColor Yellow "..Moving $($NA.Name) to another free port on $($VDSPG.Name)"
								$NA | Set-NetworkAdapter -PortKey $DVPort -DistributedSwitch $VDSPG.VirtualSwitch -Confirm:$false | Out-Null
								Write-Host -ForegroundColor Yellow "..Moving $($NA.Name) back to port $PortKey"
								$NA | Set-NetworkAdapter -PortKey $PortKey -DistributedSwitch $VDSPG.VirtualSwitch -Confirm:$false | Out-Null
								Write-Host -ForegroundColor Yellow "..Checking changes were completed"
								$filecheck = Get-ChildItem -Path $filename -ErrorAction SilentlyContinue
								if ($filecheck) {
									Write-Host -ForegroundColor Green "$VMName $($NA.Name) is now fixed and OK"
								} Else {
									Write-Host -ForegroundColor Red "Problem still exists with $VMName please resolve manually"
								}
								If ($PGAdded) {
									Write-Host -ForegroundColor Yellow "..Removing the added port on $($VDSPG.Name)"
									Set-VDSPGNumPorts -VDSPG $VDSPG -NumPorts $CurrentPorts
									$PGAdded = $false
								}
							}
						}
					}
				} Else {
					Write-Host -ForegroundColor Green "$VMName is not connected to a dvSwitch so this issue is not relevant."
				}
			}
		}
		Get-PSDrive | Where { ($_.Provider -like "*VimDatastore") -and ( $_.Name -notlike "*vmstore*")} | Foreach {
			Remove-PSDrive $_ | Out-Null
		}
	}
}

