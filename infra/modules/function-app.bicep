// ============================================================================
// modules/function-app.bicep
// User-assigned MI + Storage + EP1 Plan + Function App + optional VNet
// ============================================================================

param functionAppName string
param appServicePlanName string
param storageAccountName string
param managedIdentityName string
param location string
param appInsightsConnectionString string
param keyVaultUri string
param vnetSubnetId string = ''
param piiConfidenceThreshold string = '0.8'
param piiFailureMode string = 'block'

// ── User-Assigned Managed Identity ──────────────────────────────────────────
// MI is created in main.bicep; reference it here as existing.
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: managedIdentityName
}

// ── Storage Account ──────────────────────────────────────────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// ── App Service Plan — Elastic Premium EP1 ──────────────────────────────────
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
  }
  kind: 'elastic'
  properties: {
    reserved: true                    // Linux
    maximumElasticWorkerCount: 20
  }
}

// ── Function App ─────────────────────────────────────────────────────────────
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    reserved: true
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        // ── Functions runtime ──────────────────────────────────────────────
        { name: 'FUNCTIONS_EXTENSION_VERSION',             value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',                value: 'python' }
        // ── Storage ────────────────────────────────────────────────────────
        { name: 'AzureWebJobsStorage',                     value: storageConnectionString }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: storageConnectionString }
        { name: 'WEBSITE_CONTENTSHARE',                    value: toLower(functionAppName) }
        // ── Monitoring ─────────────────────────────────────────────────────
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',   value: appInsightsConnectionString }
        // ── Identity + Key Vault ───────────────────────────────────────────
        { name: 'AZURE_CLIENT_ID',                         value: managedIdentity.properties.clientId }
        { name: 'KEY_VAULT_URI',                           value: keyVaultUri }
        // ── PII config ─────────────────────────────────────────────────────
        { name: 'PII_CONFIDENCE_THRESHOLD',                value: piiConfidenceThreshold }
        { name: 'PII_FAILURE_MODE',                        value: piiFailureMode }
        // ── Cold-start optimisation for EP1 ───────────────────────────────
        { name: 'WEBSITE_RUN_FROM_PACKAGE',                value: '1' }
      ]
    }
  }
}

// ── VNet Integration (applied only when subnetId is provided) ────────────────
resource vnetIntegration 'Microsoft.Web/sites/networkConfig@2023-12-01' = if (!empty(vnetSubnetId)) {
  name: 'virtualNetwork'
  parent: functionApp
  properties: {
    subnetResourceId: vnetSubnetId
    swiftSupported: true
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output functionAppId string = functionApp.id
output defaultHostName string = functionApp.properties.defaultHostName
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output managedIdentityClientId string = managedIdentity.properties.clientId
