/// A single exercise's outcome within a completed workout, port of the
/// `exercises: [{id,name,sets,reps,status}]` shape saved by
/// screen-workout.jsx's WorkoutInProgress.
class SessionExercise {
  final String id;
  final String name;
  final int sets;
  final int reps;
  final String status; // "done" | "skipped" | "todo"

  const SessionExercise({
    required this.id,
    required this.name,
    required this.sets,
    required this.reps,
    required this.status,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sets': sets,
        'reps': reps,
        'status': status,
      };

  factory SessionExercise.fromJson(Map<String, dynamic> json) => SessionExercise(
        id: json['id'] as String,
        name: json['name'] as String,
        sets: json['sets'] as int,
        reps: json['reps'] as int,
        status: json['status'] as String,
      );
}

/// A recorded session persisted to the device -- either a completed workout
/// (screen-workout.jsx) or a logged free-form activity (screen-record.jsx).
/// Union type mirroring the shape of objects pushed into the web app's
/// `sessions` array (localStorage key mhealth.sessions.v1).
class RecordedSession {
  final String kind; // "workout" | "activity"
  final int savedAt; // epoch millis

  // Workout fields
  final String? planId;
  final String? planName;
  final int? completed;
  final int? total;
  final List<SessionExercise>? exercises;
  final List<String>? tags;

  // Activity fields
  final String? type; // walk/run/bike/swim/strength/yoga/free
  final int? hr;
  final double? distanceKm;
  final int? steps;
  final String? pace;
  final int? sets;
  final int? feel; // 1..5

  // Shared
  final int elapsed; // seconds
  final int kcal;
  final String? notes;

  const RecordedSession({
    required this.kind,
    required this.savedAt,
    required this.elapsed,
    required this.kcal,
    this.planId,
    this.planName,
    this.completed,
    this.total,
    this.exercises,
    this.tags,
    this.type,
    this.hr,
    this.distanceKm,
    this.steps,
    this.pace,
    this.sets,
    this.feel,
    this.notes,
  });

  DateTime get savedAtDate => DateTime.fromMillisecondsSinceEpoch(savedAt);

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'savedAt': savedAt,
        'elapsed': elapsed,
        'kcal': kcal,
        'planId': planId,
        'planName': planName,
        'completed': completed,
        'total': total,
        'exercises': exercises?.map((e) => e.toJson()).toList(),
        'tags': tags,
        'type': type,
        'hr': hr,
        'distanceKm': distanceKm,
        'steps': steps,
        'pace': pace,
        'sets': sets,
        'feel': feel,
        'notes': notes,
      };

  factory RecordedSession.fromJson(Map<String, dynamic> json) => RecordedSession(
        kind: json['kind'] as String,
        savedAt: json['savedAt'] as int,
        elapsed: json['elapsed'] as int,
        kcal: json['kcal'] as int,
        planId: json['planId'] as String?,
        planName: json['planName'] as String?,
        completed: json['completed'] as int?,
        total: json['total'] as int?,
        exercises: (json['exercises'] as List?)
            ?.map((e) => SessionExercise.fromJson(e as Map<String, dynamic>))
            .toList(),
        tags: (json['tags'] as List?)?.cast<String>(),
        type: json['type'] as String?,
        hr: json['hr'] as int?,
        distanceKm: (json['distanceKm'] as num?)?.toDouble(),
        steps: json['steps'] as int?,
        pace: json['pace'] as String?,
        sets: json['sets'] as int?,
        feel: json['feel'] as int?,
        notes: json['notes'] as String?,
      );
}
