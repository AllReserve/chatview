import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef DownloadProgress = void Function(int received, int? total); // bytes
typedef DebugLogger = void Function(String message);

enum SaveDirectory {
  appDocuments,
  appSupport,
  appCache,
  externalAppDirs,
}

class DownloadOptions {
  final Map<String, String> headers;
  final int retries;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Duration sendTimeout;
  final bool probeWithHead;
  final SaveDirectory saveDirectory;
  final String? subDirectory; // e.g., "voice_messages"
  final String? fileName; // base name; ext is inferred
  final bool enableResume; // try HTTP Range resume if .part exists

  const DownloadOptions({
    this.headers = const {},
    this.retries = 2,
    this.connectTimeout = const Duration(seconds: 12),
    this.receiveTimeout = const Duration(seconds: 180),
    this.sendTimeout = const Duration(seconds: 180),
    this.probeWithHead = false,
    this.saveDirectory = SaveDirectory.appDocuments,
    this.subDirectory,
    this.fileName,
    this.enableResume = true,
  });

  DownloadOptions copyWith({
    Map<String, String>? headers,
    int? retries,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    bool? probeWithHead,
    SaveDirectory? saveDirectory,
    String? subDirectory,
    String? fileName,
    bool? enableResume,
  }) {
    return DownloadOptions(
      headers: headers ?? this.headers,
      retries: retries ?? this.retries,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      probeWithHead: probeWithHead ?? this.probeWithHead,
      saveDirectory: saveDirectory ?? this.saveDirectory,
      subDirectory: subDirectory ?? this.subDirectory,
      fileName: fileName ?? this.fileName,
      enableResume: enableResume ?? this.enableResume,
    );
  }
}

class GenericFileDownloader {
  GenericFileDownloader._();

  static Future<DownloadTask> createTask({
    required String url,
    DownloadOptions options = const DownloadOptions(),
    DownloadProgress? onProgress,
    DebugLogger? onDebug,
  }) async {
    if (url.trim().isEmpty) {
      throw ArgumentError('URL cannot be empty.');
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: options.connectTimeout,
        receiveTimeout: options.receiveTimeout,
        sendTimeout: options.sendTimeout,
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (s) => true,
        headers: <String, String>{
          'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept': '*/*',
          ...options.headers,
        },
      ),
    );

    final Directory baseDir = await _resolveBaseDir(options.saveDirectory);
    final Directory targetDir = await _prepareTargetDir(
      baseDir: baseDir,
      sub: options.subDirectory,
    );

    // Probe headers to decide filename/extension without full download
    final probe = await _probeForMeta(
      dio: dio,
      url: url,
      useHead: options.probeWithHead,
      onDebug: onDebug,
    );

    final baseName = _sanitizeBaseName(
      options.fileName ?? _basenameWithoutExt(_safeLastPath(url)),
    );

    final ext = _chooseExtension(
      urlPath: probe.urlPath,
      contentType: probe.contentType,
    );

    final savePath = await _uniquePath(
      dir: targetDir,
      base: probe.filenameFromDisposition != null
          ? _sanitizeBaseName(
              _basenameWithoutExt(probe.filenameFromDisposition!))
          : baseName,
      ext: ext,
    );

    final task = DownloadTask._(
      dio: dio,
      url: url,
      finalPath: savePath,
      onProgress: onProgress,
      onDebug: onDebug,
      retries: options.retries,
      enableResume: options.enableResume,
      headers: options.headers,
    );

    return task;
  }

  // Internal helpers below

  static Future<Directory> _resolveBaseDir(SaveDirectory sd) async {
    switch (sd) {
      case SaveDirectory.appDocuments:
        return getApplicationDocumentsDirectory();
      case SaveDirectory.appSupport:
        return getApplicationSupportDirectory();
      case SaveDirectory.appCache:
        return getTemporaryDirectory();
      case SaveDirectory.externalAppDirs:
        final dirs = await getExternalStorageDirectories();
        if (dirs != null && dirs.isNotEmpty) return dirs.first;
        return getApplicationDocumentsDirectory();
    }
  }

  static Future<Directory> _prepareTargetDir({
    required Directory baseDir,
    String? sub,
  }) async {
    final dir = sub != null && sub.trim().isNotEmpty
        ? Directory(p.join(baseDir.path, sub))
        : baseDir;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<String> _uniquePath({
    required Directory dir,
    required String base,
    required String ext,
  }) async {
    String candidate = '$base$ext';
    String path = p.join(dir.path, candidate);
    int counter = 1;
    while (await File(path).exists()) {
      candidate = '$base($counter)$ext';
      path = p.join(dir.path, candidate);
      counter++;
    }
    return path;
  }

  static String _basenameWithoutExt(String pathLike) {
    final base = p.basename(pathLike);
    final dot = base.lastIndexOf('.');
    if (dot > 0) return base.substring(0, dot);
    return base;
  }

  static String _safeLastPath(String url) {
    try {
      final uri = Uri.parse(url);
      final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'file';
      return '/$last';
    } catch (_) {
      return '/file';
    }
  }

  static Future<_ProbeResult> _probeForMeta({
    required Dio dio,
    required String url,
    required bool useHead,
    DebugLogger? onDebug,
  }) async {
    String pathFromUrl = _safeLastPath(url);
    String? contentType;
    String? filenameFromDisposition;

    Future<Response> doHead() => dio.head(
          url,
          options: Options(responseType: ResponseType.plain),
        );
    Future<Response<ResponseBody>> doRangeGet() => dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=0-0'},
          ),
        );

    Response? res;
    try {
      if (useHead) {
        res = await doHead();
        onDebug?.call('HEAD ${res.requestOptions.uri} -> ${res.statusCode}');
        if (res.statusCode == null || res.statusCode! >= 400) {
          final rg = await doRangeGet();
          onDebug
              ?.call('Range GET ${rg.requestOptions.uri} -> ${rg.statusCode}');
          res = rg;
        }
      } else {
        final rg = await doRangeGet();
        onDebug?.call('Range GET ${rg.requestOptions.uri} -> ${rg.statusCode}');
        res = rg;
        if (rg.statusCode == null || rg.statusCode! >= 400) {
          final hd = await doHead();
          onDebug?.call('HEAD ${hd.requestOptions.uri} -> ${hd.statusCode}');
          res = hd;
        }
      }
    } catch (e) {
      onDebug?.call('Probe error: $e');
      try {
        res = useHead ? await doRangeGet() : await doHead();
        onDebug?.call(
          'Probe fallback ${res.requestOptions.method} '
          '${res.requestOptions.uri} -> ${res.statusCode}',
        );
      } catch (e2) {
        onDebug?.call('Probe fallback failed: $e2');
        res = null;
      }
    }

    if (res != null) {
      contentType = res.headers.value('content-type');
      final cd = res.headers.value('content-disposition');
      final parsedName = _filenameFromContentDisposition(cd);
      if (parsedName != null && parsedName.trim().isNotEmpty) {
        filenameFromDisposition = parsedName.trim();
        pathFromUrl = '/$filenameFromDisposition';
      }
    }

    return _ProbeResult(
      urlPath: pathFromUrl,
      contentType: contentType,
      filenameFromDisposition: filenameFromDisposition,
    );
  }

  static String _chooseExtension({
    required String urlPath,
    String? contentType,
  }) {
    if (contentType != null) {
      final e = _extFromMime(contentType);
      if (e != null) return e;
    }
    final urlExt = p.extension(urlPath);
    if (urlExt.isNotEmpty) return urlExt.toLowerCase();

    final guess = lookupMimeType(urlPath) ?? 'application/octet-stream';
    return _extFromMime(guess) ?? '.bin';
  }

  static String? _extFromMime(String mime) {
    final m = mime.toLowerCase().split(';').first.trim();
    switch (m) {
      case 'audio/mpeg':
        return '.mp3';
      case 'audio/aac':
      case 'audio/aacp':
        return '.aac';
      case 'audio/mp4':
      case 'audio/m4a':
        return '.m4a';
      case 'audio/ogg':
        return '.ogg';
      case 'audio/opus':
        return '.opus';
      case 'audio/wav':
      case 'audio/x-wav':
      case 'audio/wave':
        return '.wav';
      case 'audio/flac':
        return '.flac';
      case 'audio/amr':
      case 'audio/3gpp':
        return '.amr';
      case 'video/mp4':
        return '.mp4';
      case 'video/webm':
        return '.webm';
      case 'video/x-matroska':
        return '.mkv';
      case 'image/jpeg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      case 'image/svg+xml':
        return '.svg';
      case 'application/pdf':
        return '.pdf';
      case 'text/plain':
        return '.txt';
      case 'text/csv':
        return '.csv';
      case 'application/json':
        return '.json';
      case 'application/zip':
        return '.zip';
      case 'application/x-7z-compressed':
        return '.7z';
      case 'application/x-rar-compressed':
      case 'application/vnd.rar':
        return '.rar';
      case 'application/gzip':
        return '.gz';
      case 'application/x-tar':
        return '.tar';
      default:
        return null;
    }
  }

  static String? _filenameFromContentDisposition(String? cd) {
    if (cd == null) return null;
    final parts = cd.split(';').map((e) => e.trim()).toList();
    for (final part in parts) {
      if (part.toLowerCase().startsWith('filename*=')) {
        final idx = part.indexOf("''");
        if (idx > 0 && idx + 2 < part.length) {
          final encoded = part.substring(idx + 2);
          try {
            return Uri.decodeComponent(encoded);
          } catch (_) {}
        }
      } else if (part.toLowerCase().startsWith('filename=')) {
        var v = part.substring('filename='.length).trim();
        if (v.startsWith('"') && v.endsWith('"')) {
          v = v.substring(1, v.length - 1);
        }
        return v;
      }
    }
    return null;
  }
}

class DownloadTask {
  final Dio dio;
  final String url;
  final String finalPath;
  final int retries;
  final bool enableResume;
  final Map<String, String> headers;
  final DownloadProgress? onProgress;
  final DebugLogger? onDebug;

  CancelToken? _cancelToken;
  bool _isPaused = false;
  bool _isRunning = false;

  DownloadTask._({
    required this.dio,
    required this.url,
    required this.finalPath,
    required this.retries,
    required this.enableResume,
    required this.headers,
    required this.onProgress,
    required this.onDebug,
  });

  String get partPath => '$finalPath.part';

  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;

  Future<File> start() async {
    if (_isRunning) return File(finalPath);
    _isRunning = true;
    _isPaused = false;
    _cancelToken = CancelToken();

    int attempt = 0;
    Object? lastErr;
    while (attempt <= retries) {
      try {
        await _downloadOnce(cancelToken: _cancelToken!);
        _isRunning = false;
        return File(finalPath);
      } catch (e) {
        if (_isPaused) {
          _isRunning = false;
          rethrow; // caller handles pause (treated as cancel)
        }
        lastErr = e;
        attempt++;
        if (attempt > retries) break;
        onDebug?.call('Retry $attempt/$retries due to: $e');
        await Future.delayed(Duration(milliseconds: 600 * attempt));
      }
    }
    _isRunning = false;
    throw Exception('Failed to download after $retries retries: $lastErr');
  }

  Future<void> pause() async {
    if (!_isRunning) return;
    _isPaused = true;
    _cancelToken?.cancel('paused');
  }

  Future<void> cancel() async {
    if (_isRunning) {
      _cancelToken?.cancel('canceled');
    }
    _isPaused = false;
    _isRunning = false;
    // Clean partial
    final part = File(partPath);
    if (await part.exists()) {
      await part.delete();
    }
  }

  Future<void> _downloadOnce({required CancelToken cancelToken}) async {
    final partFile = File(partPath);
    int existLen = 0;
    if (enableResume && await partFile.exists()) {
      existLen = await partFile.length();
      onDebug?.call('Resuming from $existLen bytes');
    } else {
      if (await partFile.exists()) {
        await partFile.delete();
      }
    }

    final sink = partFile.openWrite(mode: FileMode.append);

    try {
      final headers = <String, dynamic>{...this.headers};
      if (enableResume && existLen > 0) {
        headers['Range'] = 'bytes=$existLen-';
      }

      final res = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
        ),
        cancelToken: cancelToken,
      );

      final status = res.statusCode ?? 0;
      onDebug?.call('GET ${res.requestOptions.uri} -> $status');

      if (status == 206 || status == 200) {
        final contentLength = res.data?.contentLength;
        int received = 0;

        await for (final chunk in res.data!.stream) {
          received += chunk.length;
          sink.add(chunk);
          if (onProgress != null) {
            final total = contentLength != null
                ? existLen + contentLength
                : null; // may be null
            final soFar = existLen + received;
            onProgress?.call(soFar, total);
          }
        }

        await sink.flush();
        await sink.close();

        // If 200 after resume attempt, some servers ignore Range and re-send full.
        // If that happened and we appended to an existing part, we should
        // replace instead of append. Detect by content-range absence + existLen > 0.
        final contentRange = res.headers.value('content-range');
        if (existLen > 0 && status == 200 && contentRange == null) {
          // Server ignored range; we appended. Replace with last download only.
          // Move current .part to temp, copy last segment. Simpler: rewrite .part from scratch.
          final tmp = File('$partPath.tmp');
          await partFile.rename(tmp.path);
          // Rewrite final from tmp's last segment is complex; instead, just use tmp as whole file.
          // In practice, since we appended full content, the file is double-sized. We need to fix.
          // Safer approach: if resume attempted and got 200, discard old part before writing.
          // To ensure correctness next runs, throw to retry without resume.
          await tmp.delete();
          throw Exception(
              'Server does not support Range; retrying without resume.');
        }

        // Atomically move to final
        await partFile.rename(finalPath);
        onProgress?.call(
            await File(finalPath).length(), await File(finalPath).length());
        return;
      } else {
        final snippet = await _readSmallSnippet(res.data);
        throw Exception('HTTP $status while downloading. Snippet: $snippet');
      }
    } on DioException catch (e) {
      await sink.close();
      if (_isPaused || (e.type == DioExceptionType.cancel)) {
        // Keep .part for resume
        rethrow;
      }
      // On other network errors, keep .part for resume attempts
      final status = e.response?.statusCode;
      String? snippet;
      if (e.response?.data is ResponseBody) {
        snippet = await _readSmallSnippet(e.response!.data as ResponseBody);
      } else if (e.response?.data is String) {
        final s = e.response!.data as String;
        snippet = s.substring(0, s.length.clamp(0, 200));
      } else if (e.response?.data != null) {
        try {
          snippet = jsonEncode(e.response!.data);
        } catch (_) {
          snippet = e.response!.data.toString();
        }
      }
      final msg = StringBuffer('Network error');
      if (status != null) msg.write(' (HTTP $status)');
      if (snippet != null) msg.write(': $snippet');
      throw Exception(msg.toString());
    } catch (e) {
      await sink.close();
      rethrow;
    }
  }
}

class _ProbeResult {
  final String urlPath;
  final String? contentType;
  final String? filenameFromDisposition;

  _ProbeResult({
    required this.urlPath,
    required this.contentType,
    required this.filenameFromDisposition,
  });
}

Future<String> _readSmallSnippet(ResponseBody? body) async {
  if (body == null) return '';
  try {
    final stream = body.stream;
    final chunks = <List<int>>[];
    int total = 0;
    await for (final chunk in stream) {
      chunks.add(chunk);
      total += chunk.length;
      if (total >= 512) break;
    }
    final bytes = chunks.expand((e) => e).toList();
    final decoded = utf8.decode(bytes, allowMalformed: true);
    return decoded.substring(0, decoded.length.clamp(0, 512));
  } catch (_) {
    return '';
  }
}

String _sanitizeBaseName(String name) {
  final trimmed = name.trim();
  final sanitized = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return sanitized.isEmpty ? 'file' : sanitized;
}
