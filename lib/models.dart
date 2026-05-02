enum GenerationKind { image, video }

enum JobState { submitted, running, completed, failed }

class ModelOption {
  const ModelOption({
    required this.id,
    required this.label,
    this.creditsPerSecond = 0,
    this.creditsPerImage = 0,
    this.durations = const <int>[],
    this.resolutions = const <String>[],
    this.imageCounts = const <int>[],
    this.supportsAudio = false,
  });

  final String id;
  final String label;
  final int creditsPerSecond;
  final int creditsPerImage;
  final List<int> durations;
  final List<String> resolutions;
  final List<int> imageCounts;
  final bool supportsAudio;
}

class GenerationJob {
  const GenerationJob({
    required this.id,
    required this.kind,
    required this.prompt,
    required this.modelId,
    required this.modelLabel,
    required this.createdAt,
    required this.state,
    required this.statusLabel,
    required this.progress,
    required this.estimatedCredits,
    required this.chargedCredits,
    required this.downloads,
    required this.errorText,
    this.elapsedSeconds = 0,
  });

  final String id;
  final GenerationKind kind;
  final String prompt;
  final String modelId;
  final String modelLabel;
  final DateTime createdAt;
  final JobState state;
  final String statusLabel;
  final int progress;
  final int estimatedCredits;
  final int chargedCredits;
  final List<String> downloads;
  final String errorText;
  final int elapsedSeconds;

  bool get isRunning => state == JobState.submitted || state == JobState.running;
  bool get isDone => state == JobState.completed;

  GenerationJob copyWith({
    JobState? state,
    String? statusLabel,
    int? progress,
    int? estimatedCredits,
    int? chargedCredits,
    List<String>? downloads,
    String? errorText,
    int? elapsedSeconds,
  }) {
    return GenerationJob(
      id: id,
      kind: kind,
      prompt: prompt,
      modelId: modelId,
      modelLabel: modelLabel,
      createdAt: createdAt,
      state: state ?? this.state,
      statusLabel: statusLabel ?? this.statusLabel,
      progress: progress ?? this.progress,
      estimatedCredits: estimatedCredits ?? this.estimatedCredits,
      chargedCredits: chargedCredits ?? this.chargedCredits,
      downloads: downloads ?? this.downloads,
      errorText: errorText ?? this.errorText,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
    );
  }
}

class JobUpdate {
  const JobUpdate({
    required this.state,
    required this.statusLabel,
    required this.progress,
    required this.downloads,
    required this.chargedCredits,
    required this.errorText,
  });

  final JobState state;
  final String statusLabel;
  final int progress;
  final List<String> downloads;
  final int chargedCredits;
  final String errorText;
}

