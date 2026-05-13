from dataclasses import dataclass, field
from typing import List


@dataclass
class DetectedEntity:
    entity_type: str
    start: int
    end: int
    score: float
    original_text: str


@dataclass
class ScrubResponse:
    scrubbed_text: str
    entities_detected: List[DetectedEntity] = field(default_factory=list)
    pii_detected: bool = False

    def to_dict(self) -> dict:
        return {
            "scrubbed_text": self.scrubbed_text,
            "pii_detected": self.pii_detected,
            "entities_detected": [
                {
                    "entity_type": e.entity_type,
                    "start": e.start,
                    "end": e.end,
                    "score": round(e.score, 4),
                    "original_text": e.original_text,
                }
                for e in self.entities_detected
            ],
        }
