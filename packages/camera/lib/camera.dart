import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

final MethodChannel _channel = const MethodChannel('plugins.flutter.io/camera')
  ..invokeMethod('init');

enum CameraLensDirection { front, back, external }

enum ResolutionPreset { low, medium, high }

/// Returns the resolution preset as a String.
String serializeResolutionPreset(ResolutionPreset resolutionPreset) {
  switch (resolutionPreset) {
    case ResolutionPreset.high:
      return 'high';
    case ResolutionPreset.medium:
      return 'medium';
    case ResolutionPreset.low:
      return 'low';
  }
  throw new ArgumentError('Unknown ResolutionPreset value');
}

CameraLensDirection _parseCameraLensDirection(String string) {
  switch (string) {
    case 'front':
      return CameraLensDirection.front;
    case 'back':
      return CameraLensDirection.back;
    case 'external':
      return CameraLensDirection.external;
  }
  throw new ArgumentError('Unknown CameraLensDirection value');
}

/// Completes with a list of available cameras.
///
/// May throw a [CameraException].
Future<List<CameraDescription>> availableCameras() async {
  try {
    final List<dynamic> cameras =
        await _channel.invokeMethod('availableCameras');
    return cameras.map((dynamic camera) {
      return new CameraDescription(
        name: camera['name'],
        lensDirection: _parseCameraLensDirection(camera['lensFacing']),
      );
    }).toList();
  } on PlatformException catch (e) {
    throw new CameraException(e.code, e.message);
  }
}

class CameraDescription {
  final String name;
  final CameraLensDirection lensDirection;

  CameraDescription({this.name, this.lensDirection});

  @override
  bool operator ==(Object o) {
    return o is CameraDescription &&
        o.name == name &&
        o.lensDirection == lensDirection;
  }

  @override
  int get hashCode {
    return hashValues(name, lensDirection);
  }

  @override
  String toString() {
    return '$runtimeType($name, $lensDirection)';
  }
}

/// This is thrown when the plugins report an error.
class CameraException implements Exception {
  String code;
  String description;

  CameraException(this.code, this.description);

  @override
  String toString() => '$runtimeType($code, $description)';
}

// Build the UI texture view of the video data with textureId.
class CameraPreview extends StatelessWidget {
  final CameraController controller;

  const CameraPreview(this.controller);

  @override
  Widget build(BuildContext context) {
    return controller.value.isInitialized
        ? new Texture(textureId: controller._textureId)
        : new Container();
  }
}

/// The state of a [CameraController].
class CameraValue {
  /// True if the camera is on.
  final bool isOpen;

  /// True after [CameraController.openCamera] has completed successfully.
  final bool isInitialized;

  final bool isRecordingVideo;

  final String errorDescription;

  /// The size of the preview in pixels.
  ///
  /// Is `null` until  [isInitialized] is `true`.
  final Size previewSize;

  const CameraValue(
      {this.isOpen,
      this.isInitialized,
      this.errorDescription,
      this.previewSize,
      this.isRecordingVideo});

  const CameraValue.uninitialized()
      : this(isOpen: true, isInitialized: false, isRecordingVideo: false);

  /// Convenience getter for `previewSize.height / previewSize.width`.
  ///
  /// Can only be called when [isInitialized] is done.
  double get aspectRatio => previewSize.height / previewSize.width;

  bool get hasError => errorDescription != null;

  CameraValue copyWith({
    bool isOpen,
    bool isInitialized,
    bool isRecordingVideo,
    String errorDescription,
    Size previewSize,
  }) {
    return new CameraValue(
      isOpen: isOpen ?? this.isOpen,
      isInitialized: isInitialized ?? this.isInitialized,
      errorDescription: errorDescription ?? this.errorDescription,
      previewSize: previewSize ?? this.previewSize,
      isRecordingVideo: isRecordingVideo ?? this.isRecordingVideo,
    );
  }

  @override
  String toString() {
    return '$runtimeType('
        'opened: $isOpen, '
        'recordingVideo: $isRecordingVideo, '
        'initialized: $isInitialized, '
        'errorDescription: $errorDescription, '
        'previewSize: $previewSize)';
  }
}

/// Controls a device camera.
///
/// Use [availableCameras] to get a list of available cameras.
///
/// Before using a [CameraController] a call to [openCamera] must complete.
///
/// To show the camera preview on the screen use a [CameraPreview] widget.
class CameraController extends ValueNotifier<CameraValue> {
  final CameraDescription description;
  final ResolutionPreset resolutionPreset;

  int _textureId;
  bool _isDisposed = false;
  StreamSubscription<dynamic> _eventSubscription;
  Completer<Null> _creatingCompleter;

  CameraController(this.description, this.resolutionPreset)
      : super(const CameraValue.uninitialized());

  /// Initializes the camera on the device.
  ///
  /// Throws a [CameraException] if the initialization fails.
  Future<Null> openCamera() async {
    if (_isDisposed) {
      return;
    }
    try {
      _creatingCompleter = new Completer<Null>();
      final Map<dynamic, dynamic> reply = await _channel.invokeMethod(
        'openCamera',
        <String, dynamic>{
          'cameraName': description.name,
          'resolutionPreset': serializeResolutionPreset(resolutionPreset),
        },
      );
      _textureId = reply['textureId'];
      value = value.copyWith(
        isInitialized: true,
        previewSize: new Size(
          reply['previewWidth'].toDouble(),
          reply['previewHeight'].toDouble(),
        ),
      );
    } on PlatformException catch (e) {
      value = value.copyWith(errorDescription: e.message);
      throw new CameraException(e.code, e.message);
    }
    _eventSubscription =
        new EventChannel('flutter.io/cameraPlugin/cameraEvents$_textureId')
            .receiveBroadcastStream()
            .listen(_listener);
    _creatingCompleter.complete(null);
  }

  /// Listen to events from the native plugins.
  void _listener(dynamic event) {
    final Map<dynamic, dynamic> map = event;
    if (_isDisposed) {
      return;
    }

    switch (map['eventType']) {
      case 'error':
        value = value.copyWith(errorDescription: event['errorDescription']);
        break;
      case 'cameraClosing':
        value = value.copyWith(isRecordingVideo: false);
        break;
    }
  }

  /// Captures an image and saves it to [path].
  ///
  /// A path can for example be obtained using
  /// [path_provider](https://pub.dartlang.org/packages/path_provider).
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<Null> takePicture(String path) async {
    if (!value.isInitialized || _isDisposed) {
      throw new CameraException(
        'Uninitialized capture()',
        'capture() was called on uninitialized CameraController',
      );
    }
    try {
      await _channel.invokeMethod(
        'takePicture',
        <String, dynamic>{'textureId': _textureId, 'path': path},
      );
    } on PlatformException catch (e) {
      value = value.copyWith(errorDescription: e.message);
      throw new CameraException(e.code, e.message);
    }
  }

  /// Start a video recording and save the file to [path].
  ///
  /// A path can for example be obtained using
  /// [path_provider](https://pub.dartlang.org/packages/path_provider).
  ///
  /// The file is written on the flight as the video is being recorded.
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<Null> startVideoRecording(String filePath) async {
    if (!value.isInitialized || _isDisposed) {
      throw new CameraException(
        'Uninitialized CameraController',
        'startVideoRecording was called on uninitialized CameraController',
      );
    }
    try {
      value = value.copyWith(isRecordingVideo: true);
      await _channel.invokeMethod(
        'startVideoRecording',
        <String, dynamic>{'textureId': _textureId, 'filePath': filePath},
      );
    } on PlatformException catch (e) {
      value = value.copyWith(errorDescription: e.message);
      throw new CameraException(e.code, e.message);
    }
  }

  /// Stop recording.
  Future<Null> stopVideoRecording() async {
    if (!value.isInitialized || _isDisposed) {
      throw new CameraException(
        'Uninitialized CameraController',
        'stopVideoRecording was called on uninitialized CameraController',
      );
    }
    try {
      value = value.copyWith(isRecordingVideo: false);
      await _channel.invokeMethod(
        'stopVideoRecording',
        <String, dynamic>{'textureId': _textureId},
      );
    } on PlatformException catch (e) {
      value = value.copyWith(errorDescription: e.message);
      throw new CameraException(e.code, e.message);
    }
  }

  /// Releases the resources of this camera.
  @override
  Future<Null> dispose() async {
    if (_isDisposed) {
      return new Future<Null>.value(null);
    }
    _isDisposed = true;
    super.dispose();
    if (_creatingCompleter == null) {
      return new Future<Null>.value(null);
    } else {
      return _creatingCompleter.future.then((_) async {
        await _channel.invokeMethod(
          'closeCamera',
          <String, dynamic>{'textureId': _textureId},
        );
        await _eventSubscription?.cancel();
      });
    }
  }
}
