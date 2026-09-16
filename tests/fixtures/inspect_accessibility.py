#!/usr/bin/env python3
"""Read or focus a named widget on the calling private accessibility bus."""
import argparse,json,gi
gi.require_version('Atspi','2.0')
from gi.repository import Atspi
p=argparse.ArgumentParser();p.add_argument('--focus');p.add_argument('--action');p.add_argument('--all',action='store_true');a=p.parse_args()
queue=[(Atspi.get_desktop(0),0)];seen=0;nodes=[];performed=False;attempts=[]
while queue and seen<5000:
 node,depth=queue.pop(0);seen+=1
 try:
  name=node.get_name();role=node.get_role_name();states=node.get_state_set()
  showing=states.contains(Atspi.StateType.SHOWING)
  if a.all or (showing and name):nodes.append(dict(name=name[:512],description=node.get_description()[:512],role=role,showing=showing,sensitive=states.contains(Atspi.StateType.SENSITIVE),focused=states.contains(Atspi.StateType.FOCUSED),checked=states.contains(Atspi.StateType.CHECKED),pressed=states.contains(Atspi.StateType.PRESSED),selected=states.contains(Atspi.StateType.SELECTED)))
  if showing and not performed and name==(a.focus or a.action):
   if a.focus:
    attempts.append(dict(role=role,focusable=states.contains(Atspi.StateType.FOCUSABLE),sensitive=states.contains(Atspi.StateType.SENSITIVE)))
    performed=node.get_component_iface().grab_focus()
   else:performed=node.get_action_iface().do_action(0)
  if depth<32:queue.extend((node.get_child_at_index(i),depth+1) for i in range(min(node.get_child_count(),1024)))
 except Exception as e:
  if a.focus or a.action:attempts.append(dict(error=str(e)))
  continue
print(json.dumps(dict(nodes=nodes,visited=seen,performed=performed,attempts=attempts)))
if a.focus or a.action:raise SystemExit(not performed)
