param(
    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$SubnetName,

    [string]$VirtualNetworkName = "vnet-eastus-2",

    [Parameter(Mandatory = $true)]
    [string]$NetworkInterfaceName,

    [bool]$EnableAcceleratedNetworking = $true,

    [Parameter(Mandatory = $true)]
    [string]$NetworkSecurityGroupName,

    [Parameter(Mandatory = $true)]
    [object[]]$NetworkSecurityGroupRules,

    [Parameter(Mandatory = $true)]
    [string]$VirtualMachineName,

    [Parameter(Mandatory = $true)]
    [string]$VirtualMachineComputerName,

    [Parameter(Mandatory = $true)]
    [string]$VirtualMachineRG,

    [string]$VirtualMachineSize = "Standard_D4s_v5",

    [string]$OSDiskType = "Premium_LRS",

    [string]$OSDiskDeleteOption = "Delete",

    [string]$DiskControllerType = "SCSI",

    [string]$NICDeleteOption = "Delete",

    [string]$SecurityType = "TrustedLaunch",

    [bool]$SecureBoot = $true,

    [bool]$vTPM = $true,

    [Parameter(Mandatory = $true)]
    [string]$AdminUsername,

    [Parameter(Mandatory = $true)]
    [System.Security.SecureString]$AdminPassword,

    [string]$PatchMode = "AutomaticByOS",

    [string]$EnablePeriodicAssessment = "ImageDefault",

    [bool]$EnableHotpatching = $false,

    [bool]$HibernationEnabled = $false,

    [string]$KeyVaultName = "CTX-KV-BUILD",

    [string]$DomainCredentialSecretName = "azureuser",

    [string]$DomainName = "alphaq.com",

    [string]$DomainOUPath = "",

    [string]$DomainDNS = "172.16.0.4"
)

$ErrorActionPreference = "Stop"

$SubscriptionId = "ca16a05c-d19b-4147-a90d-37bf25f100ef"
$NetworkResourceGroup = "Citrix_Build"
$VNetName = $VirtualNetworkName
$VNetId = "/subscriptions/$SubscriptionId/resourceGroups/$NetworkResourceGroup/providers/Microsoft.Network/virtualNetworks/$VNetName"

Write-Output "============================================================"
Write-Output "Citrix DDC Machine Creation"
Write-Output "============================================================"

Write-Output "VM              : $VirtualMachineName"
Write-Output "Computer Name   : $VirtualMachineComputerName"
Write-Output "VM RG           : $VirtualMachineRG"
Write-Output "VNet            : $VNetName"
Write-Output "Subnet          : $SubnetName"
Write-Output "DNS             : $DomainDNS"
Write-Output "Domain          : $DomainName"
Write-Output "VM Size         : $VirtualMachineSize"

# ------------------------------------------------------------
# Azure authentication
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Connecting to Azure"
Write-Output "============================================================"

Import-Module Az.Accounts -Force
Import-Module Az.Compute -Force
Import-Module Az.Network -Force
Import-Module Az.Resources -Force

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

Write-Output "Azure authentication: SUCCESS"

# ------------------------------------------------------------
# Resolve network
# ------------------------------------------------------------

Write-Output ""
Write-Output "Resolving VNet and subnet..."

$VNet = Get-AzVirtualNetwork `
    -ResourceGroupName $NetworkResourceGroup `
    -Name $VNetName `
    -ErrorAction Stop

$Subnet = Get-AzVirtualNetworkSubnetConfig `
    -VirtualNetwork $VNet `
    -Name $SubnetName `
    -ErrorAction Stop

Write-Output "VNet   : $($VNet.Name)"
Write-Output "Subnet : $($Subnet.Name)"
Write-Output "Prefix : $($Subnet.AddressPrefix)"

# ------------------------------------------------------------
# Resource group
# ------------------------------------------------------------

if (-not (Get-AzResourceGroup -Name $VirtualMachineRG -ErrorAction SilentlyContinue)) {
    Write-Output "Creating resource group: $VirtualMachineRG"

    New-AzResourceGroup `
        -Name $VirtualMachineRG `
        -Location $Location `
        -ErrorAction Stop | Out-Null
}

# ------------------------------------------------------------
# NSG
# ------------------------------------------------------------

Write-Output ""
Write-Output "Creating / updating Network Security Group..."

$NSG = Get-AzNetworkSecurityGroup `
    -ResourceGroupName $VirtualMachineRG `
    -Name $NetworkSecurityGroupName `
    -ErrorAction SilentlyContinue

if (-not $NSG) {

    $NSG = New-AzNetworkSecurityGroup `
        -ResourceGroupName $VirtualMachineRG `
        -Location $Location `
        -Name $NetworkSecurityGroupName `
        -ErrorAction Stop
}

foreach ($Rule in $NetworkSecurityGroupRules) {

    $ExistingRule = $NSG.SecurityRules |
        Where-Object Name -eq $Rule.name

    if (-not $ExistingRule) {

        $Params = @{
            Name                     = $Rule.name
            Description              = $Rule.description
            Access                   = $Rule.access
            Protocol                 = $Rule.protocol
            Direction                = $Rule.direction
            Priority                 = [int]$Rule.priority
            SourceAddressPrefix      = $Rule.sourceAddressPrefix
            SourcePortRange          = $Rule.sourcePortRange
            DestinationAddressPrefix = $Rule.destinationAddressPrefix
            DestinationPortRange     = $Rule.destinationPortRange
        }

        Add-AzNetworkSecurityRuleConfig `
            -NetworkSecurityGroup $NSG `
            @Params | Out-Null
    }
}

$NSG = Set-AzNetworkSecurityGroup `
    -NetworkSecurityGroup $NSG `
    -ErrorAction Stop

Write-Output "NSG ready: $NetworkSecurityGroupName"

# ------------------------------------------------------------
# NIC
# ------------------------------------------------------------

Write-Output ""
Write-Output "Creating NIC with DHCP private IP..."

$ExistingNIC = Get-AzNetworkInterface `
    -ResourceGroupName $VirtualMachineRG `
    -Name $NetworkInterfaceName `
    -ErrorAction SilentlyContinue

if ($ExistingNIC) {
    throw "NIC '$NetworkInterfaceName' already exists."
}

$NIC = New-AzNetworkInterface `
    -ResourceGroupName $VirtualMachineRG `
    -Location $Location `
    -Name $NetworkInterfaceName `
    -SubnetId $Subnet.Id `
    -NetworkSecurityGroupId $NSG.Id `
    -EnableAcceleratedNetworking:$EnableAcceleratedNetworking `
    -PrivateIpAddressVersion IPv4 `
    -ErrorAction Stop

Write-Output "NIC created."

# ------------------------------------------------------------
# DNS
# ------------------------------------------------------------

Write-Output ""
Write-Output "Setting NIC DNS server to $DomainDNS..."

$NIC.DnsSettings.DnsServers = @($DomainDNS)

$NIC = Set-AzNetworkInterface `
    -NetworkInterface $NIC `
    -ErrorAction Stop

Write-Output "DNS configured."

# ------------------------------------------------------------
# VM
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Creating Windows Server 2022 VM"
Write-Output "============================================================"

$Credential = New-Object System.Management.Automation.PSCredential(
    $AdminUsername,
    $AdminPassword
)

$OSDisk = New-AzDiskConfig `
    -AccountType $OSDiskType `
    -Location $Location `
    -CreateOption Empty

$VMConfig = New-AzVMConfig `
    -VMName $VirtualMachineName `
    -VMSize $VirtualMachineSize `
    -SecurityType $SecurityType `
    -EnableVtpm:$vTPM `
    -EnableSecureBoot:$SecureBoot

$VMConfig = Set-AzVMOperatingSystem `
    -VM $VMConfig `
    -Windows `
    -ComputerName $VirtualMachineComputerName `
    -Credential $Credential `
    -ProvisionVMAgent `
    -EnableAutoUpdate

$VMConfig = Set-AzVMSourceImage `
    -VM $VMConfig `
    -PublisherName "MicrosoftWindowsServer" `
    -Offer "WindowsServer" `
    -Skus "2022-datacenter-smalldisk-g2" `
    -Version "latest"

$VMConfig = Add-AzVMNetworkInterface `
    -VM $VMConfig `
    -Id $NIC.Id `
    -DeleteOption $NICDeleteOption

$VMConfig = Set-AzVMOSDisk `
    -VM $VMConfig `
    -StorageAccountType $OSDiskType `
    -DiskSizeInGB 127 `
    -CreateOption FromImage `
    -DeleteOption $OSDiskDeleteOption

$VMConfig = Set-AzVMUefi `
    -VM $VMConfig `
    -EnableVtpm $vTPM `
    -EnableSecureBoot $SecureBoot

New-AzVM `
    -ResourceGroupName $VirtualMachineRG `
    -Location $Location `
    -VM $VMConfig `
    -ErrorAction Stop | Out-Null

Write-Output "VM provisioning: SUCCESS"

# ------------------------------------------------------------
# Retrieve DHCP-assigned IP
# ------------------------------------------------------------

Write-Output ""
Write-Output "Retrieving DHCP-assigned private IP..."

$NIC = Get-AzNetworkInterface `
    -ResourceGroupName $VirtualMachineRG `
    -Name $NetworkInterfaceName `
    -ErrorAction Stop

$PrivateIP = $NIC.IpConfigurations[0].PrivateIpAddress

if ([string]::IsNullOrWhiteSpace($PrivateIP)) {
    throw "Azure did not return a private IP for the new NIC."
}

Write-Output "DHCP assigned IP: $PrivateIP"

# ------------------------------------------------------------
# Convert the SAME IP from Dynamic to Static
# ------------------------------------------------------------

Write-Output ""
Write-Output "Converting $PrivateIP from Dynamic to Static..."

$NIC.IpConfigurations[0].PrivateIpAllocationMethod = "Static"
$NIC.IpConfigurations[0].PrivateIpAddress = $PrivateIP
$NIC.DnsSettings.DnsServers = @($DomainDNS)

$NIC = Set-AzNetworkInterface `
    -NetworkInterface $NIC `
    -ErrorAction Stop

Write-Output "Private IP is now STATIC: $PrivateIP"
Write-Output "DNS server: $DomainDNS"

# ------------------------------------------------------------
# Domain credential from Key Vault REST API
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Retrieving Domain Join Credential"
Write-Output "============================================================"

$TokenResponse = Invoke-RestMethod `
    -Method GET `
    -Headers @{ Metadata = "true" } `
    -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
    -ErrorAction Stop

$KVHeaders = @{
    Authorization = "Bearer $($TokenResponse.access_token)"
}

$SecretUri = "https://$KeyVaultName.vault.azure.net/secrets/$DomainCredentialSecretName?api-version=7.4"

$SecretResponse = Invoke-RestMethod `
    -Method GET `
    -Uri $SecretUri `
    -Headers $KVHeaders `
    -ErrorAction Stop

$DomainCredentialData = $SecretResponse.value | ConvertFrom-Json

$DomainPassword = ConvertTo-SecureString `
    $DomainCredentialData.Password `
    -AsPlainText `
    -Force

$DomainCredential = New-Object System.Management.Automation.PSCredential(
    $DomainCredentialData.Username,
    $DomainPassword
)

Write-Output "Domain credential retrieved successfully."

# ------------------------------------------------------------
# Wait for Azure VM agent
# ------------------------------------------------------------

Write-Output ""
Write-Output "Waiting for Azure VM Agent..."

for ($i = 1; $i -le 30; $i++) {

    $VM = Get-AzVM `
        -ResourceGroupName $VirtualMachineRG `
        -Name $VirtualMachineName `
        -Status `
        -ErrorAction Stop

    $Agent = $VM.VMAgent.Statuses |
        Where-Object Code -like "ProvisioningState/*"

    if ($Agent.DisplayStatus -eq "Ready") {
        Write-Output "Azure VM Agent: READY"
        break
    }

    if ($i -eq 30) {
        throw "Azure VM Agent did not become ready within the timeout."
    }

    Start-Sleep -Seconds 10
}

# ------------------------------------------------------------
# Domain Join Extension
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Joining $VirtualMachineComputerName to $DomainName"
Write-Output "============================================================"

$DomainJoinSettings = @{
    Name    = $DomainName
    OUPath  = $DomainOUPath
    User    = $DomainCredentialData.Username
    Restart = "true"
    Options = "3"
}

$DomainJoinProtectedSettings = @{
    Password = $DomainCredentialData.Password
}

Set-AzVMExtension `
    -ResourceGroupName $VirtualMachineRG `
    -VMName $VirtualMachineName `
    -Name "joindomain" `
    -Publisher "Microsoft.Compute" `
    -ExtensionType "JsonADDomainExtension" `
    -TypeHandlerVersion "1.3" `
    -Settings $DomainJoinSettings `
    -ProtectedSettings $DomainJoinProtectedSettings `
    -Location $Location `
    -ErrorAction Stop | Out-Null

Write-Output "Domain Join extension completed."

# ------------------------------------------------------------
# Final NIC verification
# ------------------------------------------------------------

$NIC = Get-AzNetworkInterface `
    -ResourceGroupName $VirtualMachineRG `
    -Name $NetworkInterfaceName `
    -ErrorAction Stop

$FinalIP = $NIC.IpConfigurations[0].PrivateIpAddress
$FinalAllocation = $NIC.IpConfigurations[0].PrivateIpAllocationMethod
$FinalDNS = $NIC.DnsSettings.DnsServers -join ", "

Write-Output ""
Write-Output "============================================================"
Write-Output "DDC MACHINE CREATION COMPLETED"
Write-Output "============================================================"

Write-Output "VM Name       : $VirtualMachineName"
Write-Output "Computer Name : $VirtualMachineComputerName"
Write-Output "Resource Group: $VirtualMachineRG"
Write-Output "Private IP    : $FinalIP"
Write-Output "IP Allocation : $FinalAllocation"
Write-Output "DNS Server    : $FinalDNS"
Write-Output "Domain        : $DomainName"
Write-Output "OS            : Windows Server 2022 Datacenter Small Disk Gen2"
Write-Output "Accelerated   : $EnableAcceleratedNetworking"
Write-Output "Secure Boot   : $SecureBoot"
Write-Output "vTPM          : $vTPM"
Write-Output "============================================================"

if ($FinalIP -ne $PrivateIP) {
    throw "Private IP changed unexpectedly from $PrivateIP to $FinalIP."
}

if ($FinalAllocation -ne "Static") {
    throw "Private IP $FinalIP is not configured as Static."
}

if ($FinalDNS -notmatch [regex]::Escape($DomainDNS)) {
    throw "NIC DNS configuration does not contain $DomainDNS."
}

Write-Output "READY FOR DDC PART 1"
