import logging
from typing import Dict, Optional
from models.schemas import TenantContext

logger = logging.getLogger(__name__)


class TenantContextService:
    """
    Extracts tenant/subscription metadata from APIM-injected request headers
    and returns a structured TenantContext for downstream enrichment.

    APIM inbound policy is expected to set-header:
      X-Subscription-Id  → APIM subscription ID
      X-Tenant-Id        → Azure AD tenant ID
      X-Product-Name     → APIM product name
      X-User-Id          → APIM user ID (optional)
    """

    _HEADER_SUBSCRIPTION_ID = "x-subscription-id"
    _HEADER_TENANT_ID        = "x-tenant-id"
    _HEADER_PRODUCT_NAME     = "x-product-name"
    _HEADER_USER_ID          = "x-user-id"

    def extract_from_headers(self, headers: Dict[str, str]) -> TenantContext:
        # Azure Functions lowercases all header names at runtime.
        subscription_id: str = headers.get(self._HEADER_SUBSCRIPTION_ID, "unknown")
        tenant_id: str       = headers.get(self._HEADER_TENANT_ID, "unknown")
        product_name: Optional[str] = headers.get(self._HEADER_PRODUCT_NAME)
        user_id: Optional[str]      = headers.get(self._HEADER_USER_ID)

        logger.info(
            "Tenant context extracted — subscription_id=%s, tenant_id=%s, product=%s",
            subscription_id,
            tenant_id,
            product_name,
        )

        return TenantContext(
            subscription_id=subscription_id,
            tenant_id=tenant_id,
            product_name=product_name,
            user_id=user_id,
        )
