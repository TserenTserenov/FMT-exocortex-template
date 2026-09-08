"""
Research & Formalization outputs для Ф8.

scenario=research → ResearchGenerator (карта фронтира)
scenario=formalize → FormalizationAssistant (структурирование знания)

Оба - не порционные выходы, одна роль DP.ROLE.095.
"""

from dataclasses import dataclass, field, asdict
from typing import List, Dict, Optional
from datetime import datetime


@dataclass
class ResearchMapCluster:
    """Один кластер на карте фронтира."""

    name: str  # "Capabilities", "Security", "Applications"
    description: str
    topics: List[str] = field(default_factory=list)  # ["Reasoning", "Multimodal"]
    key_resources: List[Dict] = field(default_factory=list)  # {title, url, year}
    open_questions: List[str] = field(default_factory=list)  # открытые вопросы


@dataclass
class ResearchMap:
    """Карта фронтира исследований (выход Исследователя)."""

    topic: str
    domain: str
    clusters: List[ResearchMapCluster]
    key_sources: List[Dict] = field(default_factory=list)  # {title, url, date, relevance}
    generated_at: str = ""

    def to_markdown(self) -> str:
        """Экспортирует карту в Markdown."""

        lines = [f"# Research Map: {self.topic}\n"]
        lines.append(f"**Domain:** {self.domain}\n")
        lines.append(f"**Generated:** {self.generated_at}\n\n")

        for cluster in self.clusters:
            lines.append(f"## {cluster.name}\n")
            lines.append(f"{cluster.description}\n\n")

            if cluster.topics:
                lines.append("### Topics\n")
                for topic in cluster.topics:
                    lines.append(f"- {topic}\n")
                lines.append("\n")

            if cluster.key_resources:
                lines.append("### Key Resources\n")
                for res in cluster.key_resources:
                    lines.append(f"- [{res.get('title', 'Unknown')}]({res.get('url', '#')}) ({res.get('year', 'N/A')})\n")
                lines.append("\n")

            if cluster.open_questions:
                lines.append("### Open Questions\n")
                for q in cluster.open_questions:
                    lines.append(f"- {q}\n")
                lines.append("\n")

        return "".join(lines)


@dataclass
class FormalizationConcept:
    """Одно понятие из формализации."""

    name: str
    definition: str
    examples: List[str] = field(default_factory=list)
    sources: List[str] = field(default_factory=list)  # ссылки на notes/clips


@dataclass
class FormalizationDistinction:
    """Одно различение из формализации."""

    title: str  # "Consensus vs Consistency"
    item_a: str  # "Consensus"
    description_a: str
    item_b: str  # "Consistency"
    description_b: str
    sources: List[str] = field(default_factory=list)


@dataclass
class FormalizationMethod:
    """Один метод/процедура из формализации."""

    name: str
    steps: List[str]
    when_to_use: str
    examples: List[str] = field(default_factory=list)
    sources: List[str] = field(default_factory=list)


@dataclass
class FormalizationDraft:
    """Структурированный черновик знания (выход Просветителя)."""

    topic: str
    concepts: List[FormalizationConcept] = field(default_factory=list)
    distinctions: List[FormalizationDistinction] = field(default_factory=list)
    methods: List[FormalizationMethod] = field(default_factory=list)
    approval_status: str = "pending_review"  # "pending_review", "approved", "rejected"
    generated_at: str = ""

    def to_yaml_dict(self) -> dict:
        """Экспортирует черновик в YAML-dict."""

        return {
            "formalization": {
                "topic": self.topic,
                "concepts": [asdict(c) for c in self.concepts],
                "distinctions": [asdict(d) for d in self.distinctions],
                "methods": [asdict(m) for m in self.methods],
                "approval_status": self.approval_status,
                "generated_at": self.generated_at,
            }
        }


class ResearchGenerator:
    """Генерирует карту фронтира исследований."""

    # MVP: встроенный пример карты для AI/LLM
    BUILTIN_MAPS = {
        "ai.llm": {
            "clusters": [
                {
                    "name": "Capabilities",
                    "description": "Core abilities and what LLMs can do",
                    "topics": ["Reasoning", "Multimodal", "Code Generation", "Long Context"],
                    "resources": [
                        {"title": "o1 Technical Report", "url": "https://openai.com", "year": 2026},
                        {"title": "GPT-4 Capabilities", "url": "https://arxiv.org", "year": 2024},
                    ],
                    "questions": [
                        "How will reasoning scale beyond current approaches?",
                        "What are the limits of context length?",
                    ],
                },
                {
                    "name": "Safety & Alignment",
                    "description": "Making LLMs safer and more aligned with human values",
                    "topics": ["Jailbreaking Defense", "Constitutional AI", "RLHF Alternatives"],
                    "resources": [
                        {"title": "Constitutional AI", "url": "https://anthropic.com", "year": 2025},
                        {"title": "Alignment Faking", "url": "https://arxiv.org", "year": 2026},
                    ],
                    "questions": [
                        "Does Constitutional AI scale to superintelligence?",
                        "Can alignment be empirically verified?",
                    ],
                },
                {
                    "name": "Applications",
                    "description": "Real-world use cases and product applications",
                    "topics": ["Enterprise AI", "Scientific Discovery", "Creative Tools"],
                    "resources": [
                        {"title": "AI in Science", "url": "https://nature.com", "year": 2026},
                    ],
                    "questions": [
                        "What are the most impactful applications?",
                        "How will adoption curves differ by industry?",
                    ],
                },
            ]
        },
        "programming.python": {
            "clusters": [
                {
                    "name": "Fundamentals",
                    "description": "Core language features and semantics",
                    "topics": ["Syntax", "Data Structures", "Functions", "OOP"],
                    "resources": [
                        {"title": "Python Official Docs", "url": "https://docs.python.org", "year": 2026},
                    ],
                    "questions": [
                        "What new syntax is coming in Python 3.14?",
                    ],
                },
            ]
        },
    }

    def __init__(self, topic_data: dict):
        """
        Args:
            topic_data: topic.yaml (scenario=research)
        """
        self.topic_data = topic_data

    def generate(self) -> ResearchMap:
        """Генерирует карту фронтира."""

        topic_name = self.topic_data.get("topic_name", "Unknown")
        domain = self.topic_data.get("domain_mapping", "unknown")

        # MVP: используем встроенную карту если есть
        if domain in self.BUILTIN_MAPS:
            map_def = self.BUILTIN_MAPS[domain]
            clusters = [
                ResearchMapCluster(
                    name=c.get("name"),
                    description=c.get("description"),
                    topics=c.get("topics", []),
                    key_resources=c.get("resources", []),
                    open_questions=c.get("questions", []),
                )
                for c in map_def.get("clusters", [])
            ]
        else:
            # Честная деградация
            clusters = [
                ResearchMapCluster(
                    name="Recommended Starting Point",
                    description="Begin with foundational materials in this domain",
                    topics=[],
                )
            ]

        return ResearchMap(
            topic=topic_name,
            domain=domain,
            clusters=clusters,
            generated_at=datetime.utcnow().isoformat(),
        )


class FormalizationAssistant:
    """Помощник структурирования знания пользователя (режим formalize)."""

    def __init__(self, topic_data: dict, user_knowledge: Optional[List[Dict]] = None):
        """
        Args:
            topic_data: topic.yaml (scenario=formalize)
            user_knowledge: список размеченных заметок/clips (2.3/2.4 пользователя)
        """
        self.topic_data = topic_data
        self.user_knowledge = user_knowledge or []

    def generate(self) -> FormalizationDraft:
        """Генерирует структурированный черновик из знания пользователя."""

        topic_name = self.topic_data.get("topic_name", "Unknown")

        # MVP реализация: если нет user_knowledge, вернуть пустой черновик
        if not self.user_knowledge:
            return FormalizationDraft(
                topic=topic_name,
                approval_status="pending_review",
                generated_at=datetime.utcnow().isoformat(),
            )

        # Собираем концепты, различения, методы из user_knowledge
        concepts = self._extract_concepts()
        distinctions = self._extract_distinctions()
        methods = self._extract_methods()

        return FormalizationDraft(
            topic=topic_name,
            concepts=concepts,
            distinctions=distinctions,
            methods=methods,
            approval_status="pending_review",
            generated_at=datetime.utcnow().isoformat(),
        )

    def _extract_concepts(self) -> List[FormalizationConcept]:
        """Извлекает определения понятий из user_knowledge."""

        concepts = []
        for item in self.user_knowledge:
            if item.get("type") in ("2.3", "definition"):
                concept = FormalizationConcept(
                    name=item.get("title", "Unnamed"),
                    definition=item.get("content", ""),
                    sources=[item.get("id", "")],
                )
                concepts.append(concept)
        return concepts

    def _extract_distinctions(self) -> List[FormalizationDistinction]:
        """Извлекает различения из user_knowledge."""

        distinctions = []
        # MVP: поиск заметок, начинающихся с "distinguish" или содержащих ":"
        for item in self.user_knowledge:
            content = item.get("content", "")
            if "distinguish" in content.lower() or " vs " in content.lower():
                # Наивный парсинг: разделить по "vs"
                parts = content.split(" vs ")
                if len(parts) == 2:
                    distinction = FormalizationDistinction(
                        title=item.get("title", "Unnamed"),
                        item_a=parts[0].strip().split("\n")[0],
                        description_a=parts[0].strip(),
                        item_b=parts[1].strip().split("\n")[0],
                        description_b=parts[1].strip(),
                        sources=[item.get("id", "")],
                    )
                    distinctions.append(distinction)
        return distinctions

    def _extract_methods(self) -> List[FormalizationMethod]:
        """Извлекает методы/процедуры из user_knowledge."""

        methods = []
        for item in self.user_knowledge:
            if item.get("type") in ("2.4", "method", "procedure"):
                method = FormalizationMethod(
                    name=item.get("title", "Unnamed"),
                    steps=[],  # MVP: не парсируем шаги
                    when_to_use=item.get("content", ""),
                    sources=[item.get("id", "")],
                )
                methods.append(method)
        return methods


def generate_research_map(topic_data: dict) -> ResearchMap:
    """Convenience для генерации карты фронтира."""
    generator = ResearchGenerator(topic_data)
    return generator.generate()


def generate_formalization_draft(topic_data: dict, user_knowledge: Optional[List[Dict]] = None) -> FormalizationDraft:
    """Convenience для генерации черновика формализации."""
    assistant = FormalizationAssistant(topic_data, user_knowledge)
    return assistant.generate()
