import 'dart:io';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite/sqlite_api.dart';

import '../models/note.dart';

class DatabaseHelper {
  /// Database singleton instance
  static Database? _database;

  /// Database name and version
  static const String _databaseName = 'notepad.db';
  static const int _databaseVersion = 1;

  /// Table name for notes
  static const String _tableName = 'notes';

  /// Private constructor to prevent instantiation
  DatabaseHelper._();

  /// Singleton factory for DatabaseHelper
  static final DatabaseHelper instance = DatabaseHelper._();

  /// Getter for the database instance with lazy initialization
  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  /// Initializes the database by creating the file and tables
  Future<Database> _initDatabase() async {
    // Get the database path from the sqflite package
    final databasePath = await getDatabasesPath();
    
    // Create the full path to the database file
    final path = join(databasePath, _databaseName);

    // Open the database with creation logic
    return openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        // Enable foreign keys if needed in future
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  /// Creates the notes table when the database is first created
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        date TEXT NOT NULL
      )
    ''');
  }

  /// Handles database upgrades when the version number changes
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Handle future schema migrations here
    if (oldVersion < 2) {
      // Example migration: add new columns or tables
    }
  }

  /// Closes the database connection
  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// Inserts a new note into the database
  /// Returns the ID of the newly inserted note
  Future<int> insertNote(Note note) async {
    final db = await database;
    return await db.insert(
      _tableName,
      note.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Retrieves all notes from the database, ordered by date (newest first)
  Future<List<Note>> getNotes() async {
    final db = await database;
    
    // Query all notes ordered by date descending (newest first)
    final List<Map<String, dynamic>> maps = await db.query(
      _tableName,
      orderBy: 'date DESC',
    );

    // Convert the maps to Note objects
    return maps.map((map) => Note.fromMap(map)).toList();
  }

  /// Retrieves a single note by its ID
  Future<Note?> getNoteById(int id) async {
    final db = await database;
    
    final List<Map<String, dynamic>> maps = await db.query(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (maps.isNotEmpty) {
      return Note.fromMap(maps.first);
    }
    return null;
  }

  /// Updates an existing note in the database
  /// Returns the number of rows affected (should be 1 for success)
  Future<int> updateNote(Note note) async {
    final db = await database;
    return await db.update(
      _tableName,
      note.toMap(),
      where: 'id = ?',
      whereArgs: [note.id],
    );
  }

  /// Deletes a note from the database by its ID
  /// Returns the number of rows affected (should be 1 for success)
  Future<int> deleteNote(int id) async {
    final db = await database;
    return await db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes all notes from the database
  /// Returns the number of rows affected
  Future<int> deleteAllNotes() async {
    final db = await database;
    return await db.delete(_tableName);
  }

  /// Gets the count of all notes in the database
  Future<int> getNoteCount() async {
    final db = await database;
    final List<Map<String, dynamic>> result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_tableName',
    );
    return result.first['count'] as int;
  }

  /// Searches for notes containing the given query in title or content
  Future<List<Note>> searchNotes(String query) async {
    final db = await database;
    
    final List<Map<String, dynamic>> maps = await db.query(
      _tableName,
      where: 'title LIKE ? OR content LIKE ?',
      whereArgs: ['%$query%', '%$query%'],
      orderBy: 'date DESC',
    );

    return maps.map((map) => Note.fromMap(map)).toList();
  }

  /// Checks if the database exists
  Future<bool> databaseExists() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, _databaseName);
    return File(path).exists();
  }
}
