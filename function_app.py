import json
import logging

import azure.functions as func

from services.presidio_service import PresidioService

logger = logging.getLogger(__name__)

app = func.FunctionApp()

# ── Singleton — initialised once at cold start ──────────────────────────────
_presidio_svc: PresidioService = None


def _get_presidio() -> PresidioService:
    global _presidio_svc
    if _presidio_svc is None:
        _presidio_svc = PresidioService()
    return _presidio_svc


# ── PII Redaction ────────────────────────────────────────────────────────────

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



