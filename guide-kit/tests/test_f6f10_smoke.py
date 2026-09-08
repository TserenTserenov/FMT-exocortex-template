"""Smoke tests для Ф6-Ф10: все модули импортируются и работают."""

import pytest


class TestF6Decomposer:
    """Ф6: Decomposer импортируется и базовая логика работает."""

    def test_decomposer_imports(self):
        """Модуль импортируется без ошибок."""
        from generator.decomposer import Decomposer, decompose_topic
        assert Decomposer is not None
        assert decompose_topic is not None

    def test_decomposer_basic_flow(self):
        """Основной flow: topic.yaml → DecompositionResult."""
        from generator.decomposer import decompose_topic

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Test Topic",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [
                {
                    "id": "s1",
                    "title": "Chapter 1",
                    "source_location": "Ch 1",
                    "learning_objectives": ["Learn X"],
                    "estimated_hours": 2,
                }
            ],
        }

        result = decompose_topic(topic)
        assert result.topic_name == "Test Topic"
        assert len(result.sections) == 1
        assert result.sections[0].title == "Chapter 1"


class TestF7SourceFinder:
    """Ф7: SourceFinder импортируется и базовая логика работает."""

    def test_source_finder_imports(self):
        """Модуль импортируется без ошибок."""
        from generator.source_finder import SourceFinder, find_sources
        assert SourceFinder is not None
        assert find_sources is not None

    def test_source_finder_basic_flow(self):
        """Основной flow: topic.yaml (mode=V) → CandidateList."""
        from generator.source_finder import find_sources

        topic = {
            "scenario": "learn",
            "mode": "V",
            "topic_name": "Python Learning",
            "search_criteria": {
                "domain": "programming.python",
                "difficulty": "intermediate",
                "format_preference": ["book", "video"],
                "max_candidates": 3,
            },
        }

        result = find_sources(topic)
        assert result.topic_name == "Python Learning"
        assert isinstance(result.candidates, list)
        # Может быть 0 или больше в зависимости от каталога
        assert len(result.candidates) <= 3


class TestF8Research:
    """Ф8 Исследователь: ResearchGenerator импортируется и работает."""

    def test_research_imports(self):
        """Модуль импортируется без ошибок."""
        from generator.research_formalize import ResearchGenerator, generate_research_map
        assert ResearchGenerator is not None
        assert generate_research_map is not None

    def test_research_basic_flow(self):
        """Основной flow: topic.yaml (scenario=research) → ResearchMap."""
        from generator.research_formalize import generate_research_map

        topic = {
            "scenario": "research",
            "topic_name": "AI/LLM Research",
            "domain_mapping": "ai.llm",
        }

        result = generate_research_map(topic)
        assert result.topic == "AI/LLM Research"
        assert result.domain == "ai.llm"
        assert isinstance(result.clusters, list)


class TestF8Formalize:
    """Ф8 Просветитель: FormalizationAssistant импортируется и работает."""

    def test_formalize_imports(self):
        """Модуль импортируется без ошибок."""
        from generator.research_formalize import FormalizationAssistant, generate_formalization_draft
        assert FormalizationAssistant is not None
        assert generate_formalization_draft is not None

    def test_formalize_basic_flow(self):
        """Основной flow: topic.yaml (scenario=formalize) → FormalizationDraft."""
        from generator.research_formalize import generate_formalization_draft

        topic = {
            "scenario": "formalize",
            "topic_name": "My Knowledge",
        }

        result = generate_formalization_draft(topic)
        assert result.topic == "My Knowledge"
        assert result.approval_status == "pending_review"
        assert isinstance(result.concepts, list)


class TestF10HealthAdapter:
    """Ф10: HealthAdapter импортируется и базовая логика работает."""

    def test_health_adapter_imports(self):
        """Модуль импортируется без ошибок."""
        from generator.health_adapter import (
            HealthPersonalizationEngine,
            compute_health_adaptation,
        )
        assert HealthPersonalizationEngine is not None
        assert compute_health_adaptation is not None

    def test_health_adapter_basic_flow(self):
        """Основной flow: health_status.json → AdaptationParams."""
        from generator.health_adapter import compute_health_adaptation

        health = {
            "sleep": {"total_hours": 4, "quality_score": 0.3},
            "cardiovascular": {"stress_indicator": True, "hrv_score": 35},
            "activity": {"vo2_max": 40},
        }

        adaptation = compute_health_adaptation(health)
        assert adaptation.difficulty_modifier < 1.0  # плохой сон → лёгче
        assert adaptation.first_practice_recommendation is not None
        assert adaptation.mood == "calming"  # стресс → успокаивающее


class TestScenarioRouter:
    """Маршрутизатор: router импортируется и маршрутизирует по scenario."""

    def test_router_imports(self):
        """Модуль импортируется без ошибок."""
        from generator.scenario_router import route_scenario, route_and_serialize
        assert route_scenario is not None
        assert route_and_serialize is not None

    def test_router_mode_b(self):
        """Маршрут: learn + B → Decomposer."""
        from generator.scenario_router import route_scenario

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Test",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [{"id": "s1", "title": "Ch1", "source_location": "Ch1", "learning_objectives": [], "estimated_hours": 1}],
        }

        result = route_scenario(topic)
        assert hasattr(result, "sections")  # DecompositionResult

    def test_router_mode_v(self):
        """Маршрут: learn + V → SourceFinder."""
        from generator.scenario_router import route_scenario

        topic = {
            "scenario": "learn",
            "mode": "V",
            "topic_name": "Search",
            "search_criteria": {"domain": "programming.python"},
        }

        result = route_scenario(topic)
        assert hasattr(result, "candidates")  # CandidateList

    def test_router_research(self):
        """Маршрут: scenario=research → ResearchGenerator."""
        from generator.scenario_router import route_scenario

        topic = {
            "scenario": "research",
            "topic_name": "Research",
            "domain_mapping": "ai.llm",
        }

        result = route_scenario(topic)
        assert hasattr(result, "clusters")  # ResearchMap

    def test_router_formalize(self):
        """Маршрут: scenario=formalize → FormalizationAssistant."""
        from generator.scenario_router import route_scenario

        topic = {
            "scenario": "formalize",
            "topic_name": "Formalize",
        }

        result = route_scenario(topic)
        assert hasattr(result, "concepts")  # FormalizationDraft

    def test_router_default(self):
        """Маршрут: нет scenario или topic_data → пусто (дефолт)."""
        from generator.scenario_router import route_scenario

        result = route_scenario({})
        assert result == {}


class TestF6F10Integration:
    """Интеграционный модуль: импортируется и функции доступны."""

    def test_integration_imports(self):
        """Модуль импортируется без ошибок."""
        from generator.f6f10_integration import (
            load_topic_yaml,
            load_health_status,
            apply_applied_topics,
            apply_health_adaptation,
        )
        assert load_topic_yaml is not None
        assert load_health_status is not None
        assert apply_applied_topics is not None
        assert apply_health_adaptation is not None

    def test_integration_missing_files(self):
        """load_topic_yaml и load_health_status работают с отсутствующими файлами."""
        from generator.f6f10_integration import load_topic_yaml, load_health_status

        # Несуществующая директория
        topic = load_topic_yaml("/nonexistent")
        health = load_health_status("/nonexistent")

        assert topic is None
        assert health is None

    def test_integration_health_adaptation(self):
        """apply_health_adaptation работает."""
        from generator.f6f10_integration import apply_health_adaptation

        profile = {"rcs": {"W": 0.5}}
        health = {
            "sleep": {"total_hours": 3, "quality_score": 0.2},
            "cardiovascular": {"stress_indicator": True, "hrv_score": 30},
        }

        adapted = apply_health_adaptation(profile, health)
        assert "_health_adaptation" in adapted
        assert adapted["_health_adaptation"]["intensity_level"] == "low"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
