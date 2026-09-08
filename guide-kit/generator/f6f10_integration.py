"""
Integration layer for Ф6-Ф10 (applied topics, health adaptation).

Добавляется в adapter.py:
1. route_scenario() если есть topic.yaml
2. health_adaptation если есть health_status.json
"""

import os
import json
import logging
from typing import Optional, Dict, Any, Tuple

from scenario_router import route_and_serialize
from health_adapter import adapt_profile_with_health

logger = logging.getLogger(__name__)


def load_topic_yaml(base_path: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Загружает topic.yaml если он есть в базовой директории.

    Args:
        base_path: путь к директории (где лежит profile.yaml и topic.yaml)

    Returns:
        Загруженный topic.yaml или None
    """
    if not base_path:
        return None

    topic_path = os.path.join(base_path, "topic.yaml")
    if not os.path.isfile(topic_path):
        return None

    try:
        import yaml
        with open(topic_path, encoding="utf-8") as fh:
            topic = yaml.safe_load(fh) or {}
            logger.info("Loaded topic.yaml: scenario=%s, mode=%s",
                       topic.get("scenario"), topic.get("mode"))
            return topic
    except Exception as e:
        logger.warning("Failed to load topic.yaml: %s", e)
        return None


def load_health_status(base_path: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Загружает health_status.json если он есть (из WP-470).

    Args:
        base_path: путь к директории

    Returns:
        Загруженный health_status.json или None
    """
    if not base_path:
        return None

    health_path = os.path.join(base_path, "health_status.json")
    if not os.path.isfile(health_path):
        return None

    try:
        with open(health_path, encoding="utf-8") as fh:
            health = json.load(fh)
            logger.info("Loaded health_status.json: sleep=%.1fh, stress=%s",
                       health.get("sleep", {}).get("total_hours", 0),
                       health.get("cardiovascular", {}).get("stress_indicator", False))
            return health
    except Exception as e:
        logger.warning("Failed to load health_status.json: %s", e)
        return None


def apply_applied_topics(planner_result: Dict[str, Any], topic_data: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Применяет маршрутизацию сценария Ф6-Ф8 к результату планировщика.

    Если topic.yaml присутствует:
    - scenario=learn + mode=B → Decomposer (Ф6)
    - scenario=learn + mode=V → SourceFinder (Ф7)
    - scenario=research → ResearchGenerator (Ф8)
    - scenario=formalize → FormalizationAssistant (Ф8)

    Args:
        planner_result: результат plan_horizon()
        topic_data: загруженный topic.yaml

    Returns:
        Модифицированный planner_result с applied_topic_data
    """
    if not topic_data or not topic_data.get("scenario"):
        # Дефолт: наша фундаментальная тема (Ф1)
        return planner_result

    try:
        scenario_result = route_and_serialize(topic_data)

        # Добавляем результат маршрутизации в planner_result
        result = dict(planner_result)
        result["applied_topic"] = {
            "scenario": topic_data.get("scenario"),
            "mode": topic_data.get("mode", "A"),
            "topic_name": topic_data.get("topic_name"),
            "result": scenario_result,
        }

        logger.info("Applied topic scenario=%s: got %d items",
                   topic_data.get("scenario"),
                   len(scenario_result.get("sections", [])) or len(scenario_result.get("candidates", [])))

        return result
    except Exception as e:
        logger.error("Failed to apply applied topics: %s", e)
        # Честная деградация: вернуть исходный результат без applied_topic
        return planner_result


def apply_health_adaptation(profile: Dict[str, Any], health_status: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Применяет адаптацию по health-метрикам (Ф10).

    Если health_status.json присутствует:
    - Плохой сон → лёгкие практики
    - Стресс → медитация на первое место
    - Хорошая физ.подготовка → сложнее задачи

    Args:
        profile: исходный profile.yaml
        health_status: загруженный health_status.json

    Returns:
        Адаптированный profile с health-параметрами
    """
    if not health_status:
        return profile

    try:
        adapted = adapt_profile_with_health(profile, health_status)
        logger.info("Applied health adaptation: difficulty=%.2fx, intensity=%s",
                   adapted.get("_health_adaptation", {}).get("difficulty_modifier", 1.0),
                   adapted.get("_health_adaptation", {}).get("intensity_level", "normal"))
        return adapted
    except Exception as e:
        logger.warning("Failed to apply health adaptation: %s", e)
        # Честная деградация: вернуть исходный профиль
        return profile


def integrate_f6f10_into_generation(
    profile: Dict[str, Any],
    config: Dict[str, Any],
    base_path: Optional[str] = None
) -> Tuple[Dict[str, Any], Dict[str, Any], Optional[Dict[str, Any]]]:
    """
    Единая функция интеграции Ф6-Ф10 в pipeline generate_daily_plan.

    Returns:
        (adapted_profile, config_with_topic, planner_modifications)
    """

    # 1. Загружаем topic.yaml (Ф6-Ф8)
    topic_data = load_topic_yaml(base_path)

    # 2. Загружаем health_status.json (Ф10)
    health_status = load_health_status(base_path)

    # 3. Применяем health-адаптацию к профилю
    adapted_profile = apply_health_adaptation(profile, health_status)

    # 4. Передаём topic_data в config для позднейшей маршрутизации
    config_with_topic = dict(config)
    if topic_data:
        config_with_topic["_applied_topic_data"] = topic_data

    return adapted_profile, config_with_topic, topic_data


# Export functions for use in adapter.py
__all__ = [
    "load_topic_yaml",
    "load_health_status",
    "apply_applied_topics",
    "apply_health_adaptation",
    "integrate_f6f10_into_generation",
]
