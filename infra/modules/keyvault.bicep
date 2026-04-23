// ============================================================================
// modules/keyvault.bicep
// Key Vault + RBAC role assignment for the user-assigned MI
// ============================================================================

param keyVaultName string
param location string
param managedIdentityPrincipalId string

// ── Key Vault ────────────────────────────────────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true   // use role assignments, not access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    networkAcls: {
      defaultAction: 'Allow'        // tighten to 'Deny' once VNet is confirmed
      bypass: 'AzureServices'
    }
  }
}

// ── Grant MI "Key Vault Secrets User" (read secrets only) ────────────────────
// Built-in role ID: 4633458b-17de-408a-b874-0445c86b69e6
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentityPrincipalId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultId string = keyVault.id
