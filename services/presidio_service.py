import os
import logging
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig
from models.schemas import DetectedEntity, ScrubResponse

logger = logging.getLogger(__name__)

ENTITIES_TO_DETECT = [
    "PERSON",
    "EMAIL_ADDRESS",
    "PHONE_NUMBER",
    "CREDIT_CARD",
    "US_SSN",
    "IBAN_CODE",
    "IP_ADDRESS",
    "LOCATION",
    "DATE_TIME",
    "NRP",
    "MEDICAL_LICENSE",
    "URL",
]

REDACTION_OPERATORS = {
    "PERSON":           OperatorConfig("replace", {"new_value": "[PERSON]"}),
    "EMAIL_ADDRESS":    OperatorConfig("replace", {"new_value": "[EMAIL]"}),
    "PHONE_NUMBER":     OperatorConfig("replace", {"new_value": "[PHONE]"}),
    "CREDIT_CARD":      OperatorConfig("mask",    {"chars_to_mask": 12, "masking_char": "*", "from_end": True}),
    "US_SSN":           OperatorConfig("replace", {"new_value": "[SSN]"}),
    "IBAN_CODE":        OperatorConfig("replace", {"new_value": "[IBAN]"}),
    "IP_ADDRESS":       OperatorConfig("replace", {"new_value": "[IP_ADDRESS]"}),
    "LOCATION":         OperatorConfig("replace", {"new_value": "[LOCATION]"}),
    "DATE_TIME":        OperatorConfig("replace", {"new_value": "[DATE]"}),
    "NRP":              OperatorConfig("replace", {"new_value": "[NRP]"}),
    "MEDICAL_LICENSE":  OperatorConfig("replace", {"new_value": "[MEDICAL_LICENSE]"}),
    "URL":              OperatorConfig("replace", {"new_value": "[URL]"}),
    "DEFAULT":          OperatorConfig("replace", {"new_value": "[REDACTED]"}),
}


class PresidioService:
    def __init__(self):
        self._confidence_threshold = float(
            os.environ.get("PII_CONFIDENCE_THRESHOLD", "0.8")
        )
        self._failure_mode = os.environ.get("PII_FAILURE_MODE", "block").lower()

        logger.info(
            "Presidio config — threshold=%s, failure_mode=%s",
            self._confidence_threshold,
            self._failure_mode,
        )
        logger.info("Initializing Presidio engines...")
        self._analyzer = AnalyzerEngine()
        self._anonymizer = AnonymizerEngine()
        logger.info("Presidio engines ready.")

    @property
    def failure_mode(self) -> str:
        return self._failure_mode

    def scrub(self, text: str, correlation_id: str = None) -> ScrubResponse:
        log_prefix = f"[{correlation_id}] " if correlation_id else ""
        logger.info("%sAnalyzing text (%d chars)...", log_prefix, len(text))

        results = self._analyzer.analyze(
            text=text,
            entities=ENTITIES_TO_DETECT,
            language="en",
            score_threshold=self._confidence_threshold,
        )

        if not results:
            logger.info("%sNo PII detected.", log_prefix)
            return ScrubResponse(scrubbed_text=text, entities_detected=[], pii_detected=False)

        detected_entities = [
            DetectedEntity(
                entity_type=r.entity_type,
                start=r.start,
                end=r.end,
                score=r.score,
                original_text=text[r.start:r.end],
            )
            for r in results
        ]

        logger.info("%s%d PII entities detected.", log_prefix, len(results))

        anonymized = self._anonymizer.anonymize(
            text=text,
            analyzer_results=results,
            operators=REDACTION_OPERATORS,
        )

        return ScrubResponse(
            scrubbed_text=anonymized.text,
            entities_detected=detected_entities,
            pii_detected=True,
        )
