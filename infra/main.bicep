// ============================================================================
// main.bicep — PII Scrubber Function App (NTT APIM)
// Deploy: az deployment group create --resource-group rg-dev-aigw-compute
//         --template-file infra/main.bicep --parameters env=dev
// ============================================================================

// ── Parameters ───────────────────────────────────────────────────────────────
@description('Environment tag (dev / stg / prd)')
param env string = 'dev'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Subnet resource ID for VNet integration. Leave empty to skip.')
param vnetSubnetId string = ''

@description('PII confidence threshold (0.0 – 1.0)')
param piiConfidenceThreshold string = '0.8'

@description('PII failure mode: block | pass')
@allowed(['block', 'pass'])
param piiFailureMode string = 'block'

@description('Optional suffix to make resource names unique (e.g. your name). Leave empty for NTT production names.')
param suffix string = 'elena'

// ── Derived resource names ────────────────────────────────────────────────────
var sfx                 = empty(suffix) ? '' : '-${suffix}'
var sfxAlpha            = empty(suffix) ? '' : suffix          // no dash for storage account
var functionAppName     = 'fun-${env}-aigw${sfx}'
var appServicePlanName  = 'asp-${env}-aigw${sfx}'
var storageAccountName  = 'st${env}aigwfunc${sfxAlpha}'        // alphanumeric only, max 24 chars
var keyVaultName        = 'kv-${env}-aigw${sfx}'
var managedIdentityName = 'id-${env}-aigw${sfx}'
var appInsightsName     = 'appi-${env}-aigw${sfx}'
var logAnalyticsName    = 'log-${env}-aigw${sfx}'

// ── User-Assigned Managed Identity ───────────────────────────────────────────
// Created here first so both kv and fn modules can reference it without a race.
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

// ── Log Analytics Workspace ──────────────────────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ── Application Insights ─────────────────────────────────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ── Key Vault module ─────────────────────────────────────────────────────────
module kv 'modules/keyvault.bicep' = {
  name: 'keyvault-deploy'
  params: {
    keyVaultName: keyVaultName
    location: location
    managedIdentityPrincipalId: managedIdentity.properties.principalId
  }
}

// ── Function App module ──────────────────────────────────────────────────────
module fn 'modules/function-app.bicep' = {
  name: 'functionapp-deploy'
  params: {
    functionAppName: functionAppName
    appServicePlanName: appServicePlanName
    storageAccountName: storageAccountName
    managedIdentityName: managedIdentityName
    location: location
    appInsightsConnectionString: appInsights.properties.ConnectionString
    keyVaultUri: kv.outputs.keyVaultUri
    vnetSubnetId: vnetSubnetId
    piiConfidenceThreshold: piiConfidenceThreshold
    piiFailureMode: piiFailureMode
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output functionAppName string = functionAppName
output functionAppHostname string = fn.outputs.defaultHostName
output keyVaultName string = keyVaultName
output appInsightsName string = appInsightsName
output managedIdentityClientId string = fn.outputs.managedIdentityClientId
