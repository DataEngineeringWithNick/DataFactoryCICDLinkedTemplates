# Helpful Links:
# https://dev.to/adbertram/running-powershell-scripts-in-azure-devops-pipelines-2-of-2-3j0e
# https://stackoverflow.com/questions/47779157/convertto-json-and-convertfrom-json-with-special-characters
# https://learn.microsoft.com/en-us/cli/azure/delete-azure-resources-at-scale#delete-all-azure-resources-of-a-type
# https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables?view=powershell-7.4#matches
# https://learn.microsoft.com/en-us/azure/data-factory/continuous-integration-delivery-linked-templates


<#
PowerShell script can be used to deploy Data Factory (ADF) via linked templates in a more secure way instead of using a Storage Account and SAS token. Use linked templates when the Data Factory ARM template is over 4MB.
Original linked template ADF approach for context: https://learn.microsoft.com/en-us/azure/data-factory/continuous-integration-delivery-linked-templates
ARM Template limits: https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/best-practices#template-limits

This script does the following things:

Step 1:
- Grabs the ADF linked template files 
- For each ADF linked template file, creates a new Template Spec which stores the ADF linked template file (JSON). The ADF linked template file is not updated at all.


Step 2:
- Grabs the ADF linked template master file (ArmTemplate_master.json) and does the following:
    - Removes the containerUri and containerSasToken parameters as they aren't needed anymore (using linked Template Specs instead)
    - For each resource in the ArmTemplate_master.json file (linked ADF ARM template in the file):
        - Retrieves the Template Spec Resource ID for that file (ArmTemplate_0 for example)
        - Adds a new id property and adds the Template Spec Resource ID as the value
        - Removes the uri and contentVersion properties
    - Updates the apiVersion property to one that can use the Template Spec id property (2019-11-01 for example) 
    - Ensures the special characters in JSON are escaped properly when generating the updated file (see https://stackoverflow.com/questions/47779157/convertto-json-and-convertfrom-json-with-special-characters)
    - Outputs the new file (doesn't overwrite the existing file) to the root of the repository: "$(Build.Repository.LocalPath)/NewARMTemplateV2_master.json"
#>


# Defining parameters for the script
[CmdletBinding()]
param(
  $FolderPathADFLinkedARMTemplates,
  $DeployTemplateSpecsResourceGroupName,
  $DeployTemplateSpecsResourceGroupLocation,
  $TemplateSpecsVersionNumber
)


$LinkedARMTemplateFiles = Get-ChildItem -Path $FolderPathADFLinkedARMTemplates -Exclude *master* # Excludes the master.json and parameters_master.json files

    Write-Host "Attempting to create the template specs for the linked ARM templates. Template Spec resources will be deployed in Resource Group $DeployTemplateSpecsResourceGroupName. This may take a couple of mins."
    Write-Host `n

    foreach ($FileName in $LinkedARMTemplateFiles.Name) {
      
      # Removes .json from the file name. Ex: ArmTemplate_0.json becomes ArmTemplate_0
      $TemplateSpecName = $FileName.split('.')[0]
      
      # Create a new Template Spec for each ARM Template. Doesn't update the ARM Template at all
      Write-Host "Attempting to create a new Template Spec for linked ARM template $TemplateSpecName.json"
      az ts create --name $TemplateSpecName --version $TemplateSpecsVersionNumber --resource-group $DeployTemplateSpecsResourceGroupName --location $DeployTemplateSpecsResourceGroupLocation `
        --template-file $FolderPathADFLinkedARMTemplates/$FileName --yes --output none # --yes means don't prompt for confirmation and overwrite the existing Template Spec if it exists
      
      Write-Host "Successfully created a new Template Spec called $TemplateSpecName for linked ARM template $TemplateSpecName.json"
      Write-Host `n
    }

    Write-Host "Successfully created all necessary Template Specs in Resource Group $DeployTemplateSpecsResourceGroupName"
    Write-Host `n

    Write-Host "Attempting to read the ArmTemplate_master.json file"
    $MasterARMTemplateFile = Get-Content $FolderPathADFLinkedARMTemplates/ArmTemplate_master.json -Raw | ConvertFrom-Json

    # Remove the containerUri and containerSasToken parameters
    ($MasterARMTemplateFile.parameters).PSObject.Properties.Remove('containerUri')
    ($MasterARMTemplateFile.parameters).PSObject.Properties.Remove('containerSasToken')

    
    foreach ($item in $MasterARMTemplateFile.resources) {

    $ResourceName = $item.Name -Match 'ArmTemplate_.*' # Extracts the ARM Template name out of the resource name property. Ex: my-datafactory-name_ArmTemplate_0 returns ArmTemplate_0
    $TemplateSpecExtractedName = $matches[0] # $matches is an automatic variable in PowerShell. https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables?view=powershell-7.4#matches

    $TemplateSpecResourceID = $(az ts show --name $TemplateSpecExtractedName --resource-group $DeployTemplateSpecsResourceGroupName --version $TemplateSpecsVersionNumber --query "id")

    $item.properties.templateLink | Add-Member -Name "id" -value $TemplateSpecResourceID.replace("`"","") -MemberType NoteProperty # removes the initial and ending double quotes from the string
    ($item.properties.templateLink).PSObject.Properties.Remove('uri')
    ($item.properties.templateLink).PSObject.Properties.Remove('contentVersion')

    # Updates the API version to one that can use the TemplateSpec ID
    $item.apiVersion = '2019-11-01'
    }


    Write-Host "Attempting to output the new Master.json file"

    # Ensures the JSON special characters are escaped and come through correctly. For example not returning a \u0027 string value.
    # See https://stackoverflow.com/questions/47779157/convertto-json-and-convertfrom-json-with-special-characters for more details.
    $MasterARMTemplateFile | ConvertTo-Json -Depth 15 | %{
    [Regex]::Replace($_, 
        "\\u(?<Value>[a-zA-Z0-9]{4})", {
            param($m) ([char]([int]::Parse($m.Groups['Value'].Value,
                [System.Globalization.NumberStyles]::HexNumber))).ToString() } )} |  Set-Content 'NewARMTemplateV2_master.json'

    Write-Host "Successfully created the NewARMTemplateV2_master.json file"
