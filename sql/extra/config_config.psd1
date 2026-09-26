@{
    SqlServer = 'SQLSERVER.example.test'
    SqlDatabase = 'ToastNotifications'
    SqlPort = 1433

    UseIntegratedSecurity = $true
    SqlCredential = $null

    ClientName = $null

    ClientGroups = @(
        'IT'
        'Stockholm'
        'Servers'
    )

    AppDeployToolkitModulePath = $null
    Encrypt = $true
    TrustServerCertificate = $false
    ConnectTimeoutSeconds = 15
    CommandTimeoutSeconds = 15
}