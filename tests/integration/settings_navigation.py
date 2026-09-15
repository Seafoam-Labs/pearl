"""Drive the compact section chooser with real keyboard events."""
from pearl_session import wait_for
from test_surfaces import ctl

PAGES = ('overview', 'network', 'bluetooth', 'sound', 'power')


def report(session, binary):
    return ctl(session, binary, 'aqueous', 'status', '--text', 'test-settings-page')['result']


def choose_page(session, binary, page):
    # Page restoration runs after GTK allocates the newly mapped viewport.
    wait_for(lambda: not report(session, binary).get('restoring', False))
    for _ in range(80):
        if report(session, binary)['focus'] == 'section-chooser':
            break
        session.run(['wtype', '-s', '50', '-k', 'Tab', '-s', '50'])
    else:
        raise AssertionError('Section chooser is not keyboard reachable')
    keys = ['space', 'Home', *(['Down'] * PAGES.index(page)), 'Return']
    argv = ['wtype', '-s', '100']
    for key in keys:
        argv += ['-k', key, '-s', '100']
    session.run(argv)
    return wait_for(lambda: (value if (value := report(session, binary))['page'] == page and not value.get('restoring', False) else False))


def show_page(session, binary, page, output=None):
    ctl(session, binary, 'control-center', 'show', *(['--output', output] if output else []))
    return choose_page(session, binary, page)
