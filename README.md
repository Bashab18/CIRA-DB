# CIRA-DB

The on-device SQLite schema for the CIRA mobile app (Flutter/sqflite). This is a
**reference copy** taken from [Bashab18/TEST](https://github.com/Bashab18/TEST)
(`lib/services/app_database.dart`, `lib/models/recorded_session.dart`) — not a
package the app depends on, so changes here don't automatically apply there.

## What's in here

- `lib/services/app_database.dart` — table definitions, versioned migrations
  (`onUpgrade`), and query helpers for recorded sessions, favorited exercises,
  the onboarded flag, daily Health Connect/HealthKit history snapshots, custom
  workout plans, and reminders.
- `lib/models/recorded_session.dart` — the one model type the schema code
  depends on.

## Keeping this in sync

Copy the same two files over from the main app repo whenever the schema
changes there:

```
cp path/to/mobile/lib/services/app_database.dart lib/services/
cp path/to/mobile/lib/models/recorded_session.dart lib/models/
```
