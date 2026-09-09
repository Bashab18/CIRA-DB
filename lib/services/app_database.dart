import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/recorded_session.dart';

/// On-device SQLite storage backing recorded sessions, favorited exercises,
/// the onboarded flag, and a daily history of Health Connect / HealthKit
/// snapshots. Replaces the earlier shared_preferences JSON-blob persistence
/// for the first three; health history is new data with no prior storage.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static const _dbVersion = 12;
  static const _maxSessions = 50;

  static const _remindersTableSql = '''
    CREATE TABLE reminders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      hour INTEGER NOT NULL,
      minute INTEGER NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL
    )
  ''';

  // Achievements/challenges, pre-user_id shape (v6) -- kept only so the `<6`
  // upgrade step keeps creating what it always created on a device jumping
  // straight from an old version; the `<7` step (see onUpgrade) then adds
  // per-account scoping on top, same "frozen historical shape" pattern as
  // _usersTableSqlV3 below.
  static const _achievementsTableSqlV6 = '''
    CREATE TABLE achievements (
      achievement_id TEXT PRIMARY KEY,
      earned_at INTEGER NOT NULL
    )
  ''';

  static const _regularChallengeStateTableSqlV6 = '''
    CREATE TABLE regular_challenge_state (
      challenge_id TEXT PRIMARY KEY,
      state TEXT NOT NULL DEFAULT 'active'
    )
  ''';

  static const _customChallengesTableSqlV6 = '''
    CREATE TABLE custom_challenges (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      desc TEXT NOT NULL,
      current INTEGER NOT NULL DEFAULT 0,
      goal INTEGER NOT NULL,
      unit TEXT NOT NULL,
      days_left INTEGER NOT NULL DEFAULT 7,
      streak INTEGER NOT NULL DEFAULT 0,
      bar_color TEXT NOT NULL,
      glyph TEXT NOT NULL,
      tone TEXT NOT NULL,
      sub_stat TEXT,
      done INTEGER NOT NULL DEFAULT 0,
      exceeded INTEGER NOT NULL DEFAULT 0,
      needs_attention INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'active',
      created_at INTEGER NOT NULL
    )
  ''';

  // Fresh-install (v7) shapes -- every row scoped to the account that owns
  // it. Devices upgrading from an earlier version get here via the `<6`
  // shapes above plus the `<7` migration (see onUpgrade).
  static const _achievementsTableSql = '''
    CREATE TABLE achievements (
      user_id INTEGER NOT NULL,
      achievement_id TEXT NOT NULL,
      earned_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, achievement_id)
    )
  ''';

  static const _regularChallengeStateTableSql = '''
    CREATE TABLE regular_challenge_state (
      user_id INTEGER NOT NULL,
      challenge_id TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'active',
      PRIMARY KEY (user_id, challenge_id)
    )
  ''';

  static const _customChallengesTableSql = '''
    CREATE TABLE custom_challenges (
      id TEXT PRIMARY KEY,
      user_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      desc TEXT NOT NULL,
      current INTEGER NOT NULL DEFAULT 0,
      goal INTEGER NOT NULL,
      unit TEXT NOT NULL,
      days_left INTEGER NOT NULL DEFAULT 7,
      streak INTEGER NOT NULL DEFAULT 0,
      bar_color TEXT NOT NULL,
      glyph TEXT NOT NULL,
      tone TEXT NOT NULL,
      sub_stat TEXT,
      done INTEGER NOT NULL DEFAULT 0,
      exceeded INTEGER NOT NULL DEFAULT 0,
      needs_attention INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'active',
      created_at INTEGER NOT NULL
    )
  ''';

  // Schema exactly as it was when the `<3` upgrade step below was written --
  // frozen so that step keeps creating what it always created. The v5
  // columns are added separately, by the `<5` step's ALTER TABLEs, for both
  // devices upgrading from this v3 shape and devices already sitting at v3
  // or v4. _usersTableSql (below) is for fresh installs only (onCreate) and
  // has since grown those columns inline -- reusing it here would make `<3`
  // create them too, so the `<5` ALTER TABLEs then fail with "duplicate
  // column name" on any device upgrading straight from v2.
  static const _usersTableSqlV3 = '''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      first_name TEXT NOT NULL,
      last_name TEXT NOT NULL,
      dob TEXT,
      phone TEXT,
      weight_lb INTEGER,
      height_in INTEGER,
      age INTEGER,
      conditions TEXT,
      goals TEXT,
      units TEXT,
      notifications INTEGER,
      haptics INTEGER,
      workout_reminders INTEGER,
      sleep_reminders INTEGER,
      weekly_digest INTEGER,
      ai_avatar TEXT,
      ai_name TEXT,
      ai_personality TEXT,
      ai_voice TEXT,
      ai_notify INTEGER,
      activity_level TEXT,
      days_per_week INTEGER,
      pref_time TEXT,
      session_len TEXT,
      location TEXT,
      exercise_types TEXT,
      body_build TEXT,
      created_at INTEGER NOT NULL
    )
  ''';

  // Fresh-install shape (onCreate only) -- includes the v5 columns inline
  // since a brand new database has no separate ALTER TABLE step to add them.
  static const _usersTableSql = '''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      first_name TEXT NOT NULL,
      last_name TEXT NOT NULL,
      dob TEXT,
      phone TEXT,
      weight_lb INTEGER,
      height_in INTEGER,
      age INTEGER,
      conditions TEXT,
      goals TEXT,
      units TEXT,
      notifications INTEGER,
      haptics INTEGER,
      workout_reminders INTEGER,
      sleep_reminders INTEGER,
      weekly_digest INTEGER,
      user_avatar TEXT,
      user_avatar_animated INTEGER,
      ai_avatar TEXT,
      ai_avatar_animated INTEGER,
      ai_name TEXT,
      ai_personality TEXT,
      ai_voice TEXT,
      ai_notify INTEGER,
      activity_level TEXT,
      days_per_week INTEGER,
      pref_time TEXT,
      session_len TEXT,
      location TEXT,
      exercise_types TEXT,
      body_build TEXT,
      contacts TEXT,
      analytics INTEGER,
      share_with_coaches INTEGER,
      biometric_lock INTEGER,
      created_at INTEGER NOT NULL
    )
  ''';

  // v8 -- backs PlanStore. `plan_exercises` holds, per (user, plan), the
  // full current exercise list once the user has customized that plan in
  // any way (add-to-plan or a full edit) -- an override of that plan's
  // built-in/base list, not a delta, so removals and reordering round-trip
  // correctly too. `custom_plans` holds plans the user created from scratch
  // (custom builder, AI builder, or "New plan" inside the add-to-plan
  // sheet). Both replace what used to be toast-only, non-persisted stubs.
  static const _planExercisesTableSql = '''
    CREATE TABLE plan_exercises (
      user_id INTEGER NOT NULL,
      plan_id TEXT NOT NULL,
      exercise_id TEXT NOT NULL,
      added_at INTEGER NOT NULL,
      PRIMARY KEY (user_id, plan_id, exercise_id)
    )
  ''';

  // Shape as it was at v8 -- frozen for the `<8` upgrade step below (see
  // _usersTableSqlV3 for why). `_customPlansTableSql` (no suffix) has since
  // grown difficulty/days/notes for the `<9` step and fresh installs.
  static const _customPlansTableSqlV8 = '''
    CREATE TABLE custom_plans (
      id TEXT PRIMARY KEY,
      user_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      duration INTEGER NOT NULL,
      target TEXT NOT NULL,
      tags TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';

  static const _customPlansTableSql = '''
    CREATE TABLE custom_plans (
      id TEXT PRIMARY KEY,
      user_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      duration INTEGER NOT NULL,
      target TEXT NOT NULL,
      tags TEXT NOT NULL,
      difficulty TEXT,
      days TEXT,
      notes TEXT,
      created_at INTEGER NOT NULL
    )
  ''';

  Future<Database>? _dbFuture;
  Future<Database> get _database => _dbFuture ??= _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'mhealth.db');
    return openDatabase(
      path,
      version: _dbVersion,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE health_snapshots ADD COLUMN deep_sleep_hours REAL');
          await db.execute('ALTER TABLE health_snapshots ADD COLUMN rem_sleep_hours REAL');
          await db.execute('ALTER TABLE health_snapshots ADD COLUMN light_sleep_hours REAL');
        }
        if (oldVersion < 3) {
          await db.execute(_usersTableSqlV3);
        }
        if (oldVersion < 4) {
          await db.execute(_remindersTableSql);
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE users ADD COLUMN contacts TEXT');
          await db.execute('ALTER TABLE users ADD COLUMN analytics INTEGER');
          await db.execute('ALTER TABLE users ADD COLUMN share_with_coaches INTEGER');
          await db.execute('ALTER TABLE users ADD COLUMN personalized_ads INTEGER');
          await db.execute('ALTER TABLE users ADD COLUMN biometric_lock INTEGER');
        }
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE health_snapshots ADD COLUMN resting_hr INTEGER');
          await db.execute('ALTER TABLE health_snapshots ADD COLUMN peak_hr INTEGER');
          await db.execute('ALTER TABLE health_snapshots ADD COLUMN hrv_ms REAL');
          await db.execute('ALTER TABLE health_snapshots ADD COLUMN heart_zone_minutes TEXT');
          await db.execute(_achievementsTableSqlV6);
          await db.execute(_regularChallengeStateTableSqlV6);
          await db.execute(_customChallengesTableSqlV6);
        }
        if (oldVersion < 7) {
          await _migrateToV7(db);
        }
        if (oldVersion < 8) {
          await db.execute(_planExercisesTableSql);
          await db.execute(_customPlansTableSqlV8);
        }
        if (oldVersion < 9) {
          await db.execute('ALTER TABLE custom_plans ADD COLUMN difficulty TEXT');
          await db.execute('ALTER TABLE custom_plans ADD COLUMN days TEXT');
          await db.execute('ALTER TABLE custom_plans ADD COLUMN notes TEXT');
        }
        if (oldVersion < 10) {
          await db.execute('ALTER TABLE users ADD COLUMN ai_avatar_animated INTEGER');
        }
        if (oldVersion < 11) {
          await db.execute('ALTER TABLE users ADD COLUMN user_avatar TEXT');
          await db.execute('ALTER TABLE users ADD COLUMN user_avatar_animated INTEGER');
        }
        if (oldVersion < 12) {
          // See the matching comments on these same indexes in onCreate.
          await db.execute('CREATE INDEX idx_users_username_lower ON users (lower(username))');
          await db.execute('CREATE INDEX idx_users_email_lower ON users (lower(email))');
          await db.execute('CREATE INDEX idx_custom_challenges_user_id ON custom_challenges (user_id)');
          await db.execute('CREATE INDEX idx_custom_plans_user_id ON custom_plans (user_id)');
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            kind TEXT NOT NULL,
            saved_at INTEGER NOT NULL,
            plan_id TEXT,
            plan_name TEXT,
            completed INTEGER,
            total INTEGER,
            exercises TEXT,
            tags TEXT,
            type TEXT,
            hr INTEGER,
            distance_km REAL,
            steps INTEGER,
            pace TEXT,
            sets INTEGER,
            feel INTEGER,
            elapsed INTEGER NOT NULL,
            kcal INTEGER NOT NULL,
            notes TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_sessions_saved_at ON sessions (saved_at DESC)');
        await db.execute('CREATE INDEX idx_sessions_user_id ON sessions (user_id)');

        await db.execute('CREATE TABLE favorites (exercise_id TEXT PRIMARY KEY)');

        await db.execute('CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT)');

        await db.execute('''
          CREATE TABLE health_snapshots (
            user_id INTEGER NOT NULL,
            day TEXT NOT NULL,
            fetched_at INTEGER NOT NULL,
            steps INTEGER NOT NULL,
            active_calories INTEGER NOT NULL,
            latest_heart_rate INTEGER,
            sleep_hours REAL,
            deep_sleep_hours REAL,
            rem_sleep_hours REAL,
            light_sleep_hours REAL,
            resting_hr INTEGER,
            peak_hr INTEGER,
            hrv_ms REAL,
            heart_zone_minutes TEXT,
            PRIMARY KEY (user_id, day)
          )
        ''');

        await db.execute(_usersTableSql);
        // Expression indexes matching the lower(username)/lower(email)
        // WHERE clauses actually used at signup/login (see
        // findUserByUsernameOrEmail/usernameOrEmailTaken below) -- without
        // these, wrapping the indexed columns in lower() at query time
        // stops SQLite from using the plain UNIQUE index, forcing a full
        // table scan on every check.
        await db.execute('CREATE INDEX idx_users_username_lower ON users (lower(username))');
        await db.execute('CREATE INDEX idx_users_email_lower ON users (lower(email))');
        await db.execute(_remindersTableSql);
        await db.execute(_achievementsTableSql);
        await db.execute(_regularChallengeStateTableSql);
        await db.execute(_customChallengesTableSql);
        await db.execute('CREATE INDEX idx_custom_challenges_user_id ON custom_challenges (user_id)');
        await db.execute(_planExercisesTableSql);
        await db.execute(_customPlansTableSql);
        await db.execute('CREATE INDEX idx_custom_plans_user_id ON custom_plans (user_id)');
      },
    );
  }

  /// Adds per-account scoping to sessions/health_snapshots/achievements/
  /// regular_challenge_state/custom_challenges -- without this, every real
  /// account on the same device shared one global pool of "history", so a
  /// brand-new sign-up could see another account's (e.g. the demo account's)
  /// workouts, achievements, and challenge progress. Existing unscoped rows
  /// are attributed to whichever account was last signed in (best-effort;
  /// there's no way to know their true original owner), so at worst they
  /// surface once for that one account instead of every account forever.
  Future<void> _migrateToV7(Database db) async {
    final currentUserId = await db.rawQuery("SELECT value FROM app_meta WHERE key = 'current_user_id'");
    final ownerIdLiteral = currentUserId.isEmpty ? 'NULL' : "'${currentUserId.first['value']}'";

    await db.execute('ALTER TABLE sessions ADD COLUMN user_id INTEGER');
    await db.execute('UPDATE sessions SET user_id = $ownerIdLiteral WHERE user_id IS NULL');
    await db.execute('CREATE INDEX idx_sessions_user_id ON sessions (user_id)');

    await db.execute('ALTER TABLE custom_challenges ADD COLUMN user_id INTEGER');
    await db.execute('UPDATE custom_challenges SET user_id = $ownerIdLiteral WHERE user_id IS NULL');

    await db.execute('''
      CREATE TABLE health_snapshots_v7 (
        user_id INTEGER,
        day TEXT NOT NULL,
        fetched_at INTEGER NOT NULL,
        steps INTEGER NOT NULL,
        active_calories INTEGER NOT NULL,
        latest_heart_rate INTEGER,
        sleep_hours REAL,
        deep_sleep_hours REAL,
        rem_sleep_hours REAL,
        light_sleep_hours REAL,
        resting_hr INTEGER,
        peak_hr INTEGER,
        hrv_ms REAL,
        heart_zone_minutes TEXT,
        PRIMARY KEY (user_id, day)
      )
    ''');
    await db.execute('''
      INSERT INTO health_snapshots_v7
      SELECT $ownerIdLiteral, day, fetched_at, steps, active_calories, latest_heart_rate,
             sleep_hours, deep_sleep_hours, rem_sleep_hours, light_sleep_hours,
             resting_hr, peak_hr, hrv_ms, heart_zone_minutes
      FROM health_snapshots
    ''');
    await db.execute('DROP TABLE health_snapshots');
    await db.execute('ALTER TABLE health_snapshots_v7 RENAME TO health_snapshots');

    await db.execute('''
      CREATE TABLE achievements_v7 (
        user_id INTEGER,
        achievement_id TEXT NOT NULL,
        earned_at INTEGER NOT NULL,
        PRIMARY KEY (user_id, achievement_id)
      )
    ''');
    await db.execute('INSERT INTO achievements_v7 SELECT $ownerIdLiteral, achievement_id, earned_at FROM achievements');
    await db.execute('DROP TABLE achievements');
    await db.execute('ALTER TABLE achievements_v7 RENAME TO achievements');

    await db.execute('''
      CREATE TABLE regular_challenge_state_v7 (
        user_id INTEGER,
        challenge_id TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'active',
        PRIMARY KEY (user_id, challenge_id)
      )
    ''');
    await db.execute('INSERT INTO regular_challenge_state_v7 SELECT $ownerIdLiteral, challenge_id, state FROM regular_challenge_state');
    await db.execute('DROP TABLE regular_challenge_state');
    await db.execute('ALTER TABLE regular_challenge_state_v7 RENAME TO regular_challenge_state');
  }

  // ---- sessions ----

  Future<List<RecordedSession>> loadSessions({required int userId, int limit = _maxSessions}) async {
    final db = await _database;
    final rows = await db.query('sessions', where: 'user_id = ?', whereArgs: [userId], orderBy: 'saved_at DESC', limit: limit);
    return rows.map(_sessionFromRow).toList();
  }

  Future<void> insertSession(RecordedSession session, {required int userId}) async {
    final db = await _database;
    await db.insert('sessions', _sessionToRow(session, userId));
    await _trimSessions(db, userId: userId);
  }

  Future<void> insertSessions(List<RecordedSession> sessions, {required int userId}) async {
    final db = await _database;
    final batch = db.batch();
    for (final s in sessions) {
      batch.insert('sessions', _sessionToRow(s, userId));
    }
    await batch.commit(noResult: true);
    await _trimSessions(db, userId: userId);
  }

  /// Keeps only the most recent [_maxSessions] rows PER ACCOUNT, matching the
  /// cap the web app's `saveSession` applies to its localStorage array.
  Future<void> _trimSessions(Database db, {required int userId, int keep = _maxSessions}) async {
    final rows = await db.query('sessions', columns: ['id'], where: 'user_id = ?', whereArgs: [userId], orderBy: 'saved_at DESC');
    if (rows.length <= keep) return;
    final batch = db.batch();
    for (final row in rows.skip(keep)) {
      batch.delete('sessions', where: 'id = ?', whereArgs: [row['id'] as int]);
    }
    await batch.commit(noResult: true);
  }

  Map<String, dynamic> _sessionToRow(RecordedSession s, int userId) => {
        'user_id': userId,
        'kind': s.kind,
        'saved_at': s.savedAt,
        'plan_id': s.planId,
        'plan_name': s.planName,
        'completed': s.completed,
        'total': s.total,
        'exercises': s.exercises == null ? null : jsonEncode(s.exercises!.map((e) => e.toJson()).toList()),
        'tags': s.tags == null ? null : jsonEncode(s.tags),
        'type': s.type,
        'hr': s.hr,
        'distance_km': s.distanceKm,
        'steps': s.steps,
        'pace': s.pace,
        'sets': s.sets,
        'feel': s.feel,
        'elapsed': s.elapsed,
        'kcal': s.kcal,
        'notes': s.notes,
      };

  RecordedSession _sessionFromRow(Map<String, Object?> row) => RecordedSession(
        kind: row['kind'] as String,
        savedAt: row['saved_at'] as int,
        elapsed: row['elapsed'] as int,
        kcal: row['kcal'] as int,
        planId: row['plan_id'] as String?,
        planName: row['plan_name'] as String?,
        completed: row['completed'] as int?,
        total: row['total'] as int?,
        exercises: row['exercises'] == null
            ? null
            : (jsonDecode(row['exercises'] as String) as List)
                .map((e) => SessionExercise.fromJson(e as Map<String, dynamic>))
                .toList(),
        tags: row['tags'] == null ? null : (jsonDecode(row['tags'] as String) as List).cast<String>(),
        type: row['type'] as String?,
        hr: row['hr'] as int?,
        distanceKm: (row['distance_km'] as num?)?.toDouble(),
        steps: row['steps'] as int?,
        pace: row['pace'] as String?,
        sets: row['sets'] as int?,
        feel: row['feel'] as int?,
        notes: row['notes'] as String?,
      );

  // ---- favorites ----

  Future<Set<String>> loadFavorites() async {
    final db = await _database;
    final rows = await db.query('favorites', columns: ['exercise_id']);
    return rows.map((r) => r['exercise_id'] as String).toSet();
  }

  Future<void> addFavorite(String exerciseId) async {
    final db = await _database;
    await db.insert('favorites', {'exercise_id': exerciseId}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> removeFavorite(String exerciseId) async {
    final db = await _database;
    await db.delete('favorites', where: 'exercise_id = ?', whereArgs: [exerciseId]);
  }

  // ---- app_meta: small key/value settings (onboarded flag, currently-signed-in user id) ----

  Future<String?> getMeta(String key) async {
    final db = await _database;
    final rows = await db.query('app_meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String value) async {
    final db = await _database;
    await db.insert('app_meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteMeta(String key) async {
    final db = await _database;
    await db.delete('app_meta', where: 'key = ?', whereArgs: [key]);
  }

  // ---- health_snapshots: one row per calendar day, upserted on every sync ----

  /// Public so callers that need to build many rows for [upsertHealthSnapshots]
  /// (e.g. DemoSeeder) don't have to duplicate this column mapping.
  Map<String, Object?> healthSnapshotRow({
    required int userId,
    required String day,
    required int fetchedAt,
    required int steps,
    required int activeCalories,
    int? latestHeartRate,
    double? sleepHours,
    double? deepSleepHours,
    double? remSleepHours,
    double? lightSleepHours,
    int? restingHr,
    int? peakHr,
    double? hrvMs,
    Map<String, int>? heartZoneMinutes,
  }) => {
        'user_id': userId,
        'day': day,
        'fetched_at': fetchedAt,
        'steps': steps,
        'active_calories': activeCalories,
        'latest_heart_rate': latestHeartRate,
        'sleep_hours': sleepHours,
        'deep_sleep_hours': deepSleepHours,
        'rem_sleep_hours': remSleepHours,
        'light_sleep_hours': lightSleepHours,
        'resting_hr': restingHr,
        'peak_hr': peakHr,
        'hrv_ms': hrvMs,
        'heart_zone_minutes': heartZoneMinutes == null ? null : jsonEncode(heartZoneMinutes),
      };

  Future<void> upsertHealthSnapshot({
    required int userId,
    required String day,
    required int fetchedAt,
    required int steps,
    required int activeCalories,
    int? latestHeartRate,
    double? sleepHours,
    double? deepSleepHours,
    double? remSleepHours,
    double? lightSleepHours,
    int? restingHr,
    int? peakHr,
    double? hrvMs,
    Map<String, int>? heartZoneMinutes,
  }) async {
    final db = await _database;
    await db.insert(
      'health_snapshots',
      healthSnapshotRow(
        userId: userId,
        day: day,
        fetchedAt: fetchedAt,
        steps: steps,
        activeCalories: activeCalories,
        latestHeartRate: latestHeartRate,
        sleepHours: sleepHours,
        deepSleepHours: deepSleepHours,
        remSleepHours: remSleepHours,
        lightSleepHours: lightSleepHours,
        restingHr: restingHr,
        peakHr: peakHr,
        hrvMs: hrvMs,
        heartZoneMinutes: heartZoneMinutes,
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Batched sibling of [upsertHealthSnapshot] -- one transaction instead of
  /// one round trip per row. Used by DemoSeeder, which otherwise writes 21
  /// rows sequentially on account creation.
  Future<void> upsertHealthSnapshots(List<Map<String, Object?>> rows) async {
    final db = await _database;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('health_snapshots', row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Most recent [days] daily snapshots for [userId], newest first -- backs
  /// the Stats screen's Activities/Sleep trend charts.
  Future<List<Map<String, Object?>>> loadHealthHistory({required int userId, int days = 30}) async {
    final db = await _database;
    return db.query('health_snapshots', where: 'user_id = ?', whereArgs: [userId], orderBy: 'day DESC', limit: days);
  }

  /// Wipes [userId]'s sessions/health/achievements/challenges (and the
  /// device-wide favorites/reminders/app_meta) -- backs Settings > Master
  /// Reset. Callers are responsible for reloading any in-memory stores
  /// afterwards. Deliberately leaves `users` alone: master reset clears app
  /// data, not accounts ("Account stays", per the confirmation screen's copy).
  Future<void> resetAll({required int userId}) async {
    final db = await _database;
    final batch = db.batch();
    for (final table in ['sessions', 'health_snapshots', 'achievements', 'regular_challenge_state', 'custom_challenges']) {
      batch.delete(table, where: 'user_id = ?', whereArgs: [userId]);
    }
    for (final table in ['favorites', 'app_meta', 'reminders']) {
      batch.delete(table);
    }
    await batch.commit(noResult: true);
  }

  // ---- reminders: user-scheduled notifications (see NotificationService) ----

  Future<List<Map<String, Object?>>> loadReminders() async {
    final db = await _database;
    return db.query('reminders', orderBy: 'hour, minute');
  }

  Future<int> insertReminder({required String title, required String body, required int hour, required int minute, bool enabled = true}) async {
    final db = await _database;
    return db.insert('reminders', {
      'title': title,
      'body': body,
      'hour': hour,
      'minute': minute,
      'enabled': enabled ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> setReminderEnabled(int id, bool enabled) async {
    final db = await _database;
    await db.update('reminders', {'enabled': enabled ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteReminder(int id) async {
    final db = await _database;
    await db.delete('reminders', where: 'id = ?', whereArgs: [id]);
  }

  // ---- users: local accounts backing Sign Up / Sign In ----

  Future<int> countUsers() async {
    final db = await _database;
    return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM users')) ?? 0;
  }

  Future<bool> usernameOrEmailTaken(String username, String email) async {
    final db = await _database;
    final rows = await db.query(
      'users',
      columns: ['id'],
      where: 'lower(username) = ? OR lower(email) = ?',
      whereArgs: [username.toLowerCase(), email.toLowerCase()],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<Map<String, Object?>?> findUserByUsernameOrEmail(String usernameOrEmail) async {
    final db = await _database;
    final rows = await db.query(
      'users',
      where: 'lower(username) = ? OR lower(email) = ?',
      whereArgs: [usernameOrEmail.toLowerCase(), usernameOrEmail.toLowerCase()],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Looks up an account by its row id -- used to restore the signed-in
  /// user's real profile on a cold app start (see ProfileStore.load()).
  Future<Map<String, Object?>?> findUserById(int id) async {
    final db = await _database;
    final rows = await db.query('users', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Inserts a new account. [row] must already have a hashed password under
  /// `password_hash` -- this layer never sees plaintext.
  Future<int> insertUser(Map<String, Object?> row) async {
    final db = await _database;
    return db.insert('users', row);
  }

  /// Updates an existing account's profile fields (never touches
  /// `password_hash`; callers may include `email` since Personal Details
  /// lets the user change it). Returns false instead of throwing if the
  /// new email collides with another account's unique constraint.
  Future<bool> updateUser(int id, Map<String, Object?> row) async {
    final db = await _database;
    try {
      final count = await db.update('users', row, where: 'id = ?', whereArgs: [id]);
      return count > 0;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) return false;
      rethrow;
    }
  }

  // ---- achievements: permanent record of when each was first earned ----

  Future<Set<String>> loadEarnedAchievementIds({required int userId}) async {
    final db = await _database;
    final rows = await db.query('achievements', columns: ['achievement_id'], where: 'user_id = ?', whereArgs: [userId]);
    return rows.map((r) => r['achievement_id'] as String).toSet();
  }

  /// No-ops (via [ConflictAlgorithm.ignore]) if already earned -- earning is
  /// permanent and the original `earned_at` must never be overwritten.
  Future<void> insertEarnedAchievement(String achievementId, int earnedAt, {required int userId}) async {
    final db = await _database;
    await db.insert(
      'achievements',
      {'user_id': userId, 'achievement_id': achievementId, 'earned_at': earnedAt},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ---- regular_challenge_state: user-togglable Active/Inactive/Dropped state ----
  // for the built-in challenges computed live by ChallengeEngine. Absence of a
  // row means the default (active).

  Future<Map<String, String>> loadRegularChallengeStates({required int userId}) async {
    final db = await _database;
    final rows = await db.query('regular_challenge_state', where: 'user_id = ?', whereArgs: [userId]);
    return {for (final r in rows) r['challenge_id'] as String: r['state'] as String};
  }

  Future<void> setRegularChallengeState(String challengeId, String state, {required int userId}) async {
    final db = await _database;
    await db.insert(
      'regular_challenge_state',
      {'user_id': userId, 'challenge_id': challengeId, 'state': state},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---- custom_challenges: fully user-authored, no automatic derivation ----

  Future<List<Map<String, Object?>>> loadCustomChallenges({required int userId}) async {
    final db = await _database;
    return db.query('custom_challenges', where: 'user_id = ?', whereArgs: [userId], orderBy: 'created_at DESC');
  }

  Future<void> insertCustomChallenge(Map<String, Object?> row, {required int userId}) async {
    final db = await _database;
    await db.insert('custom_challenges', {...row, 'user_id': userId}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Batched sibling of [insertCustomChallenge] -- used by DemoSeeder to
  /// avoid one round trip per demo challenge.
  Future<void> insertCustomChallenges(List<Map<String, Object?>> rows, {required int userId}) async {
    final db = await _database;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('custom_challenges', {...row, 'user_id': userId}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateCustomChallenge(String id, Map<String, Object?> row, {required int userId}) async {
    final db = await _database;
    await db.update('custom_challenges', row, where: 'id = ? AND user_id = ?', whereArgs: [id, userId]);
  }

  Future<void> deleteCustomChallenge(String id, {required int userId}) async {
    final db = await _database;
    await db.delete('custom_challenges', where: 'id = ? AND user_id = ?', whereArgs: [id, userId]);
  }

  // ---- workout plans ----

  /// Exercises the user added to a plan, keyed by plan id -- layered on top
  /// of that plan's base `exercises` list by the caller (built-in plans
  /// have a base list from kWorkoutPlans; custom plans start empty).
  Future<Map<String, List<String>>> loadPlanExercises({required int userId}) async {
    final db = await _database;
    final rows = await db.query('plan_exercises', where: 'user_id = ?', whereArgs: [userId], orderBy: 'added_at ASC');
    final map = <String, List<String>>{};
    for (final row in rows) {
      (map[row['plan_id'] as String] ??= []).add(row['exercise_id'] as String);
    }
    return map;
  }

  /// Replaces the full exercise-list override for a plan -- not a delta, so
  /// this is also how a removal/reorder from the edit-plan flow round-trips.
  Future<void> setPlanExercises(String planId, List<String> exerciseIds, {required int userId}) async {
    final db = await _database;
    final batch = db.batch();
    batch.delete('plan_exercises', where: 'user_id = ? AND plan_id = ?', whereArgs: [userId, planId]);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < exerciseIds.length; i++) {
      batch.insert('plan_exercises', {'user_id': userId, 'plan_id': planId, 'exercise_id': exerciseIds[i], 'added_at': now + i});
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, Object?>>> loadCustomPlans({required int userId}) async {
    final db = await _database;
    return db.query('custom_plans', where: 'user_id = ?', whereArgs: [userId], orderBy: 'created_at DESC');
  }

  Future<void> insertCustomPlan(Map<String, Object?> row, {required int userId}) async {
    final db = await _database;
    await db.insert('custom_plans', {...row, 'user_id': userId}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
