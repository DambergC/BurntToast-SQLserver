[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[switch]$Register,[switch]$Once,[int]$PollSeconds=30)
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot\..\Module\ToastSql.psm1" -Force
$config=Import-ToastConfig -Path $ConfigPath -RequiredProperties @('SqlServer','SqlDatabase','SqlPort','UseIntegratedSecurity','ClientName','ClientGroups','AppDeployToolkitModulePath','Encrypt','TrustServerCertificate','ConnectTimeoutSeconds','CommandTimeoutSeconds') -NullableProperties @('ClientName','AppDeployToolkitModulePath') -NonEmptyProperties @('ClientGroups') -ResolveClientName
Set-ToastClientDependencyOptions -AppDeployToolkitModulePath $config.AppDeployToolkitModulePath
#Test-ToastSqlPort -Server $config.SqlServer -Port $config.SqlPort
$conn=Get-ToastConnectionString $config
$sqlCredential=Get-ToastSqlCredential $config
$computer=$config.ClientName
$deliveryAckRetryDelayMilliseconds = 250
$displayedToastOccurrenceRetentionMinutes = 60
$displayedToastOccurrences = @{}
function Get-ToastOccurrenceKey {
    param(
        [Parameter(Mandatory)][long]$MessageId,
        [Parameter(Mandatory)][int]$ShowCount
    )

    return "${MessageId}:${ShowCount}"
}
function Clear-StaleDisplayedToastOccurrences {
    $cutoffUtc = [datetime]::UtcNow.AddMinutes(-$displayedToastOccurrenceRetentionMinutes)
    foreach ($key in @($script:displayedToastOccurrences.Keys)) {
        if ($script:displayedToastOccurrences[$key] -lt $cutoffUtc) {
            [void]$script:displayedToastOccurrences.Remove($key)
        }
    }
}
function Invoke-ToastDeliveryRecord {
    param(
        [Parameter(Mandatory)][long]$MessageId,
        [Parameter(Mandatory)][ValidateSet('Delivered','Failed')][string]$Status,
        [string]$ErrorMessage,
        [Parameter(Mandatory)][guid]$LeaseId,
        [switch]$RetryOnce
    )

    $params = @{
        ComputerName = $computer
        MessageId = $MessageId
        Status = $Status
        ErrorMessage = $ErrorMessage
        LeaseId = $LeaseId
    }

    try {
        Invoke-ToastSql -ConnectionString $conn -SqlCredential $sqlCredential -CommandText 'EXEC dbo.usp_RecordToastDelivery @ComputerName,@MessageId,@Status,@ErrorMessage,@LeaseId' -Parameters $params -CommandTimeoutSeconds $config.CommandTimeoutSeconds -NonQuery
        return
    } catch {
        if (-not $RetryOnce) {
            throw
        }

        Start-Sleep -Milliseconds $deliveryAckRetryDelayMilliseconds
        Invoke-ToastSql -ConnectionString $conn -SqlCredential $sqlCredential -CommandText 'EXEC dbo.usp_RecordToastDelivery @ComputerName,@MessageId,@Status,@ErrorMessage,@LeaseId' -Parameters $params -CommandTimeoutSeconds $config.CommandTimeoutSeconds -NonQuery
    }
}
function Test-ToastDeliveryRetryableError {
    param([string]$ErrorMessage)

    return $ErrorMessage -like '*timeout*' -or
        $ErrorMessage -like '*transport*' -or
        $ErrorMessage -like '*connection*' -or
        $ErrorMessage -like '*deadlock*' -or
        $ErrorMessage -like '*temporar*'
}
function Invoke-Registration {
    $sql="IF NOT EXISTS(SELECT 1 FROM dbo.ToastClient WHERE ComputerName=@ComputerName) INSERT dbo.ToastClient(ComputerName) VALUES(@ComputerName); DECLARE @ClientId int=(SELECT ClientId FROM dbo.ToastClient WHERE ComputerName=@ComputerName); MERGE dbo.ToastGroup AS t USING (SELECT @GroupName GroupName) s ON t.GroupName=s.GroupName WHEN NOT MATCHED THEN INSERT(GroupName) VALUES(s.GroupName); INSERT dbo.ToastClientGroup(ClientId,GroupId) SELECT @ClientId,GroupId FROM dbo.ToastGroup g WHERE g.GroupName=@GroupName AND NOT EXISTS(SELECT 1 FROM dbo.ToastClientGroup x WHERE x.ClientId=@ClientId AND x.GroupId=g.GroupId);"
    foreach($g in $config.ClientGroups){Invoke-ToastSql -ConnectionString $conn -SqlCredential $sqlCredential -CommandText $sql -Parameters @{ComputerName=$computer;GroupName=$g} -CommandTimeoutSeconds $config.CommandTimeoutSeconds -NonQuery}
}
if($Register){Invoke-Registration;Write-Output "Registered $computer";if($Once){return}}
function Invoke-Poll {
    Clear-StaleDisplayedToastOccurrences
    $rows=Invoke-ToastSql -ConnectionString $conn -SqlCredential $sqlCredential -CommandText 'EXEC dbo.usp_GetPendingToast @ComputerName' -Parameters @{ComputerName=$computer} -CommandTimeoutSeconds $config.CommandTimeoutSeconds
    foreach($row in $rows){
        $occurrenceKey = Get-ToastOccurrenceKey -MessageId $row.MessageId -ShowCount $row.ShowCount
        if ($script:displayedToastOccurrences.ContainsKey($occurrenceKey)) {
            try {
                Invoke-ToastDeliveryRecord -MessageId $row.MessageId -Status Delivered -LeaseId $row.LeaseId -RetryOnce
                [void]$script:displayedToastOccurrences.Remove($occurrenceKey)
            } catch {
                $script:displayedToastOccurrences[$occurrenceKey] = [datetime]::UtcNow
                Write-Warning "Toast message $($row.MessageId) was already displayed locally but delivery acknowledgement still failed: $($_.Exception.Message)"
            }

            continue
        }

        try{
            Invoke-ToastNotification -ToastRow $row
        }catch{
            $toastErrorRecord = $_
            $toastErrorMessage = $toastErrorRecord.Exception.Message
            try {
                Invoke-ToastDeliveryRecord -MessageId $row.MessageId -Status Failed -ErrorMessage $toastErrorMessage -LeaseId $row.LeaseId
                continue
            } catch {
                throw $toastErrorRecord
            }
        }

        try {
            Invoke-ToastDeliveryRecord -MessageId $row.MessageId -Status 'Delivered' -LeaseId $row.LeaseId -RetryOnce
        } catch {
            $deliveryErrorMessage = $_.Exception.Message
            if (Test-ToastDeliveryRetryableError -ErrorMessage $deliveryErrorMessage) {
                $script:displayedToastOccurrences[$occurrenceKey] = [datetime]::UtcNow
                Write-Warning "Displayed toast message $($row.MessageId) but could not record delivery status after retry: $deliveryErrorMessage"
                continue
            }

            throw
        }

        if ($script:displayedToastOccurrences.ContainsKey($occurrenceKey)) {
            [void]$script:displayedToastOccurrences.Remove($occurrenceKey)
        }
    }
}
do{Invoke-Poll;if($Once){break};Start-Sleep -Seconds $PollSeconds}while($true)
