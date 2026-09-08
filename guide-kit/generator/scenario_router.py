"""
Маршрутизация сценария (scenario: learn|research|formalize).

После Ф6-Ф8 реализации: adapter.py делегирует на основе scenario в topic.yaml.
"""

import sys
import os
from typing import Optional, Union, Dict, Any
from dataclasses import asdict

# Add generator dir to path
_generator_dir = os.path.dirname(os.path.abspath(__file__))
if _generator_dir not in sys.path:
    sys.path.insert(0, _generator_dir)

from decomposer import decompose_topic, DecompositionResult
from source_finder import find_sources, CandidateList
from research_formalize import generate_research_map, generate_formalization_draft, ResearchMap, FormalizationDraft


def route_scenario(topic_data: Dict[str, Any]) -> Union[DecompositionResult, CandidateList, ResearchMap, FormalizationDraft, Dict]:
    """
    Маршрутизирует запрос по сценарию.

    Args:
        topic_data: загруженный topic.yaml

    Returns:
        Результат в зависимости от scenario:
        - scenario=learn + mode=B/V → DecompositionResult или CandidateList
        - scenario=research → ResearchMap
        - scenario=formalize → FormalizationDraft
        - Нет topic.yaml → пустой dict (дефолт: наша фундаментальная тема)
    """

    # Если нет topic.yaml или scenario не задан → дефолт (наша фундаментальная тема)
    if not topic_data or "scenario" not in topic_data:
        return {}

    scenario = topic_data.get("scenario", "learn")
    mode = topic_data.get("mode")

    # learn × Б/В → режимы подачи прикладных тем
    if scenario == "learn":
        if mode == "B":
            # Режим Б: источник назван, разложить на карточки (Ф6)
            return decompose_topic(topic_data)
        elif mode == "V":
            # Режим В: источник неизвестен, найти кандидатов (Ф7)
            return find_sources(topic_data)
        else:
            # Дефолт: наша фундаментальная тема (режим А)
            return {}

    # research → карта фронтира (Ф8)
    elif scenario == "research":
        return generate_research_map(topic_data)

    # formalize → структурирование знания (Ф8)
    elif scenario == "formalize":
        return generate_formalization_draft(topic_data)

    else:
        # Неизвестный сценарий → дефолт
        return {}


def serialize_result(result: Any) -> Dict[str, Any]:
    """
    Сериализует результат маршрутизации в JSON-compatible dict.

    Args:
        result: результат route_scenario()

    Returns:
        JSON-ready dict
    """

    if isinstance(result, dict):
        # Пустой результат (дефолт или ошибка)
        return result

    # DecompositionResult
    if hasattr(result, "to_dict") and hasattr(result, "sections"):
        return result.to_dict()

    # CandidateList
    if hasattr(result, "candidates"):
        return {
            "topic_name": result.topic_name,
            "search_criteria": result.search_criteria,
            "candidates": [c.to_dict() for c in result.candidates],
        }

    # ResearchMap
    if hasattr(result, "clusters"):
        return {
            "topic": result.topic,
            "domain": result.domain,
            "clusters": [
                {
                    "name": c.name,
                    "description": c.description,
                    "topics": c.topics,
                    "key_resources": c.key_resources,
                    "open_questions": c.open_questions,
                }
                for c in result.clusters
            ],
        }

    # FormalizationDraft
    if hasattr(result, "concepts"):
        return result.to_yaml_dict()

    # Fallback
    return {}


def route_and_serialize(topic_data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Единая функция маршрутизации + сериализации.

    Используется в adapter.py для обработки topic.yaml.
    """

    result = route_scenario(topic_data)
    return serialize_result(result)
