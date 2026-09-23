/// Immutable domain model for one row of the local `notes` table.
///
/// The SQLite schema is:
/// `id INTEGER PRIMARY KEY, title TEXT, content TEXT, updatedAt TEXT`
class Note {
  /// Physical SQLite table name.
  static const String tableName = 'notes';

  /// Id of the note that the background location service owns.
  ///
  /// The row is seeded once and afterwards only ever updated: the 15 minute
  /// background loop overwrites [content] and [updatedAt] and never touches the
  /// primary key, which keeps the note stable across app restarts.
  static const int fixedNoteId = 1;

  /// Title of the seeded note.
  static const String fixedNoteTitle = '📍 Live Location Tracker';

  /// Body written when the fixed note is seeded. It mirrors the shape of the
  /// payload produced by the background loop so the list preview never jumps.
  static const String fixedNotePlaceholder =
      'Last Status: Waiting for first location update\n'
      'Timestamp: --\n'
      'Latitude: --\n'
      'Longitude: --';

  /// Primary key. `null` until the row has been inserted.
  final int? id;

  /// User editable title.
  final String title;

  /// User editable body. Owned by the background service for [fixedNoteId].
  final String content;

  /// Last write timestamp, stored through `DateFormatter.formatForStorage`
  /// (`yyyy-MM-dd HH:mm:ss`) so that `ORDER BY updatedAt` stays chronological.
  final String updatedAt;

  const Note({
    this.id,
    required this.title,
    required this.content,
    required this.updatedAt,
  });

  /// True when this note is the background location tracker note.
  bool get isFixedNote => id == fixedNoteId;

  /// Title rendered by the list. Falls back to `New Note` like iOS Notes.
  String get displayTitle => title.trim().isEmpty ? 'New Note' : title.trim();

  /// One line summary of the body rendered under the title.
  String get preview {
    final List<String> lines = content
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
    return lines.isEmpty ? 'No additional text' : lines.join('  ');
  }

  /// Builds a [Note] from a SQLite row.
  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id: map['id'] as int?,
      title: (map['title'] as String?) ?? '',
      content: (map['content'] as String?) ?? '',
      updatedAt: (map['updatedAt'] as String?) ?? '',
    );
  }

  /// SQLite friendly representation. [id] is omitted while it is `null` so the
  /// database can assign the next free primary key.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      if (id != null) 'id': id,
      'title': title,
      'content': content,
      'updatedAt': updatedAt,
    };
  }

  /// Copy with the given fields replaced.
  Note copyWith({
    int? id,
    String? title,
    String? content,
    String? updatedAt,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Note &&
        other.id == id &&
        other.title == title &&
        other.content == content &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(id, title, content, updatedAt);

  @override
  String toString() => 'Note(id: $id, title: $title, updatedAt: $updatedAt)';
}
