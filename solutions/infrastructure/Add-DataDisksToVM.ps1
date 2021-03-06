<#
.SYNOPSIS
  Creates a Virtual Machine with two data disks.
.DESCRIPTION
  Creates a Virtual Machine (small) configured with two data disks.  After the Virtual
  Machine is provisioned and running, the data disks are then formatted and have drive
  letters assigned.  User is prompted for credentials to use to provision the new Virtual Machine.

  If there is a VM with the given name, under the given cloud service, the script simply 
  adds new disks to it and formats the new disks.

  Note: This script requires an Azure Storage Account to run.  A storage account can be 
  specified by setting the subscription configuration.  For example:
    Set-AzureSubscription -SubscriptionName "MySubscription" -CurrentStorageAccount "MyStorageAccount"

  Note: There are limits on the number of disks attached to VMs as dictated by their size. 
  This script does not validate the disk number for the default VM size, which is small.  

.EXAMPLE
  .\Add-DataDisksToVM.ps1 -ServiceName "MyServiceName" -VMName "MyVM" `
      -Location "West US" -NumberOfDisks 2 -DiskSizeInGB 16
#>

param (
    # Cloud service name to deploy the VMs to
    [Parameter(Mandatory = $true)]
    [String]$ServiceName,
    
    # Name of the Virtual Machine to create
    [Parameter(Mandatory = $true)]
    [String]$VMName,
    
    # Location, this is not a mandatory parameter. THe script checkes the existence if service is not found.
    [Parameter(Mandatory = $false)]
    [String]$Location,
    
    # Disk size in GB
    [Parameter(Mandatory = $true)]
    [Int32]$DiskSizeInGB,
    
    # Number of data disks to add to each virtual machine
    [Parameter(Mandatory = $true)]
    [Int32]$NumberOfDisks)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

# Check if Windows Azure Powershell is avaiable
if ((Get-Module -ListAvailable Azure) -eq $null)
{
    throw "Windows Azure Powershell not found! Please make sure to install them from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
}

<#
.SYNOPSIS
   Installs a WinRm certificate to the local store
.DESCRIPTION
   Gets the WinRM certificate from the Virtual Machine in the Service Name specified, and 
   installs it on the Current User's personal store.
.EXAMPLE
    Install-WinRmCertificate -ServiceName testservice -vmName testVm
.INPUTS
   None
.OUTPUTS
   None
#>
function Install-WinRmCertificate($ServiceName, $VMName)
{
    $vm = Get-AzureVM -ServiceName $ServiceName -Name $VMName
    $winRmCertificateThumbprint = $vm.VM.DefaultWinRMCertificateThumbprint
    
    $winRmCertificate = Get-AzureCertificate -ServiceName $ServiceName -Thumbprint $winRmCertificateThumbprint -ThumbprintAlgorithm sha1
    
    $installedCert = Get-Item Cert:\CurrentUser\My\$winRmCertificateThumbprint -ErrorAction SilentlyContinue
    
    if ($installedCert -eq $null)
    {
        $certBytes = [System.Convert]::FromBase64String($winRmCertificate.Data)
        $x509Cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate
        $x509Cert.Import($certBytes)
        
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
        $store.Open("ReadWrite")
        $store.Add($x509Cert)
        $store.Close()
    }
}

<#
.SYNOPSIS
  Returns the latest image for a given image family name filter.
.DESCRIPTION
  Will return the latest image based on a filter match on the ImageFamilyName and
  PublisedDate of the image.  The more specific the filter, the more control you have
  over the object returned.
.EXAMPLE
  The following example will return the latest SQL Server image.  It could be SQL Server
  2014, 2012 or 2008
    
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server*"

  The following example will return the latest SQL Server 2014 image. This function will
  also only select the image from images published by Microsoft.  
   
    Get-LatestImage -ImageFamilyNameFilter "*SQL Server 2014*" -OnlyMicrosoftImages

  The following example will return $null because Microsoft doesn't publish Ubuntu images.
   
    Get-LatestImage -ImageFamilyNameFilter "*Ubuntu*" -OnlyMicrosoftImages
#>
function Get-LatestImage
{
    param
    (
        # A filter for selecting the image family.
        # For example, "Windows Server 2012*", "*2012 Datacenter*", "*SQL*, "Sharepoint*"
        [Parameter(Mandatory = $true)]
        [String]
        $ImageFamilyNameFilter,

        # A switch to indicate whether or not to select the latest image where the publisher is Microsoft.
        # If this switch is not specified, then images from all possible publishers are considered.
        [Parameter(Mandatory = $false)]
        [switch]
        $OnlyMicrosoftImages
    )

    # Get a list of all available images.
    $imageList = Get-AzureVMImage

    if ($OnlyMicrosoftImages.IsPresent)
    {
        $imageList = $imageList |
                         Where-Object { `
                             ($_.PublisherName -ilike "Microsoft*" -and `
                              $_.ImageFamily -ilike $ImageFamilyNameFilter ) }
    }
    else
    {
        $imageList = $imageList |
                         Where-Object { `
                             ($_.ImageFamily -ilike $ImageFamilyNameFilter ) } 
    }

    $imageList = $imageList | 
                     Sort-Object -Unique -Descending -Property ImageFamily |
                     Sort-Object -Descending -Property PublishedDate

    $imageList | Select-Object -First(1)
}

# Check if the current subscription's storage account's location is the same as the Location parameter
$subscription = Get-AzureSubscription -Current
$currentStorageAccountLocation = (Get-AzureStorageAccount -StorageAccountName $subscription.CurrentStorageAccount).GeoPrimaryLocation

if ($Location -ne $currentStorageAccountLocation)
{
    throw "Selected location parameter value, ""$Location"" is not the same as the active (current) subscription's current storage account location `
        ($currentStorageAccountLocation). Either change the location parameter value, or select a different storage account for the `
        subscription."
}

# Get an image to provision virtual machines from.
$imageFamilyNameFilter = "Windows Server 2012 Datacenter"
$image = Get-LatestImage -ImageFamilyNameFilter $imageFamilyNameFilter -OnlyMicrosoftImages
if ($image -eq $null)
{
    throw "Unable to find an image for $imageFamilyNameFilter to provision Virtual Machine."
}

# Check if hosted service with $ServiceName exists
$existingService = Get-AzureService -ServiceName $ServiceName -ErrorAction SilentlyContinue

# Does the VM exist? If the VM is already there, just add the new disk
$existingVm = Get-AzureVM -ServiceName $ServiceName -Name $VMName -ErrorAction SilentlyContinue

if ($existingService -eq $null)
{
    if ($Location -eq "")
    {
        throw "Service does not exist, please specify the Location parameter"
    } 
    New-AzureService -ServiceName $ServiceName -Location $Location
}

if (($Location -ne "") -and ($existingService -ne $null))
{
    if ($existingService.Location -ne $Location)
    {
        Write-Warning "There is a service with the same name on a different location. Location parameter will be ignored."
    }
}

Write-Verbose "Prompt user for administrator credentials to use when provisioning the virtual machine(s)."
$credential = Get-Credential
Write-Verbose "Administrator credentials captured.  Use these credentials to login to the virtual machine(s) when the script is complete."

# Configure the new Virtual Machine.
$userName = $credential.GetNetworkCredential().UserName
$password = $credential.GetNetworkCredential().Password

if ($existingVm -ne $null)
{
    # Find the starting LUN for the new disks
    $startingLun = ($existingVm | Get-AzureDataDisk | Measure-Object Lun -Maximum).Maximum + 1
    
    for ($index = $startingLun; $index -lt $NumberOfDisks + $startingLun; $index++)
    { 
        $diskLabel = "disk_" + $index
        $existingVm = $existingVm | 
                           Add-AzureDataDisk -CreateNew -DiskSizeInGB $DiskSizeInGB `
                               -DiskLabel $diskLabel -LUN $index        
    }
    
    $existingVm | Update-AzureVM
}
else
{
    $vmConfig = New-AzureVMConfig -Name $VMName -InstanceSize Small -ImageName $image.ImageName | 
    Add-AzureProvisioningConfig -Windows -AdminUsername $userName -Password $password 
    
    for ($index = 0; $index -lt $NumberOfDisks; $index++)
    { 
        $diskLabel = "disk_" + $index
        $vmConfig = $vmConfig | 
                        Add-AzureDataDisk -CreateNew -DiskSizeInGB $DiskSizeInGB `
                            -DiskLabel $diskLabel -LUN $index        
    }
    
    # Create the Virtual Machine and wait for it to boot.
    New-AzureVM -ServiceName $ServiceName -VMs $vmConfig -WaitForBoot
}

# Install a remote management certificate from the Virtual Machine.
Install-WinRmCertificate -serviceName $ServiceName -vmName $VMName

# Format data disks and assign drive letters.
$winRmUri = Get-AzureWinRMUri -ServiceName $ServiceName -Name $VMName
Invoke-Command -ConnectionUri $winRmUri.ToString() -Credential $credential -ScriptBlock {
    Get-Disk | 
    Where-Object PartitionStyle -eq "RAW" | 
    Initialize-Disk -PartitionStyle MBR -PassThru | 
    New-Partition -AssignDriveLetter -UseMaximumSize | 
    Format-Volume -FileSystem NTFS -Confirm:$false
}
