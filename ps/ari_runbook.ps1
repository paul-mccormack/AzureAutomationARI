# Azure Resource Inventory Runbook Script
# This script uses the AzureResourceInventory module to inventory Azure resources across all subscriptions in a tenant.
# It saves the inventory reports to a specified Azure Storage account and container.

# Script created by Paul McCormack
# Contact: https://github.com/paul-mccormack
# Date: 08/10/2025
# Version: 1.0

Import-Module AzureResourceInventory

# Import storage account name from Automation Account variables
$stg = Get-AutomationVariable -Name 'storageAccountName'

# Ensures you do not inherit an AzContext in your runbook  
Disable-AzContextAutosave -Scope Process | Out-Null  

# Connect using a Managed Service Identity  
try {  
        Connect-AzAccount -Identity  
}  
catch{  
        Write-Output "There is no system-assigned user identity. Aborting.";   
        exit  
}  

# Get Azure tenant ID
$tenantId = Get-AzTenant | Select-Object -ExpandProperty TenantId

# Run Azure Resource Inventory
Invoke-ARI -TenantID $tenantId -Automation -SecurityCenter -IncludeCosts -StorageAccount $stg -StorageContainer "reports"