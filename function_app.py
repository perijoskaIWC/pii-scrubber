import json
import logging

import azure.functions as func

from services.presidio_service import PresidioService
from services.tenant_context_service import TenantContextService

logger = logging.getLogger(__name__)

app = func.FunctionApp()

# ── Singletons — initialised once at cold start ──────────────────────────────
_presidio_svc: PresidioService = None
_tenant_ctx_svc: TenantContextService = None
_startup_error: str = None


def _get_presidio() -> PresidioService:
    global _presidio_svc, _startup_error
    if _presidio_svc is None:
        try:
            _presidio_svc = PresidioService()
        except Exception as exc:
            _startup_error = str(exc)
            raise
    return _presidio_svc


def _get_tenant_ctx() -> TenantContextService:
    global _tenant_ctx_svc, _startup_error
    if _tenant_ctx_svc is None:
        try:
            _tenant_ctx_svc = TenantContextService()
        except Exception as exc:
            _startup_error = str(exc)
            raise
    return _tenant_ctx_svc


# ── Function 3: Health Check ────────────────────────────────────────────────

@app.route(route="health", methods=["GET"], auth_level=func.AuthLevel.ANONYMOUS)
def health(req: func.HttpRequest) -> func.HttpResponse:
    """
    Lightweight liveness probe — no auth required.
    Returns 200 if both singletons initialised successfully, 503 otherwise.
    """
    presidio_ready = _presidio_svc is not None
    tenant_ready = _tenant_ctx_svc is not None

    if presidio_ready and tenant_ready:
        return func.HttpResponse(
            json.dumps({"status": "healthy", "presidio": "ready", "tenant_context": "ready"}),
            status_code=200,
            mimetype="application/json",
        )

    return func.HttpResponse(
        json.dumps({
            "status": "unhealthy",
            "presidio": "ready" if presidio_ready else "not initialised",
            "tenant_context": "ready" if tenant_ready else "not initialised",
            "detail": _startup_error,
        }),
        status_code=503,
        mimetype="application/json",
    )


# ── Function 1: PII Redaction ─────────────────────────────────────────────────

@app.route(route="scrub", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def pii_scrub(req: func.HttpRequest) -> func.HttpResponse:
    """
    Called by APIM inbound policy.
    Receives prompt text, detects PII above the configured confidence
    threshold, redacts it, and returns the cleaned prompt.

    Request body:
        { "text": "<prompt>" }

    Response body:
        {
            "scrubbed_text": "...",
            "pii_detected": true | false,
            "entities_detected": [ { "entity_type", "start", "end",
                                     "score", "original_text" } ]
        }

    On Presidio failure:
        PII_FAILURE_MODE=block → 422 (request rejected)
        PII_FAILURE_MODE=pass  → 200 with original text (passthrough)
    """
    correlation_id = (
        req.headers.get("x-correlation-id")
        or req.headers.get("x-ms-client-request-id")
    )
    logger.info("[%s] PII scrub request received.", correlation_id)

    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Request body must be valid JSON."}),
            status_code=400,
            mimetype="application/json",
        )

    text = body.get("text") or body.get("prompt")
    if not text or not isinstance(text, str) or not text.strip():
        return func.HttpResponse(
            json.dumps({"error": "Missing or empty 'text' field in request body."}),
            status_code=400,
            mimetype="application/json",
        )

    svc = _get_presidio()

    try:
        result = svc.scrub(text=text, correlation_id=correlation_id)
        return func.HttpResponse(
            json.dumps(result.to_dict()),
            status_code=200,
            mimetype="application/json",
        )
    except Exception as exc:
        logger.error("[%s] Presidio error: %s", correlation_id, exc, exc_info=True)

        if svc.failure_mode == "pass":
            logger.warning(
                "[%s] PII_FAILURE_MODE=pass — returning original text unredacted.",
                correlation_id,
            )
            return func.HttpResponse(
                json.dumps({
                    "scrubbed_text": text,
                    "pii_detected": False,
                    "entities_detected": [],
                    "warning": "PII redaction failed; passthrough mode active.",
                }),
                status_code=200,
                mimetype="application/json",
            )

        return func.HttpResponse(
            json.dumps({"error": "PII redaction failed. Request blocked."}),
            status_code=422,
            mimetype="application/json",
        )


# ── Function 2: Tenant Context Injection ──────────────────────────────────────

@app.route(route="tenant-context", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def tenant_context_inject(req: func.HttpRequest) -> func.HttpResponse:
    """
    Called by APIM inbound policy before routing to the backend LLM.
    Reads tenant/subscription metadata from APIM-injected headers and
    returns it as a valid OpenAI system message payload.

    Expected APIM-set headers:
        X-Subscription-Id, X-Tenant-Id, X-Product-Name, X-User-Id

    Request body: any JSON object (unused except for JSON validation)
    Response body:
        {
            "role": "system",
            "content": "Tenant context: subscription_id=...; ..."
        }
    """
    correlation_id = (
        req.headers.get("x-correlation-id")
        or req.headers.get("x-ms-client-request-id")
    )
    logger.info("[%s] Tenant context injection request received.", correlation_id)

    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Request body must be valid JSON."}),
            status_code=400,
            mimetype="application/json",
        )

    try:
        tenant_ctx = _get_tenant_ctx().extract_from_headers(dict(req.headers))
        system_message = {
            "role": "system",
            "content": (
                "Tenant context: "
                f"subscription_id={tenant_ctx.subscription_id}; "
                f"tenant_id={tenant_ctx.tenant_id}; "
                f"product_name={tenant_ctx.product_name or 'unknown'}; "
                f"user_id={tenant_ctx.user_id or 'unknown'}."
            ),
        }
        return func.HttpResponse(
            json.dumps(system_message),
            status_code=200,
            mimetype="application/json",
        )
    except Exception as exc:
        logger.error(
            "[%s] Tenant context error: %s", correlation_id, exc, exc_info=True
        )
        return func.HttpResponse(
            json.dumps({"error": "Tenant context injection failed."}),
            status_code=500,
            mimetype="application/json",
        )
