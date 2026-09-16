"""Reach retained compact editors through their real Overview links after CLI cutover."""
import time
from test_surfaces import ctl
from test_session_services import key


def open_editor(s, binary, aqueous=False, output=None):
    args=['control-center','show']
    if output:args+=['--output',output]
    ctl(s,binary,*args)
    time.sleep(.2)
    label='Aqueous settings' if aqueous else 'Pearl settings'
    for _ in range(100):
        page=ctl(s,binary,'aqueous','status','--text','test-settings-page')['result']
        if page['button']==label:
            key(s,'-k','Return');break
        key(s,'-k','Tab')
    else:raise AssertionError('compact editor link not reachable: '+label)
