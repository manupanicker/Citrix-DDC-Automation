param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')]
    [string]$MachineName
)

$ErrorActionPreference = "Stop"

# ============================================================
# HARD-CODED DDC BUILD CONFIGURATION
# ============================================================

$SubscriptionId = "ca16a05c-d19b-4147-a90d-37bf25f100ef"
$ResourceGroup  = "CITRIX_BUILD"
$Location       = "eastus"

$VNetResourceGroup = "Citrix_Build"
$VNetName          = "vnet-eastus-2"
$SubnetName        = "snet-eastus-1"

$DomainName = "alphaq.com"
$DomainDNS  = "172.16.0.4"

$VMSize             = "Standard_D2as_v7"
$OSDiskType         = "Premium_LRS"
$SecurityType       = "TrustedLaunch"
$SecureBoot         = $true
$vTPM               = $true
$AcceleratedNetwork = $true

$OSPublisher = "MicrosoftWindowsServer"
$OSOffer     = "WindowsServer"
$OSSku      = "2022-datacenter-smalldisk-g2"
$OSVersion  = "latest"

$OSDiskDeleteOption = "Delete"
$NICDeleteOption    = "Delete"
$DiskControllerType = "SCSI"

$KeyVaultName          = "CTX-KV-BUILD"
$DomainCredentialSecret = "azureuser"

$NICName = "$MachineName-nic"
$NSGName = "$MachineName-nsg"

# ============================================================
# HELPER
# ============================================================

function Write-Section {
    param([string]$Title)

    Write-Output ""
    Write-Output "============================================================"
    Write-Output $Title
    Write-Output "============================================================"
}

# ============================================================
# VALIDATION
# ============================================================

Write-Section "Citrix DDC Machine Creation"

Write-Output "Machine Name       : $MachineName"
Write-Output "VM Name            : $MachineName"
Write-Output "Computer Name      : $MachineName"
Write-Output "Resource Group     : $ResourceGroup"
Write-Output "Location           : $Location"
Write-Output "VNet               : $VNetName"
Write-Output "Subnet             : $SubnetName"
Write-Output "VM Size            : $VMSize"
Write-Output "DNS                : $DomainDNS"
Write-Output "Domain             : $DomainName"

if ($MachineName.Length -gt 15) {
    throw "MachineName exceeds the Windows computer-name limit of 15 characters."
}

# ============================================================
# AZURE MODULES / AUTHENTICATION
# ============================================================

Write-Section "Loading Azure PowerShell Modules"

Import-Module Az.Accounts -Force -ErrorAction Stop
Import-Module Az.Compute  -Force -ErrorAction Stop
Import-Module Az.Network  -Force -ErrorAction Stop
Import-Module Az.Resources -Force -ErrorAction Stop

Write-Output "Az modules loaded successfully."

Write-Section "Connecting to Azure"

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

Write-Output "Azure authentication: SUCCESS"
Write-Output "Subscription: $SubscriptionId"

# ============================================================
# CHECK FOR EXISTING VM
# ============================================================

Write-Section "Checking Existing Resources"

$ExistingVM = Get-AzVM `
    -ResourceGroupName $ResourceGroup `
    -Name $MachineName `
    -ErrorAction SilentlyContinue

if ($ExistingVM) {
    throw "A VM named '$MachineName' already exists in resource group '$ResourceGroup'."
}

$ExistingNIC = Get-AzNetworkInterface `
    -ResourceGroupName $ResourceGroup `
    -Name $NICName `
    -ErrorAction SilentlyContinue

if ($ExistingNIC) {
    throw "A NIC named '$NICName' already exists."
}

# ============================================================
# RESOURCE GROUP
# ============================================================

if (-not (Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue)) {
    Write-Output "Resource group '$ResourceGroup' does not exist. Creating it..."

    New-AzResourceGroup `
        -Name $ResourceGroup `
        -Location $Location `
        -ErrorAction Stop | Out-Null
}
else {
    Write-Output "Resource group '$ResourceGroup': EXISTS"
}

# ============================================================
# RESOLVE VNET / SUBNET
# ============================================================

Write-Section "Resolving Network"

$VNet = Get-AzVirtualNetwork `
    -ResourceGroupName $VNetResourceGroup `
    -Name $VNetName `
    -ErrorAction Stop

$Subnet = Get-AzVirtualNetworkSubnetConfig `
    -VirtualNetwork $VNet `
    -Name $SubnetName `
    -ErrorAction Stop

Write-Output "VNet   : $($VNet.Name)"
Write-Output "Subnet : $($Subnet.Name)"
Write-Output "Subnet ID: $($Subnet.Id)"

# ============================================================
# CREATE NSG
# ============================================================

Write-Section "Creating Network Security Group"

$NSG = Get-AzNetworkSecurityGroup `
    -ResourceGroupName $ResourceGroup `
    -Name $NSGName `
    -ErrorAction SilentlyContinue

if (-not $NSG) {

    $RdpRule = New-AzNetworkSecurityRuleConfig `
        -Name "RDP" `
        -Description "Allow RDP" `
        -Access Allow `
        -Protocol Tcp `
        -Direction Inbound `
        -Priority 300 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange 3389

    $NSG = New-AzNetworkSecurityGroup `
        -ResourceGroupName $ResourceGroup `
        -Location $Location `
        -Name $NSGName `
        -SecurityRules $RdpRule `
        -ErrorAction Stop
}
else {
    Write-Output "NSG already exists: $NSGName"
}

Write-Output "NSG ready: $NSGName"

# ============================================================
# CREATE NIC WITH DHCP
# ============================================================

Write-Section "Creating Network Interface"

$NIC = New-AzNetworkInterface `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -Name $NICName `
    -SubnetId $Subnet.Id `
    -NetworkSecurityGroupId $NSG.Id `
    -EnableAcceleratedNetworking:$AcceleratedNetwork `
    -PrivateIpAddressVersion IPv4 `
    -ErrorAction Stop

Write-Output "NIC created: $NICName"

# ============================================================
# CONFIGURE DNS
# ============================================================

Write-Section "Configuring DNS"

$NIC.DnsSettings.DnsServers = @($DomainDNS)

$NIC = Set-AzNetworkInterface `
    -NetworkInterface $NIC `
    -ErrorAction Stop

Write-Output "DNS server configured: $DomainDNS"

# ============================================================
# READ DHCP IP
# ============================================================

Write-Section "Reading DHCP Assigned IP"

$NIC = Get-AzNetworkInterface `
    -ResourceGroupName $ResourceGroup `
    -Name $NICName `
    -ErrorAction Stop

$AssignedIP = $NIC.IpConfigurations[0].PrivateIpAddress

if ([string]::IsNullOrWhiteSpace($AssignedIP)) {
    throw "Azure did not assign a private IP address to NIC '$NICName'."
}

Write-Output "DHCP assigned IP: $AssignedIP"

# ============================================================
# CONVERT SAME IP TO STATIC
# ============================================================

Write-Section "Converting DHCP IP To Static"

$NIC.IpConfigurations[0].PrivateIpAllocationMethod = "Static"
$NIC.IpConfigurations[0].PrivateIpAddress = $AssignedIP
$NIC.DnsSettings.DnsServers = @($DomainDNS)

$NIC = Set-AzNetworkInterface `
    -NetworkInterface $NIC `
    -ErrorAction Stop

Write-Output "Private IP: $AssignedIP"
Write-Output "Allocation : Static"
Write-Output "DNS        : $DomainDNS"

# ============================================================
# ADMIN CREDENTIAL
# ============================================================

Write-Section "Preparing Local Administrator Credential"

$AdminUsername = Get-AutomationVariable -Name "DDCAdminUsername"

if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
    throw "Automation variable 'DDCAdminUsername' is missing or empty."
}

$AdminPassword = Get-AutomationPSCredential -Name "DDCAdminCredential"

if (-not $AdminPassword) {
    throw "Automation credential 'DDCAdminCredential' was not found."
}

Write-Output "Administrator username: $AdminUsername"

# ============================================================
# CREATE VM
# ============================================================

Write-Section "Creating Windows Server 2022 VM"

$VMConfig = New-AzVMConfig `
    -VMName $MachineName `
    -VMSize $VMSize `
    -SecurityType $SecurityType

$VMConfig = Set-AzVMOperatingSystem `
    -VM $VMConfig `
    -Windows `
    -ComputerName $MachineName `
    -Credential $AdminPassword `
    -ProvisionVMAgent `
    -EnableAutoUpdate

$VMConfig = Set-AzVMSourceImage `
    -VM $VMConfig `
    -PublisherName $OSPublisher `
    -Offer $OSOffer `
    -Skus $OSSku `
    -Version $OSVersion

$VMConfig = Set-AzVMOSDisk `
    -VM $VMConfig `
    -StorageAccountType $OSDiskType `
    -CreateOption FromImage `
    -DeleteOption $OSDiskDeleteOption

$VMConfig = Add-AzVMNetworkInterface `
    -VM $VMConfig `
    -Id $NIC.Id `
    -Primary `
    -DeleteOption $NICDeleteOption

$VMConfig = Set-AzVMUefi `
    -VM $VMConfig `
    -EnableVtpm $vTPM `
    -EnableSecureBoot $SecureBoot

$VMConfig = Set-AzVMDiskController `
    -VM $VMConfig `
    -DiskControllerType $DiskControllerType

New-AzVM `
    -ResourceGroupName $ResourceGroup `
    -Location $Location `
    -VM $VMConfig `
    -ErrorAction Stop | Out-Null

Write-Output "VM provisioning: SUCCESS"

# ============================================================
# VERIFY VM
# ============================================================

Write-Section "Verifying VM"

$VM = Get-AzVM `
    -ResourceGroupName $ResourceGroup `
    -Name $MachineName `
    -Status `
    -ErrorAction Stop

$NIC = Get-AzNetworkInterface `
    -ResourceGroupName $ResourceGroup `
    -Name $NICName `
    -ErrorAction Stop

$FinalIP = $NIC.IpConfigurations[0].PrivateIpAddress
$FinalAllocation = $NIC.IpConfigurations[0].PrivateIpAllocationMethod
$FinalDNS = $NIC.DnsSettings.DnsServers -join ", "

Write-Output "VM Name       : $($VM.Name)"
Write-Output "VM Size       : $($VM.HardwareProfile.VmSize)"
Write-Output "Private IP    : $FinalIP"
Write-Output "IP Allocation : $FinalAllocation"
Write-Output "DNS           : $FinalDNS"

if ($FinalIP -ne $AssignedIP) {
    throw "Private IP changed unexpectedly. Expected '$AssignedIP', got '$FinalIP'."
}

if ($FinalAllocation -ne "Static") {
    throw "Private IP '$FinalIP' is not Static."
}

if ($FinalDNS -notmatch [regex]::Escape($DomainDNS)) {
    throw "NIC DNS is not configured to '$DomainDNS'."
}

# ============================================================
# DOMAIN JOIN CREDENTIAL FROM KEY VAULT REST API
# ============================================================

Write-Section "Retrieving Domain Join Credential"

$TokenResponse = Invoke-RestMethod `
    -Method GET `
    -Headers @{ Metadata = "true" } `
    -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
    -ErrorAction Stop

$KVHeaders = @{
    Authorization = "Bearer $($TokenResponse.access_token)"
}

$SecretUri = "https://$KeyVaultName.vault.azure.net/secrets/$DomainCredentialSecret?api-version=7.4"

$SecretResponse = Invoke-RestMethod `
    -Method GET `
    -Uri $SecretUri `
    -Headers $KVHeaders `
    -ErrorAction Stop

$SecretValue = $SecretResponse.value

if ([string]::IsNullOrWhiteSpace($SecretValue)) {
    throw "Key Vault secret '$DomainCredentialSecret' is empty."
}

# Supports the existing JSON credential format:
# {"Username":"ALPHAQ\azureuser","Password":"..."}
try {
    $DomainCredentialData = $SecretValue | ConvertFrom-Json -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($DomainCredentialData.Username) -or
        [string]::IsNullOrWhiteSpace($DomainCredentialData.Password)) {
        throw "JSON credential fields are missing."
    }

    $DomainUsername = $DomainCredentialData.Username
    $DomainPassword = $DomainCredentialData.Password
}
catch {
    throw "Key Vault secret '$DomainCredentialSecret' is not in the expected JSON credential format. Expected Username and Password."
}

Write-Output "Domain credential retrieved successfully."
Write-Output "Domain username: $DomainUsername"

# ============================================================
# WAIT FOR VM AGENT
# ============================================================

Write-Section "Waiting For Azure VM Agent"

$AgentReady = $false

for ($Attempt = 1; $Attempt -le 36; $Attempt++) {

    $VM = Get-AzVM `
        -ResourceGroupName $ResourceGroup `
        -Name $MachineName `
        -Status `
        -ErrorAction Stop

    $AgentStatus = $VM.VMAgent.Statuses |
        Where-Object { $_.Code -like "ProvisioningState/*" } |
        Select-Object -First 1

    if ($AgentStatus.DisplayStatus -eq "Ready") {
        $AgentReady = $true
        Write-Output "Azure VM Agent: READY"
        break
    }

    Write-Output "VM Agent not ready. Attempt $Attempt of 36..."
    Start-Sleep -Seconds 10
}

if (-not $AgentReady) {
    throw "Azure VM Agent did not become ready within 6 minutes."
}

# ============================================================
# DOMAIN JOIN
# ============================================================

Write-Section "Joining $MachineName To $DomainName"

$DomainJoinSettings = @{
    Name    = $DomainName
    User    = $DomainUsername
    Restart = "true"
    Options = "3"
}

$DomainJoinProtectedSettings = @{
    Password = $DomainPassword
}

Set-AzVMExtension `
    -ResourceGroupName $ResourceGroup `
    -VMName $MachineName `
    -Name "joindomain" `
    -Publisher "Microsoft.Compute" `
    -ExtensionType "JsonADDomainExtension" `
    -TypeHandlerVersion "1.3" `
    -Settings $DomainJoinSettings `
    -ProtectedSettings $DomainJoinProtectedSettings `
    -Location $Location `
    -ErrorAction Stop | Out-Null

Write-Output "Domain Join extension: SUCCESS"

# ============================================================
# FINAL VERIFICATION
# ============================================================

Write-Section "Final DDC Machine Verification"

$NIC = Get-AzNetworkInterface `
    -ResourceGroupName $ResourceGroup `
    -Name $NICName `
    -ErrorAction Stop

$FinalIP = $NIC.IpConfigurations[0].PrivateIpAddress
$FinalAllocation = $NIC.IpConfigurations[0].PrivateIpAllocationMethod
$FinalDNS = $NIC.DnsSettings.DnsServers -join ", "

Write-Output "============================================================"
Write-Output "DDC MACHINE CREATED SUCCESSFULLY"
Write-Output "============================================================"
Write-Output "VM Name       : $MachineName"
Write-Output "Computer Name : $MachineName"
Write-Output "Resource Group: $ResourceGroup"
Write-Output "Location      : $Location"
Write-Output "VM Size       : $VMSize"
Write-Output "Private IP    : $FinalIP"
Write-Output "IP Allocation : $FinalAllocation"
Write-Output "DNS           : $FinalDNS"
Write-Output "Domain        : $DomainName"
Write-Output "VNet          : $VNetName"
Write-Output "Subnet        : $SubnetName"
Write-Output "Accelerated   : $AcceleratedNetwork"
Write-Output "Secure Boot   : $SecureBoot"
Write-Output "vTPM          : $vTPM"
Write-Output "============================================================"
Write-Output "READY FOR DDC PART 1"
Write-Output "============================================================"

if ($FinalIP -ne $AssignedIP) {
    throw "Final IP verification failed."
}

if ($FinalAllocation -ne "Static") {
    throw "Final IP allocation verification failed."
}

if ($FinalDNS -notmatch [regex]::Escape($DomainDNS)) {
    throw "Final DNS verification failed."
}
