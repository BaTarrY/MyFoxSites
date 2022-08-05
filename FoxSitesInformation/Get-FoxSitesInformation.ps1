function Get-FoxSitesInformation {
  <#
  .SYNOPSIS
  CREATE A TABLE WITH INFORMATION ABOUT FOX SITES.

  .PARAMETER SecuredCredentials
  IF NOT SUPPLIED, ASKSF OR CREDENTIALS
  IF SUPPLIED, USE THAT SUPPLIED CREDENTIALS

  .PARAMETER Servers
  IF NOT SUPPLIED, CHECK FOR FILE "IISServers.csv" IN DOCUMNETS FOLDER THAT INCLUDES SERVER NAMES
    IF IISServers.csv IS NOT FOUND, ASKS FOR SERVERS AND SAVE TO IISServers.csv FILE AT CHOSEN Location
  IF SUPPLIED USE THAT SUPPLIED SERVERS.

  .PARAMETER OutputType
  HTML: CREATED HTML FILE WITH TABLE
  CSV: CREATED CSV FILE AT CHOSEN Location.
  EXCEL: CREATE XLSX FILE AT CHOSEN Location
  QUICKREVIEW: OUTPUT RESULTS TO CONSOLE



  .EXAMPLE
  Get-FoxSitesInformation -OutputType HTML

  #>

  #DEBUG REQUIRMENTS
  #find-module -Name ('ImportExcel','PSWriteHTML')  | Save-module -Path "$PSScriptRoot\Modules"

  param (
    [securestring]$SecuredCredentials,
    $Servers,
    [Parameter(Mandatory, ValueFromPipeline)][ValidateSet('Console', 'QuickReview', 'HTML', 'Excel', 'CSV')]$OutputType
  )


  ### Helper function to test credentials ##
  function Test-Cred {

    [CmdletBinding()]
    [OutputType([String])]

    Param (
      [Parameter(
        Mandatory = $false,
        ValueFromPipeLine = $true,
        ValueFromPipelineByPropertyName = $true
      )]
      [Alias(
        'PSCredential'
      )]
      [ValidateNotNull()]
      [System.Management.Automation.PSCredential]
      [System.Management.Automation.Credential()]
      $Credentials,
      [switch]$Quite
    )
    $Domain = $null
    $Root = $null
    $Username = $null
    $Password = $null

    If ($null -eq $Credentials) {
      Try {
        $Credentials = Get-Credential "domain\$env:username" -ErrorAction Stop
      }
      Catch {
        $ErrorMsg = $_.Exception.Message
        Write-Warning "Failed to validate credentials: $ErrorMsg "
        Pause
        Break
      }
    }

    # Checking module
    Try {
      # Split username and password
      $Username = $credentials.username
      $Password = $credentials.GetNetworkCredential().password

      # Get Domain
      $Root = "LDAP://" + ([ADSI]'').distinguishedName
      $Domain = New-Object System.DirectoryServices.DirectoryEntry($Root, $UserName, $Password)
    }
    Catch {
      $_.Exception.Message
      Continue
    }

    If (!$domain) {
      Write-Warning "Something went wrong"
    }
    Else {
      If ($null -ne $domain.name) {
        if ($Quite) { return $true }
        else { return "Authenticated" }
      }
      Else {
        if ($Quite) { return $false }
        else { return "Not authenticated" }
      }
    }
  }


  ##  Start of script ##

  if (!($Servers)) {
    $ServersPath = [Environment]::GetFolderPath('MyDocuments')
    $ServersPath = $ServersPath + '\IISServers.csv'
    if (Test-Path -Path $ServersPath) {
      $Servers = import-CSV -Path $ServersPath | Select-Object -Unique -ExpandProperty 'Servers'
    }
    Else {
      Write-output "Notice: This is a one-time Operation`n"
      'Servers' | Out-File -FilePath $ServersPath
      $Servers = (Read-Host -Prompt 'Enter your IIS Server names - Seperated by Commas (,)').Split(',')
      Add-Content -Value $Servers -Path $ServersPath
    }
  }


  if (!($SecuredCredentials)) {
    $cred = (Get-Credential -Message 'Input user credientials')
    if ((test-cred -Credentials $cred -Quite) -eq $false) {
      Write-output "`nUser provided was not validated.`nPleae verify the following and try again:`n1. Name and password supplied are correct and up to date`n2. Network is connected`n3. Connection to corporate network is established for network/corporate users`n4. User supplied is not locked "
      Start-Sleep -Seconds 2
      exit
    }

  }
  $SQLQuery = 'select value as [FoxVersion],UserDataSourcesNew.ServerName as [LDSServer],UserDataSourcesNew.Port as [LDSPort]
from SystemConfiguration
left join UserDataSourcesNew on UserDataSourcesNew.UsersContainerDistinguishedName=''CN=Fox,CN=OuTree,DC=Fox,DC=Bks''
where SystemConfiguration.property=''version'''

  $SitesInfo = Invoke-Command -ComputerName $Servers -Credential $cred   -ScriptBlock {
    ##Remote Start Here
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted
    Import-Module -Name WebAdministration

    $SitesInfo = @()
    $HostName = $env:computername
    $Sites = Get-ChildItem -Path IIS:\Sites | Where-Object -Property Name -NE 'Default Web Site' | Where-Object -Property Name -NotLike "*OPT*"
    foreach ($Site in $Sites) {
      $SiteName = ($Site | Select-Object -ExpandProperty Name)
      IF (Test-Path -Path "HKLM:\SOFTWARE\BKS\Fox\$Site") {
        $Registry = "HKLM:\SOFTWARE\BKS\Fox\$SiteName"
      }
      Elseif (Test-Path -Path "HKLM:\SOFTWARE\WOW6432Node\BKS\Fox\$SiteName") {
        $Registry = "HKLM:\SOFTWARE\WOW6432Node\BKS\Fox\$SiteName"
      }
      else { return }

      if ($null -ne (Get-ItemProperty -Path $Registry -Name Location -ErrorAction SilentlyContinue).Location) {
        $SQLInstance = Get-ItemProperty -Path $Registry | Select-Object -ExpandProperty SQL_Server
        $DataBase = Get-ItemProperty -Path $Registry | Select-Object -ExpandProperty Sql_DataBase
        $InstallLocation = Get-ItemProperty -Path $Registry | Select-Object -ExpandProperty Location
        Switch (Get-ItemProperty -Path $Registry | Select-Object -ExpandProperty SqlAuthenticationType) {
          1 { $SQLAuthType = 'SQL' }
          2 { $SQLAuthType = 'WINDOWS' }
        }
        $SQLInstanceCheck = $SQLInstance.Split('\')[0]
        if (($SQLInstanceCheck) -eq $HostName) {
          $SQLResult = Invoke-Sqlcmd -ServerInstance $SQLInstance -Database $DataBase -Query $Using:SQLQuery

        }
        else {
          $SQLResult = Invoke-Command -ComputerName $SQLInstanceCheck -ArgumentList $SQLInstance, $Database, $Using:SQLQuery -Credential $Using:cred -ScriptBlock {
            [CmdletBinding()]
            param($SQLInstance, $Database, $SQLQuery)
            Invoke-Sqlcmd -ServerInstance $SQLInstance -Database $DataBase -Query $SQLQuery }
        }
        $LDSServer = $SQLResult | Select-Object -ExpandProperty LDSServer
        if ('127.0.0.1' -or 'localhost' -or $HostName) {
          $LDSServer = $HostName
        }
        $LDSPort = $SQLResult | Select-Object -ExpandProperty LDSPort
        $Version = $SQLResult | Select-Object -ExpandProperty FoxVersion

        $HyperLinks = ''
        foreach ($bind in $site.bindings.Collection) {
          $URL = $bind.protocol + '://' + $Bind.BindingInformation.Split(":")[-1]
          $hyperlink = 'TOBEREMOVED' + '<a href="' + $url + 'TOBEREMOVED' + '">' + $url + '</a>' + 'TOBEREMOVED' + '<br>'
          [string]$hyperlinks += $hyperlink
        }
        $HyperLinks = $HyperLinks.TrimEnd('<br>')


        $item = New-Object -TypeName PSObject
        Add-Member -InputObject $Item -type NoteProperty -Name 'Fox Site' -Value $SiteName.ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'Site URLs' -Value $HyperLinks.ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'Site Status' -Value ($Site | Select-Object -ExpandProperty State).ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'IIS Server' -Value $HostName.ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'Fox Version' -Value $Version
        Add-Member -InputObject $Item -type NoteProperty -Name 'Install Location' -Value $InstallLocation.ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'SQL Server' -Value $SQLInstance.ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'Fox DataBase' -Value $DataBase.ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'SQL Authentication Type' -Value $SQLAuthType
        Add-Member -InputObject $Item -type NoteProperty -Name 'LDS Server' -Value $LDSServer.ToUpper()
        Add-Member -InputObject $Item -type NoteProperty -Name 'LDS Port' -Value $LDSPort

        $SitesInfo += $Item
      }
    }
    $SitesInfo | Format-Table -AutoSize
    ##Remote ENDs Here
  }
  Switch ($OutputType) {
    'Console' { $SitesInfo | Select-Object -ExcludeProperty 'PSComputerName', 'RunspaceId' | Format-Table -AutoSize -Force }
    'HTML' {
      $Temp = [Environment]::GetFolderPath('MyDocuments')
      $Temp = $Temp + '\FoxSitesInformation.HTML'
      $SitesInfo | Out-HtmlView  -FilePath $Temp -DefaultSortColumn 'Fox Version' -DefaultSortOrder Descending -Title 'Your Fox Sites Information' -Filtering  -FuzzySearchSmartToggle -DisablePaging -ExcludeProperty ('PSComputerName', 'RunspaceId', 'PSShowComputerName')  -Buttons ('csvHtml5', 'excelHtml5', 'pdfHtml5', 'print', 'searchBuilder', 'searchPanes') -AutoSize -Style cell-border    #-FixedHeader -FreezeColumnsLeft #-FixedHeader -AutoSize -OrderMulti  -DefaultSortOrder Descending -Title 'Fox Sites Information' -Filtering -PreventShowHTML
      $HTMLContent = Get-Content -Path $Temp
      $HTMLContent = $HTMLContent -replace '<head>', '<head>
          <!-- DisableCaching -->
          <meta http-equiv="cache-control" content="no-cache, must-revalidate, post-check=0, pre-check=0" />
          <meta http-equiv="cache-control" content="max-age=0" />
          <meta http-equiv="expires" content="0" />
          <meta http-equiv="expires" content="Tue, 01 Jan 1980 1:00:00 GMT" />
          <meta http-equiv="pragma" content="no-cache" />
          <!-- End OF DisableCaching -->
          ' -replace [Regex]::Escape('"order":[4,"dsc"]'), '"order":[4,"desc"]' -replace 'TOBEREMOVED&lt;A HREF=&quot;', '<a href="' -replace 'TOBEREMOVED&quot;&gt;', '">' -replace '&lt;/A&gt;TOBEREMOVED&lt;BR&gt;', '</a><br><br>' -replace '&lt;/A&gt;TOBEREMOVED', '</a>'
      $date = Get-Date -Format "dddd dd/MM/yyyy HH:mm"
      $replace = '<!-- End OF DisableCaching -->' + '
          Updated at: ' + $date
      $HTMLContent = $HTMLContent -replace '<!-- End OF DisableCaching -->', $replace | Out-File -FilePath $temp -Force
      Invoke-Item -Path $temp
    }
    'CSV' {
      Add-Type -AssemblyName System.Windows.Forms
      $browser = New-Object -TypeName System.Windows.Forms.FolderBrowserDialog
      $null = $browser.ShowDialog()
      $Path = $browser.SelectedPath
      if ($Path) {
        if (Test-Path -Path "$Path\FoxSitesInformation.csv") { Remove-Item -Path "$Path\FoxSitesInformation.csv" -Force }
        $SitesInfo | Select-Object -ExcludeProperty 'PSComputerName', 'RunspaceId', 'PSShowComputerName' | Out-File -FilePath "$Path\FoxSitesInformation.csv"
      }
      Else { Write-output -Object 'No File Selected. Oborting.' }
      exit
    }




    'Excel' {
      Import-Module -Name ImportExcel
      Add-Type -AssemblyName System.Windows.Forms
      $browser = New-Object -TypeName System.Windows.Forms.FolderBrowserDialog
      $null = $browser.ShowDialog()
      $Path = $browser.SelectedPath
      if ($Path) {
        if (Test-Path -Path "$Path\FoxSitesInformation.xlsx") { Remove-Item -Path "$Path\FoxSitesInformation.xlsx" -Force }
        $SitesInfo | Select-Object -ExcludeProperty 'PSComputerName', 'RunspaceId', 'PSShowComputerName' | Export-Excel -Path "$Path\FoxSitesInformation.xlsx" -Title 'Your Fox Sites Information' -WorksheetName (Get-Date -Format 'dd/MM/yyyy') -TitleBold -AutoSize -FreezeTopRowFirstColumn -TableName SitesInformation -Show
      }
      Else { Write-output -Object 'No File Selected. Oborting.' }
      exit
    }
    'QuickReview' { $SitesInfo | Select-Object -ExcludeProperty 'PSComputerName', 'RunspaceId', 'PSShowComputerName' | Out-GridView -Title 'Your Fox IIS Sites Information' }
  }
}


function Convert-Int2Name {
  param (
    [Parameter(HelpMessage = 'OutputType must macth 1,2,3 or 4', Mandatory, ValueFromPipeline)]$OutputType
  )
  Process {
    if ($OutputType -notin (1, 2, 3, 4)) {
      Write-output -ForegroundColor Red 'Invalid choise. Please select a valid number'
      $OutputType = Read-Host -Prompt "`nChoose an output Type.`nPress number to select`n1. HTML`n2. CSV`n3. EXCEL`n4. QUICKREVIEW (Export to console)`nYour Selection is" | Convert-Int2Name
    }
  }
  END {
    Switch ($OutputType) {
      '1' { $OutputType = 'HTML' }
      '2' { $OutputType = 'CSV' }
      '3' { $OutputType = 'EXCEL' }
      '4' { $OutputType = 'QUICKREVIEW' }
    }
    return $OutputType
  }
}

function Import-RequiredModules {
  Get-ChildItem -Path "$PSScriptRoot\Modules" -filter '*.psd1' -Recurse -Depth 2 | ForEach-Object {
    Write-Output -InputObject ('Importing module ' + ($_.Name).split('.')[0] )
    Import-Module -Name $_.FullName
  }
}

Clear-Host
Write-Output -InputObject 'Importing required modules'
Import-RequiredModules
Read-Host -Prompt "`nChoose an output Type.`nPress number to select`n1. HTML`n2. CSV`n3. EXCEL`n4. QUICKREVIEW (Export to console)`nYour Selection is" | Convert-Int2Name | Get-FoxSitesInformation