"""
Health Adapter (Ф10): интеграция health-метрик в guide-kit.

Входит: profile.yaml + health_status.json (из WP-470)
Выход: адаптированная порция (сложность, первая практика, mood)
"""

from dataclasses import dataclass
from datetime import datetime
from typing import Optional, Dict, Any


@dataclass
class HealthStatus:
    """Health-метрики пользователя (из WP-470)."""

    date: str  # ISO date
    sleep_hours: float
    sleep_quality_score: float  # 0-1
    stress_indicator: bool
    hrv_score: float  # 0-100
    vo2_max: Optional[float] = None  # мл/кг/мин
    resting_heart_rate: Optional[float] = None
    activity_minutes: Optional[float] = None


@dataclass
class AdaptationParams:
    """Параметры адаптации порции на основе health."""

    difficulty_modifier: float = 1.0  # 0.5 = half, 2.0 = double
    first_practice_recommendation: Optional[str] = None  # "meditation", "active", etc
    mood: str = "neutral"  # "calming", "energizing", "balanced"
    time_budget_multiplier: float = 1.0
    intensity_level: str = "normal"  # "low", "normal", "high"


class HealthPersonalizationEngine:
    """Генерирует параметры адаптации на основе health-статуса."""

    def __init__(self, health_status: Optional[Dict[str, Any]] = None):
        """
        Args:
            health_status: health_status.json из WP-470
        """
        self.health_status = health_status or {}

    def compute_adaptation(self) -> AdaptationParams:
        """Вычисляет параметры адаптации."""

        if not self.health_status:
            # No health data → дефолт
            return AdaptationParams()

        params = AdaptationParams()

        # 1. Адаптация по сну
        sleep_hours = self.health_status.get("sleep", {}).get("total_hours", 7)
        sleep_quality = self.health_status.get("sleep", {}).get("quality_score", 0.5)

        if sleep_hours < 5 or sleep_quality < 0.4:
            # Плохой сон → лёгкие практики
            params.difficulty_modifier = 0.7
            params.intensity_level = "low"
            params.mood = "calming"
            params.first_practice_recommendation = "mindfulness"
        elif sleep_hours > 8 and sleep_quality > 0.8:
            # Отличный сон → сложнее задачи
            params.difficulty_modifier = 1.3
            params.intensity_level = "high"
            params.time_budget_multiplier = 1.2

        # 2. Адаптация по стрессу и HRV
        stress = self.health_status.get("cardiovascular", {}).get("stress_indicator", False)
        hrv_score = self.health_status.get("cardiovascular", {}).get("hrv_score", 50)

        if stress or hrv_score < 40:
            # Высокий стресс, низкий HRV → медитация на первое место
            params.first_practice_recommendation = "meditation"
            params.mood = "calming"
            if params.intensity_level == "normal":  # если ещё не поменяли
                params.intensity_level = "low"

        # 3. Адаптация по физ.состоянию (VO₂ max)
        vo2_max = self.health_status.get("activity", {}).get("vo2_max")

        if vo2_max and vo2_max > 50:
            # Отличная подготовка → динамичные задачи
            params.difficulty_modifier = max(params.difficulty_modifier, 1.2)
            params.intensity_level = "high"
            params.mood = "energizing"
            params.first_practice_recommendation = "active"
        elif vo2_max and vo2_max < 35:
            # Низкая подготовка → щадящий режим
            params.difficulty_modifier = 0.8
            params.intensity_level = "low"

        # 4. Тренд: улучшается ли здоровье?
        trends = self.health_status.get("trends", {})
        if trends.get("fitness_trend_7d") == "improving":
            # Тренд улучшается → поднять планку чуть выше
            params.difficulty_modifier *= 1.1

        return params

    def adapt_profile(self, profile: Dict[str, Any], health_status: Dict[str, Any]) -> Dict[str, Any]:
        """
        Адаптирует profile.yaml на основе health-статуса.

        Args:
            profile: исходный profile.yaml
            health_status: health_status.json

        Returns:
            адаптированный profile (модифицированные параметры)
        """

        self.health_status = health_status
        adaptation = self.compute_adaptation()

        # Модифицируем профиль
        adapted = profile.copy()
        adapted["_health_adaptation"] = {
            "difficulty_modifier": adaptation.difficulty_modifier,
            "first_practice": adaptation.first_practice_recommendation,
            "mood": adaptation.mood,
            "time_budget_multiplier": adaptation.time_budget_multiplier,
            "intensity_level": adaptation.intensity_level,
            "applied_at": datetime.utcnow().isoformat(),
        }

        return adapted


def compute_health_adaptation(health_status: Optional[Dict[str, Any]] = None) -> AdaptationParams:
    """Convenience для вычисления адаптации."""

    engine = HealthPersonalizationEngine(health_status)
    return engine.compute_adaptation()


def adapt_profile_with_health(profile: Dict[str, Any], health_status: Dict[str, Any]) -> Dict[str, Any]:
    """Convenience для адаптации профиля."""

    engine = HealthPersonalizationEngine()
    return engine.adapt_profile(profile, health_status)
