# IWE Documentation English Style Rules (v1)

> Source for the translation pipeline system prompt (translate.py).
> v2 will be generated from PACK-rhetoric/language-style registry.

1. Plain English, active voice, present tense for all documentation.
2. No contractions in technical text (don't → do not, can't → cannot).
3. Use IWE terminology from the glossary exactly as specified — never paraphrase.
4. Code blocks and backtick-wrapped identifiers: never translate or modify. Translate natural-language search queries inside inline code.
5. Frontmatter YAML keys: never translate. Only translate the specific string values listed as translatable.
6. Identifiers matching patterns (WP-NNN, DP.*, AR.NNN, etc.): keep exactly as-is.
7. Proper nouns listed in the manifest: keep exactly as-is (IWE, aisystant, MimEcoSys, iwesys).
8. Preserve all markdown formatting: headers, bullet points, bold, italic, tables.
9. Sentence structure: prefer shorter sentences. Avoid embedded clauses.
10. When in doubt: translate meaning, not words. The goal is clarity for an EN-speaking reader, not literal translation.
11. The published EN tree must contain no Cyrillic characters. Translate Russian phase labels, natural-language examples, and search queries; transliterate a user-facing path example when necessary.
