# Contacts / Availability Profiles API

## Contacts

- `GET /api/contacts`
- `POST /api/contacts`
- `PATCH /api/contacts/:id`
- `DELETE /api/contacts/:id`
- `POST /api/contacts/sync_friends`

### create payload example

```json
{
  "contact": {
    "display_name": "母",
    "relation_type": "family",
    "preferred_duration_minutes": 90,
    "timezone": "Asia/Tokyo",
    "notes": "週末昼が多い"
  }
}
```

### friend-linked contact example

```json
{
  "contact": {
    "linked_user_id": 12,
    "relation_type": "friend"
  }
}
```

## Availability profiles

- `GET /api/contacts/:contact_id/availability_profiles`
- `POST /api/contacts/:contact_id/availability_profiles`
- `PATCH /api/contacts/:contact_id/availability_profiles/:id`
- `DELETE /api/contacts/:contact_id/availability_profiles/:id`

### create payload example

```json
{
  "availability_profile": {
    "weekday": 6,
    "start_minute": 660,
    "end_minute": 900,
    "preference_kind": "preferred",
    "notes": "土曜の昼は会いやすい"
  }
}
```
