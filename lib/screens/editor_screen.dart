import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../providers/note_provider.dart';
import '../utils/date_formatter.dart';

/// Minimalist iOS style canvas: an autofocusing title, a full height body field
/// and a top right "Done" action that commits the buffers back to SQLite.
///
/// The same buffers are committed when the user swipes back, so nothing is ever
/// lost silently.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.noteId});

  /// Existing note to edit, `null` to compose a new one.
  final int? noteId;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  static const Color _canvasColor = Color(0xFFFFFEFE);

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  final FocusNode _bodyFocusNode = FocusNode();

  late NoteProvider _provider;

  Note? _note;
  bool _initialized = false;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isDirty = false;
  bool _hasSaved = false;
  String _updatedAtLabel = '';

  @override
  void initState() {
    super.initState();
    _titleController.addListener(_markDirty);
    _bodyController.addListener(_markDirty);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = context.read<NoteProvider>();
    if (!_initialized) {
      _initialized = true;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _bodyFocusNode.dispose();
    super.dispose();
  }

  void _markDirty() {
    _isDirty = true;
  }

  /// Loads the note that is being edited (new notes start empty).
  Future<void> _load() async {
    final int? noteId = widget.noteId;
    if (noteId == null) {
      // Still inside `didChangeDependencies`, the framework is about to build
      // anyway, so no setState here (it would run during the build phase).
      _isLoading = false;
      return;
    }

    final Note? note = await _provider.getNoteById(noteId);
    if (!mounted) {
      return;
    }
    if (note == null) {
      setState(() => _isLoading = false);
      return;
    }

    _note = note;
    _titleController.text = note.title;
    _bodyController.text = note.content;
    _updatedAtLabel = DateFormatter.formatFullFromStorage(note.updatedAt);
    // Writing the controllers above fired the listeners; the buffers match the
    // database again, so the note is not dirty any more.
    _isDirty = false;

    setState(() => _isLoading = false);

    // iOS puts the cursor into the body for an existing note; a brand new note
    // starts with the title (see the `autofocus` below).
    _bodyFocusNode.requestFocus();
  }

  /// Commits title + body to the database.
  ///
  /// The commit is idempotent for the lifetime of this screen ([_hasSaved]): a
  /// new note must never be inserted twice. The text is snapshot into local
  /// variables *before* the first `await` so the save never touches the
  /// (possibly disposed) controllers after the database write completes.
  /// When [popAfterSave] is true (the "Done" button) the route is popped only
  /// after the write has finished; if the write fails the editor stays open
  /// and shows the error instead of silently dropping the note.
  Future<void> _save({bool popAfterSave = false}) async {
    if (_isSaving) {
      return;
    }
    if (_hasSaved) {
      if (popAfterSave && mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    final String title = _titleController.text.trim();
    final String body = _bodyController.text;
    final bool isNewNote = widget.noteId == null;
    final bool isEmpty = title.isEmpty && body.trim().isEmpty;

    // Never create empty notes, and never issue a pointless UPDATE.
    if ((isNewNote && isEmpty) || (!isNewNote && !_isDirty)) {
      _hasSaved = true;
      if (popAfterSave && mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    _isSaving = true;
    if (mounted) {
      setState(() {});
    }
    bool saved = false;
    try {
      final Note draft = (_note ??
              Note(title: title, content: body, updatedAt: ''))
          .copyWith(title: title, content: body);
      saved = await _provider.saveNote(draft);
    } finally {
      _isSaving = false;
    }

    if (!mounted) {
      return;
    }

    if (saved) {
      _hasSaved = true;
      _isDirty = false;
      _updatedAtLabel = DateFormatter.formatFullFromStorage(
        DateFormatter.formatForStorage(DateTime.now()),
      );
      setState(() {});
      if (popAfterSave) {
        Navigator.of(context).pop();
      }
    } else {
      setState(() {});
      if (popAfterSave) {
        await _showSaveErrorDialog();
      } else {
        debugPrint('[Editor] auto-save failed; keeping the editor open');
      }
    }
  }

  /// Informs the user that the note could not be written instead of losing it.
  Future<void> _showSaveErrorDialog() async {
    if (!mounted) {
      return;
    }
    await showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext context) => CupertinoAlertDialog(
        title: const Text('Could not save note'),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'The note could not be written to the database. '
            'Please try again.',
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      // While a save is in flight, block the pop so the write always finishes
      // before the route (and its controllers) goes away. The framework
      // re-invokes the callback once the user tries again.
      canPop: !_isSaving,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        // Back swipe / back button: persist whatever the user typed *before*
        // leaving. Awaiting the save first guarantees the new note reaches
        // SQLite before the list rebuilds.
        if (!didPop) {
          return;
        }
        if (_hasSaved || _isSaving) {
          return;
        }
        await _save();
      },
      child: _buildScaffold(),
    );
  }

  /// Nav bar with the "Done" action over a border free canvas.
  Widget _buildScaffold() {
    return CupertinoPageScaffold(
      backgroundColor: _canvasColor,
      navigationBar: CupertinoNavigationBar(
        border: null,
        backgroundColor: _canvasColor,
        previousPageTitle: 'Notes',
        trailing: CupertinoButton(
          minimumSize: Size.zero,
          padding: EdgeInsets.zero,
          onPressed: _isSaving ? null : () => _save(popAfterSave: true),
          child: Text(
            _isSaving ? 'Saving…' : 'Done',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.systemBlue,
            ),
          ),
        ),
      ),
      child: SafeArea(
        child: _isLoading
            ? const Center(child: CupertinoActivityIndicator())
            : _buildCanvas(),
      ),
    );
  }

  /// Title + body canvas. The body field expands so tapping anywhere below the
  /// title focuses it, exactly like the iPhone Notes editor.
  Widget _buildCanvas() {
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Column(
              children: <Widget>[
                CupertinoTextField(
                  controller: _titleController,
                  autofocus: widget.noteId == null,
                  padding: EdgeInsets.zero,
                  decoration: null,
                  placeholder: 'Title',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.black,
                  ),
                  placeholderStyle: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFC7C7CC),
                  ),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (String value) => _bodyFocusNode.requestFocus(),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: CupertinoTextField(
                    controller: _bodyController,
                    focusNode: _bodyFocusNode,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    padding: EdgeInsets.zero,
                    decoration: null,
                    placeholder: 'Start writing…',
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(
                      fontSize: 17,
                      height: 1.35,
                      color: CupertinoColors.black,
                    ),
                    placeholderStyle: const TextStyle(
                      fontSize: 17,
                      color: Color(0xFFC7C7CC),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_note != null) _buildFooter(),
      ],
    );
  }

  /// Footer that explains where the timestamp comes from.
  Widget _buildFooter() {
    final bool isTrackedNote = _note?.isFixedNote ?? false;
    final String label = isTrackedNote
        ? 'Refreshed every 15 minutes by the background service'
        : 'Last updated $_updatedAtLabel';

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFE5E5EA), width: 0.5),
        ),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            CupertinoIcons.time,
            size: 13,
            color: CupertinoColors.systemGrey,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
