import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_config.dart';
import 'models.dart';

class GenerationSubmitResult {
  const GenerationSubmitResult({
    required this.jobId,
    required this.statusLabel,
    required this.estimatedCredits,
    required this.chargedCredits,
    required this.downloads,
  });

  final String jobId;
  final String statusLabel;
  final int estimatedCredits;
  final int chargedCredits;
  final List<String> downloads;
}

class MagicHourService {
  static const List<ModelOption> videoModels = <ModelOption>[
    ModelOption(
      id: 'ltx-2.3',
      label: 'LTX-2.3',
      creditsPerSecond: 30,
      durations: <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20],
      resolutions: <String>['480p', '720p', '1080p'],
      supportsAudio: true,
    ),
    ModelOption(
      id: 'wan-2.2',
      label: 'WAN 2.2',
      creditsPerSecond: 35,
      durations: <int>[3, 4, 5, 6, 7, 8, 9, 10, 15],
      resolutions: <String>['480p', '720p', '1080p'],
      supportsAudio: false,
    ),
  ];

  static const List<ModelOption> imageModels = <ModelOption>[
    ModelOption(
      id: 'nano-banana-2',
      label: 'Nano Banana 2',
      creditsPerImage: 100,
      imageCounts: <int>[1, 4, 9, 16],
      resolutions: <String>['640px', '1k', '2k', '4k'],
    ),
    ModelOption(
      id: 'z-image-turbo',
      label: 'Z-Image Turbo',
      creditsPerImage: 5,
      imageCounts: <int>[1, 2, 3, 4],
      resolutions: <String>['640px', '1k', '2k'],
    ),
    ModelOption(
      id: 'seedream-v4',
      label: 'Seedream 4',
      creditsPerImage: 40,
      imageCounts: <int>[1, 2, 3, 4],
      resolutions: <String>['640px', '1k', '2k', '4k'],
    ),
  ];

  final http.Client _client;

  MagicHourService({http.Client? client}) : _client = client ?? http.Client();

  void dispose() => _client.close();

  Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer ${AppConfig.magicHourApiToken}',
        'Content-Type': 'application/json',
      };

  Future<GenerationSubmitResult> createImageJob({
    required String prompt,
    required String modelId,
    required String resolution,
    required int imageCount,
  }) async {
    final Uri uri = Uri.parse('${AppConfig.magicHourBaseUrl}/ai-image-generator');
    final ModelOption model = imageModels.firstWhere(
      (ModelOption item) => item.id == modelId,
      orElse: () => imageModels.first,
    );

    final Map<String, dynamic> payload = <String, dynamic>{
      'image_count': imageCount,
      'name': 'OleksandrAi Flow image',
      'model': modelId,
      'resolution': resolution,
      'aspect_ratio': '1:1',
      'style': <String, dynamic>{
        'prompt': prompt.trim(),
        'tool': 'general',
      },
    };

    final http.Response response = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode(payload),
    );

    final Map<String, dynamic> data = _decodeJson(response);
    _throwIfFailed(response, data);

    return GenerationSubmitResult(
      jobId: (data['id'] ?? '').toString(),
      statusLabel: (data['status'] ?? 'submitted').toString(),
      estimatedCredits: (data['estimated_credits'] as num?)?.round() ?? model.creditsPerImage * imageCount,
      chargedCredits: (data['credits_charged'] as num?)?.round() ?? 0,
      downloads: _extractDownloads(data),
    );
  }

  Future<GenerationSubmitResult> createVideoJob({
    required String prompt,
    required String modelId,
    required int durationSeconds,
    required String resolution,
    required bool audio,
  }) async {
    final Uri uri = Uri.parse('${AppConfig.magicHourBaseUrl}/text-to-video');
    final ModelOption model = videoModels.firstWhere(
      (ModelOption item) => item.id == modelId,
      orElse: () => videoModels.first,
    );

    final String apiModel = _normalizeVideoApiModel(modelId);
    final Map<String, dynamic> payload = <String, dynamic>{
      'end_seconds': durationSeconds,
      'name': 'OleksandrAi Flow video',
      'model': apiModel,
      'resolution': resolution,
      'aspect_ratio': '16:9',
      'audio': audio && model.supportsAudio,
      'style': <String, dynamic>{'prompt': prompt.trim()},
    };

    final http.Response response = await _client.post(
      uri,
      headers: _headers,
      body: jsonEncode(payload),
    );

    final Map<String, dynamic> data = _decodeJson(response);
    _throwIfFailed(response, data);

    return GenerationSubmitResult(
      jobId: (data['id'] ?? '').toString(),
      statusLabel: (data['status'] ?? 'submitted').toString(),
      estimatedCredits: (data['estimated_credits'] as num?)?.round() ?? (model.creditsPerSecond * durationSeconds),
      chargedCredits: (data['credits_charged'] as num?)?.round() ?? 0,
      downloads: _extractDownloads(data),
    );
  }

  Future<JobUpdate> pollJob({
    required GenerationKind kind,
    required String jobId,
    required int fallbackProgress,
  }) async {
    final String endpoint =
        kind == GenerationKind.image ? '/image-projects/$jobId' : '/video-projects/$jobId';
    final Uri uri = Uri.parse('${AppConfig.magicHourBaseUrl}$endpoint');
    final http.Response response = await _client.get(uri, headers: _headers);
    final Map<String, dynamic> data = _decodeJson(response);
    _throwIfFailed(response, data);

    final List<String> downloads = _extractDownloads(data);
    final String status = (data['status'] ?? 'processing').toString();
    final int chargedCredits = (data['credits_charged'] as num?)?.round() ?? 0;
    final String errorText = (data['error'] ?? data['message'] ?? '').toString();
    final JobState state = _mapState(status: status, downloads: downloads, errorText: errorText);
    final int progress = _resolveProgress(
      state: state,
      status: status,
      fallbackProgress: fallbackProgress,
      data: data,
      hasDownloads: downloads.isNotEmpty,
    );

    return JobUpdate(
      state: state,
      statusLabel: status,
      progress: progress,
      downloads: downloads,
      chargedCredits: chargedCredits,
      errorText: errorText,
    );
  }

  String _normalizeVideoApiModel(String modelId) {
    if (modelId == 'ltx-2.3') return 'ltx-2';
    return modelId;
  }

  JobState _mapState({
    required String status,
    required List<String> downloads,
    required String errorText,
  }) {
    final String normalized = status.trim().toLowerCase();
    const Set<String> done = <String>{
      'complete',
      'completed',
      'done',
      'success',
      'succeeded',
      'rendered',
    };
    const Set<String> running = <String>{
      'queued',
      'rendering',
      'submitted',
      'processing',
      'pending',
      'in_progress',
    };
    const Set<String> failed = <String>{'error', 'failed', 'rejected', 'canceled', 'cancelled'};

    if (downloads.isNotEmpty || done.contains(normalized)) return JobState.completed;
    if (failed.contains(normalized) || errorText.isNotEmpty) return JobState.failed;
    if (running.contains(normalized)) {
      if (normalized == 'submitted' || normalized == 'queued') return JobState.submitted;
      return JobState.running;
    }
    return JobState.running;
  }

  int _resolveProgress({
    required JobState state,
    required String status,
    required int fallbackProgress,
    required Map<String, dynamic> data,
    required bool hasDownloads,
  }) {
    if (state == JobState.completed || hasDownloads) return 100;
    if (state == JobState.failed) return fallbackProgress.clamp(0, 99);

    final num? rawProgress = data['progress'] as num?;
    if (rawProgress != null) {
      final int value = rawProgress.round();
      if (value >= 1 && value <= 99) return value;
    }

    final String normalized = status.toLowerCase();
    if (normalized == 'submitted' || normalized == 'queued') {
      return (fallbackProgress < 8 ? 8 : fallbackProgress).clamp(1, 95);
    }
    return (fallbackProgress + 6).clamp(12, 95);
  }

  List<String> _extractDownloads(Map<String, dynamic> data) {
    final List<String> links = <String>[];
    void append(dynamic node) {
      if (node == null) return;
      if (node is String && node.startsWith('http')) {
        links.add(node);
        return;
      }
      if (node is Map<String, dynamic>) {
        for (final String key in <String>['url', 'download_url', 'file_url', 'path']) {
          final dynamic value = node[key];
          if (value is String && value.startsWith('http')) links.add(value);
        }
      }
      if (node is List) {
        for (final dynamic item in node) {
          append(item);
        }
      }
    }

    append(data['downloads']);
    append(data['outputs']);
    append(data['items']);
    append(data['result']);

    return links.toSet().toList();
  }

  Map<String, dynamic> _decodeJson(http.Response response) {
    if (response.body.isEmpty) return <String, dynamic>{};
    final dynamic decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  }

  void _throwIfFailed(http.Response response, Map<String, dynamic> data) {
    if (response.statusCode < 200 || response.statusCode > 299) {
      final String message = (data['message'] ?? data['error'] ?? data['detail'] ?? 'API error').toString();
      throw Exception('Magic Hour: $message (${response.statusCode})');
    }
  }
}
