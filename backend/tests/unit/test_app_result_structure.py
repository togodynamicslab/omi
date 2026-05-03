"""APP_RESULT_STRUCTURE_TEMPLATE — pin the section shape.

The template is the contract between every app's prompt and the mobile
renderer. If a section name changes here without a corresponding mobile
update, conversations render with missing/unstyled sections. These tests
make the contract structural, not vibes-based.

Importing get_app_result requires the LLM client which pulls in fastapi
and friends; we test the template constant directly to keep the test
unit-pure (matches test_rate_limiting.py's parse_overrides pattern).
"""

import unittest

from utils.llm.conversation_processing import APP_RESULT_STRUCTURE_TEMPLATE


class TestAppResultStructureTemplate(unittest.TestCase):
    """Pin the structural sections + their empty-state phrasing."""

    REQUIRED_SECTIONS = (
        '## Snapshot',
        '## Topics',
        '## Decisions',
        '## Action Items',
        '## Notable Quotes',
        '## Open Questions',
    )

    REQUIRED_EMPTY_STATES = (
        'None this session.',  # Decisions
        'None captured.',  # Action Items
        'None.',  # Notable Quotes / Open Questions share this phrasing
    )

    def test_all_required_sections_present(self):
        for header in self.REQUIRED_SECTIONS:
            self.assertIn(
                header,
                APP_RESULT_STRUCTURE_TEMPLATE,
                f"Section header missing from template: {header!r}",
            )

    def test_sections_appear_in_canonical_order(self):
        last_idx = -1
        for header in self.REQUIRED_SECTIONS:
            idx = APP_RESULT_STRUCTURE_TEMPLATE.index(header)
            self.assertGreater(
                idx,
                last_idx,
                f"Section out of order: {header!r} appears before earlier sections",
            )
            last_idx = idx

    def test_empty_state_phrasings_present(self):
        # Mobile / users come to expect specific phrasing — pin it so
        # an unrelated edit can't drift "None this session." into
        # "Nothing decided." and break visual consistency.
        for phrase in self.REQUIRED_EMPTY_STATES:
            self.assertIn(phrase, APP_RESULT_STRUCTURE_TEMPLATE)

    def test_template_forbids_extra_sections(self):
        # The template must explicitly tell the LLM not to add other
        # top-level sections, otherwise lens-specific apps drift the
        # shape ("## Sales Pipeline", "## Engineering Backlog", etc.).
        self.assertIn('Do NOT', APP_RESULT_STRUCTURE_TEMPLATE)

    def test_template_is_markdown_friendly(self):
        # Must NOT mandate XML-tag output — apps may embed generative-UI
        # tags inside sections, but the structural skeleton itself stays
        # markdown so a no-tag app still renders cleanly.
        self.assertNotIn('<accordion>', APP_RESULT_STRUCTURE_TEMPLATE)
        self.assertNotIn('<rich-list>', APP_RESULT_STRUCTURE_TEMPLATE)

    def test_template_is_not_empty_or_truncated(self):
        # Cheap canary — if a future merge accidentally trims the
        # template, this catches it before the LLM goes shape-free.
        self.assertGreater(len(APP_RESULT_STRUCTURE_TEMPLATE), 800)


if __name__ == '__main__':
    unittest.main()
