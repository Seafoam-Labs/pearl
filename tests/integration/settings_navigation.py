"""Drive the compact section tabs with real keyboard events."""
from pearl_session import wait_for
from test_surfaces import ctl

PAGES = ('overview', 'network', 'bluetooth', 'sound', 'power')
TITLES = dict(overview='Overview', network='Network', bluetooth='Bluetooth', sound='Sound', power='Power & battery')


def report(session, binary):
    return ctl(session, binary, 'aqueous', 'status', '--text', 'test-settings-page')['result']


def choose_page(session, binary, page):
    # Page restoration runs after GTK allocates the newly mapped viewport.
    wait_for(lambda: not report(session, binary).get('restoring', False))
    for _ in range(160):
        if report(session, binary).get('tab') == TITLES[page]:
            break
        session.run(['wtype', '-s', '50', '-k', 'Tab', '-s', '50'])
    else:
        raise AssertionError('Section tab is not keyboard reachable: '+page)
    session.run(['wtype', '-s', '100', '-k', 'Return', '-s', '100'])
    return wait_for(lambda: (value if (value := report(session, binary))['page'] == page and not value.get('restoring', False) else False))


def show_page(session, binary, page, output=None):
    ctl(session, binary, 'control-center', 'show', *(['--output', output] if output else []))
    return choose_page(session, binary, page)
