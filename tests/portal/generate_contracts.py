#!/usr/bin/env python3
"""Generate the backend introspection strings from the pinned, licensed XML."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[2]
names=['FileChooser','AppChooser','Print','Notification','Inhibit','Access','Account','Email','DynamicLauncher','Lockdown','Settings','Request','Session']
text='/* Generated from tests/fixtures/portal; preserve the XML license notices there. */\n'
for name in names:
    source=ROOT/'tests/fixtures/portal'/f'org.freedesktop.impl.portal.{name}.xml'
    xml=ET.tostring(ET.fromstring(source.read_text()),encoding='unicode')
    text+=f'static const char xml_{name}[] = '+json.dumps(xml)+';\n'
path=ROOT/'src/portal/contracts.h'
parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
if args.check:assert path.read_text()==text,'Regenerate portal contracts'
else:path.write_text(text)
