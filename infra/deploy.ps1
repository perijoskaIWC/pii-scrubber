# =============================================================================
# deploy.ps1 — Full deploy: infrastructure + code + APIM wiring
# Usage:
#   ./infra/deploy.ps1 -Env dev
#   ./infra/deploy.ps1 -Env dev -VnetSubnetId "/subscriptions/.../subnets/snet-xxx"
# =============================================================================
[CmdletBinding()]
param(
  [string]$Env           = 'dev',
  [string]$Suffix        = 'elena',
  [string]$VnetSubnetId  = '',           # leave empty until NTT provides it
  [string]$ResourceGroup = 'rg-dev-aigw-compute',
  [string]$Location      = 'eastus',
  [string]$ApimName      = 'apim-pilot-elena',
  [string]$ApimRg        = 'rg-apim-openai-pilot',
  [string]$ApiId         = 'openai-api-elena',
  [string]$OperationId   = ''                         # leave empty to apply at API level
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Helper ────────────────────────────────────────────────────────────────────
function Log($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Error $msg; exit 1 }

# ── 1. Verify az cli login ────────────────────────────────────────────────────
Log "Checking Azure CLI login..."
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) { Die "Not logged in. Run: az login" }
Write-Host "  Subscription: $($account.name) ($($account.id))"

# ── 2. Ensure resource group exists ──────────────────────────────────────────
Log "Ensuring resource group '$ResourceGroup' in '$Location'..."
az group create --name $ResourceGroup --location $Location --output none

# ── 3. Deploy Bicep (infrastructure) ─────────────────────────────────────────
Log "Deploying Bicep infrastructure..."
$bicepParams = @(
  "--resource-group", $ResourceGroup,
  "--template-file", "$ScriptDir/main.bicep",
  "--parameters", "env=$Env",
  "--parameters", "suffix=$Suffix",
  "--parameters", "location=$Location",
  "--parameters", "piiConfidenceThreshold=0.8",
  "--parameters", "piiFailureMode=block"
)
if ($VnetSubnetId) {
  $bicepParams += "--parameters", "vnetSubnetId=$VnetSubnetId"
}

$deployment = az deployment group create @bicepParams `
  --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) { Die "Bicep deployment failed." }

$functionAppName = $deployment.properties.outputs.functionAppName.value
$functionHostname = $deployment.properties.outputs.functionAppHostname.value
$keyVaultName    = $deployment.properties.outputs.keyVaultName.value

Write-Host "  Function App : $functionAppName"
Write-Host "  Hostname     : $functionHostname"
Write-Host "  Key Vault    : $keyVaultName"

# ── 4. Publish function code ──────────────────────────────────────────────────
Log "Publishing function app code..."
Push-Location (Split-Path -Parent $ScriptDir)
try {
  func azure functionapp publish $functionAppName --python --build remote
  if ($LASTEXITCODE -ne 0) { Die "func publish failed." }
} finally {
  Pop-Location
}

# ── 5. Get function host key and store in Key Vault ───────────────────────────
Log "Retrieving function host key..."
$hostKey = az functionapp keys list `
  --name $functionAppName `
  --resource-group $ResourceGroup `
  --query "functionKeys.default" `
  --output tsv

if (-not $hostKey) { Die "Could not retrieve function host key." }

# Grant the current CLI caller 'Key Vault Secrets Officer' so we can write secrets.
# (The KV uses RBAC; only the MI has read access by default.)
Log "Granting deployer Key Vault Secrets Officer on '$keyVaultName'..."
$currentUserOid = az ad signed-in-user show --query id --output tsv
$kvResourceId   = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName"
az role assignment create `
  --role "Key Vault Secrets Officer" `
  --assignee $currentUserOid `
  --scope $kvResourceId `
  --output none 2>$null   # ignore if already assigned

# Role assignments can take ~30s to propagate; retry up to 6 times.
Log "Storing function host key in Key Vault '$keyVaultName'..."
$kvStored = $false
for ($i = 1; $i -le 6; $i++) {
  $result = az keyvault secret set `
    --vault-name $keyVaultName `
    --name "func-host-key" `
    --value $hostKey `
    --output none 2>&1
  if ($LASTEXITCODE -eq 0) { $kvStored = $true; break }
  Write-Host "  Waiting for RBAC propagation (attempt $i/6)..."
  # poll by checking the vault is reachable rather than sleeping
  $null = az keyvault show --name $keyVaultName --query id --output tsv 2>$null
  $null = az keyvault show --name $keyVaultName --query id --output tsv 2>$null
  $null = az keyvault show --name $keyVaultName --query id --output tsv 2>$null
}
if (-not $kvStored) { Write-Warning "Could not store secret in Key Vault - re-run the script in ~1 min." }

# ── 6. Create / update APIM Named Values ─────────────────────────────────────
Log "Configuring APIM Named Values in '$ApimName'..."

$scrubUrl        = "https://${functionHostname}/api/scrub"
$tenantCtxUrl    = "https://${functionHostname}/api/tenant-context"
$kvSecretUri     = "https://${keyVaultName}.vault.azure.net/secrets/func-host-key"

$namedValues = @(
  @{ name = "func-scrub-url";          value = $scrubUrl;     secret = $false },
  @{ name = "func-tenant-context-url"; value = $tenantCtxUrl; secret = $false }
)

foreach ($nv in $namedValues) {
  az apim nv create `
    --service-name $ApimName `
    --resource-group $ApimRg `
    --named-value-id $nv.name `
    --display-name $nv.name `
    --value $nv.value `
    --secret $nv.secret.ToString().ToLower() `
    --output none 2>$null
  # update if already exists
  az apim nv update `
    --service-name $ApimName `
    --resource-group $ApimRg `
    --named-value-id $nv.name `
    --value $nv.value `
    --output none 2>$null
  Write-Host "  Named Value: $($nv.name)"
}

# func-host-key comes from Key Vault — create as a KV-backed named value
az apim nv create `
  --service-name $ApimName `
  --resource-group $ApimRg `
  --named-value-id "func-host-key" `
  --display-name "func-host-key" `
  --value $hostKey `
  --secret true `
  --output none 2>$null
az apim nv update `
  --service-name $ApimName `
  --resource-group $ApimRg `
  --named-value-id "func-host-key" `
  --value $hostKey `
  --secret true `
  --output none 2>$null
Write-Host "  Named Value: func-host-key (secret)"

# ── 7. Apply APIM inbound policy (via az rest — az apim api policy not in all CLI versions) ──
Log "Applying APIM inbound policy to API '$ApiId'..."
$policyXmlPath = Join-Path $ScriptDir "apim-policy.xml"
$policyXml = Get-Content $policyXmlPath -Raw

$subscriptionId = $account.id
$apiVersion     = '2022-08-01'

if ($OperationId) {
  $policyUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ApimRg/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId/operations/$OperationId/policies/policy?api-version=$apiVersion"
} else {
  $policyUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ApimRg/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId/policies/policy?api-version=$apiVersion"
}

# Write raw XML to a temp file and PUT with the APIM raw-XML content type.
# Use "*" as ETag to overwrite without version check.
$tmpBodyFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.xml'
[System.IO.File]::WriteAllText($tmpBodyFile, $policyXml, [System.Text.Encoding]::UTF8)

az rest `
  --method PUT `
  --uri $policyUri `
  --body "@$tmpBodyFile" `
  --headers "Content-Type=application/vnd.ms-azure-apim.policy.raw+xml" "If-Match=*" `
  --output none

Remove-Item $tmpBodyFile -Force

if ($LASTEXITCODE -ne 0) { Die "Failed to apply APIM policy." }
if ($OperationId) {
  Write-Host "  Policy applied to operation: $OperationId"
} else {
  Write-Host "  Policy applied to API: $ApiId"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Log "Deployment complete!"
Write-Host ""
Write-Host "  Scrub endpoint    : $scrubUrl"
Write-Host "  Tenant-ctx endpoint: $tenantCtxUrl"
Write-Host "  Health endpoint   : https://${functionHostname}/api/health"
Write-Host ""
Write-Host "To add VNet integration later, re-run with:"
Write-Host "  ./infra/deploy.ps1 -VnetSubnetId '/subscriptions/.../subnets/snet-xxx'"
