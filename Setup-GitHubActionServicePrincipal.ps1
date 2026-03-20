#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the smallest practical Entra app registration for GitHub Actions OIDC.

.DESCRIPTION
    This helper creates or reuses:
    - an application registration
    - its service principal
    - one GitHub Actions federated credential for a branch

    It is intentionally minimal for this repository. It does not assign API permissions,
    create client secrets, or grant Key Vault access. After running it, use the emitted
    client ID and tenant ID with azure/login, then grant the service principal the
    Key Vault role you need separately.

.PARAMETER AppName
    Display name for the Entra application registration.

.PARAMETER GitHubRepo
    GitHub repository in owner/repo format.

.PARAMETER Branch
    Branch name allowed to request tokens through the federated credential.

.PARAMETER KeyVaultName
    Optional Key Vault name. When provided, the script resolves the vault and grants
    the service principal the Key Vault Crypto User role on that vault.

.EXAMPLE
    .\Setup-GitHubActionServicePrincipal.ps1

.EXAMPLE
    .\Setup-GitHubActionServicePrincipal.ps1 -GitHubRepo 'contoso/action-passkey-login' -Branch 'main'

.EXAMPLE
    .\Setup-GitHubActionServicePrincipal.ps1 -KeyVaultName 'kv-passkeys-prod'
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$AppName = 'action-passkey-login',

    [Parameter()]
    [string]$GitHubRepo = 'nathanmcnulty/action-passkey-login',

    [Parameter()]
    [string]$Branch = 'main',

    [Parameter()]
    [string]$KeyVaultName
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) {
            return $null
        }

        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$output"
    }

    if (-not $output) {
        return $null
    }

    return $output | ConvertFrom-Json
}

function Test-AzLoggedIn {
    & az account show --output none 2>$null
    return $LASTEXITCODE -eq 0
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install Azure CLI and run az login first.'
}

if (-not (Test-AzLoggedIn)) {
    throw 'No Azure CLI session found. Run az login first.'
}

$account = Invoke-AzCliJson -Arguments @('account', 'show', '--output', 'json')
$tenantId = $account.tenantId

Write-Host "Connected tenant: $tenantId" -ForegroundColor Cyan
Write-Host "Checking application '$AppName'..." -ForegroundColor Cyan

$appList = Invoke-AzCliJson -Arguments @('ad', 'app', 'list', '--display-name', $AppName, '--output', 'json')
$app = @($appList | Where-Object { $_.displayName -eq $AppName }) | Select-Object -First 1

if (-not $app) {
    $app = Invoke-AzCliJson -Arguments @('ad', 'app', 'create', '--display-name', $AppName, '--sign-in-audience', 'AzureADMyOrg', '--output', 'json')
    Write-Host "Created application registration." -ForegroundColor Green
} else {
    Write-Host "Reusing existing application registration." -ForegroundColor Yellow
}

$sp = Invoke-AzCliJson -Arguments @('ad', 'sp', 'show', '--id', $app.appId, '--output', 'json') -AllowFailure
if (-not $sp) {
    $sp = Invoke-AzCliJson -Arguments @('ad', 'sp', 'create', '--id', $app.appId, '--output', 'json')
    Write-Host "Created service principal." -ForegroundColor Green
} else {
    Write-Host "Reusing existing service principal." -ForegroundColor Yellow
}

$credentialName = "github-$($Branch.Replace('/', '-'))"
$subject = "repo:$GitHubRepo:ref:refs/heads/$Branch"

$existingCredentials = Invoke-AzCliJson -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $app.id, '--output', 'json')
$existingCredential = @($existingCredentials | Where-Object { $_.name -eq $credentialName -or $_.subject -eq $subject }) | Select-Object -First 1

if (-not $existingCredential) {
    $credential = @{
        name = $credentialName
        issuer = 'https://token.actions.githubusercontent.com'
        subject = $subject
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Depth 5

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("federated-credential-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -Path $tempFile -Value $credential -NoNewline
        Invoke-AzCliJson -Arguments @('ad', 'app', 'federated-credential', 'create', '--id', $app.id, '--parameters', $tempFile, '--output', 'json') | Out-Null
        Write-Host "Created federated credential." -ForegroundColor Green
    } finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "Reusing existing federated credential." -ForegroundColor Yellow
}

$keyVault = $null
if ($KeyVaultName) {
    Write-Host "Checking Key Vault '$KeyVaultName'..." -ForegroundColor Cyan
    $keyVault = Invoke-AzCliJson -Arguments @('keyvault', 'show', '--name', $KeyVaultName, '--output', 'json') -AllowFailure

    if (-not $keyVault) {
        throw "Key Vault '$KeyVaultName' was not found in the current Azure context."
    }

    $existingAssignment = Invoke-AzCliJson -Arguments @(
        'role', 'assignment', 'list',
        '--assignee-object-id', $sp.id,
        '--scope', $keyVault.id,
        '--role', 'Key Vault Crypto User',
        '--output', 'json'
    )

    if (-not $existingAssignment -or @($existingAssignment).Count -eq 0) {
        Invoke-AzCliJson -Arguments @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $sp.id,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', 'Key Vault Crypto User',
            '--scope', $keyVault.id,
            '--output', 'json'
        ) | Out-Null

        Write-Host "Granted 'Key Vault Crypto User' on '$($keyVault.name)'." -ForegroundColor Green
    } else {
        Write-Host "Reusing existing 'Key Vault Crypto User' assignment on '$($keyVault.name)'." -ForegroundColor Yellow
    }
}

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host ""
Write-Host "GitHub repository: https://github.com/$GitHubRepo" -ForegroundColor Cyan
Write-Host "Application (client) ID: $($app.appId)" -ForegroundColor Yellow
Write-Host "Tenant ID: $tenantId" -ForegroundColor Yellow
Write-Host "Service principal object ID: $($sp.id)" -ForegroundColor Yellow
Write-Host "Federated subject: $subject" -ForegroundColor Yellow
Write-Host ""
Write-Host "Recommended GitHub variables:" -ForegroundColor Cyan
Write-Host "  AZURE_CLIENT_ID  = $($app.appId)" -ForegroundColor White
Write-Host "  AZURE_TENANT_ID  = $tenantId" -ForegroundColor White
Write-Host ""
if ($keyVault) {
    Write-Host "Key Vault role assignment:" -ForegroundColor Cyan
    Write-Host "  Vault name: $($keyVault.name)" -ForegroundColor White
    Write-Host "  Role: Key Vault Crypto User" -ForegroundColor White
} else {
    Write-Host "Next step for Key Vault-backed signing:" -ForegroundColor Cyan
    Write-Host "  Re-run with -KeyVaultName <vault-name> or grant this service principal 'Key Vault Crypto User' on the target Key Vault or key scope." -ForegroundColor White
}
