import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:http/http.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _MjpegStateNotifier extends ChangeNotifier {
  bool _mounted = true;
  bool _visible = true;

  _MjpegStateNotifier() : super();

  bool get mounted => _mounted;

  bool get visible => _visible;

  set visible(value) {
    _visible = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _mounted = false;
    notifyListeners();
    super.dispose();
  }
}

/// A preprocessor for each JPEG frame from an MJPEG stream.
class MjpegPreprocessor {
  List<int>? process(List<int> frame) => frame;
}

/// An Mjpeg.
class Mjpeg extends HookWidget {
  final String stream;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final bool isLive;
  final Duration timeout;
  final Duration frameTimeout;
  final WidgetBuilder? loading;
  final Client? httpClient;
  final VoidCallback? onStreamLoaded;
  final Widget Function(BuildContext context, dynamic error, dynamic stack)?
      error;
  final Map<String, String> headers;
  final MjpegPreprocessor? preprocessor;

  const Mjpeg({
    this.httpClient,
    this.isLive = false,
    this.width,
    this.timeout = const Duration(seconds: 5),
    this.frameTimeout = const Duration(seconds: 3),
    this.height,
    this.fit,
    required this.stream,
    this.error,
    this.loading,
    this.headers = const {},
    this.preprocessor,
    this.onStreamLoaded,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final image = useState<MemoryImage?>(null);
    final state = useMemoized(() => _MjpegStateNotifier());
    final visible = useListenable(state);
    final errorState = useState<List<dynamic>?>(null);
    final isMounted = useIsMounted();

    final manager = useMemoized(
        () => _StreamManager(
              stream,
              isLive && visible.visible,
              headers,
              timeout,
              frameTimeout,
              httpClient ?? Client(),
              preprocessor ?? MjpegPreprocessor(),
              isMounted,
            ),
        [
          stream,
          isLive,
          visible.visible,
          timeout,
          frameTimeout,
          httpClient,
          preprocessor,
          isMounted
        ]);

    final key = useMemoized(() => UniqueKey(), [manager]);

    final hasCalledCallback = useState(false);

    useEffect(() {
      errorState.value = null;
      manager.updateStream(context, image, errorState);
      return manager.dispose;
    }, [manager]);

    if (errorState.value != null) {
      return SizedBox(
        width: width,
        height: height,
        child: error == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    '${errorState.value}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              )
            : error!(context, errorState.value!.first, errorState.value!.last),
      );
    }

    if (image.value == null) {
      return SizedBox(
          width: width,
          height: height,
          child: loading == null
              ? Center(
                  child: SizedBox(
                    height: 75,
                    width: 75,
                    child: CircularProgressIndicator(
                      color: Color(0xFFffc425),
                    ),
                  ),
                )
              : loading!(context));
    }

    if (image.value != null && !hasCalledCallback.value) {
      if (onStreamLoaded != null) {
        onStreamLoaded!();
      }
      hasCalledCallback.value = true;
    }

    return VisibilityDetector(
      key: key,
      child: Image(
        image: image.value!,
        width: width,
        height: height,
        gaplessPlayback: true,
        fit: fit,
      ),
      onVisibilityChanged: (VisibilityInfo info) {
        if (visible.mounted) {
          visible.visible = info.visibleFraction != 0;
        }
      },
    );
  }
}

class _StreamManager {
  static const _trigger = 0xFF;
  static const _soi = 0xD8;
  static const _eoi = 0xD9;

  final String stream;
  final bool isLive;
  final Duration _timeout;
  final Duration _frameTimeout;
  Timer? _frameTimeoutTimer;
  final Map<String, String> headers;
  final Client _httpClient;
  final MjpegPreprocessor _preprocessor;
  final bool Function() _mounted;
  // ignore: cancel_subscriptions
  StreamSubscription? _subscription;

  _StreamManager(
    this.stream,
    this.isLive,
    this.headers,
    this._timeout,
    this._frameTimeout,
    this._httpClient,
    this._preprocessor,
    this._mounted,
  );

  Future<void> dispose() async {
    _frameTimeoutTimer?.cancel();
    if (_subscription != null) {
      await _subscription!.cancel();
      _subscription = null;
    }
    _httpClient.close();
  }

  void _onFrameTimeout(ValueNotifier<List<dynamic>?> errorState,
      ValueNotifier<MemoryImage?> image) {
    if (_mounted()) {
      errorState.value = ['Connection lost: Frame timeout', StackTrace.current];
      image.value = null;
      dispose();
    }
  }

  void _resetFrameTimeout(ValueNotifier<List<dynamic>?> errorState,
      ValueNotifier<MemoryImage?> image) {
    _frameTimeoutTimer?.cancel();
    _frameTimeoutTimer =
        Timer(_frameTimeout, () => _onFrameTimeout(errorState, image));
  }

  void _sendImage(BuildContext context, ValueNotifier<MemoryImage?> image,
      ValueNotifier<List<dynamic>?> errorState, List<int> chunks) async {
    // Pass image through preprocessor and send to [Image] for rendering
    final List<int>? imageData = _preprocessor.process(chunks);
    if (imageData == null) return;

    final imageMemory = MemoryImage(Uint8List.fromList(imageData));
    if (_mounted()) {
      errorState.value = null;
      image.value = imageMemory;
      _resetFrameTimeout(errorState, image);
    }
  }

  void updateStream(BuildContext context, ValueNotifier<MemoryImage?> image,
      ValueNotifier<List<dynamic>?> errorState) async {
    try {
      final request = Request("GET", Uri.parse(stream));
      request.headers.addAll(headers);
      final response = await _httpClient.send(request).timeout(_timeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _resetFrameTimeout(errorState, image);

        var _carry = <int>[];
        _subscription = response.stream.listen((chunk) async {
          if (_carry.isNotEmpty && _carry.last == _trigger) {
            if (chunk.first == _eoi) {
              _carry.add(chunk.first);
              _sendImage(context, image, errorState, _carry);
              _carry = [];
              if (!isLive) {
                dispose();
              }
            }
          }

          for (var i = 0; i < chunk.length - 1; i++) {
            final d = chunk[i];
            final d1 = chunk[i + 1];

            if (d == _trigger && d1 == _soi) {
              _carry = [];
              _carry.add(d);
            } else if (d == _trigger && d1 == _eoi && _carry.isNotEmpty) {
              _carry.add(d);
              _carry.add(d1);

              _sendImage(context, image, errorState, _carry);
              _carry = [];
              if (!isLive) {
                dispose();
              }
            } else if (_carry.isNotEmpty) {
              _carry.add(d);
              if (i == chunk.length - 2) {
                _carry.add(d1);
              }
            }
          }
        }, onError: (error, stack) {
          try {
            if (_mounted()) {
              errorState.value = [error, stack];
              image.value = null;
            }
          } catch (ex) {}
          dispose();
        }, onDone: () {
          if (_mounted()) {
            errorState.value = [
              'Stream closed unexpectedly',
              StackTrace.current
            ];
            image.value = null;
          }
          dispose();
        }, cancelOnError: true);
      } else {
        if (_mounted()) {
          errorState.value = [
            HttpException('Stream returned ${response.statusCode} status'),
            StackTrace.current
          ];
          image.value = null;
        }
        dispose();
      }
    } catch (error, stack) {
      // Ignore certain errors related to connection headers
      if (!error
          .toString()
          .contains('Connection closed before full header was received')) {
        if (_mounted()) {
          errorState.value = [error, stack];
          image.value = null;
        }
      }
      dispose();
    }
  }
}
