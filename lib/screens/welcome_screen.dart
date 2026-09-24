import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../models/device_profile.dart';
import '../providers/note_provider.dart';

/// One-time welcome setup: asks the customer for their mobile number once and
/// stores it next to the auto-generated device id.
///
/// Shown as a full-screen dialog on first launch (while [NoteProvider.hasProfile]
/// is false). Every Firebase write afterwards — `notes/<id>` and
/// `locations/latest` / `locations/history` — carries both `deviceId` and
/// `phoneNumber`, so a stored record always says which device and which
/// customer it belongs to.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final TextEditingController _phoneController = TextEditingController();
  String? _error;
  bool _isSaving = false;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final NoteProvider provider = context.read<NoteProvider>();
    final String raw = _phoneController.text;
    if (!DeviceProfile.isValidPhoneNumber(raw)) {
      setState(() {
        _error =
            'Enter a valid mobile number (${DeviceProfile.minPhoneDigits}-'
            '${DeviceProfile.maxPhoneDigits} digits, country code included).';
      });
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    final bool saved = await provider.savePhoneNumber(raw);
    if (!mounted) {
      return;
    }
    setState(() => _isSaving = false);
    if (saved) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = 'Could not save the number. Please try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final NoteProvider provider = context.watch<NoteProvider>();
    final String deviceId = provider.profile?.deviceId ?? '…';

    return CupertinoPageScaffold(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Welcome to BizNote',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Enter your mobile number once. It is saved on this device '
                'and attached to every location update sent to Firebase '
                '(every 15 minutes), together with this device id:',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 12),
              Text(
                'Device: $deviceId',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: CupertinoColors.secondaryLabel),
              ),
              const SizedBox(height: 24),
              CupertinoTextField(
                controller: _phoneController,
                placeholder: 'Mobile number, e.g. +91 98765 43210',
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                maxLength: 16,
                onSubmitted: (_) => _save(),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.destructiveRed,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              CupertinoButton.filled(
                onPressed: _isSaving ? null : _save,
                child: _isSaving
                    ? const CupertinoActivityIndicator(color: CupertinoColors.white)
                    : const Text('Save & Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
