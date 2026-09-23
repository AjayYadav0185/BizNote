import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/note_provider.dart';
import '../utils/date_formatter.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NoteProvider>().loadNotes();
  void _openEditor({int? noteId}) {
    Navigator.of(context).push(CupertinoPageRoute(
      builder: (context) => EditorScreen(noteId: noteId), fullscreenDialog: false));
  }
  void _showDeleteConfirmation(int noteId, BuildContext context) {
  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(child: SafeArea(child: Column(children: [
      _buildHeader(), _buildSearchBar(), Expanded(child: _buildNotesList()), _buildBottomBar()])));
  }
  Widget _buildHeader() {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [const SizedBox(width: 4),
        const Expanded(child: Text('Notes', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w300, letterSpacing: -0.5))),
        const SizedBox(width: 4)]));
  }
  Widget _buildSearchBar() {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: CupertinoSearchTextField(controller: _searchController, focusNode: _searchFocusNode,
        placeholder: 'Search Notes', onChanged: (value) { context.read<NoteProvider>().setSearchQuery(value); },
        onSuffixTap: () { _searchController.clear(); context.read<NoteProvider>().clearSearchQuery(); _searchFocusNode.unfocus(); },
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: CupertinoColors.systemGrey5, borderRadius: BorderRadius.circular(10))));
  }

    showCupertinoDialog(context: context, builder: (context) => CupertinoAlertDialog(
      title: const Text('Delete Note'), content: const Text('Are you sure?'),
      actions: [CupertinoDialogAction(child: const Text('Cancel'), onPressed: () => Navigator.of(context).pop()),
        CupertinoDialogAction(isDestructiveAction: true, child: const Text('Delete'),
          onPressed: () { Navigator.of(context).pop(); context.read<NoteProvider>().deleteNote(noteId); })]));
  }

    });
  }
  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  State<HomeScreen> createState() => _HomeScreenState();
}
