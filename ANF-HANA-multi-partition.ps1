<#
 .Synopsis
  Creates multiple Azure NetApp Files application volume groups (AVGs) to support multi-partition deployments.

 .Description
  For larger HANA systems, such as the new 24TiB VMs, a single data volume does not deliver enough performance and capacity.
  For this scenario, SAP supports 'multiple partitions' (MP) where the SAP HANA database is striped across multiple volumes.
  This script automates the deployment of multiple Azure NetApp Files application volumes groups (AVGs) to support SAP HANA databases
  striped across one or more data volume partitions.

 .Parameter SID
  The SAP ID (SID).

 .Parameter Partitions
  The number of data partitions required. Default is 4.

 .Parameter DataPartitionSizeGiB
  The desired size of each data partition in gibibytes.

 .Parameter DataPartitionTPutMiBps
  The desired throughput of each data partition in mebibytes per second.

 .Parameter SharedVolSizeGiB
  The desired size of the shared volume in gibibytes.

 .Parameter SharedVolTPutMiBps
  The desired throughput of the shared volume in mebibytes per second.

 .Parameter LogVolumeSizeGiB
  The desired size of the log volume in gibibytes.

 .Parameter LogVolSizeTPutMiBps
  The desired throughput of the log volume in mebibytes per second.

 .Parameter SubnetId
  The Azure resource Id of the subnet that is delegated to Azure NetApp Files.

 .Parameter ProximityPlacementGroupId
  The Azure resource Id of the proximity placement group that should be used for the application volume group deployment.

 .Parameter CapacityPoolId
  The Azure resource Id of the Azure NetApp Files capacity pool that will be used for the application volume group deployment.
  A capacity pool with the QoS type of 'manual' is required.

 .Parameter DeployForHSR
  If deploying for HSR, set this variable to $true. Application volume group names and volume names will have a prefix as defined by 'prefix'.
  Default is $false.

 .Parameter MountPoint
  This defines the volume name suffix. Default value is '-mnt00001'.

 .Parameter ConfigFile
  This defines the path to the config file used to define the parameters above instead of specifing via command line arguments.

 .Parameter CleanUponFail
  This determines whether the script should cleanup if any errors are detected. If set to true and errors are detected, script will delete all resources it created.

 .EXAMPLE
  ./ANF-HANA-multi-partition.ps1 -configFile ./config.ps1

 .EXAMPLE
  ./ANF-HANA-multi-partition.ps1 -numPartitions 4 -subnetId "subnetResourceId" -ppgId "ppgResourceId" -capacityPoolId "capacityPoolResourceId" -avgAppIdentifier "SH1" -mountPoint "-mnt00001" -deployForHSR $false -sharedVolSizeGiBs 1024 -sharedVolTPutMiBps 128 -logVolSizeGiBs 512 -logVolTPutMiBps 250 -dataVolSizeGiBs 4096 -dataVolTPutMiBps 300 -cleanUponFail $true
#>

param (
  [Parameter(ParameterSetName = "arg", Mandatory = $true, HelpMessage="The number of data partitions required.")]
  [Alias('partitions')]
  [int]$numPartitions,
  
  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The Azure resource Id of the subnet that is delegated to Azure NetApp Files.")]
  [string]$subnetId,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The Azure resource Id of the proximity placement group that should be used for the application volume group deployment.")]
  [string]$ppgId,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The Azure resource Id of the Azure NetApp Files capacity pool that will be used for the application volume group deployment. A capacity pool with the QoS type of 'manual' is required.")]
  [string]$capacityPoolId,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The SAP ID (SID).")]
  [Alias('sid')]
  [string]$avgAppIdentifier,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="This defines the volume name suffix. Default value is '-mnt00001'.")]
  [string]$mountPoint,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="If deploying for HSR, set this variable to true. Application volume group names and volume names will have a prefix as defined by 'prefix'. Default is false.")]
  [bool]$deployForHSR,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The desired size of the shared volume in gibibytes.")]
  [int]$sharedVolSizeGiBs,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The desired throughput of the shared volume in mebibytes per second.")]
  [int]$sharedVolTPutMiBps,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The desired size of the log volume in gibibytes.")]
  [int]$logVolSizeGiBs,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The desired throughput of the log volume in mebibytes per second.")]
  [int]$logVolTPutMiBps,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The desired size of each data partition in gibibytes.")]
  [int]$dataVolSizeGiBs,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="The desired throughput of each data partition in mebibytes per second.")]
  [int]$dataVolTPutMiBps,

  [Parameter(ParameterSetName = 'arg', Mandatory = $true, HelpMessage="This determines whether the script should cleanup if any errors are detected.")]
  [bool]$cleanUponFail=$true,

  [Parameter(ParameterSetName = 'file', Mandatory = $true, HelpMessage="The config file used to define the script parameters. For exeample: ./config.ps1")]
  [string]$configFile
  )

if($configFile) {
    . $configFile
}

try {
    $null = Get-AzResource -ResourceId $subnetId -ErrorAction Stop
}
catch {
    Write-Host 'Specified subnet not found.'
    Write-Host ""
    exit
}

try {
    $null = Get-AzResource -ResourceId $ppgId -ErrorAction Stop
}
catch {
    Write-Host 'Specified proximity placement group not found.'
    Write-Host ""
    exit
}

try {
    $capacityPoolDetails = Get-AzNetAppFilesPool -ResourceId $capacityPoolId -ErrorAction Stop
}
catch {
    Write-Host "Specified capacity pool not found."
    Write-Host ""
    exit
}

if($capacityPoolDetails.QosType -ne 'Manual') {
    Write-Host "Specified capacity pool does not have the correct QoS type. Capacity pool QoS type must be 'Manual'."
    Write-Host ""
    exit
}

$tempBufferTPutNeeded = 10 + (10 * $numPartitions)
$totalTPutRequested = $sharedVolTPutMiBps + $logVolTPutMiBps + ($numPartitions * $dataVolTPutMiBps)
$totalTPutNeeded = $tempBufferTPutNeeded + $totalTPutRequested
$availablePoolTPut = $capacityPoolDetails.TotalThroughputMibps - $capacityPoolDetails.UtilizedThroughputMibps
Write-Host ""
Write-Host "Capacity pool throughput requested (MiB/s)                    : $totalTPutRequested"
Write-Host "Capacity pool throughput needed for temporary volumes (MiB/s) : $tempBufferTPutNeeded"
Write-Host "Total capacity pool throughput needed (MiB/s)                 : $totalTPutNeeded"
Write-Host "Capacity Pool throughput available (MiB/s)                    : $availablePoolTPut"
if($totalTPutNeeded -gt $availablePoolTPut) {
  Write-Host ""
  Write-Host "Specifed capacity pool does not have enough available throughput. Increase capacity pool available throughput."
  Write-Host ""
  exit
}

$tempBufferCapNeeded = 100 + (100 * $numPartitions)
$totalCapRequested = $sharedVolSizeGiBs + $logVolSizeGiBs + ($numPartitions * $dataVolSizeGiBs)
$totalCapNeeded = $tempBufferCapNeeded + $totalCapRequested
$availablePoolCap = $capacityPoolDetails.Size/1024/1024/1024
Write-Host ""
Write-Host "Capacity pool capacity requested (GiB)                    : $totalCapRequested"
Write-Host "Capacity pool capacity needed for temporary volumes (GiB) : $tempBufferCapNeeded"
Write-Host "Total capacity pool capacity needed (GiB)                 : $totalCapNeeded"
Write-Host "Capacity Pool capacity available (GiB)                    : $availablePoolCap"
if($totalCapNeeded -gt $availablePoolCap) {
  Write-Host ""
  Write-Host "Specifed capacity pool does not have enough available capacity. Increase capacity pool capacity."
  Write-Host ""
  exit
}


if($deployForHSR -eq $true) {
  $prefix = 'HA-'
}else {
  $prefix = ''
}

$avgLocation = $capacityPoolDetails.Location
$serviceLevel = $capacityPoolDetails.ServiceLevel
$subId = $capacityPoolId.split('/')[2]
$resourceGroup = $capacityPoolId.split('/')[4]
$netappAccount = $capacityPoolId.split('/')[8]
$avgResourceIds = @()
$deleteVolResourceIds = @()
$dateStamp = Get-Date

# Create base AVG which includes 'shared' and 'log' volumes
$avgName = $prefix + 'SAP-HANA-' + $avgAppIdentifier + '-shared-log'
$avgDescription = $prefix + 'SAP-HANA shared and log volumes' + ' for ' + $avgAppIdentifier
$URI = '/subscriptions/' + $subId + '/resourceGroups/' + $resourceGroup + '/providers/Microsoft.NetApp/netappAccounts/' + $netappAccount + '/volumeGroups/' + $avgName + '?api-version=2022-05-01'
$avgResourceIds += $URI.split('?')[0]
$restParams = @{
  Path = $URI
  Method = 'PUT'
  Payload = '{
"location": "' + $avgLocation + '",
"properties": {
"groupMetaData": {
  "groupDescription": "' + $avgDescription + '",
  "applicationType": "SAP-HANA",
  "applicationIdentifier": "' + $avgAppIdentifier + '",
  "deploymentSpecId": "20542149-bfca-5618-1879-9863dc6767f1"
},
"volumes": [
  {
    "name": "' + $prefix + $avgAppIdentifier + '-shared",
    "properties": {
      "creationToken": "' + $prefix + $avgAppIdentifier + '-shared",
      "serviceLevel": "' + $serviceLevel + '",
      "throughputMibps": ' + $sharedVolTPutMiBps + ',
      "subnetId": "' + $subnetId + '",
      "usageThreshold": ' + $sharedVolSizeGiBs*1024*1024*1024 + ',
      "volumeSpecName": "shared",
      "capacityPoolResourceId": "' + $capacityPoolId + '",
      "proximityPlacementGroup": "' + $ppgId + '"
    }
  },
  {
      "name": "' + $prefix + $avgAppIdentifier + '-log' + $mountPoint + '",
      "properties": {
        "creationToken": "' + $prefix + $avgAppIdentifier + '-log' + $mountPoint + '",
        "serviceLevel": "' + $serviceLevel + '",
        "throughputMibps": ' + $logVolTPutMiBps + ',
        "subnetId": "' + $subnetId + '",
        "usageThreshold": ' + $logVolSizeGiBs*1024*1024*1024 + ',
        "volumeSpecName": "log",
        "capacityPoolResourceId": "' + $capacityPoolId + '",
        "proximityPlacementGroup": "' + $ppgId + '"
      }
    },
    {
      "name": "' + $prefix + $avgAppIdentifier + '-data-temp",
      "properties": {
        "creationToken": "' + $prefix + $avgAppIdentifier + '-data-temp",
        "serviceLevel": "' + $serviceLevel + '",
        "throughputMibps": ' + 10 + ',
        "subnetId": "' + $subnetId + '",
        "usageThreshold": ' + 100*1024*1024*1024 + ',
        "volumeSpecName": "data",
        "capacityPoolResourceId": "' + $capacityPoolId + '",
        "proximityPlacementGroup": "' + $ppgId + '"
      }
    }
  ]
}
}'
}

Write-Host ""
Write-Host "Creating base application volume group containing 'shared' and 'log' volumes: $avgName"
Write-Host ""
$null = Invoke-AzRestMethod @restParams

# Add base data volume to deleted volumes array
$baseDataVolResourceId = $capacityPoolId + '/volumes/' + $prefix + $avgAppIdentifier + '-data-temp'
$deleteVolResourceIds += $baseDataVolResourceId

# Create additional partition volumes
for ($partition = 1; $partition -le $numPartitions; $partition++) {
    $avgName = $prefix + 'SAP-HANA-' + $avgAppIdentifier + '-part' + $partition + $mountPoint # consider creating variable for this called 'mountPoint'
    $dataVolName = $prefix + $avgAppIdentifier + '-data-part' + $partition + $mountPoint
    $logVolName = $prefix + $avgAppIdentifier + '-log' + $partition + $mountPoint
    $volUsageThreshold = $dataVolSizeGiBs*1024*1024*1024
    $avgDescription = $prefix + 'Partition ' + $partition + ' for ' + $avgAppIdentifier + $mountPoint
    $URI = '/subscriptions/' + $subId + '/resourceGroups/' + $resourceGroup + '/providers/Microsoft.NetApp/netappAccounts/' + $netappAccount + '/volumeGroups/' + $avgName + '?api-version=2022-05-01'
    $avgResourceIds += $URI.split('?')[0]
    $restParams = @{
        Path = $URI
        Method = 'PUT'
        Payload = '{
    "location": "' + $avgLocation + '",
    "properties": {
      "groupMetaData": {
        "groupDescription": "' + $avgDescription + '",
        "applicationType": "SAP-HANA",
        "applicationIdentifier": "' + $avgAppIdentifier + '",
        "deploymentSpecId": "20542149-bfca-5618-1879-9863dc6767f1"
      },
      "volumes": [
        {
          "name": "' + $dataVolName + '",
          "properties": {
            "creationToken": "' + $dataVolName + '",
            "serviceLevel": "' + $serviceLevel + '",
            "throughputMibps": ' + $dataVolTPutMiBps + ',
            "subnetId": "' + $subnetId + '",
            "usageThreshold": ' + $volUsageThreshold + ',
            "volumeSpecName": "data",
            "capacityPoolResourceId": "' + $capacityPoolId + '",
            "proximityPlacementGroup": "' + $ppgId + '"
          }
        },
        {
            "name": "' + $logVolName + '-temp",
            "properties": {
              "creationToken": "' + $logVolName + '-temp",
              "serviceLevel": "' + $serviceLevel + '",
              "throughputMibps": ' + 10 + ',
              "subnetId": "' + $subnetId + '",
              "usageThreshold": ' + 100*1024*1024*1024 + ',
              "volumeSpecName": "log",
              "capacityPoolResourceId": "' + $capacityPoolId + '",
              "proximityPlacementGroup": "' + $ppgId + '"
            }
          }
        ]
      }
    }'
    }
    Write-Host "Creating data partition application volume group for partition"$partition": "$avgName
    $null = Invoke-AzRestMethod @restParams
    # Add each log volume to deleted volumes array
    $logVolumeResourceId = $capacityPoolId + '/volumes/' + $logVolname + '-temp'
    $deleteVolResourceIds += $logVolumeResourceId
}

Write-Host ""
Write-Host "Sleeping for 3 minutes while application volume groups are created..."
Write-Host ""
Start-Sleep -Seconds 180

Write-Host "Checking status of application volume groups..."
Write-Host ""
$allAvgSuccess = $false
$errorDetected = $false
while($allAvgSuccess -eq $false -and $errorDetected -eq $false){
  $allAvgSuccess = $true
  foreach($avgResourceId in $avgResourceIds){
    $avgCreatedName = $avgResourceId.split('/')[10]
    $successStatus = (Get-AzActivityLog -ResourceProvider Microsoft.NetApp -StartTime $dateStamp -WarningAction SilentlyContinue | Where-Object {$_.ResourceId -eq $avgResourceId -and $_.Status -eq "Succeeded"}).Status
    $failedStatus = (Get-AzActivityLog -ResourceProvider Microsoft.NetApp -StartTime $dateStamp -WarningAction SilentlyContinue | Where-Object {$_.ResourceId -eq $avgResourceId -and $_.Status -eq "Failed"}).Status
    if($successStatus -ne 'Succeeded') {
      $successStatus = 'Pending...'
    }
    if($failedStatus -eq 'Failed') {
      $successStatus = 'Failed'
    }
    Write-Host "  Status of AVG creation for"$avgCreatedName": "$successStatus
    if($failedStatus -eq 'Failed') {
      $errorDetected = $true
    }
    if($successStatus -ne 'Succeeded'){
      $allAvgSuccess = $false
    }
  }
  if($allAvgSuccess -eq $false -and $errorDetected -eq $false){
    Write-Host ""
    Write-Host "Application volume groups still creating, sleeping for 1 minute..."
    Write-Host ""
    Start-Sleep 60
  }
}

if($errorDetected -eq $true) {
  Write-Host ""
  Write-Host "Problem creating one or more application volume groups."
  Write-Host "Check the activity log within the Azure portal for more details."
  Write-Host ""
  if($cleanUponFail -eq $true) {
    Write-Host "Begining cleanup process..."
    $avgDetails = $null
    foreach($avgResourceId in $avgResourceIds) {
      try {
        Write-Host "Checking for application volume group with the following resource Id:"
        Write-Host "  "$avgResourceId
        Write-Host ""
        $avgDetails = Get-AzNetAppFilesVolumeGroup -ResourceId $avgResourceId -ErrorAction Stop
      }
      catch {
        Write-Host ""
        Write-Host "Application volume group not found, nothing to clean up."
        Write-Host ""
      }
      if($avgDetails) {
        foreach($volume in $avgDetails.volumes){
          Write-Host "Deleting volume:"$volume.Name
          Write-Host ""
          Remove-AzNetAppFilesVolume -ResourceId $volume.Id
        }
        Write-Host "Deleting application volume group with resource Id:"
        Write-Host "  "$avgResourceId
        Write-Host ""
        Remove-AzNetAppFilesVolumeGroup -ResourceId $avgResourceId
      }
    }
  }else {
    exit
  }
}else {
  Write-Host ""
  Write-Host "All application volume groups created successfully!"
  Write-Host ""
  Write-Host "Deleting temporary data and log volumes..."
  foreach($deleteVolResourceId in $deleteVolResourceIds) {
    $volName = $deleteVolResourceId.split('/')[12]
    Write-Host "  Deleting temporary volume:"$volName
    Remove-AzNetAppFilesVolume -ResourceId $deleteVolResourceId
  }

  Write-Host ""
  Write-Host "The following application volume groups were created:"
  foreach($avgResourceId in $avgResourceIds){
    $avgDetails = Get-AzNetAppFilesVolumeGroup -ResourceId $avgResourceId
    $avgName = ($avgDetails.Name).split('/')[1]
    Write-Host ""
    Write-Host 'Group name: '$avgDetails.Name
    Write-Host 'Group description: '$avgDetails.GroupMetaData.GroupDescription
    foreach($volume in $avgDetails.volumes){
      $volSize = $volume.usageThreshold / 1024 / 1024 / 1024
      $volMountPath = $volume.mountTargets[0].ipAddress + ':/' + $volume.creationToken
      Write-Host '  Volume: '$volume.creationToken
      Write-Host '    size (GiB):'$volSize
      Write-Host '    throughput (MiB/s):'$volume.throughputMibps
      Write-Host '    mount path:'$volMountPath
    }
  }
}




