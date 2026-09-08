"""
Decomposer: разбирает пользовательский источник на карточки CAT-формы.

Режим Б — источник назван пользователем (учебник, курс, методичка).
Входит: topic.yaml с режимом=B и структурой секций.
Выход: topic_sections.yaml (граф тем с якорями на оригинал) + decision_log.
"""

import json
from dataclasses import dataclass, asdict, field
from typing import Optional, List, Dict, Any
from pathlib import Path
from datetime import datetime
import hashlib


@dataclass
class Section:
    """Одна секция источника (глава, видео, раздел)."""

    id: str  # уникальный ID секции
    title: str
    source_location: str  # "Chapter 3", "URL#section-2", "Timestamp 15:30"
    learning_objectives: List[str] = field(default_factory=list)
    prerequisites: List[str] = field(default_factory=list)  # ID других секций
    estimated_hours: float = 0.0

    # Локальная ось областей (может отличаться от нашей 5-области)
    local_domain_areas: Optional[List[str]] = None

    # Якорь на оригинал источника
    source_anchor: Optional[str] = None  # URL, page number, ISBN, etc

    # Рейтинг важности этой секции (0-1, где 1 = критично)
    importance: float = 0.5

    # Граф зависимостей (topological sort затем)
    depends_on: List[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class DecompositionResult:
    """Результат разложения источника."""

    topic_name: str
    source_url: str
    source_type: str
    sections: List[Section]
    local_axis: Optional[Dict[str, str]] = None  # "section-01": "oop.inheritance"
    source_hash: str = ""  # SHA для отслеживания версий
    decomposed_at: str = ""  # ISO timestamp
    # Audit trail of why the graph looks the way it does — dropped cycles, skipped
    # sections, empty input. The module docstring and decompose_topic() both promise
    # it as part of the output, and the repo's Trust Stack requires legible reasoning,
    # but until now it lived only on the Decomposer instance and died with it.
    decision_log: List[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "topic_name": self.topic_name,
            "source_url": self.source_url,
            "source_type": self.source_type,
            "sections": [s.to_dict() for s in self.sections],
            "local_axis": self.local_axis,
            "source_hash": self.source_hash,
            "decomposed_at": self.decomposed_at,
            "decision_log": self.decision_log,
        }


class Decomposer:
    """
    Разбирает пользовательский источник на карточки CAT-формы.

    MVP реализация: пользователь сам предоставляет структуру в topic.yaml (sections).
    Future: парсинг PDF/HTML/медиа автоматизируется.
    """

    def __init__(self, topic_data: dict):
        """
        Args:
            topic_data: загруженный topic.yaml (из adapter.load_topic)
        """
        self.topic_data = topic_data
        self.sections: List[Section] = []
        self.local_axis: Dict[str, str] = {}
        self.decision_log: List[dict] = []

    def decompose(self) -> DecompositionResult:
        """Главный метод разложения."""

        # 1. Валидация входа
        self._validate_input()

        # 2. Парсинг секций
        self._parse_sections()

        # 3. Построение графа зависимостей
        self._build_dependency_graph()

        # 4. Топологический обход (порядок подачи)
        ordered_sections = self._topological_sort()

        # 5. Построение локальной оси областей (если предоставлена)
        self._build_local_axis()

        # 6. Вычисление хеша источника (для отслеживания версий)
        source_hash = self._compute_source_hash()

        # Результат
        return DecompositionResult(
            topic_name=self.topic_data.get("topic_name", "Unknown"),
            source_url=self.topic_data.get("source_url", ""),
            source_type=self.topic_data.get("source_type", "unknown"),
            sections=ordered_sections,
            local_axis=self.local_axis if self.local_axis else None,
            source_hash=source_hash,
            decomposed_at=datetime.utcnow().isoformat(),
            decision_log=list(self.decision_log),
        )

    def _validate_input(self) -> None:
        """Проверяет, что topic.yaml содержит необходимые поля."""

        required_fields = ["scenario", "mode", "topic_name"]
        for field in required_fields:
            if field not in self.topic_data:
                self._log_decision(f"FAIL: missing field '{field}'", "validation")
                raise ValueError(f"Topic must have '{field}' field")

        if self.topic_data.get("scenario") != "learn":
            self._log_decision(f"warn: scenario={self.topic_data['scenario']} (expected 'learn')", "validation")

        if self.topic_data.get("mode") not in ("B", "V"):
            self._log_decision(f"warn: mode={self.topic_data['mode']} (expected B or V)", "validation")

        # Режим В должен иметь search_criteria, Б должен иметь sections.
        # An ABSENT key is a malformed topic.yaml — the author never declared the
        # structure, nothing can be built, so it fails loudly. A PRESENT but empty
        # list is a different thing: the structure was declared and turned out to
        # hold nothing (a source that decomposed to zero sections). That is a
        # degenerate result to report, not a crash — _parse_sections already has
        # the "WARN: no sections found" branch for it, which used to be dead code
        # because this check raised first.
        if self.topic_data.get("mode") == "B":
            if "sections" not in self.topic_data:
                self._log_decision("FAIL: mode=B requires 'sections' field", "validation")
                raise ValueError("Mode B (source named) requires 'sections' in topic.yaml")
            if not self.topic_data["sections"]:
                self._log_decision("WARN: mode=B with no sections — empty decomposition", "validation")

        self._log_decision("Input validated OK", "validation")

    def _parse_sections(self) -> None:
        """Парсит список секций из topic.yaml."""

        sections_raw = self.topic_data.get("sections", [])
        if not sections_raw:
            self._log_decision("WARN: no sections found", "parsing")
            return

        for sec_data in sections_raw:
            try:
                section = Section(
                    id=sec_data.get("id", f"sec-{len(self.sections):03d}"),
                    title=sec_data.get("title", "Untitled"),
                    source_location=sec_data.get("source_location", ""),
                    learning_objectives=sec_data.get("learning_objectives", []),
                    prerequisites=sec_data.get("prerequisites", []),
                    estimated_hours=float(sec_data.get("estimated_hours", 0)),
                    local_domain_areas=sec_data.get("local_domain_areas"),
                    source_anchor=sec_data.get("source_anchor"),
                    importance=float(sec_data.get("importance", 0.5)),
                    depends_on=sec_data.get("depends_on", []),
                )
                self.sections.append(section)
                self._log_decision(f"parsed section '{section.id}' ({len(section.learning_objectives)} objectives)", "parsing")
            except Exception as e:
                self._log_decision(f"WARN: failed to parse section: {e}", "parsing")

    def _build_dependency_graph(self) -> None:
        """Валидирует граф зависимостей между секциями."""

        section_ids = {s.id for s in self.sections}

        for section in self.sections:
            # Проверяем prerequisites
            for prereq in section.prerequisites:
                if prereq not in section_ids:
                    self._log_decision(f"WARN: section '{section.id}' has unknown prerequisite '{prereq}'", "graph_build")

            # Проверяем depends_on
            for dep in section.depends_on:
                if dep not in section_ids:
                    self._log_decision(f"WARN: section '{section.id}' depends on unknown section '{dep}'", "graph_build")

        self._log_decision(f"Dependency graph built ({len(self.sections)} nodes)", "graph_build")

    def _topological_sort(self) -> List[Section]:
        """
        Топологический обход графа: порядок подачи материала.
        От известного (пересечение с базой пользователя) к цели.

        MVP: простой sort по depends_on (не full topological sort).
        """

        sorted_sections = []
        visited = set()

        def visit(section_id: str, path: set):
            if section_id in visited:
                return
            if section_id in path:
                self._log_decision(f"WARN: cycle detected in dependencies at '{section_id}'", "topo_sort")
                return

            path.add(section_id)

            # Найти секцию
            section = next((s for s in self.sections if s.id == section_id), None)
            if not section:
                return

            # Рекурсивно посещаем зависимости
            for dep in section.depends_on:
                visit(dep, path)

            if section_id not in visited:
                sorted_sections.append(section)
                visited.add(section_id)

            path.discard(section_id)

        # Начинаем с секций без зависимостей
        for section in self.sections:
            if not section.depends_on:
                visit(section.id, set())

        # Добавляем оставшиеся (если есть циклы или ошибки)
        for section in self.sections:
            visit(section.id, set())

        self._log_decision(f"Topological sort: {len(sorted_sections)} sections ordered", "topo_sort")
        return sorted_sections

    def _build_local_axis(self) -> None:
        """Строит локальную ось областей темы (если предоставлена)."""

        # MVP: если в topic_data есть domain_mapping, используем его для всех секций
        domain_mapping = self.topic_data.get("domain_mapping")
        if domain_mapping:
            for section in self.sections:
                self.local_axis[section.id] = domain_mapping
            self._log_decision(f"Local axis: inherited from domain_mapping='{domain_mapping}'", "local_axis")
        else:
            # Или собираем из local_domain_areas секций
            for section in self.sections:
                if section.local_domain_areas:
                    # Берем первую область (MVP)
                    self.local_axis[section.id] = section.local_domain_areas[0]

            if self.local_axis:
                self._log_decision(f"Local axis: built from {len(self.local_axis)} sections", "local_axis")
            else:
                self._log_decision("Local axis: not provided, will inherit our 5-domain", "local_axis")

    def _compute_source_hash(self) -> str:
        """Хеш источника для отслеживания версий."""

        source_str = json.dumps({
            "topic": self.topic_data.get("topic_name"),
            "source_url": self.topic_data.get("source_url"),
            "sections_count": len(self.sections),
        }, sort_keys=True)

        return hashlib.sha256(source_str.encode()).hexdigest()[:16]

    def _log_decision(self, message: str, step: str) -> None:
        """Логирует решения для decision_log."""

        self.decision_log.append({
            "timestamp": datetime.utcnow().isoformat(),
            "step": step,
            "message": message,
            "method": "decomposer_v1",
            "confidence": 1.0,
        })


def decompose_topic(topic_data: dict) -> DecompositionResult:
    """
    Convenience функция для разложения topic.yaml.

    Args:
        topic_data: загруженный topic.yaml

    Returns:
        DecompositionResult с графом тем и decision_log

    Raises:
        ValueError: если topic.yaml некорректен
    """
    decomposer = Decomposer(topic_data)
    return decomposer.decompose()
