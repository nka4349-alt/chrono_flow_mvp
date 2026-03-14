"""Insert route for Api::GroupEventsController.

Adds inside `namespace :api do`:
  get 'groups/:id/events', to: 'group_events#index'

It is inserted right after `namespace :api do` line, if not already present.
"""

from pathlib import Path

p = Path('config/routes.rb')
text = p.read_text(encoding='utf-8')

needle = "to: 'group_events#index'"
if needle in text:
    print('OK: route already exists')
    raise SystemExit(0)

lines = text.splitlines(True)

for i, line in enumerate(lines):
    if line.strip() == 'namespace :api do':
        lines.insert(i+1, "    get 'groups/:id/events', to: 'group_events#index'\n")
        p.write_text(''.join(lines), encoding='utf-8')
        print('OK: inserted group events route')
        raise SystemExit(0)

raise SystemExit('ERROR: namespace :api do not found in config/routes.rb')
