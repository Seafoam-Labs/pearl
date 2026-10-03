"""Regression tests for the protocol assertions used by test-surfaces."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent / 'integration'))
from background_effect_trace import BackgroundEffects, outside


def trace(*requests):
    return BackgroundEffects(['[00:00:00] -> ' + request for request in requests])


CREATE = 'wl_compositor#2.create_surface(new id wl_surface#10)'
EFFECT = 'ext_background_effect_manager_v1#3.get_background_effect(new id ext_background_effect_surface_v1#11, wl_surface#10)'


class TraceTests(unittest.TestCase):
    def test_duplicate_on_another_binding_is_rejected(self):
        with self.assertRaisesRegex(AssertionError, 'duplicate live effect'):
            trace(CREATE, EFFECT, EFFECT.replace('#3.', '#4.').replace('#11,', '#12,'))

    def test_surface_id_reuse_does_not_reuse_ownership(self):
        ledger = trace(CREATE, EFFECT, 'wl_surface#10.destroy()', CREATE,
                       EFFECT.replace('#11,', '#12,'),
                       'ext_background_effect_surface_v1#11.destroy()')
        self.assertEqual(ledger.surfaces[10]['effect']['id'], 12)
        self.assertIsNot(ledger.history[0]['surface'], ledger.history[1]['surface'])

    def test_effect_id_reuse_and_double_buffered_region_copy(self):
        prefix = [CREATE, EFFECT, 'wl_surface#10.attach(wl_buffer#20, 0, 0)',
                  'wl_compositor#2.create_region(new id wl_region#12)',
                  'wl_region#12.add(5, 6, 100, 20)',
                  'ext_background_effect_surface_v1#11.set_blur_region(wl_region#12)',
                  'wl_region#12.destroy()']
        self.assertEqual(trace(*prefix).effects[11]['active'], ())
        prefix += ['wl_surface#10.commit()']
        self.assertEqual(trace(*prefix).effects[11]['active'], ((5, 6, 100, 20),))
        prefix += ['ext_background_effect_surface_v1#11.set_blur_region(nil)', 'wl_surface#10.commit()',
                   'ext_background_effect_surface_v1#11.destroy()', EFFECT,
                   'ext_background_effect_surface_v1#11.destroy()', 'wl_surface#10.destroy()']
        ledger = trace(*prefix)
        ledger.assert_finished()
        self.assertEqual(len(ledger.history), 2)

    def test_region_union_allows_touching_panels_but_rejects_gaps(self):
        shapes = [dict(x=0, y=0, width=10, height=20), dict(x=10, y=0, width=10, height=20)]
        self.assertFalse(outside((0, 0, 20, 20), shapes))
        shapes[1]['x'] = 11
        self.assertTrue(outside((0, 0, 20, 20), shapes))


if __name__ == '__main__':
    unittest.main()
