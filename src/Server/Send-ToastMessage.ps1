[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$GroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Title,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Body,
    [datetime]$ExpiresUtc,
    [string]$AppLogoPath,
    [string]$HeroImagePath,
    [string]$AppLogoFilePath,
    [string]$HeroImageFilePath,
    [byte[]]$AppLogoBytes,
    [byte[]]$HeroImageBytes,
    [string]$AppLogoContentType,
    [string]$HeroImageContentType,
    [ValidateSet('Default','IM','Mail','Reminder','SMS','Alarm','Alarm2','Alarm3','Alarm4','Alarm5','Alarm6','Alarm7','Alarm8','Alarm9','Alarm10','Call','Call2','Call3','Call4','Call5','Call6','Call7','Call8','Call9','Call10')][string]$Sound,
    [switch]$Urgent,
    [Nullable[int]]$RepeatIntervalSeconds,
    [Nullable[int]]$RepeatIntervalMinutes,
    [Nullable[int]]$RepeatCount,
    [Parameter(HelpMessage='Optional text shown on a single toast action button.')][string]$ButtonText,
    [Parameter(HelpMessage='Optional button argument, typically an absolute URL or protocol URI.')][string]$ButtonArguments,
    [Parameter(HelpMessage='Button activation type. Use Protocol to open a URI or Dismiss to close the toast.')][ValidateSet('Protocol','Dismiss')][string]$ButtonActivationType,
    [ValidateSet('Default','Reminder','Alarm','IncomingCall')][string]$Scenario = 'Default',
    [ValidateSet('AppDeployToolkit')][string]$DisplayMode = 'AppDeployToolkit'
)

Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force

function Resolve-ToastQueueResult {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result
    )

    if ($null -eq $Result) {
        throw 'Queue toast message SQL command returned no result set.'
    }

    if ($Result -is [System.Data.DataTable]) {
        if ($Result.Rows.Count -eq 0) {
            throw 'Queue toast message SQL command returned no rows.'
        }

        if (-not $Result.Columns.Contains('MessageId')) {
            throw 'Queue toast message SQL result must include a MessageId column.'
        }

        $messageId = $Result.Rows[0]['MessageId']
        if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
            throw 'Queue toast message SQL result contained a null MessageId value.'
        }

        return [pscustomobject]@{
            MessageId = [long]$messageId
        }
    }

    if ($Result -is [System.Data.DataRow]) {
        if (-not $Result.Table.Columns.Contains('MessageId')) {
            throw 'Queue toast message SQL result must include a MessageId column.'
        }

        $messageId = $Result['MessageId']
        if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
            throw 'Queue toast message SQL result contained a null MessageId value.'
        }

        return [pscustomobject]@{
            MessageId = [long]$messageId
        }
    }

    $messageIdProperty = $Result.PSObject.Properties['MessageId']
    if ($null -eq $messageIdProperty) {
        throw 'Queue toast message SQL result must expose a MessageId value.'
    }

    $messageId = $messageIdProperty.Value
    if ($null -eq $messageId -or $messageId -is [System.DBNull]) {
        throw 'Queue toast message SQL result contained a null MessageId value.'
    }

    return [pscustomobject]@{
        MessageId = [long]$messageId
    }
}

function Assert-ToastImageResolutionResult {
    [CmdletBinding()]
    param(
        [AllowNull()]$Result,
        [Parameter(Mandatory)][string]$ParameterName
    )

    if ($null -eq $Result) {
        throw "$ParameterName image resolution returned no value."
    }

    $hasImageBytes = $null -ne $Result.PSObject.Properties['ImageBytes']
    $hasContentType = $null -ne $Result.PSObject.Properties['ContentType']
    if (-not $hasImageBytes -or -not $hasContentType) {
        throw "$ParameterName image resolution must return ImageBytes and ContentType values."
    }
}

$config = Import-ToastConfig -Path $ConfigPath -RequiredProperties @(
    'SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','Encrypt',
    'TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds'
)

Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn = Get-ToastConnectionString $config
$sqlCredential = Get-ToastSqlCredential $config

$repeatSettings = Resolve-ToastRepeatSettings `
    -RepeatIntervalSeconds $RepeatIntervalSeconds `
    -RepeatIntervalMinutes $RepeatIntervalMinutes `
    -RepeatCount $RepeatCount

$buttonParams = @{
    ButtonText = $ButtonText
    ButtonArguments = $ButtonArguments
}

if (-not [string]::IsNullOrWhiteSpace([string]$ButtonActivationType)) {
    $buttonParams.ButtonActivationType = $ButtonActivationType
}

$buttonSettings = Resolve-ToastButtonSettings @buttonParams

$soundValue = if (
    $PSBoundParameters.ContainsKey('Sound') -and
    -not [string]::IsNullOrWhiteSpace([string]$Sound)
) {
    [string]$Sound
} else {
    $null
}

$resolvedAppLogo = Resolve-ToastImageInput `
    -FilePath $AppLogoFilePath `
    -ImageBytes $AppLogoBytes `
    -ContentType $AppLogoContentType `
    -ParameterName 'AppLogo'
Assert-ToastImageResolutionResult -Result $resolvedAppLogo -ParameterName 'AppLogo'

$resolvedHeroImage = Resolve-ToastImageInput `
    -FilePath $HeroImageFilePath `
    -ImageBytes $HeroImageBytes `
    -ContentType $HeroImageContentType `
    -ParameterName 'HeroImage'
Assert-ToastImageResolutionResult -Result $resolvedHeroImage -ParameterName 'HeroImage'

$params = @{
    GroupName = $GroupName
    Title = $Title
    Body = $Body
    ExpiresUtc = if ($ExpiresUtc) { $ExpiresUtc } else { $null }
    AppLogoPath = if ([string]::IsNullOrWhiteSpace([string]$AppLogoPath)) { $null } else { [string]$AppLogoPath }
    HeroImagePath = if ([string]::IsNullOrWhiteSpace([string]$HeroImagePath)) { $null } else { [string]$HeroImagePath }
    AppLogoBytes = $resolvedAppLogo.ImageBytes
    AppLogoContentType = $resolvedAppLogo.ContentType
    HeroImageBytes = $resolvedHeroImage.ImageBytes
    HeroImageContentType = $resolvedHeroImage.ContentType
    Sound = $soundValue
    IsUrgent = $Urgent.IsPresent
    RepeatIntervalSeconds = if ($null -ne $repeatSettings) { $repeatSettings.RepeatIntervalSeconds } else { $null }
    RepeatCount = if ($null -ne $repeatSettings) { $repeatSettings.RepeatCount } else { $null }
    ButtonText = if ($null -ne $buttonSettings) { $buttonSettings.ButtonText } else { $null }
    ButtonArguments = if ($null -ne $buttonSettings) { $buttonSettings.ButtonArguments } else { $null }
    ButtonActivationType = if ($null -ne $buttonSettings) { $buttonSettings.ButtonActivationType } else { $null }
    Scenario = $Scenario
    DisplayMode = $DisplayMode
}

foreach ($parameterName in @(
    'GroupName','Title','Body','ExpiresUtc','AppLogoPath','HeroImagePath',
    'AppLogoBytes','AppLogoContentType','HeroImageBytes','HeroImageContentType',
    'Sound','IsUrgent','RepeatIntervalSeconds','RepeatCount',
    'ButtonText','ButtonArguments','ButtonActivationType','Scenario','DisplayMode'
)) {
    if (-not $params.ContainsKey($parameterName)) {
        $params[$parameterName] = $null
    }
}

$sql = @'
EXEC dbo.usp_QueueToastMessage
    @GroupName = @GroupName,
    @Title = @Title,
    @Body = @Body,
    @ExpiresUtc = @ExpiresUtc,
    @AppLogoPath = @AppLogoPath,
    @HeroImagePath = @HeroImagePath,
    @AppLogoBytes = @AppLogoBytes,
    @AppLogoContentType = @AppLogoContentType,
    @HeroImageBytes = @HeroImageBytes,
    @HeroImageContentType = @HeroImageContentType,
    @Sound = @Sound,
    @IsUrgent = @IsUrgent,
    @RepeatIntervalSeconds = @RepeatIntervalSeconds,
    @RepeatCount = @RepeatCount,
    @ButtonText = @ButtonText,
    @ButtonArguments = @ButtonArguments,
    @ButtonActivationType = @ButtonActivationType,
    @Scenario = @Scenario,
    @DisplayMode = @DisplayMode
'@

$result = Invoke-ToastSql `
    -ConnectionString $conn `
    -SqlCredential $sqlCredential `
    -CommandText $sql `
    -Parameters $params `
    -CommandTimeoutSeconds $config.CommandTimeoutSeconds

$queuedResult = Resolve-ToastQueueResult -Result $result

Write-Output "Queued message $($queuedResult.MessageId) for group '$GroupName'."