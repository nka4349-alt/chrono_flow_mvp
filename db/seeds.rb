# frozen_string_literal: true

# --- Users ---
admin = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.name = 'Admin'
  u.password = 'password'
  u.password_confirmation = 'password'
end

user2 = User.find_or_create_by!(email: 'member@example.com') do |u|
  u.name = 'Member'
  u.password = 'password'
  u.password_confirmation = 'password'
end

# --- EventTypes (user-defined) ---
meeting = EventType.find_or_create_by!(user: admin, name: 'Meeting') do |t|
  t.color = '#ef4444'
end

holiday = EventType.find_or_create_by!(user: admin, name: 'Holiday') do |t|
  t.color = '#10b981'
end

# --- Groups ---
root_group = Group.find_or_create_by!(name: 'プロジェクトA', owner: admin) do |g|
  g.position = 0
end

GroupMember.find_or_create_by!(group: root_group, user: admin) do |gm|
  gm.role = :admin
end

GroupMember.find_or_create_by!(group: root_group, user: user2) do |gm|
  gm.role = :member
end

# --- Sample Events ---
Event.find_or_create_by!(title: '個人：テスト予定', created_by: admin) do |e|
  e.start_at = Time.zone.now.change(min: 0) + 1.hour
  e.end_at = Time.zone.now.change(min: 0) + 2.hours
  e.event_type = meeting
end

# group event
ge = Event.find_or_create_by!(title: 'グループ：定例', created_by: admin) do |e|
  e.start_at = (Time.zone.now + 1.day).change(hour: 10, min: 0)
  e.end_at = (Time.zone.now + 1.day).change(hour: 11, min: 0)
  e.event_type = meeting
end

EventGroup.find_or_create_by!(event: ge, group: root_group)

puts 'seed done.'
