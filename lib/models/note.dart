import 'package:flutter/material.dart';

class Note {
  final int? id;
  final String title;
  final String content;
  final String date;

  Note({
    this.id,
    required this.title,
    required this.content,
    required this.date,
  });

  /// Creates a Note instance from a database map
  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id: map['id'] as int?,
      title: map['title'] as String,
      content: map['content'] as String,
      date: map['date'] as String,
    );
  }

  /// Converts a Note instance to a database map
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'content': content,
      'date': date,
    };
  }

  /// Creates a copy of this Note with optional new values
  Note copyWith({
    int? id,
    String? title,
    String? content,
    String? date,
  }) {
    return Note(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      date: date ?? this.date,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Note &&
        other.id == id &&
        other.title == title &&
        other.content == content &&
        other.date == date;
  }

  @override
  int get hashCode {
    return Object.hash(id, title, content, date);
  }

  @override
  String toString() {
    return 'Note(id: $id, title: $title, content: $content, date: $date)';
  }
}
