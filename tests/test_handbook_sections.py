"""Do not mistake example code or an unmatched fence for source policy."""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "cli"))
import handbook


class SourceSectionTests(unittest.TestCase):
    def lifecycle(self, content):
        return handbook._declared_lifecycle({"content": content})

    def test_different_fence_character_does_not_end_code(self):
        body = "# Usage\n\n```text\n~~~\n# Not a heading\nStatus: active\n```\n\n## Policy\n\nStatus: proposed\n"
        sections = list(handbook._sections(body))
        self.assertEqual(len(sections), 2)
        self.assertIn("# Not a heading", sections[0])
        self.assertEqual(self.lifecycle(body), ["proposed"])

    def test_short_fence_does_not_end_long_fence(self):
        body = "# Example\n\n````text\n```\n# Example title\nStatus: accepted\n````\n\n## Draft\n\nStatus: draft\n"
        self.assertEqual(len(list(handbook._sections(body))), 2)
        self.assertEqual(self.lifecycle(body), ["draft"])

    def test_closing_fence_cannot_have_non_whitespace_suffix(self):
        body = "~~~text\n~~~not-a-close\nStatus: active\n~~~\nStatus: superseded\n"
        self.assertEqual(self.lifecycle(body), ["superseded"])

    def test_unterminated_fence_keeps_remainder_together(self):
        body = "# Example\n\n```\n# Child\nStatus: active\n~~~\n## Another child\nStatus: accepted\n"
        self.assertEqual(len(list(handbook._sections(body))), 1)
        self.assertEqual(self.lifecycle(body), [])

    def test_indented_code_status_is_not_source_lifecycle(self):
        body = "# Example\n\n    Status: active\n\tStatus: accepted\n\nStatus: proposed\n"
        self.assertEqual(self.lifecycle(body), ["proposed"])

    def test_fences_up_to_three_spaces_and_longer_closer(self):
        body = "# Policy\n\n  ~~~python\nStatus: active\n   ~~~~~  \n\n## Proposal\n\nStatus: proposed\n"
        self.assertEqual(len(list(handbook._sections(body))), 2)
        self.assertEqual(self.lifecycle(body), ["proposed"])

    def test_ordinary_sections_remain_verbatim(self):
        body = "# Project\n\nPurpose.\n\n## Rule\n\nOnly when online.\n"
        self.assertEqual(list(handbook._sections(body)),
                         ["# Project\n\nPurpose.", "## Rule\n\nOnly when online."])


if __name__ == "__main__":
    unittest.main()
