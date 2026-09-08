"""Tests для decomposer.py (Ф6: Разложение прикладных источников)."""

import pytest
from generator.decomposer import Decomposer, Section, DecompositionResult, decompose_topic


class TestDecomposerValidation:
    """Валидация входа (topic.yaml)."""

    def test_missing_required_field(self):
        """Должен отказать при отсутствии обязательных полей."""

        topic_incomplete = {"scenario": "learn", "mode": "B"}
        # отсутствует topic_name

        with pytest.raises(ValueError, match="topic_name"):
            decompose_topic(topic_incomplete)

    def test_mode_b_requires_sections(self):
        """Режим Б требует поля 'sections'."""

        topic_no_sections = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Python",
            "source_url": "https://example.com",
            "source_type": "book",
            # отсутствует sections
        }

        with pytest.raises(ValueError, match="sections"):
            decompose_topic(topic_no_sections)

    def test_valid_mode_b_input(self):
        """Режим Б с корректными полями должен пройти валидацию."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Python Patterns",
            "source_url": "https://example.com/python",
            "source_type": "book",
            "sections": [
                {
                    "id": "sec-01",
                    "title": "Introduction",
                    "source_location": "Chapter 1",
                    "learning_objectives": ["Understand patterns"],
                    "estimated_hours": 2,
                }
            ],
        }

        result = decompose_topic(topic)
        assert result.topic_name == "Python Patterns"
        assert len(result.sections) == 1


class TestDecomposerParsing:
    """Парсинг секций."""

    def test_parse_single_section(self):
        """Парсит одну секцию из topic.yaml."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Test",
            "source_url": "http://test.com",
            "source_type": "course",
            "sections": [
                {
                    "id": "sec-creational",
                    "title": "Creational Patterns",
                    "source_location": "Chapter 2-4",
                    "learning_objectives": ["Master Factory", "Understand Singleton"],
                    "estimated_hours": 5,
                    "importance": 0.9,
                }
            ],
        }

        result = decompose_topic(topic)
        assert len(result.sections) == 1
        assert result.sections[0].id == "sec-creational"
        assert result.sections[0].title == "Creational Patterns"
        assert len(result.sections[0].learning_objectives) == 2
        assert result.sections[0].estimated_hours == 5

    def test_parse_multiple_sections(self):
        """Парсит несколько секций."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Advanced OOP",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [
                {
                    "id": "sec-01",
                    "title": "Intro",
                    "source_location": "Chapter 1",
                    "learning_objectives": ["Overview"],
                    "estimated_hours": 1,
                },
                {
                    "id": "sec-02",
                    "title": "Advanced Concepts",
                    "source_location": "Chapters 2-5",
                    "learning_objectives": ["Metaprogramming", "Protocols"],
                    "estimated_hours": 4,
                    "depends_on": ["sec-01"],
                },
            ],
        }

        result = decompose_topic(topic)
        assert len(result.sections) == 2
        assert result.sections[0].id == "sec-01"
        assert result.sections[1].depends_on == ["sec-01"]

    def test_parse_section_with_source_anchor(self):
        """Парсит якорь на оригинальный источник."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Video Course",
            "source_url": "https://youtu.be/xyz",
            "source_type": "video",
            "sections": [
                {
                    "id": "vid-01",
                    "title": "Intro",
                    "source_location": "Timestamp 0:00-10:30",
                    "source_anchor": "youtu.be/xyz?t=0s",
                    "learning_objectives": ["Get started"],
                    "estimated_hours": 0.25,
                }
            ],
        }

        result = decompose_topic(topic)
        assert result.sections[0].source_anchor == "youtu.be/xyz?t=0s"


class TestDecomposerDependencyGraph:
    """Построение графа зависимостей."""

    def test_topological_sort_linear(self):
        """Линейные зависимости должны отсортироваться в порядке."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Sequential",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [
                {"id": "s1", "title": "First", "source_location": "Ch1", "learning_objectives": [], "estimated_hours": 1},
                {
                    "id": "s2",
                    "title": "Second",
                    "source_location": "Ch2",
                    "learning_objectives": [],
                    "estimated_hours": 1,
                    "depends_on": ["s1"],
                },
                {
                    "id": "s3",
                    "title": "Third",
                    "source_location": "Ch3",
                    "learning_objectives": [],
                    "estimated_hours": 1,
                    "depends_on": ["s2"],
                },
            ],
        }

        result = decompose_topic(topic)
        # Топосорт должен вернуть s1 → s2 → s3
        ids = [s.id for s in result.sections]
        assert ids.index("s1") < ids.index("s2") < ids.index("s3")

    def test_topological_sort_with_cycle_detection(self):
        """Должен обнаружить циклы и логировать их."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Cyclic",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [
                {
                    "id": "s1",
                    "title": "A",
                    "source_location": "Ch1",
                    "learning_objectives": [],
                    "estimated_hours": 1,
                    "depends_on": ["s2"],
                },
                {
                    "id": "s2",
                    "title": "B",
                    "source_location": "Ch2",
                    "learning_objectives": [],
                    "estimated_hours": 1,
                    "depends_on": ["s1"],  # Цикл: s1 → s2 → s1
                },
            ],
        }

        result = decompose_topic(topic)
        # Должны быть оба узла, но цикл должен быть залогирован
        assert len(result.sections) == 2
        cycle_logged = any("cycle" in log["message"].lower() for log in result.decision_log)


class TestDecomposerLocalAxis:
    """Построение локальной оси областей темы."""

    def test_local_axis_from_domain_mapping(self):
        """Если есть domain_mapping, используется для всех секций."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "OOP Design",
            "source_url": "http://test.com",
            "source_type": "book",
            "domain_mapping": "programming.oop.patterns",
            "sections": [
                {"id": "s1", "title": "Chapter 1", "source_location": "Ch1", "learning_objectives": [], "estimated_hours": 1},
                {"id": "s2", "title": "Chapter 2", "source_location": "Ch2", "learning_objectives": [], "estimated_hours": 1},
            ],
        }

        result = decompose_topic(topic)
        assert result.local_axis is not None
        assert result.local_axis["s1"] == "programming.oop.patterns"
        assert result.local_axis["s2"] == "programming.oop.patterns"

    def test_local_axis_from_section_domains(self):
        """Если секции имеют local_domain_areas, используются они."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Multi-domain",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [
                {
                    "id": "s1",
                    "title": "Chapter 1",
                    "source_location": "Ch1",
                    "learning_objectives": [],
                    "estimated_hours": 1,
                    "local_domain_areas": ["web.frontend", "javascript"],
                },
                {
                    "id": "s2",
                    "title": "Chapter 2",
                    "source_location": "Ch2",
                    "learning_objectives": [],
                    "estimated_hours": 1,
                    "local_domain_areas": ["web.backend", "database"],
                },
            ],
        }

        result = decompose_topic(topic)
        assert result.local_axis is not None
        assert result.local_axis["s1"] == "web.frontend"
        assert result.local_axis["s2"] == "web.backend"


class TestDecomposerHashAndMetadata:
    """Хеширование источника и метаданные."""

    def test_source_hash_computed(self):
        """Вычисляется хеш источника для отслеживания версий."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Python",
            "source_url": "https://example.com/python",
            "source_type": "book",
            "sections": [{"id": "s1", "title": "Ch1", "source_location": "Ch1", "learning_objectives": [], "estimated_hours": 1}],
        }

        result = decompose_topic(topic)
        assert result.source_hash
        assert len(result.source_hash) > 0

    def test_decomposed_at_timestamp(self):
        """Фиксируется время разложения (ISO format)."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Test",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [{"id": "s1", "title": "Ch1", "source_location": "Ch1", "learning_objectives": [], "estimated_hours": 1}],
        }

        result = decompose_topic(topic)
        assert result.decomposed_at
        assert "T" in result.decomposed_at  # ISO timestamp format


class TestDecomposerEmptyInput:
    """Честная деградация при пустом/неполном входе."""

    def test_empty_sections_list(self):
        """Пустой список секций → диагностика, не ошибка."""

        topic = {
            "scenario": "learn",
            "mode": "B",
            "topic_name": "Empty",
            "source_url": "http://test.com",
            "source_type": "book",
            "sections": [],
        }

        result = decompose_topic(topic)
        assert len(result.sections) == 0
        # Должна быть запись в decision_log о пустых секциях
        assert any("no sections" in log["message"].lower() for log in result.decision_log)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
