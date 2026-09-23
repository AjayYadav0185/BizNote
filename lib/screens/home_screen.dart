import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../providers/note_provider.dart';
import '../services/background_service.dart';
import '../utils/date_formatter.dart';
import 'editor_screen.dart';

/// Home screen styled after the iPhone Notes app: large bold header, search
/// field, note list and a bottom action bar with the note count and the compose
/// button.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const Color _canvasColor = Color(0xFFFFFFFF);
  static const Color _barColor = Color(0xFFF9F9F9);
  static const Color _dividerColor = Color(0xFFE5E5EA);
  static const Color _dateColor = Color(0xFF8E8E93);
  static const Color _previewColor = Color(0xFF8E8E93);

  /// Notepad illustration bundled through the `lib/assets/` pubspec entry.
  static const String _emptyStateAsset = 'lib/assets/note.webp';

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.read<NoteProvider>().loadNotes();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// Opens the editor. [noteId] is `null` for a brand new note.
  void _openEditor({int? noteId}) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (BuildContext context) => EditorScreen(noteId: noteId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: _canvasColor,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _buildHeader(),
            _buildSearchField(),
            Expanded(child: _buildNotesList()),
            _buildBottomBar(context),
          ],
        ),
      ),
    );
  }

  /// Large, bold "Notes" title.
  Widget _buildHeader() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'Notes',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.8,
                color: CupertinoColors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// iOS style search bar.
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: CupertinoSearchTextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        placeholder: 'Search',
        onChanged: (String value) =>
            context.read<NoteProvider>().setSearchQuery(value),
        onSuffixTap: () {
          _searchController.clear();
          context.read<NoteProvider>().clearSearchQuery();
          _searchFocusNode.unfocus();
        },
      ),
    );
  }

  /// Scrollable list of notes (with pull to refresh).
  Widget _buildNotesList() {
    final NoteProvider provider = context.watch<NoteProvider>();
    final List<Note> notes = provider.notes;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: <Widget>[
        CupertinoSliverRefreshControl(
          onRefresh: provider.refreshFromDatabase,
        ),
        if (notes.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(provider),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (BuildContext context, int index) => _buildNoteRow(notes[index]),
              childCount: notes.length,
            ),
          ),
      ],
    );
  }

  /// One row: bold title over a grey "date · preview" line, exactly like the
  /// iOS Notes list. Long pressing opens the native context menu whenever the
  /// row has an action to offer.
  Widget _buildNoteRow(Note note) {
    Widget content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openEditor(noteId: note.id),
      child: Container(
        color: _canvasColor,
        padding: const EdgeInsets.fromLTRB(20, 11, 20, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              note.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.black,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: <Widget>[
                Text(
                  DateFormatter.formatRelativeFromStorage(note.updatedAt),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: _dateColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    note.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      color: _previewColor,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    final List<CupertinoContextMenuAction> actions =
        _buildContextMenuActions(note);
    if (actions.isNotEmpty) {
      content = CupertinoContextMenu(actions: actions, child: content);
    }

    return Column(
      children: <Widget>[
        content,
        Container(
          height: 0.5,
          margin: const EdgeInsets.only(left: 20),
          color: _dividerColor,
        ),
      ],
    );
  }

  /// Context menu shown on long press.
  ///
  /// The tracked note offers "Update Now" (asks the background isolate for an
  /// immediate fix) and "Pause Tracking"; every other note can be deleted. The
  /// tracked note keeps its menu hidden on platforms without a background
  /// service (web/desktop), where those actions do not exist.
  List<CupertinoContextMenuAction> _buildContextMenuActions(Note note) {
    if (note.isFixedNote) {
      if (!isBackgroundTrackingSupported) {
        return <CupertinoContextMenuAction>[];
      }
      return <CupertinoContextMenuAction>[
        CupertinoContextMenuAction(
          trailingIcon: CupertinoIcons.location_fill,
          onPressed: () {
            Navigator.of(context).pop();
            context.read<NoteProvider>().requestImmediateLocationUpdate();
          },
          child: const Text('Update Now'),
        ),
        CupertinoContextMenuAction(
          isDestructiveAction: true,
          trailingIcon: CupertinoIcons.pause,
          onPressed: () {
            Navigator.of(context).pop();
            context.read<NoteProvider>().pauseLocationTracking();
          },
          child: const Text('Pause Tracking'),
        ),
      ];
    }

    return <CupertinoContextMenuAction>[
      CupertinoContextMenuAction(
        isDestructiveAction: true,
        trailingIcon: CupertinoIcons.trash,
        onPressed: () {
          Navigator.of(context).pop();
          final int? noteId = note.id;
          if (noteId != null) {
            context.read<NoteProvider>().deleteNote(noteId);
          }
        },
        child: const Text('Delete'),
      ),
    ];
  }

  /// Bottom action bar: total note count on the left, compose button on the
  /// right, home indicator inset included.
  Widget _buildBottomBar(BuildContext context) {
    final int count = context.select<NoteProvider, int>(
      (NoteProvider provider) => provider.noteCount,
    );
    final double bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      height: 52 + bottomInset,
      padding: EdgeInsets.fromLTRB(20, 0, 8, bottomInset),
      decoration: const BoxDecoration(
        color: _barColor,
        border: Border(top: BorderSide(color: _dividerColor, width: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '$count ${count == 1 ? 'Note' : 'Notes'}',
            style: const TextStyle(
              fontSize: 13,
              color: CupertinoColors.systemGrey,
            ),
          ),
          const Spacer(),
          CupertinoButton(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            onPressed: () => _openEditor(),
            child: const Icon(
              CupertinoIcons.square_pencil,
              size: 25,
              color: CupertinoColors.systemBlue,
            ),
          ),
        ],
      ),
    );
  }

  /// "No Notes" / "No Results" placeholder.
  Widget _buildEmptyState(NoteProvider provider) {
    final String query = provider.searchQuery;
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 60),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Image.asset(
              _emptyStateAsset,
              width: 72,
              height: 72,
            ),
            const SizedBox(height: 14),
            Text(
              query.isEmpty ? 'No Notes' : 'No Results',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.systemGrey,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              query.isEmpty
                  ? 'Tap the compose button to write one.'
                  : 'No note matches "$query".',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                color: CupertinoColors.systemGrey,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
