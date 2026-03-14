ChronoFlow fix: /api/groups/:id/events returns 500

This patch adds a robust controller:
  app/controllers/api/group_events_controller.rb

And a helper script to add the route:
  tools/add_group_events_route.py

Apply:
  1) unzip into project root
  2) python3 tools/add_group_events_route.py
  3) ruby -c config/routes.rb
  4) bin/rails s (restart)

Why 500 happens:
  existing controller likely uses wrong column names (starts_at/ends_at) but DB uses start_at/end_at.
