import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../models/note.dart';
import '../providers/note_provider.dart';
import '../services/background_service.dart';
import '../utils/date_formatter.dart';
import 'editor_screen.dart';
import 'welcome_screen.dart';

/// Home screen styled after the iPhone Notes app: large bold header, search
/// field, note list and a bottom action bar with the note count and the compose
/// button.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CupertinoThemeData get _theme => CupertinoTheme.of(context);

  Color _resolveColor(Color color) =>
      CupertinoDynamicColor.resolve(color, context);

  /// Notepad illustration bundled through the `lib/assets/` pubspec entry.
  static const String _emptyStateAsset = 'lib/assets/note.webp';

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  /// True while the manual cloud sync is in flight: the button swaps its icon
  /// for a spinner, and a second tap is ignored (the write can wait up to the
  /// service timeout when the device is offline).
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final NoteProvider provider = context.read<NoteProvider>();
      // The profile is loaded first: its device id generation adds a write and
      // a notify, so starting the notes read before it finished made the
      // startup cloud mirror race itself.
      provider.loadProfile().whenComplete(() {
        if (!mounted) {
          return;
        }
        provider.loadNotes();
        _maybeShowWelcome();
      });
    });
  }

  /// Shows the one-time mobile number setup on first launch. Runs once the
  /// profile row is in memory; skipped on later launches because the stored
  /// number is already there.
  Future<void> _maybeShowWelcome() async {
    final NoteProvider provider = context.read<NoteProvider>();
    // The profile read above already finished, but keep the guard: the sheet
    // must never appear before the identity is known.
    if (!provider.isProfileLoaded || provider.hasProfile) {
      return;
    }
    await Navigator.of(context).push(
      CupertinoPageRoute<bool>(
        fullscreenDialog: true,
        builder: (BuildContext context) => const WelcomeScreen(),
      ),
    );
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
      backgroundColor: _theme.scaffoldBackgroundColor,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'Notes',
              style: _theme.textTheme.navLargeTitleTextStyle.copyWith(
                letterSpacing: -0.8,
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
  ///
  /// While the whole notebook is on screen the rows live in a
  /// [SliverReorderableList], so any row can be grabbed by its handle and
  /// dropped somewhere else; the new order is written back through
  /// [NoteProvider.reorderNotes]. During a search the very same rows are
  /// rendered by a plain [SliverList] instead: the drag indices address the
  /// unfiltered list, and "where does this note belong inside a filtered
  /// subset" has no answer a user could predict.
  Widget _buildNotesList() {
    final NoteProvider provider = context.watch<NoteProvider>();
    final List<Note> notes = provider.notes;
    final bool isReorderable = provider.searchQuery.isEmpty;

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
        else if (isReorderable)
          SliverReorderableList(
            itemCount: notes.length,
            onReorderItem: provider.reorderNotes,
            proxyDecorator: _buildDragProxy,
            itemBuilder: (BuildContext context, int index) =>
                _buildNoteRow(notes[index], reorderIndex: index),
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
  /// iOS Notes list.
  ///
  /// Long pressing opens the native context menu; the trailing handle only
  /// appears when [reorderIndex] is set (the unfiltered, reorderable list) and
  /// starts a drag. The outer [Column] carries a [ValueKey] on the note id,
  /// which is what lets [SliverReorderableList] follow a row while it moves.
  Widget _buildNoteRow(Note note, {int? reorderIndex}) {
    final bool isReorderable = reorderIndex != null;
    final String updatedAtLabel =
        DateFormatter.formatRelativeFromStorage(note.updatedAt);

    final Color secondaryLabelColor =
        _resolveColor(CupertinoColors.secondaryLabel);
    final Color separatorColor = _resolveColor(CupertinoColors.separator);

    Widget row = Container(
      color: _theme.scaffoldBackgroundColor,
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openEditor(noteId: note.id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 11, 0, 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      note.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _theme.textTheme.textStyle.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: <Widget>[
                        Text(
                          updatedAtLabel,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: secondaryLabelColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            note.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: secondaryLabelColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isReorderable)
            _buildDragHandle(reorderIndex)
          else
            const SizedBox(width: 20),
        ],
      ),
    );

    final List<CupertinoContextMenuAction> actions =
        _buildContextMenuActions(note);
    if (actions.isNotEmpty) {
      row = CupertinoContextMenu(actions: actions, child: row);
    }

    return Column(
      key: ValueKey<int?>(note.id),
      children: <Widget>[
        row,
        Container(
          height: 0.5,
          margin: const EdgeInsets.only(left: 20),
          color: separatorColor,
        ),
      ],
    );
  }

  /// The grab affordance that starts a reorder drag.
  ///
  /// A dedicated handle instead of the whole row is deliberate: the row's long
  /// press already belongs to [CupertinoContextMenu], and
  /// [ReorderableDragStartListener] needs a pointer-down surface of its own
  /// that a tap can never mistake for "open this note". 44x44 is the minimum
  /// touch target iOS asks for.
  Widget _buildDragHandle(int index) {
    return ReorderableDragStartListener(
      index: index,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(
            CupertinoIcons.line_horizontal_3,
            size: 18,
            color: _resolveColor(CupertinoColors.tertiaryLabel),
          ),
        ),
      ),
    );
  }

  /// Lifts the dragged row off the page with the soft shadow iOS shows while an
  /// item is being moved.
  Widget _buildDragProxy(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (BuildContext context, Widget? inner) {
        final double lift = Curves.easeInOut.transform(animation.value);
        return Transform.scale(
          scale: 1 + (lift * 0.03),
          child: Container(
            decoration: BoxDecoration(
              color: CupertinoTheme.of(context).scaffoldBackgroundColor,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: const Color(0x33000000),
                  blurRadius: 12 * lift,
                  offset: Offset(0, 5 * lift),
                ),
              ],
            ),
            child: inner,
          ),
        );
      },
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
      decoration: BoxDecoration(
        color: _theme.barBackgroundColor,
        border: Border(
          top: BorderSide(
            color: _resolveColor(CupertinoColors.separator),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          Text(
            '$count ${count == 1 ? 'Note' : 'Notes'}',
            style: TextStyle(
              fontSize: 13,
              color: _resolveColor(CupertinoColors.secondaryLabel),
            ),
          ),
          const Spacer(),
          CupertinoButton(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            onPressed: _syncToFirebase,
            child: _isSyncing
                ? const CupertinoActivityIndicator(radius: 9)
                : Icon(
                    CupertinoIcons.cloud_upload,
                    size: 22,
                    color: _resolveColor(CupertinoColors.secondaryLabel),
                  ),
          ),
          CupertinoButton(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            onPressed: () => _openEditor(),
            child: Icon(
              CupertinoIcons.square_pencil,
              size: 25,
              color: _theme.primaryColor,
            ),
          ),
        ],
      ),
    );
  }

  /// Uploads every record to Firebase Realtime Database and reports the result.
  ///
  /// Notes are mirrored automatically after each save/delete/reorder; this
  /// button exists for the first push (after fixing the Realtime Database rules,
  /// say) and to verify from the phone that the cloud copy is up to date.
  Future<void> _syncToFirebase() async {
    if (_isSyncing) {
      return;
    }
    final NoteProvider provider = context.read<NoteProvider>();
    setState(() => _isSyncing = true);

    int? pushed;
    try {
      pushed = await provider.syncNotesToFirebase();
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }

    if (!mounted) {
      return;
    }

    await showCupertinoDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => CupertinoAlertDialog(
        title: const Text('Firebase'),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            pushed == null
                ? 'The notes could not be uploaded. Check the Realtime '
                    'Database rules and the connection.'
                : '$pushed ${pushed == 1 ? 'note' : 'notes'} saved to "notes/".',
          ),
        ),
        actions: <Widget>[
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// "No Notes" / "No Results" placeholder.
  Widget _buildEmptyState(NoteProvider provider) {
    final String query = provider.searchQuery;
    final Color secondaryLabelColor =
        _resolveColor(CupertinoColors.secondaryLabel);
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
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: secondaryLabelColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              query.isEmpty
                  ? 'Tap the compose button to write one.'
                  : 'No note matches "$query".',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: secondaryLabelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
