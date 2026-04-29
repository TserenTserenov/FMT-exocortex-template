#!/bin/bash
# detector-regex.sh — shared source-of-truth для regex'ов detector'ов.
#
# Цель: устранить DRY-нарушение (regex дублировался в integration-contract-validator.sh
# и test-detectors.sh — при правке regex в одном месте второе расходилось).
# Найдено: subagent post-release verify 0.29.18.
#
# Usage:
#   source "$(dirname "$0")/detector-regex.sh"
#   if grep -qE "$DETECTOR_07_REGEX" "$file"; then ...
#
# При добавлении detector_08+ — пополнять этот файл, source'ить из обоих скриптов.
#
# see VR.SC.006 (release-verification-protocol), VR.M.006 (5-layer verification)

# Detector #7: prompts_python_coverage — bare DS-strategy в prompts/.py файлах
# История regex: 0.29.5 базовый, 0.29.14 расширен на backtick+slash паттерн
# (subagent post-release verify нашёл gap, Євгений нашёл бы на fresh clone).
export DETECTOR_07_REGEX='`DS-strategy[`/]|/DS-strategy/| DS-strategy[ /]'

# (При добавлении detector_08+ — добавлять здесь как DETECTOR_NN_REGEX)
