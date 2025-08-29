import 'dart:async';
import 'dart:io';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:chatview/chatview.dart' show Message;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_bubble.dart';
import '../models/config_models/message_reaction_configuration.dart';
import '../models/config_models/voice_message_configuration.dart';
import '../utils/downloader.dart';
import 'reaction_widget.dart';

class VoiceMessageView extends StatefulWidget {
  const VoiceMessageView({
    Key? key,
    required this.screenWidth,
    required this.message,
    required this.isMessageBySender,
    this.inComingChatBubbleConfig,
    this.outgoingChatBubbleConfig,
    this.onMaxDuration,
    this.messageReactionConfig,
    this.config,
  }) : super(key: key);

  final VoiceMessageConfiguration? config;
  final double screenWidth;
  final Message message;
  final ValueSetter<int>? onMaxDuration;
  final bool isMessageBySender;
  final MessageReactionConfiguration? messageReactionConfig;
  final ChatBubble? inComingChatBubbleConfig;
  final ChatBubble? outgoingChatBubbleConfig;

  @override
  State<VoiceMessageView> createState() => _VoiceMessageViewState();
}

class _VoiceMessageViewState extends State<VoiceMessageView> {
  late PlayerController controller;
  StreamSubscription<PlayerState>? playerStateSubscription;

  final ValueNotifier<PlayerState> _playerState =
      ValueNotifier<PlayerState>(PlayerState.stopped);

  // Download state
  DownloadTask? _task;
  final ValueNotifier<_DlState> _dlState =
      ValueNotifier<_DlState>(_DlState.idle);
  final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);
  String? _localPath;
  Object? _lastError;

  PlayerWaveStyle playerWaveStyle = const PlayerWaveStyle(scaleFactor: 70);

  @override
  void initState() {
    super.initState();
    controller = PlayerController();
    _init();
  }

  @override
  void dispose() {
    playerStateSubscription?.cancel();
    controller.dispose();
    _playerState.dispose();
    _dlState.dispose();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final msgPathOrUrl = widget.message.message;
    final isUrl = _looksLikeUrl(msgPathOrUrl);

    if (!isUrl) {
      // Must be a local file path. Validate then prepare.
      final ok = await _validateLocalAudio(msgPathOrUrl);
      if (!ok) {
        _dlState.value = _DlState.error;
        _lastError = 'Local file is missing or not a valid audio.';
        setState(() {});
        return;
      }
      _localPath = msgPathOrUrl;
      await _preparePlayer(_localPath!);
      return;
    }

    // If already downloaded file exists (e.g., from previous run), use it
    final existing = await _findExistingDownloaded(msgPathOrUrl);
    if (existing != null && await _validateLocalAudio(existing)) {
      _localPath = existing;
      await _preparePlayer(_localPath!);
      return;
    }

    // Prepare download
    _dlState.value = _DlState.ready;
    _task = await GenericFileDownloader.createTask(
      url: msgPathOrUrl,
      options: const DownloadOptions(
        subDirectory: 'voice_messages',
        enableResume: true,
      ),
      onProgress: (received, total) {
        if (total == null || total <= 0) {
          _progress.value = 0.0;
        } else {
          _progress.value = received / total;
        }
      },
      onDebug: (m) {
        // debugPrint('[voice-dl] $m'); // Uncomment to trace
      },
    );

    // Auto-start download
    await _startDownload();
  }

  Future<bool> _validateLocalAudio(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      final len = await f.length();
      if (len == 0) return false;

      // Quick MIME sniff by extension/name. If we can detect a known non-audio,
      // we reject early. If unknown, allow (iOS may still decode).
      final mime = lookupMimeType(path) ?? '';
      if (mime.isNotEmpty) {
        if (mime.startsWith('text/') ||
            mime == 'application/json' ||
            mime == 'text/html') {
          return false;
        }
      }

      // Extra guard: ensure path is local (not URL)
      if (path.startsWith('http://') || path.startsWith('https://')) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _preparePlayer(String filePath) async {
    try {
      await controller.preparePlayer(
        path: filePath,
        noOfSamples: widget.config?.playerWaveStyle
                ?.getSamplesForWidth(widget.screenWidth * 0.5) ??
            playerWaveStyle.getSamplesForWidth(widget.screenWidth * 0.5),
      );
      widget.onMaxDuration?.call(controller.maxDuration);
      playerStateSubscription?.cancel();
      playerStateSubscription = controller.onPlayerStateChanged
          .listen((state) => _playerState.value = state);
      if (mounted) setState(() {});
    } on Object catch (e) {
      // If iOS fails to decode due to unsupported codec, surface error UI
      _lastError =
          'Failed to prepare audio. File may be corrupted or codec unsupported.';
      _dlState.value = _DlState.error;
      if (mounted) setState(() {});
      debugPrint(
          'Failed to prepare audio. File may be corrupted or codec unsupported. $e');
    }
  }

  Future<void> _startDownload() async {
    if (_task == null) return;
    _lastError = null;
    _dlState.value = _DlState.downloading;
    try {
      final file = await _task!.start();
      final valid = await _validateLocalAudio(file.path);
      if (!valid) {
        // Clean up invalid file and show error
        try {
          await File(file.path).delete();
        } catch (_) {}
        _dlState.value = _DlState.error;
        _lastError = 'Downloaded file is not a valid audio.';
        return;
      }
      _localPath = file.path;
      _dlState.value = _DlState.completed;
      await _preparePlayer(_localPath!);
    } catch (e) {
      if (_task!.isPaused) {
        _dlState.value = _DlState.paused;
        return;
      }
      _lastError = e;
      _dlState.value = _DlState.error;
    }
  }

  Future<void> _pauseDownload() async {
    if (_task == null) return;
    await _task!.pause();
    _dlState.value = _DlState.paused;
  }

  Future<void> _resumeDownload() async {
    if (_task == null) return;
    await _startDownload();
  }

  Future<void> _cancelDownload() async {
    if (_task == null) return;
    await _task!.cancel();
    _progress.value = 0.0;
    _dlState.value = _DlState.ready;
  }

  bool _looksLikeUrl(String s) {
    return s.startsWith('http://') || s.startsWith('https://');
  }

  String _deriveBasename(String url) {
    try {
      final u = Uri.parse(url);
      final last = u.pathSegments.isNotEmpty ? u.pathSegments.last : 'voice';
      final name = last.isEmpty ? 'voice' : last;
      final base =
          name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      return base.isEmpty ? 'voice' : base;
    } catch (_) {
      return 'voice';
    }
  }

  Future<String?> _findExistingDownloaded(String url) async {
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(docs.path, 'voice_messages'));
    if (!await folder.exists()) return null;

    final base = _deriveBasename(url);
    final candidates =
        folder.listSync(followLinks: false).whereType<File>().where((f) {
      final bn = p.basenameWithoutExtension(f.path);
      return bn == base || bn.startsWith('$base(');
    }).toList();

    candidates
        .sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return candidates.isNotEmpty ? candidates.first.path : null;
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.isMessageBySender
        ? widget.outgoingChatBubbleConfig?.textStyle?.color
        : widget.inComingChatBubbleConfig?.textStyle?.color;

    final bubbleColor = widget.isMessageBySender
        ? widget.outgoingChatBubbleConfig?.color
        : widget.inComingChatBubbleConfig?.color;

    final decoration = widget.config?.decoration ??
        BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: bubbleColor,
        );

    final padding =
        widget.config?.padding ?? const EdgeInsets.symmetric(horizontal: 8);

    final margin = widget.config?.margin ??
        EdgeInsets.symmetric(
          horizontal: 8,
          vertical: widget.message.reaction.reactions.isNotEmpty ? 15 : 0,
        );

    final showPlayer = _localPath != null;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: decoration,
          padding: padding,
          margin: margin,
          child: showPlayer
              ? _buildPlayer(textColor)
              : _buildDownloader(textColor),
        ),
        if (widget.message.reaction.reactions.isNotEmpty)
          ReactionWidget(
            isMessageBySender: widget.isMessageBySender,
            reaction: widget.message.reaction,
            messageReactionConfig: widget.messageReactionConfig,
          ),
      ],
    );
  }

  Widget _buildPlayer(Color? textColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<PlayerState>(
          valueListenable: _playerState,
          builder: (context, state, _) {
            return IconButton(
              onPressed: _playOrPause,
              icon: state.isStopped || state.isPaused || state.isInitialised
                  ? widget.config?.playIcon ??
                      Icon(Icons.play_arrow, color: textColor)
                  : widget.config?.pauseIcon ??
                      Icon(Icons.stop, color: textColor),
            );
          },
        ),
        AudioFileWaveforms(
          size: Size(widget.screenWidth * 0.40, 60),
          playerController: controller,
          waveformType: WaveformType.fitWidth,
          playerWaveStyle: widget.config?.playerWaveStyle ?? playerWaveStyle,
          padding: widget.config?.waveformPadding ?? EdgeInsets.zero,
          margin: widget.config?.waveformMargin ?? EdgeInsets.zero,
          animationCurve: widget.config?.animationCurve ?? Curves.easeIn,
          animationDuration: widget.config?.animationDuration ??
              const Duration(milliseconds: 500),
          enableSeekGesture: widget.config?.enableSeekGesture ?? true,
        ),
        SizedBox(
          width: 60,
          child: Center(
            child: StreamBuilder<int>(
              stream: controller.onCurrentDurationChanged,
              builder: (context, snapshot) {
                final duration = snapshot.data ?? 0;
                if (duration == 0) {
                  return FutureBuilder<int>(
                    future: controller.getDuration(),
                    builder: (context, snapshot) {
                      return Text(
                        (snapshot.data?.mmss() ?? '00:00'),
                        style: TextStyle(color: textColor),
                      );
                    },
                  );
                }
                return Text(
                  (duration.mmss()),
                  style: TextStyle(color: textColor),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloader(Color? textColor) {
    return ValueListenableBuilder<_DlState>(
      valueListenable: _dlState,
      builder: (context, state, _) {
        final isDownloading = state == _DlState.downloading;
        final isPaused = state == _DlState.paused;
        final isError = state == _DlState.error;
        final isReady = state == _DlState.ready;

        return SizedBox(
          width: widget.screenWidth * 0.70,
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  isDownloading
                      ? Icons.pause_circle_filled
                      : Icons.cloud_download,
                  color: textColor,
                ),
                onPressed: () async {
                  if (isDownloading) {
                    await _pauseDownload();
                  } else {
                    await _resumeDownload();
                  }
                },
              ),
              Expanded(
                child: ValueListenableBuilder<double>(
                  valueListenable: _progress,
                  builder: (context, p, __) {
                    final showIndeterminate =
                        p <= 0.0 || p.isNaN || p.isInfinite;
                    final statusText = isError
                        ? (_lastError
                                    ?.toString()
                                    .contains('not a valid audio') ==
                                true
                            ? 'Invalid audio. Tap retry'
                            : 'Failed. Tap retry')
                        : isPaused
                            ? 'Paused'
                            : isReady
                                ? 'Ready to download'
                                : showIndeterminate
                                    ? 'Downloading...'
                                    : '${(p * 100).toStringAsFixed(0)}%';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(
                          value: showIndeterminate ? null : p.clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor:
                              (textColor ?? Colors.black).withOpacity(0.2),
                          color: textColor ?? Colors.black,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          statusText,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    );
                  },
                ),
              ),
              IconButton(
                icon: Icon(
                  isError ? Icons.refresh : Icons.cancel,
                  color: textColor,
                ),
                onPressed: () async {
                  if (isError) {
                    _dlState.value = _DlState.ready;
                    await _resumeDownload();
                  } else {
                    await _cancelDownload();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _playOrPause() {
    assert(
      defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android,
      "Voice messages are only supported with android and ios platform",
    );
    final state = _playerState.value;
    if (state.isInitialised || state.isPaused || state.isStopped) {
      controller.startPlayer();
      controller.setFinishMode(finishMode: FinishMode.pause);
    } else {
      controller.pausePlayer();
    }
  }
}

enum _DlState { idle, ready, downloading, paused, completed, error }

extension on int {
  String mmss() {
    final totalSeconds = this ~/ 1000;
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
