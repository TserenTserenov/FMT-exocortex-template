"""
SourceFinder: поиск SOTA-источников по критериям пользователя (Ф7).

Режим В — источник неизвестен. Пользователь ищет лучший материал.
Входит: topic.yaml с mode=V и search_criteria.
Выход: список кандидатов (candidates.yaml) + выбранный источник.

MVP реализация: поиск в локальных каталогах (CAT.001-003), без Родника.
"""

from dataclasses import dataclass, field, asdict
from typing import List, Dict, Optional, Tuple
from datetime import datetime
import json


@dataclass
class SearchCriteria:
    """Критерии поиска источника (режим В)."""

    domain: Optional[str] = None  # "programming.python"
    difficulty: Optional[str] = None  # "beginner", "intermediate", "advanced", "expert"
    recency_years: int = 5  # ищем источники последних N лет
    format_preference: List[str] = field(default_factory=list)  # ["video", "course", "book"]
    coverage: List[str] = field(default_factory=list)  # ["patterns", "best-practices"]
    max_candidates: int = 5  # сколько вариантов предложить


@dataclass
class Candidate:
    """Один кандидат источника."""

    id: str  # уникальный ID
    title: str
    source_type: str  # "course", "book", "video", "paper", "podcast"
    url: Optional[str] = None
    domain: Optional[str] = None
    difficulty: Optional[str] = None
    year_published: Optional[int] = None
    format_match: float = 0.0  # 0-1, матч по format_preference
    domain_match: float = 0.0  # 0-1, матч по domain
    recency_score: float = 0.0  # 0-1, свежесть источника
    coverage_match: float = 0.0  # 0-1, покрытие нужных тем
    overall_score: float = 0.0  # итоговый рейтинг (weighted average)

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class CandidateList:
    """Результат поиска: список кандидатов."""

    topic_name: str
    search_criteria: Dict  # JSON-serializable
    candidates: List[Candidate]
    selected_id: Optional[str] = None  # выбранный кандидат
    search_metadata: Dict = field(default_factory=dict)


class SourceFinder:
    """Поиск SOTA-источников в локальных каталогах."""

    # MVP: встроенный каталог источников (потом → Родник)
    BUILTIN_CATALOG = [
        # Python
        {
            "id": "python-patterns-1",
            "title": "Design Patterns in Python",
            "source_type": "book",
            "url": "https://refactoring.guru/design-patterns/python",
            "domain": "programming.python.oop",
            "difficulty": "intermediate",
            "year_published": 2024,
            "keywords": ["patterns", "oop", "best-practices"],
        },
        {
            "id": "python-advanced-2",
            "title": "Fluent Python (2nd Edition)",
            "source_type": "book",
            "url": "https://shop.oreilly.com/product/0636920287179.do",
            "domain": "programming.python",
            "difficulty": "advanced",
            "year_published": 2022,
            "keywords": ["advanced", "metaprogramming", "protocols"],
        },
        {
            "id": "python-testing-1",
            "title": "Python Testing with pytest",
            "source_type": "book",
            "url": "https://pragprog.com/titles/bopytest/python-testing-with-pytest/",
            "domain": "programming.python.testing",
            "difficulty": "intermediate",
            "year_published": 2023,
            "keywords": ["testing", "pytest", "best-practices"],
        },
        # Testing
        {
            "id": "testing-handbook-1",
            "title": "The Testing Handbook",
            "source_type": "course",
            "url": "https://example.com/testing-handbook",
            "domain": "qa.testing",
            "difficulty": "beginner",
            "year_published": 2025,
            "keywords": ["testing", "unit-tests", "integration"],
        },
        # AI/LLM
        {
            "id": "llm-fundamentals-1",
            "title": "Large Language Models: A Comprehensive Guide",
            "source_type": "video",
            "url": "https://youtube.com/playlist?list=llm-2026",
            "domain": "ai.llm",
            "difficulty": "intermediate",
            "year_published": 2026,
            "keywords": ["llm", "transformers", "training", "inference"],
        },
    ]

    def __init__(self, topic_data: dict):
        """
        Args:
            topic_data: загруженный topic.yaml (mode=V)
        """
        self.topic_data = topic_data
        self.search_criteria: Optional[SearchCriteria] = None
        self.candidates: List[Candidate] = []

    def search(self) -> CandidateList:
        """Выполняет поиск источников и возвращает отсортированный список."""

        # 1. Парсим критерии поиска
        self._parse_search_criteria()

        # 2. Ищем в каталоге
        self._search_catalog()

        # 3. Рейтинг кандидатов (weighted score)
        self._score_candidates()

        # 4. Сортируем по score
        self.candidates.sort(key=lambda c: c.overall_score, reverse=True)

        # 5. Ограничиваем по max_candidates
        max_count = self.search_criteria.max_candidates if self.search_criteria else 5
        self.candidates = self.candidates[:max_count]

        return CandidateList(
            topic_name=self.topic_data.get("topic_name", "Unknown"),
            search_criteria=asdict(self.search_criteria) if self.search_criteria else {},
            candidates=self.candidates,
        )

    def _parse_search_criteria(self) -> None:
        """Парсит search_criteria из topic.yaml."""

        criteria_raw = self.topic_data.get("search_criteria", {})

        self.search_criteria = SearchCriteria(
            domain=criteria_raw.get("domain"),
            difficulty=criteria_raw.get("difficulty"),
            recency_years=criteria_raw.get("recency_years", 5),
            format_preference=criteria_raw.get("format_preference", []),
            coverage=criteria_raw.get("coverage", []),
            max_candidates=criteria_raw.get("max_candidates", 5),
        )

    def _search_catalog(self) -> None:
        """Ищет в встроенном каталоге (MVP)."""

        if not self.search_criteria:
            return

        for item in self.BUILTIN_CATALOG:
            # MVP фильтры: domain (если задан)
            if self.search_criteria.domain:
                if self.search_criteria.domain not in item.get("domain", ""):
                    continue

            # Difficulty (если задан)
            if self.search_criteria.difficulty:
                if item.get("difficulty") != self.search_criteria.difficulty:
                    continue

            # Добавляем кандидата
            candidate = Candidate(
                id=item["id"],
                title=item["title"],
                source_type=item["source_type"],
                url=item.get("url"),
                domain=item.get("domain"),
                difficulty=item.get("difficulty"),
                year_published=item.get("year_published"),
            )
            self.candidates.append(candidate)

    def _score_candidates(self) -> None:
        """Вычисляет рейтинг кандидатов по критериям."""

        if not self.search_criteria:
            return

        current_year = datetime.now().year

        for candidate in self.candidates:
            # 1. Format match (30%)
            if self.search_criteria.format_preference:
                if candidate.source_type in self.search_criteria.format_preference:
                    candidate.format_match = 1.0
                else:
                    candidate.format_match = 0.0
            else:
                candidate.format_match = 0.5  # neutral

            # 2. Domain match (30%)
            if self.search_criteria.domain and candidate.domain:
                if self.search_criteria.domain == candidate.domain:
                    candidate.domain_match = 1.0
                elif self.search_criteria.domain in candidate.domain or candidate.domain in self.search_criteria.domain:
                    candidate.domain_match = 0.7
                else:
                    candidate.domain_match = 0.0
            else:
                candidate.domain_match = 0.5

            # 3. Recency score (20%)
            if candidate.year_published:
                years_old = current_year - candidate.year_published
                if years_old <= self.search_criteria.recency_years:
                    candidate.recency_score = 1.0 - (years_old / self.search_criteria.recency_years) * 0.3
                else:
                    candidate.recency_score = 0.0
            else:
                candidate.recency_score = 0.3  # unknown year = partial score

            # 4. Coverage match (20%)
            if self.search_criteria.coverage:
                item_keywords = set()
                # Find original item to get keywords
                for item in self.BUILTIN_CATALOG:
                    if item["id"] == candidate.id:
                        item_keywords = set(item.get("keywords", []))
                        break

                if item_keywords and self.search_criteria.coverage:
                    coverage_set = set(self.search_criteria.coverage)
                    match_count = len(item_keywords & coverage_set)
                    candidate.coverage_match = min(1.0, match_count / len(coverage_set))
                else:
                    candidate.coverage_match = 0.5
            else:
                candidate.coverage_match = 0.5

            # Overall score (weighted average)
            candidate.overall_score = (
                candidate.format_match * 0.30
                + candidate.domain_match * 0.30
                + candidate.recency_score * 0.20
                + candidate.coverage_match * 0.20
            )


def find_sources(topic_data: dict) -> CandidateList:
    """
    Convenience функция для поиска источников.

    Args:
        topic_data: topic.yaml (mode=V)

    Returns:
        CandidateList с рейтингованными кандидатами
    """
    finder = SourceFinder(topic_data)
    return finder.search()
