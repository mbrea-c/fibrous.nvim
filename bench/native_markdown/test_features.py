import unittest
from features import first_difference


class FeatureComparison(unittest.TestCase):
    def setUp(self):
        self.frame = dict(step="resize to 18", text="lines", highlights="marks",
                          sources="map", events=["guide"], issues=[])
        self.reference = dict(status="ok", frames=[self.frame])

    def test_complete_match(self):
        self.assertIsNone(first_difference(self.reference, self.reference))

    def test_visible_match_cannot_hide_incorrect_callback(self):
        other = dict(status="ok", frames=[dict(self.frame, events=[])])
        self.assertIn("events", first_difference(self.reference, other))

    def test_partial_run_cannot_match(self):
        self.assertIn("frame count", first_difference(self.reference, dict(status="ok", frames=[])))

    def test_native_setup_refusal_has_no_frame_timing(self):
        other = dict(status="unsupported", reason="layout unavailable", frames=[])
        self.assertIn("layout unavailable", first_difference(self.reference, other))


if __name__ == "__main__":
    unittest.main()
