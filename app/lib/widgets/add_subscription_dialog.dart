import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';

/// Minimal "Add subscription" form: URL and name. A stand-in for the mockup's Add sheet and
/// source form (markup/20-nodes.html `sh-add`, `sh-srcform`) until Nodes is ported; it feeds the
/// same [CoreHost.addSubscription] the full form will.
///
/// Returns once the form is closed; the fetch goes on in the background (the card shows
/// "updating", a failure arrives as a [HostNotice] `subFailed`), like the mockup.
Future<void> showAddSubscriptionDialog(BuildContext context) {
  final host = CoreHostScope.read(context);
  return showDialog<void>(
    context: context,
    builder: (_) => _AddSubscriptionDialog(host: host),
  );
}

class _AddSubscriptionDialog extends StatefulWidget {
  const _AddSubscriptionDialog({required this.host});

  final CoreHost host;

  @override
  State<_AddSubscriptionDialog> createState() => _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState extends State<_AddSubscriptionDialog> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  bool _empty = false;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _empty = true);
      return;
    }
    // not awaited: the dialog closes now, the fetch shows itself on the card
    widget.host.addSubscription(url, name: _name.text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.addSubscription),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.subscriptionUrl,
                errorText: _empty ? l10n.pasteASubscriptionUrlFirst : null,
              ),
              onChanged: (_) {
                if (_empty) setState(() => _empty = false);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: l10n.name),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.add2)),
      ],
    );
  }
}
