import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../data/delivery_api.dart';
import '../delivery_providers.dart';
import '../domain/delivery_status.dart';
import 'delivery_format.dart';

/// Completes the delivery with the recipient's one-time code. The code is
/// checked by the backend only; the app never knows the right answer.
class VerifyDeliveryScreen extends ConsumerStatefulWidget {
  const VerifyDeliveryScreen({super.key});

  @override
  ConsumerState<VerifyDeliveryScreen> createState() =>
      _VerifyDeliveryScreenState();
}

class _VerifyDeliveryScreenState extends ConsumerState<VerifyDeliveryScreen> {
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    // A stale error from an earlier attempt shouldn't greet the partner.
    Future.microtask(() {
      if (mounted) ref.read(activeDeliveryProvider.notifier).clearActionError();
    });
  }

  @override
  void dispose() {
    // Don't keep the code around longer than the screen.
    _code
      ..clear()
      ..dispose();
    super.dispose();
  }

  Future<void> _submit(int length) async {
    final code = _code.text.trim();
    if (code.length != length) return;
    final done = await ref
        .read(activeDeliveryProvider.notifier)
        .completeWithOtp(code);
    if (!mounted) return;
    if (done) {
      Navigator.of(context).pop();
    } else {
      final error = ref.read(activeDeliveryProvider).actionError;
      if (error?.code == DeliveryErrorCode.invalidOtp) _code.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final status = StatusColors.of(context);
    final state = ref.watch(activeDeliveryProvider);
    final delivery = state.delivery;
    final mock = ref.watch(mockDeliveryApiProvider);

    // The delivery moved on (completed elsewhere, cancelled): nothing to do.
    if (delivery == null || delivery.status != DeliveryStatus.atDropoff) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text('This delivery no longer needs a code.'),
        ),
      );
    }

    final length = delivery.verification.otpLength;
    final busy = state.pendingAction != null;
    final error = state.actionError;
    final locked = error?.code == DeliveryErrorCode.otpLocked;
    final demoCode = mock?.debugOtp(delivery.id);

    return Scaffold(
      appBar: AppBar(title: const Text('Delivery code')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text(
              'Ask ${delivery.dropoff.name} for the $length-digit code',
              style: text.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'It was sent to their phone when the order was placed. The '
              'delivery is complete only once the code is accepted.',
              style: text.bodyLarge?.copyWith(color: status.muted),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _code,
              enabled: !busy && !locked,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: length,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofillHints: const [AutofillHints.oneTimeCode],
              enableSuggestions: false,
              autocorrect: false,
              style: text.headlineMedium?.copyWith(
                fontSize: 34,
                letterSpacing: 14,
              ),
              decoration: InputDecoration(
                counterText: '',
                hintText: '•' * length,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(length),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                errorMessage(error),
                style: text.bodyMedium?.copyWith(color: status.failed),
              ),
            ],
            if (demoCode != null) ...[
              const SizedBox(height: 16),
              Text(
                'Demo mode: the recipient\'s code is $demoCode.',
                style: text.bodySmall,
              ),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: busy || locked || _code.text.length != length
                  ? null
                  : () => _submit(length),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
              child: busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Complete delivery'),
            ),
          ],
        ),
      ),
    );
  }
}
