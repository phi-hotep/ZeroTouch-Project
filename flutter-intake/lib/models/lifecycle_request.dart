/// Request model sent to the Azure Function. JSON keys (camelCase) match
/// exactly what `run.ps1` expects.
library;

enum LifecycleAction { joiner, mover, leaver }

extension LifecycleActionX on LifecycleAction {
  /// Value sent to the backend (the PowerShell router expects these exact strings).
  String get wire => switch (this) {
        LifecycleAction.joiner => 'Joiner',
        LifecycleAction.mover => 'Mover',
        LifecycleAction.leaver => 'Leaver',
      };

  /// Label shown to the user.
  String get label => switch (this) {
        LifecycleAction.joiner => 'Joiner',
        LifecycleAction.mover => 'Mover',
        LifecycleAction.leaver => 'Leaver',
      };

  String get description => switch (this) {
        LifecycleAction.joiner => 'New hire. Create the account and access',
        LifecycleAction.mover => 'Transfer. Change department',
        LifecycleAction.leaver => 'Departure. Disable and reclaim licenses',
      };
}

class LifecycleRequest {
  const LifecycleRequest({
    required this.action,
    this.firstName,
    this.lastName,
    this.department,
    this.jobTitle,
    this.personalEmail,
    this.identity,
    this.newDepartment,
    this.lastDay,
    this.removeStaleAccess = false,
  });

  final LifecycleAction action;

  // Joiner fields
  final String? firstName;
  final String? lastName;
  final String? department;
  final String? jobTitle;
  final String? personalEmail;

  // Mover / Leaver fields
  final String? identity; // work email (UPN)
  final String? newDepartment; // Mover
  final DateTime? lastDay; // Leaver

  // Mover only: also removes access from the previous department.
  // Default (false) is additive-only — old access stays in place until
  // manually or explicitly removed.
  final bool removeStaleAccess;

  Map<String, dynamic> toJson() => {
        'action': action.wire,
        if (firstName != null) 'firstName': firstName,
        if (lastName != null) 'lastName': lastName,
        if (department != null) 'department': department,
        if (jobTitle != null) 'jobTitle': jobTitle,
        if (personalEmail != null) 'personalEmail': personalEmail,
        if (identity != null) 'identity': identity,
        if (newDepartment != null) 'newDepartment': newDepartment,
        if (lastDay != null) 'lastDay': _dateOnly(lastDay!),
        // Only meaningful for Mover; only send it then to keep other actions'
        // payloads exactly as before (and as the run.ps1 field-validation expects).
        if (action == LifecycleAction.mover)
          'removeStaleAccess': removeStaleAccess,
      };

  static String _dateOnly(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
