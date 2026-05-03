import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gallery_saver_plus/gallery_saver.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import 'magic_hour_service.dart';
import 'models.dart';

void main() {
  runApp(const OleksandrAiFlowApp());
}

class OleksandrAiFlowApp extends StatelessWidget {
  const OleksandrAiFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OleksandrAi Flow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7CF1AF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF06070B),
        useMaterial3: true,
      ),
      home: const StudioPage(),
    );
  }
}

enum _MobileScreen { home, project }

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});

  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  static const Map<String, double> _resolutionMultiplier = <String, double>{
    '480p': 0.65,
    '720p': 1.0,
    '1080p': 1.6,
    '640px': 0.7,
    '1k': 1.0,
    '2k': 1.45,
    '4k': 2.0,
  };

  final MagicHourService _service = MagicHourService();
  final TextEditingController _promptController = TextEditingController();
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const <String>['email', 'profile', 'openid'],
    // Client ID is configured in Google Cloud OAuth settings.
    serverClientId:
        '1034187669203-7ssee2rn0ldvhv1c6q7pmrkckj9evvd6.apps.googleusercontent.com',
  );

  final List<GenerationJob> _jobs = <GenerationJob>[];

  Timer? _pollTimer;
  Timer? _elapsedTimer;

  bool _isVideoMode = true;
  bool _isSubmitting = false;
  bool _videoAudio = true;

  String _videoModelId = MagicHourService.videoModels.first.id;
  String _videoResolution = '720p';
  int _videoDuration = 5;

  String _imageModelId = 'nano-banana-2';
  String _imageResolution = '1k';
  int _imageCount = 1;
  String _assetSearch = '';
  _MobileScreen _mobileScreen = _MobileScreen.home;

  GoogleSignInAccount? _account;
  String _infoText = '';

  @override
  void initState() {
    super.initState();
    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) {
      if (!mounted) return;
      setState(() {
        _account = account;
      });
    });
    unawaited(_googleSignIn.signInSilently());

    _pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _pollRunningJobs(),
    );
    _elapsedTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickElapsed(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _elapsedTimer?.cancel();
    _promptController.dispose();
    _service.dispose();
    super.dispose();
  }

  ModelOption get _videoModel => MagicHourService.videoModels.firstWhere(
    (ModelOption item) => item.id == _videoModelId,
    orElse: () => MagicHourService.videoModels.first,
  );

  ModelOption get _imageModel => MagicHourService.imageModels.firstWhere(
    (ModelOption item) => item.id == _imageModelId,
    orElse: () => MagicHourService.imageModels.first,
  );

  int get _estimatedCredits {
    if (_isVideoMode) {
      final double multiplier = _resolutionMultiplier[_videoResolution] ?? 1.0;
      final double base =
          _videoModel.creditsPerSecond * _videoDuration * multiplier;
      return base.ceil();
    }
    final double multiplier = _resolutionMultiplier[_imageResolution] ?? 1.0;
    final double base = _imageModel.creditsPerImage * _imageCount * multiplier;
    return base.ceil();
  }

  Future<void> _signIn() async {
    try {
      setState(() {
        _infoText = '';
      });
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      if (account == null) {
        setState(() {
          _infoText = 'Sign-in was cancelled.';
        });
      }
    } catch (error) {
      setState(() {
        _infoText = 'Google login failed. Check OAuth client + SHA1. $error';
      });
    }
  }

  Future<void> _signOut() async {
    await _googleSignIn.disconnect();
    if (!mounted) return;
    setState(() {
      _account = null;
      _infoText = 'Signed out.';
    });
  }

  Future<bool> _ensureAuthenticated() async {
    if (_account != null) return true;
    await _signIn();
    return _account != null;
  }

  Future<void> _submitGeneration() async {
    final String prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      setState(() {
        _infoText = 'Enter a prompt first.';
      });
      return;
    }
    if (_isSubmitting) return;

    final bool isSignedIn = await _ensureAuthenticated();
    if (!isSignedIn) return;

    setState(() {
      _isSubmitting = true;
      _infoText = '';
    });

    try {
      GenerationSubmitResult result;
      GenerationKind kind;
      ModelOption model;

      if (_isVideoMode) {
        model = _videoModel;
        kind = GenerationKind.video;
        result = await _service.createVideoJob(
          prompt: prompt,
          modelId: _videoModelId,
          durationSeconds: _videoDuration,
          resolution: _videoResolution,
          audio: _videoAudio && model.supportsAudio,
        );
      } else {
        model = _imageModel;
        kind = GenerationKind.image;
        result = await _service.createImageJob(
          prompt: prompt,
          modelId: _imageModelId,
          resolution: _imageResolution,
          imageCount: _imageCount,
        );
      }

      final GenerationJob newJob = GenerationJob(
        id: result.jobId,
        kind: kind,
        prompt: prompt,
        modelId: model.id,
        modelLabel: model.label,
        createdAt: DateTime.now(),
        state: _statusToState(result.statusLabel, result.downloads),
        statusLabel: result.statusLabel,
        progress: result.downloads.isNotEmpty ? 100 : 6,
        estimatedCredits: result.estimatedCredits,
        chargedCredits: result.chargedCredits,
        downloads: result.downloads,
        errorText: '',
      );

      if (!mounted) return;
      setState(() {
        _jobs.insert(0, newJob);
        _infoText = 'Job submitted: ${newJob.modelLabel}';
        _mobileScreen = _MobileScreen.project;
      });
    } catch (error) {
      setState(() {
        _infoText = '$error';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
      });
    }
  }

  JobState _statusToState(String status, List<String> downloads) {
    final String normalized = status.toLowerCase();
    if (downloads.isNotEmpty ||
        normalized == 'complete' ||
        normalized == 'completed' ||
        normalized == 'done' ||
        normalized == 'success' ||
        normalized == 'succeeded') {
      return JobState.completed;
    }
    if (normalized == 'failed' ||
        normalized == 'error' ||
        normalized == 'rejected') {
      return JobState.failed;
    }
    if (normalized == 'submitted' || normalized == 'queued') {
      return JobState.submitted;
    }
    return JobState.running;
  }

  Future<void> _pollRunningJobs() async {
    final List<GenerationJob> running = _jobs
        .where((GenerationJob job) => job.isRunning)
        .toList();
    if (running.isEmpty) return;

    final List<GenerationJob> updated = List<GenerationJob>.from(_jobs);
    bool changed = false;

    for (final GenerationJob job in running) {
      try {
        final JobUpdate update = await _service.pollJob(
          kind: job.kind,
          jobId: job.id,
          fallbackProgress: job.progress,
        );
        final int index = updated.indexWhere(
          (GenerationJob item) => item.id == job.id,
        );
        if (index == -1) continue;
        updated[index] = updated[index].copyWith(
          state: update.state,
          statusLabel: update.statusLabel,
          progress: update.progress,
          chargedCredits: update.chargedCredits > 0
              ? update.chargedCredits
              : updated[index].chargedCredits,
          downloads: update.downloads.isNotEmpty
              ? update.downloads
              : updated[index].downloads,
          errorText: update.errorText,
        );
        changed = true;
      } catch (error) {
        final int index = updated.indexWhere(
          (GenerationJob item) => item.id == job.id,
        );
        if (index == -1) continue;
        updated[index] = updated[index].copyWith(
          state: JobState.failed,
          statusLabel: 'failed',
          errorText: '$error',
        );
        changed = true;
      }
    }

    if (!mounted || !changed) return;
    setState(() {
      _jobs
        ..clear()
        ..addAll(updated);
    });
  }

  void _tickElapsed() {
    bool changed = false;
    final List<GenerationJob> updated = _jobs.map((GenerationJob job) {
      if (!job.isRunning) return job;
      changed = true;
      return job.copyWith(elapsedSeconds: job.elapsedSeconds + 1);
    }).toList();
    if (!changed || !mounted) return;
    setState(() {
      _jobs
        ..clear()
        ..addAll(updated);
    });
  }

  List<_GeneratedAsset> get _assets {
    final List<_GeneratedAsset> assets = <_GeneratedAsset>[];
    for (final GenerationJob job in _jobs) {
      for (final String url in job.downloads) {
        assets.add(_GeneratedAsset(job: job, url: url));
      }
    }
    return assets;
  }

  List<_GeneratedAsset> _filteredAssets(List<_GeneratedAsset> assets) {
    final String query = _assetSearch.trim().toLowerCase();
    if (query.isEmpty) return assets;
    return assets.where((_GeneratedAsset asset) {
      final String haystack = '${asset.job.prompt} ${asset.job.modelLabel}'
          .toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  Future<void> _openAsset(_GeneratedAsset asset) async {
    if (asset.job.kind == GenerationKind.image) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return Dialog(
            insetPadding: const EdgeInsets.all(12),
            child: Stack(
              children: <Widget>[
                InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4,
                  child: Image.network(asset.url, fit: BoxFit.contain),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          );
        },
      );
      return;
    }

    final Uri uri = Uri.parse(asset.url);
    final bool launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      setState(() {
        _infoText = 'Cannot open video URL.';
      });
    }
  }

  Future<void> _saveAssetToDevice(_GeneratedAsset asset) async {
    try {
      final bool? saved = asset.job.kind == GenerationKind.image
          ? await GallerySaver.saveImage(
              asset.url,
              albumName: 'OleksandrAi Flow',
            )
          : await GallerySaver.saveVideo(
              asset.url,
              albumName: 'OleksandrAi Flow',
            );
      if (!mounted) return;
      setState(() {
        _infoText = saved == true
            ? 'Saved to device gallery.'
            : 'Could not save to gallery.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _infoText = 'Save failed: $error';
      });
    }
  }

  String _elapsedLabel(GenerationJob job) {
    final int sec = job.elapsedSeconds;
    final int min = sec ~/ 60;
    final int rem = sec % 60;
    return min > 0 ? '${min}m ${rem}s' : '${rem}s';
  }

  @override
  Widget build(BuildContext context) {
    final List<_GeneratedAsset> assets = _filteredAssets(_assets);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool desktop = constraints.maxWidth >= 1060;
            return Column(
              children: <Widget>[
                _buildTopBar(compact: !desktop),
                const Divider(height: 1, color: Color(0xFF1A1E2D)),
                Expanded(
                  child: desktop
                      ? Row(
                          children: <Widget>[
                            Expanded(
                              flex: 3,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  children: <Widget>[
                                    _buildComposerCard(compact: false),
                                    const SizedBox(height: 16),
                                    Expanded(child: _buildWorkspace(assets)),
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  0,
                                  16,
                                  16,
                                  16,
                                ),
                                child: _buildQueuePanel(),
                              ),
                            ),
                          ],
                        )
                      : _buildMobileLayout(assets),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMobileLayout(List<_GeneratedAsset> assets) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      child: _mobileScreen == _MobileScreen.home
          ? _buildMobileHome(assets)
          : _buildMobileProject(assets),
    );
  }

  Widget _buildMobileHome(List<_GeneratedAsset> assets) {
    return SingleChildScrollView(
      key: const ValueKey<String>('mobile-home'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF2B3650)),
              gradient: const LinearGradient(
                colors: <Color>[Color(0xFF0F1A30), Color(0xFF132A45)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            padding: const EdgeInsets.all(16),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'OleksandrAi Flow',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 8),
                Text(
                  'Create image and video projects from one mobile workspace.',
                  style: TextStyle(color: Color(0xFFC0CAE6), height: 1.25),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: FilledButton.icon(
              onPressed: () =>
                  setState(() => _mobileScreen = _MobileScreen.project),
              style: FilledButton.styleFrom(
                minimumSize: const Size(220, 56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('New project'),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Project history',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          if (_jobs.isEmpty)
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF29314A)),
                color: const Color(0xFF101625),
              ),
              padding: const EdgeInsets.all(14),
              child: const Text(
                'No generated projects yet. Create your first shot.',
              ),
            )
          else
            ..._jobs.map(_buildJobTile),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildMobileProject(List<_GeneratedAsset> assets) {
    return SingleChildScrollView(
      key: const ValueKey<String>('mobile-project'),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          TextField(
            onChanged: (String value) => setState(() => _assetSearch = value),
            decoration: InputDecoration(
              hintText: 'Search generated materials',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildComposerCard(compact: true),
          const SizedBox(height: 12),
          _buildWorkspace(assets, compact: true),
          const SizedBox(height: 12),
          _buildQueuePanel(compact: true),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildTopBar({required bool compact}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/app_logo.png',
              width: 34,
              height: 34,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'OleksandrAi Flow',
              style: TextStyle(
                fontSize: compact ? 20 : 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (compact) ...<Widget>[
            _buildTopNavButton(
              icon: Icons.home_rounded,
              active: _mobileScreen == _MobileScreen.home,
              tooltip: 'Home',
              onTap: () => setState(() => _mobileScreen = _MobileScreen.home),
            ),
            const SizedBox(width: 6),
            _buildTopNavButton(
              icon: Icons.grid_view_rounded,
              active: _mobileScreen == _MobileScreen.project,
              tooltip: 'Project',
              onTap: () =>
                  setState(() => _mobileScreen = _MobileScreen.project),
            ),
            const SizedBox(width: 10),
          ],
          if (_account != null) ...<Widget>[
            CircleAvatar(
              radius: 16,
              backgroundImage: _account!.photoUrl != null
                  ? NetworkImage(_account!.photoUrl!)
                  : null,
              child: _account!.photoUrl == null
                  ? const Icon(Icons.person, size: 17)
                  : null,
            ),
            const SizedBox(width: 8),
            if (!compact)
              TextButton(onPressed: _signOut, child: const Text('Sign out'))
            else
              IconButton(
                tooltip: 'Sign out',
                onPressed: _signOut,
                icon: const Icon(Icons.logout, size: 18),
              ),
          ] else
            FilledButton.icon(
              onPressed: _signIn,
              icon: const Icon(Icons.login, size: 18),
              label: Text(compact ? 'Login' : 'Google login'),
            ),
        ],
      ),
    );
  }

  Widget _buildTopNavButton({
    required IconData icon,
    required bool active,
    required String tooltip,
    required void Function() onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? const Color(0xFF7CF1AF) : const Color(0xFF2E3852),
            ),
            color: active ? const Color(0xFF172C26) : const Color(0xFF101725),
          ),
          child: Icon(
            icon,
            size: 19,
            color: active ? const Color(0xFF7CF1AF) : const Color(0xFFCCD7F1),
          ),
        ),
      ),
    );
  }

  Widget _buildComposerCard({required bool compact}) {
    final String modeLabel = _isVideoMode
        ? 'Video ${_videoDuration}s'
        : 'Image ${_imageCount}x';
    final IconData modeIcon = _isVideoMode
        ? Icons.videocam_outlined
        : Icons.image_outlined;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF243049)),
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF0E1320), Color(0xFF141A27)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ToggleButtons(
            borderRadius: BorderRadius.circular(12),
            constraints: BoxConstraints(
              minHeight: compact ? 38 : 40,
              minWidth: compact ? 88 : 96,
            ),
            isSelected: <bool>[_isVideoMode, !_isVideoMode],
            onPressed: (int index) {
              setState(() {
                _isVideoMode = index == 0;
              });
            },
            children: const <Widget>[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.videocam_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Video'),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.image_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Image'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            minLines: compact ? 2 : 3,
            maxLines: compact ? 3 : 4,
            decoration: const InputDecoration(
              labelText: 'Prompt',
              hintText: 'Describe what you want to generate',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_isVideoMode) ...<Widget>[_buildVideoSettings()] else ...<Widget>[
            _buildImageSettings(),
          ],
          const SizedBox(height: 12),
          if (false)
            Row(
              children: <Widget>[
                Expanded(
                  child: Container(
                    height: compact ? 50 : 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFF33405E)),
                      color: const Color(0xFF11192A),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _isSubmitting
                          ? 'Submitting...'
                          : 'Generate • ${_estimatedCredits.toString()} credits',
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          if (false)
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: compact ? 50 : 54,
                height: compact ? 50 : 54,
                child: FilledButton(
                  onPressed: _isSubmitting ? null : _submitGeneration,
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded, size: 24),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Container(
                  height: compact ? 50 : 54,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF33405E)),
                    color: const Color(0xFF11192A),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: <Widget>[
                      Icon(modeIcon, size: 18, color: const Color(0xFFD8E1F7)),
                      const SizedBox(width: 8),
                      Text(
                        modeLabel,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFE3EBFF),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _isSubmitting
                            ? 'Submitting...'
                            : '${_estimatedCredits.toString()} credits',
                        style: const TextStyle(
                          color: Color(0xFF9FB0D4),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: compact ? 50 : 54,
                height: compact ? 50 : 54,
                child: FilledButton(
                  onPressed: _isSubmitting ? null : _submitGeneration,
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded, size: 24),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _isVideoMode
                ? 'Video credits depend on model, seconds and resolution.'
                : 'Image credits depend on model, count and resolution.',
            style: const TextStyle(color: Color(0xFF8D9AB7), fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            _account == null
                ? 'When you press send, Google login is required.'
                : 'Logged as ${_account!.email}',
            style: const TextStyle(color: Color(0xFF9AA6C2), fontSize: 12.5),
          ),
          if (_infoText.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _infoText,
              style: TextStyle(
                color:
                    _infoText.toLowerCase().contains('failed') ||
                        _infoText.toLowerCase().contains('error')
                    ? Colors.redAccent
                    : const Color(0xFFC7D3EF),
                fontSize: 12.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideoSettings() {
    final ModelOption model = _videoModel;
    final List<int> durations = model.durations;
    final List<String> resolutions = model.resolutions;
    final bool narrow = MediaQuery.sizeOf(context).width < 760;
    if (!durations.contains(_videoDuration)) {
      _videoDuration = durations.isEmpty ? 5 : durations.first;
    }
    if (!resolutions.contains(_videoResolution) && resolutions.isNotEmpty) {
      _videoResolution = resolutions.first;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (narrow)
          Column(
            children: <Widget>[
              DropdownButtonFormField<String>(
                value: _videoModelId,
                decoration: const InputDecoration(labelText: 'Video model'),
                items: MagicHourService.videoModels
                    .map(
                      (ModelOption model) => DropdownMenuItem<String>(
                        value: model.id,
                        child: Text(model.label),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value == null) return;
                  setState(() {
                    _videoModelId = value;
                  });
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: _videoResolution,
                decoration: const InputDecoration(labelText: 'Resolution'),
                items: resolutions
                    .map(
                      (String value) => DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) {
                  if (value == null) return;
                  setState(() {
                    _videoResolution = value;
                  });
                },
              ),
            ],
          )
        else
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _videoModelId,
                  decoration: const InputDecoration(labelText: 'Video model'),
                  items: MagicHourService.videoModels
                      .map(
                        (ModelOption model) => DropdownMenuItem<String>(
                          value: model.id,
                          child: Text(model.label),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) {
                    if (value == null) return;
                    setState(() {
                      _videoModelId = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _videoResolution,
                  decoration: const InputDecoration(labelText: 'Resolution'),
                  items: resolutions
                      .map(
                        (String value) => DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) {
                    if (value == null) return;
                    setState(() {
                      _videoResolution = value;
                    });
                  },
                ),
              ),
            ],
          ),
        const SizedBox(height: 10),
        Text(
          'Rate: ~${model.creditsPerSecond} / sec',
          style: const TextStyle(color: Color(0xFF99A7C7), fontSize: 12.5),
        ),
        const SizedBox(height: 6),
        Text(
          'Duration: ${_videoDuration}s',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Slider(
          min: durations.isEmpty ? 1 : durations.first.toDouble(),
          max: durations.isEmpty ? 20 : durations.last.toDouble(),
          divisions: durations.isEmpty ? 19 : durations.last - durations.first,
          label: '${_videoDuration}s',
          value: _videoDuration.toDouble(),
          onChanged: (double value) {
            final int rounded = value.round();
            int nearest = rounded;
            if (durations.isNotEmpty) {
              nearest = durations.reduce((int a, int b) {
                return (a - rounded).abs() <= (b - rounded).abs() ? a : b;
              });
            }
            setState(() {
              _videoDuration = nearest;
            });
          },
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: durations.map((int sec) {
            final bool active = _videoDuration == sec;
            return ChoiceChip(
              label: Text('${sec}s'),
              selected: active,
              onSelected: (_) => setState(() => _videoDuration = sec),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Audio'),
          subtitle: Text(
            model.supportsAudio
                ? 'Include generated audio track'
                : 'Not supported by this model',
          ),
          value: _videoAudio && model.supportsAudio,
          onChanged: model.supportsAudio
              ? (bool value) => setState(() => _videoAudio = value)
              : null,
        ),
      ],
    );
  }

  Widget _buildImageSettings() {
    final ModelOption model = _imageModel;
    final List<String> resolutions = model.resolutions;
    final List<int> counts = model.imageCounts;
    final bool narrow = MediaQuery.sizeOf(context).width < 760;
    if (!resolutions.contains(_imageResolution) && resolutions.isNotEmpty) {
      _imageResolution = resolutions.first;
    }
    if (!counts.contains(_imageCount) && counts.isNotEmpty) {
      _imageCount = counts.first;
    }

    final List<Widget> controls = <Widget>[
      DropdownButtonFormField<String>(
        value: _imageModelId,
        decoration: const InputDecoration(labelText: 'Image model'),
        items: MagicHourService.imageModels
            .map(
              (ModelOption model) => DropdownMenuItem<String>(
                value: model.id,
                child: Text(model.label),
              ),
            )
            .toList(),
        onChanged: (String? value) {
          if (value == null) return;
          setState(() => _imageModelId = value);
        },
      ),
      DropdownButtonFormField<String>(
        value: _imageResolution,
        decoration: const InputDecoration(labelText: 'Resolution'),
        items: resolutions
            .map(
              (String value) =>
                  DropdownMenuItem<String>(value: value, child: Text(value)),
            )
            .toList(),
        onChanged: (String? value) {
          if (value == null) return;
          setState(() => _imageResolution = value);
        },
      ),
      DropdownButtonFormField<int>(
        value: _imageCount,
        decoration: const InputDecoration(labelText: 'Count'),
        items: counts
            .map(
              (int value) => DropdownMenuItem<int>(
                value: value,
                child: Text(value.toString()),
              ),
            )
            .toList(),
        onChanged: (int? value) {
          if (value == null) return;
          setState(() => _imageCount = value);
        },
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (narrow) ...<Widget>[
          controls[0],
          const SizedBox(height: 10),
          controls[1],
          const SizedBox(height: 10),
          controls[2],
        ] else
          Row(
            children: <Widget>[
              Expanded(child: controls[0]),
              const SizedBox(width: 12),
              Expanded(child: controls[1]),
              const SizedBox(width: 12),
              SizedBox(width: 140, child: controls[2]),
            ],
          ),
        const SizedBox(height: 8),
        Text(
          'Rate: ~${model.creditsPerImage} / image',
          style: const TextStyle(color: Color(0xFF99A7C7), fontSize: 12.5),
        ),
      ],
    );
  }

  Widget _buildWorkspace(List<_GeneratedAsset> assets, {bool compact = false}) {
    final int crossAxisCount = compact ? 1 : 2;
    final double childAspectRatio = compact ? 1.38 : 1.22;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27324D)),
        color: const Color(0xFF0B0F18),
      ),
      child: assets.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.auto_awesome,
                    size: 66,
                    color: Color(0xFFCCD7F1),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Start generating to see previews here',
                    style: TextStyle(
                      fontSize: compact ? 16 : 18,
                      color: const Color(0xFF9AA6C2),
                    ),
                  ),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: GridView.builder(
                shrinkWrap: compact,
                physics: compact
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                itemCount: assets.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: childAspectRatio,
                ),
                itemBuilder: (BuildContext context, int index) {
                  final _GeneratedAsset asset = assets[index];
                  return _buildAssetCard(asset);
                },
              ),
            ),
    );
  }

  Widget _buildAssetCard(_GeneratedAsset asset) {
    final bool image = asset.job.kind == GenerationKind.image;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF313B57)),
        color: const Color(0xFF121824),
      ),
      child: InkWell(
        onTap: () => _openAsset(asset),
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(13),
                ),
                child: image
                    ? Image.network(
                        asset.url,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      )
                    : Container(
                        width: double.infinity,
                        color: const Color(0xFF0B111B),
                        child: const Icon(
                          Icons.movie_creation_outlined,
                          size: 54,
                          color: Color(0xFFD3DEFA),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      asset.job.modelLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _saveAssetToDevice(asset),
                    icon: const Icon(Icons.download_rounded),
                    tooltip: 'Save to device',
                    iconSize: 20,
                  ),
                  IconButton(
                    onPressed: () => _openAsset(asset),
                    icon: Icon(image ? Icons.open_in_full : Icons.open_in_new),
                    tooltip: image ? 'Fullscreen' : 'Open',
                    iconSize: 20,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueuePanel({bool compact = false}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF27324D)),
        color: const Color(0xFF0E131E),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.queue_play_next, size: 20),
              const SizedBox(width: 8),
              Text(
                'Render queue (${_jobs.length})',
                style: TextStyle(
                  fontSize: compact ? 16 : 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (_jobs.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _jobs.clear()),
                  child: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (compact)
            _jobs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Text(
                        'No jobs yet',
                        style: TextStyle(color: Color(0xFF9AA6C2)),
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _jobs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final GenerationJob job = _jobs[index];
                      return _buildJobTile(job);
                    },
                  )
          else
            Expanded(
              child: _jobs.isEmpty
                  ? const Center(
                      child: Text(
                        'No jobs yet',
                        style: TextStyle(color: Color(0xFF9AA6C2)),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _jobs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (BuildContext context, int index) {
                        final GenerationJob job = _jobs[index];
                        return _buildJobTile(job);
                      },
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildJobTile(GenerationJob job) {
    final Color statusColor;
    switch (job.state) {
      case JobState.completed:
        statusColor = const Color(0xFF96F279);
        break;
      case JobState.failed:
        statusColor = Colors.redAccent;
        break;
      case JobState.submitted:
      case JobState.running:
        statusColor = const Color(0xFFA5B4FF);
        break;
    }

    final String subtitle =
        '${job.prompt}\n${job.progress}% • ${_elapsedLabel(job)} • est ${job.estimatedCredits} • charged ${job.chargedCredits}';

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333E5A)),
        color: const Color(0xFF171E2C),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                job.kind == GenerationKind.image
                    ? Icons.image_outlined
                    : Icons.videocam_outlined,
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  job.modelLabel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                job.statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFFC0CAE6),
              height: 1.25,
            ),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: job.progress / 100,
            minHeight: 6,
            borderRadius: BorderRadius.circular(999),
          ),
          if (job.errorText.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              job.errorText,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
          if (job.downloads.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton.icon(
                  onPressed: () => _saveAssetToDevice(
                    _GeneratedAsset(job: job, url: job.downloads.first),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('Save'),
                ),
                TextButton.icon(
                  onPressed: () => _openAsset(
                    _GeneratedAsset(job: job, url: job.downloads.first),
                  ),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GeneratedAsset {
  const _GeneratedAsset({required this.job, required this.url});

  final GenerationJob job;
  final String url;
}
