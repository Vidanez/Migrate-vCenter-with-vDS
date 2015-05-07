function Import-Folders{
#Function adapted from script provided by LucD
#This function has been adjusted for use by the EUC script
 
#Declaring what is needed for usage by script
  param(
  [String]$FolderType,
  [String]$DC,
  [String]$Filename
  )
 
#Setting variables for csv import and setting static type to vm as we are not working with storage or networking folders during migration
  $vmfolder = Import-Csv $filename | Sort-Object -Property Path
  $type = "vm"
 
#Loop to import folders.  Objects are sorted by path field in above import.
#Splits records by slashes and sets key as record just prior to last record.  
#The if loop then creates the first folder and then the next does all the rest
# of the folders.  The entire loop will fail without the first creation of the "vm" folder.
#Error action on first folder creation is set as this first folder, Discovered virtual machine folder will trigger errors after the first script run on a datacenter.
  foreach($folder in $VMfolder){
      $key = @()
      $key =  ($folder.Path -split "\\")[-2]
      if ($key -eq "vm") {
         get-datacenter $dc | get-folder $type | New-Folder -Name $folder.Name -ErrorAction SilentlyContinue
      } else
     {
        $location = Get-Datacenter $dc | get-folder $type | get-folder $key
        Try{
          Get-Folder -Name $folder.Name -Location $location -ErrorAction Stop
        }
        Catch{
          New-Folder -Name $folder.Name -Location $location
        }
      }
   }
}


