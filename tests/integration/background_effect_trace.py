"""WAYLAND_DEBUG client request ledger, with object lifetimes and commit state."""
import re


def outside(rect, shapes):
    """Subtract a union of boxes; Cairo may merge touching island rectangles."""
    remaining = [rect]
    for r in shapes:
        next_rects = []
        for x, y, w, h in remaining:
            left, top = max(x, r['x']), max(y, r['y'])
            right, bottom = min(x+w, r['x']+r['width']), min(y+h, r['y']+r['height'])
            if left >= right or top >= bottom:
                next_rects.append((x, y, w, h))
                continue
            for piece in ((x,y,w,top-y), (x,bottom,w,y+h-bottom),
                          (x,top,left-x,bottom-top), (right,top,x+w-right,bottom-top)):
                if piece[2] > 0 and piece[3] > 0:
                    next_rects.append(piece)
        remaining = next_rects
    return remaining


class BackgroundEffects:
    def __init__(self, lines):
        self.surfaces = {}
        self.effects = {}
        self.regions = {}
        self.history = []
        self.outputs = {}
        for line in lines:
            assert not re.search(r'wl_display#\d+\.error\(', line), line
            assert 'surface already has a background effect' not in line, line
            assert 'TRUNCATED' not in line, 'protocol trace was truncated'
            if m := re.search(r'wl_output#(\d+)\.name\("([^"]+)"\)', line):
                self.outputs[int(m[1])] = m[2]
            if ' -> ' not in line:
                continue
            if m := re.search(r'create_surface\(new id wl_surface#(\d+)\)', line):
                sid = int(m[1])
                assert sid not in self.surfaces, line
                self.surfaces[sid] = dict(id=sid, namespace=None, output=None, effect=None, attached=False)
            elif m := re.search(r'get_layer_surface\(new id .*?, wl_surface#(\d+), wl_output#(\d+), \d+, "([^"]+)"\)', line):
                self.surfaces[int(m[1])].update(namespace=m[3], output=int(m[2]))
            elif m := re.search(r'ext_background_effect_manager_v1#(\d+)\.get_background_effect\(new id ext_background_effect_surface_v1#(\d+), wl_surface#(\d+)\)', line):
                manager, eid, sid = map(int, m.groups())
                surface = self.surfaces[sid]
                assert surface['effect'] is None, ('duplicate live effect', line, surface)
                assert eid not in self.effects, line
                effect = dict(id=eid, surface=surface, manager=manager, pending=(), active=(), updates=[], commits=[], destroyed=False)
                surface['effect'] = effect
                self.effects[eid] = effect
                self.history.append(effect)
            elif m := re.search(r'create_region\(new id wl_region#(\d+)\)', line):
                self.regions[int(m[1])] = []
            elif m := re.search(r'wl_region#(\d+)\.add\((-?\d+), (-?\d+), (\d+), (\d+)\)', line):
                self.regions[int(m[1])].append(tuple(map(int, m.groups()[1:])))
            elif re.search(r'wl_region#\d+\.subtract\(', line):
                raise AssertionError('Extend region ledger for subtract before using this trace: ' + line)
            elif m := re.search(r'ext_background_effect_surface_v1#(\d+)\.set_blur_region\((nil|wl_region#\d+)\)', line):
                effect = self.effects[int(m[1])]
                region = () if m[2] == 'nil' else tuple(self.regions[int(m[2].split('#')[1])])
                effect['pending'] = region
                effect['updates'].append(region)
            elif m := re.search(r'wl_surface#(\d+)\.attach\(([^,]+),', line):
                self.surfaces[int(m[1])]['attached'] = m[2] != 'nil'
            elif m := re.search(r'wl_surface#(\d+)\.commit\(', line):
                if effect := self.surfaces[int(m[1])]['effect']:
                    effect['active'] = effect['pending']
                    effect['commits'].append(effect['active'])
            elif m := re.search(r'ext_background_effect_surface_v1#(\d+)\.destroy\(', line):
                effect = self.effects.pop(int(m[1]))
                effect['destroyed'] = True
                effect['surface']['effect'] = None
            elif m := re.search(r'wl_surface#(\d+)\.destroy\(', line):
                surface = self.surfaces.pop(int(m[1]))
                surface['attached'] = False
                # The effect resource may outlive its surface. Retain its record
                # without associating it with a later reuse of the surface ID.
            elif m := re.search(r'wl_region#(\d+)\.destroy\(', line):
                self.regions.pop(int(m[1]))

    def active(self, namespace=None):
        return [s['effect'] for s in self.surfaces.values()
                if s['attached'] and s['effect'] and
                (namespace is None or s['namespace'] == namespace)]

    def assert_blurred(self, namespace):
        effects = self.active(namespace)
        assert effects and all(e['active'] for e in effects), ('missing committed blur', namespace)
        return effects

    def assert_clear(self):
        assert all(not e['active'] for e in self.active()), 'stale committed blur region'

    def assert_bar_shapes(self, outputs, gtk_owner=False):
        for output in outputs:
            shapes = [dict(r) for r in output['island_rects'] if r]
            # The existing input ledger is in content coordinates. The default
            # island CSS adds 6px padding along the bar; GTK blurs that visible
            # background too. Empty space outside these border boxes stays clear.
            if gtk_owner and output['islands']:
                for r in shapes:
                    axis, size = ('x', 'width') if output['bar_edge'] in ('top', 'bottom') else ('y', 'height')
                    r[axis] -= 6
                    r[size] += 12
            effects = [e for e in self.assert_blurred('pearl:bar')
                       if self.outputs[e['surface']['output']] == output['connector']]
            assert len(effects) == 1, output
            region = effects[0]['active']
            for x, y, w, h in region:
                assert not outside((x, y, w, h), shapes), ('blur outside panel/islands', (x, y, w, h), shapes)
            for r in shapes:
                assert any(x < r['x']+r['width'] and x+w > r['x'] and
                           y < r['y']+r['height'] and y+h > r['y'] for x,y,w,h in region), ('island missing blur', r)
                assert not any(x <= r['x'] < x+w and y <= r['y'] < y+h for x,y,w,h in region), ('square blur corner', r)

    def assert_finished(self):
        assert self.history, 'no effect objects observed'
        assert not self.effects, 'effect objects not destroyed'
        assert all(e['destroyed'] for e in self.history)
        assert any(any(e['commits']) for e in self.history), 'no nonempty committed blur'
        assert any(e['commits'] and any(not r for r in e['commits']) and any(e['commits'])
                   for e in self.history), 'blur never cleared on an existing effect'
