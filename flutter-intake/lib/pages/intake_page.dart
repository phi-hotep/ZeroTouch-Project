import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lifecycle_request.dart';
import '../providers/submission_provider.dart';
import '../services/lifecycle_api.dart';

/// Unified intake form. The action selector (Joiner / Mover / Leaver)
/// determines which fields are shown — the equivalent of section branching
/// in a Google Form.
class IntakePage extends ConsumerStatefulWidget {
  const IntakePage({super.key});

  @override
  ConsumerState<IntakePage> createState() => _IntakePageState();
}

class _IntakePageState extends ConsumerState<IntakePage> {
  final _formKey = GlobalKey<FormState>();

  LifecycleAction _action = LifecycleAction.joiner;

  // Joiner
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _jobTitle = TextEditingController();
  final _personalEmail = TextEditingController();
  String? _department;

  // Mover / Leaver
  final _identity = TextEditingController();
  String? _newDepartment;
  DateTime? _lastDay;
  bool _removeStaleAccess = false;

  static const _departments = ['Engineering', 'Sales', 'Finance'];

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _jobTitle.dispose();
    _personalEmail.dispose();
    _identity.dispose();
    super.dispose();
  }

  void _resetFieldsForAction() {
    // Clear validation errors on now-hidden fields.
    _formKey.currentState?.reset();
    _removeStaleAccess = false;
  }

  LifecycleRequest _buildRequest() {
    return switch (_action) {
      LifecycleAction.joiner => LifecycleRequest(
          action: _action,
          firstName: _firstName.text.trim(),
          lastName: _lastName.text.trim(),
          department: _department,
          jobTitle:
              _jobTitle.text.trim().isEmpty ? null : _jobTitle.text.trim(),
          personalEmail: _personalEmail.text.trim(),
        ),
      LifecycleAction.mover => LifecycleRequest(
          action: _action,
          identity: _identity.text.trim(),
          newDepartment: _newDepartment,
          removeStaleAccess: _removeStaleAccess,
        ),
      LifecycleAction.leaver => LifecycleRequest(
          action: _action,
          identity: _identity.text.trim(),
          lastDay: _lastDay,
        ),
    };
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref.read(submissionProvider.notifier).submit(_buildRequest());
  }

  @override
  Widget build(BuildContext context) {
    final submission = ref.watch(submissionProvider);
    final isLoading = submission.isLoading;

    // Show the result in a SnackBar when it arrives.
    ref.listen<AsyncValue<LifecycleResult?>>(submissionProvider, (prev, next) {
      next.whenOrNull(
        data: (result) {
          if (result == null) return;
          final color = result.ok
              ? (result.scheduled ? Colors.orange : Colors.green)
              : Theme.of(context).colorScheme.error;
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                backgroundColor: color,
                content: Text(result.message),
                duration: const Duration(seconds: 6),
              ),
            );
        },
        error: (err, _) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
              SnackBar(
                backgroundColor: Theme.of(context).colorScheme.error,
                content: Text('Error: $err'),
              ),
            );
        },
      );
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('ZeroTouch - Identity Lifecycle'),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ActionSelector(
                    selected: _action,
                    onChanged: isLoading
                        ? null
                        : (a) {
                            setState(() => _action = a);
                            _resetFieldsForAction();
                            ref.read(submissionProvider.notifier).reset();
                          },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _action.description,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  ..._fieldsForAction(),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: isLoading ? null : _submit,
                    icon: isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    label: Text(isLoading ? 'Processing…' : 'Submit'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _fieldsForAction() {
    return switch (_action) {
      LifecycleAction.joiner => [
          _text(_firstName, 'First name', required: true),
          _text(_lastName, 'Last name', required: true),
          _departmentDropdown(
            value: _department,
            label: 'Department',
            onChanged: (v) => setState(() => _department = v),
          ),
          _text(_jobTitle, 'Job title (optional)'),
          _text(
            _personalEmail,
            'Personal email',
            required: true,
            email: true,
          ),
        ],
      LifecycleAction.mover => [
          _text(
            _identity,
            'Work email (UPN)',
            required: true,
            email: true,
          ),
          _departmentDropdown(
            value: _newDepartment,
            label: 'New department',
            onChanged: (v) => setState(() => _newDepartment = v),
          ),
          _removeStaleAccessCheckbox(),
        ],
      LifecycleAction.leaver => [
          _text(
            _identity,
            'Work email (UPN)',
            required: true,
            email: true,
          ),
          _lastDayPicker(),
        ],
    };
  }

  // ── Field widgets ─────────────────────────────────────────────────────────

  Widget _text(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool email = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
        keyboardType: email ? TextInputType.emailAddress : TextInputType.text,
        validator: (value) {
          final v = value?.trim() ?? '';
          if (required && v.isEmpty) return 'This field is required';
          if (email && v.isNotEmpty && !v.contains('@')) {
            return 'Invalid email';
          }
          return null;
        },
      ),
    );
  }

  Widget _departmentDropdown({
    required String? value,
    required String label,
    required ValueChanged<String?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: _departments
            .map((d) => DropdownMenuItem(value: d, child: Text(d)))
            .toList(),
        validator: (v) => v == null ? 'This field is required' : null,
        onChanged: onChanged,
      ),
    );
  }

  /// Mover only. By default, a Mover is ADDITIVE: access to the new
  /// department is granted, but access to the previous department is kept —
  /// useful for transition periods. Checking this box also removes the
  /// previous department's access in the same operation.
  Widget _removeStaleAccessCheckbox() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CheckboxListTile(
        value: _removeStaleAccess,
        onChanged: (v) => setState(() => _removeStaleAccess = v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        title: const Text('Remove access from previous department'),
        subtitle: const Text(
          'By default, old access is kept (transition period). '
          'Check to remove it immediately.',
        ),
      ),
    );
  }

  Widget _lastDayPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Last working day',
          suffixIcon: Icon(Icons.calendar_today),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _lastDay == null
                  ? 'Today (immediate)'
                  : LifecycleRequest(action: _action, lastDay: _lastDay)
                      .toJson()['lastDay'] as String,
            ),
            TextButton(
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _lastDay ?? now,
                  firstDate: now.subtract(const Duration(days: 1)),
                  lastDate: now.add(const Duration(days: 365)),
                );
                if (picked != null) setState(() => _lastDay = picked);
              },
              child: const Text('Choose'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Segmented action selector (Joiner / Mover / Leaver).
class _ActionSelector extends StatelessWidget {
  const _ActionSelector({required this.selected, required this.onChanged});

  final LifecycleAction selected;
  final ValueChanged<LifecycleAction>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<LifecycleAction>(
      segments: LifecycleAction.values
          .map((a) => ButtonSegment(value: a, label: Text(a.label)))
          .toList(),
      selected: {selected},
      onSelectionChanged:
          onChanged == null ? null : (set) => onChanged!(set.first),
    );
  }
}
