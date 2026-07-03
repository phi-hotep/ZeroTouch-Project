import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lifecycle_request.dart';
import '../services/lifecycle_api.dart';

/// API client injection (easy to swap for a mock in tests).
final lifecycleApiProvider = Provider<LifecycleApi>((ref) => LifecycleApi());

/// Submission state: null (idle) / loading / data(result) / error.
class SubmissionNotifier extends AutoDisposeAsyncNotifier<LifecycleResult?> {
  @override
  Future<LifecycleResult?> build() async => null;

  Future<void> submit(LifecycleRequest request) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(lifecycleApiProvider).submit(request),
    );
  }

  void reset() => state = const AsyncData(null);
}

final submissionProvider =
    AutoDisposeAsyncNotifierProvider<SubmissionNotifier, LifecycleResult?>(
  SubmissionNotifier.new,
);
