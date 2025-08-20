/*
 * Copyright (c) 2022 Simform Solutions
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:chatview/src/utils/markdown_parser.dart';
import 'package:chatview_utils/chatview_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/config_models/send_message_configuration.dart';
import '../utils/constants/constants.dart';
import '../utils/debounce.dart';
import '../utils/package_strings.dart';
import '../values/typedefs.dart';

class ChatUITextField extends StatefulWidget {
  const ChatUITextField({
    super.key,
    this.sendMessageConfig,
    required this.focusNode,
    required this.textEditingController,
    required this.onPressed,
    required this.onRecordingComplete,
    required this.onImageSelected,
  });

  /// Provides configuration of default text field in chat.
  final SendMessageConfiguration? sendMessageConfig;

  /// Provides focusNode for focusing text field.
  final FocusNode focusNode;

  /// Provides functions which handles text field.
  final MarkdownTextEditingController textEditingController;

  /// Provides callback when user tap on text field.
  final VoidCallback onPressed;

  /// Provides callback once voice is recorded.
  final ValueSetter<String?> onRecordingComplete;

  /// Provides callback when user select images from camera/gallery.
  final StringsCallBack onImageSelected;

  @override
  State<ChatUITextField> createState() => _ChatUITextFieldState();
}

class _ChatUITextFieldState extends State<ChatUITextField> {
  // State variables
  late final ValueNotifier<String> _inputText;
  late final ImagePicker _imagePicker;
  late final ValueNotifier<bool> _isRecording;
  late final ValueNotifier<TypeWriterStatus> _composingStatus;
  late final Debouncer _debouncer;

  RecorderController? _controller;
  bool Function(KeyEvent)? _keyboardHandler;

  // Configuration getters
  SendMessageConfiguration? get _sendMessageConfig => widget.sendMessageConfig;

  VoiceRecordingConfiguration? get _voiceRecordingConfig =>
      _sendMessageConfig?.voiceRecordingConfiguration;

  ImagePickerIconsConfiguration? get _imagePickerIconsConfig =>
      _sendMessageConfig?.imagePickerIconsConfig;

  TextFieldConfiguration? get _textFieldConfig =>
      _sendMessageConfig?.textFieldConfig;

  CancelRecordConfiguration? get _cancelRecordConfiguration =>
      _sendMessageConfig?.cancelRecordConfiguration;

  OutlineInputBorder get _outLineBorder => OutlineInputBorder(
        borderSide: const BorderSide(color: Colors.transparent),
        borderRadius: _textFieldConfig?.borderRadius ??
            BorderRadius.circular(textFieldBorderRadius),
      );

  bool get _isVoiceRecordingSupported =>
      !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  bool get _isVoiceRecordingEnabled =>
      (_sendMessageConfig?.allowRecordingVoice ?? false) &&
      _isVoiceRecordingSupported;

  @override
  void initState() {
    super.initState();
    _initializeState();
    _setupListeners();
    _initializeRecorderController();
    _setupKeyboardHandler();
  }

  @override
  void dispose() {
    _cleanupResources();
    super.dispose();
  }

  void _initializeState() {
    _inputText = ValueNotifier('');
    _imagePicker = ImagePicker();
    _isRecording = ValueNotifier(false);
    _composingStatus = ValueNotifier(TypeWriterStatus.typed);
    _debouncer = Debouncer(
      _textFieldConfig?.compositionThresholdTime ?? const Duration(seconds: 1),
    );
  }

  void _setupListeners() {
    _composingStatus.addListener(_onComposingStatusChanged);
    widget.textEditingController.addListener(_onTextControllerChanged);
  }

  void _initializeRecorderController() {
    if (_isVoiceRecordingSupported) {
      _controller = RecorderController();
    }
  }

  void _setupKeyboardHandler() {
    if (kIsWeb) {
      _keyboardHandler = _createHardwareKeyboardHandler();
      if (_keyboardHandler != null) {
        HardwareKeyboard.instance.addHandler(_keyboardHandler!);
      }
    }
  }

  void _cleanupResources() {
    _debouncer.dispose();
    _composingStatus.dispose();
    _isRecording.dispose();
    _inputText.dispose();

    if (_keyboardHandler != null) {
      HardwareKeyboard.instance.removeHandler(_keyboardHandler!);
    }

    _controller?.dispose();
  }

  void _onComposingStatusChanged() {
    _textFieldConfig?.onMessageTyping?.call(_composingStatus.value);
  }

  void _onTextControllerChanged() {
    final text = widget.textEditingController.text;
    if (_inputText.value != text) {
      _inputText.value = text;
    }
  }

  bool Function(KeyEvent)? _createHardwareKeyboardHandler() {
    return (KeyEvent event) {
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.enter) {
        return false;
      }

      final pressedKeys = HardwareKeyboard.instance.logicalKeysPressed;
      final isShiftPressed = pressedKeys.any((key) =>
          key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight);

      if (!isShiftPressed) {
        // Send message on Enter
        if (_inputText.value.trim().isNotEmpty) {
          _handleSendMessage();
        }
      } else {
        // Shift+Enter: insert new line
        _insertNewLineAtCursor();
      }
      return true;
    };
  }

  void _insertNewLineAtCursor() {
    final controller = widget.textEditingController;
    final text = controller.text;
    final selection = controller.selection;

    final newText = text.replaceRange(
      selection.start,
      selection.end,
      '\n',
    );

    controller
      ..text = newText
      ..selection = TextSelection.collapsed(offset: selection.start + 1);
  }

  void _handleSendMessage() {
    widget.onPressed();
    _clearInput();
  }

  void _clearInput() {
    widget.textEditingController.clear();
    _inputText.value = '';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: _textFieldConfig?.padding ?? EdgeInsets.zero,
      margin: _textFieldConfig?.margin,
      decoration: BoxDecoration(
        borderRadius: _textFieldConfig?.borderRadius ??
            BorderRadius.circular(textFieldBorderRadius),
        color: _sendMessageConfig?.textFieldBackgroundColor ?? Colors.white,
      ),
      child: ValueListenableBuilder<bool>(
        valueListenable: _isRecording,
        builder: (context, isRecordingValue, _) {
          return Row(
            children: [
              // Leading button
              if (_sendMessageConfig?.leadingButtonBuilder != null &&
                  !isRecordingValue)
                _sendMessageConfig!.leadingButtonBuilder!(context) ??
                    const SizedBox.shrink()
              else
                _buildCancelRecordingButton(),

              // Main input area
              Expanded(
                child: isRecordingValue && _controller != null
                    ? _buildVoiceRecordingWaveform()
                    : _buildTextInput(),
              ),

              // Action buttons
              _buildActionButtons(isRecordingValue),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVoiceRecordingWaveform() {
    return Row(
      children: [
        Expanded(
          child: AudioWaveforms(
            size: const Size(double.maxFinite, 48),
            recorderController: _controller!,
            margin: _voiceRecordingConfig?.margin,
            padding: _voiceRecordingConfig?.padding ?? EdgeInsets.zero,
            decoration: _voiceRecordingConfig?.decoration ??
                BoxDecoration(
                  color: _voiceRecordingConfig?.backgroundColor,
                  borderRadius: BorderRadius.circular(22.0),
                ),
            waveStyle: _voiceRecordingConfig?.waveStyle ??
                WaveStyle(
                  extendWaveform: true,
                  showMiddleLine: false,
                  waveColor: _voiceRecordingConfig?.waveStyle?.waveColor ??
                      Colors.black,
                ),
          ),
        ),
        StreamBuilder<Duration>(
          stream: _controller!.onCurrentDuration,
          builder: (context, snapshot) {
            return Text(snapshot.data?.toMMSS() ?? '00:00');
          },
        ),
      ],
    );
  }

  Widget _buildTextInput() {
    return TextField(
      focusNode: widget.focusNode,
      controller: widget.textEditingController,
      style:
          _textFieldConfig?.textStyle ?? const TextStyle(color: Colors.white),
      maxLines: _textFieldConfig?.maxLines ?? 5,
      minLines: _textFieldConfig?.minLines ?? 1,
      keyboardType: _textFieldConfig?.textInputType,
      inputFormatters: _textFieldConfig?.inputFormatters,
      onChanged: _onTextChanged,
      enabled: _textFieldConfig?.enabled ?? true,
      textCapitalization:
          _textFieldConfig?.textCapitalization ?? TextCapitalization.sentences,
      decoration: InputDecoration(
        hintText:
            _textFieldConfig?.hintText ?? PackageStrings.currentLocale.message,
        fillColor: _sendMessageConfig?.textFieldBackgroundColor ?? Colors.white,
        filled: true,
        hintStyle: _textFieldConfig?.hintStyle ??
            TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: Colors.grey.shade600,
              letterSpacing: 0.25,
            ),
        contentPadding: _textFieldConfig?.contentPadding ??
            const EdgeInsets.symmetric(horizontal: 6),
        border: _outLineBorder,
        focusedBorder: _outLineBorder,
        enabledBorder: _outLineBorder,
        disabledBorder: _outLineBorder,
      ),
    );
  }

  Widget _buildActionButtons(bool isRecordingValue) {
    return ValueListenableBuilder<String>(
      valueListenable: _inputText,
      builder: (context, inputTextValue, _) {
        final hasContent = inputTextValue.trim().isNotEmpty || isRecordingValue;
        final isEnabled = _textFieldConfig?.enabled ?? true;

        if (hasContent) {
          return _buildSendButton(isRecordingValue, isEnabled);
        }

        return _buildUtilityButtons(isRecordingValue, isEnabled);
      },
    );
  }

  Widget _buildSendButton(bool isRecordingValue, bool isEnabled) {
    return IconButton(
      color: _sendMessageConfig?.defaultSendButtonColor ?? Colors.green,
      onPressed:
          isEnabled ? () => _handleSendOrStopRecording(isRecordingValue) : null,
      padding: EdgeInsets.zero,
      icon: _sendMessageConfig?.sendButtonIcon ?? const Icon(Icons.send),
    );
  }

  Widget _buildUtilityButtons(bool isRecordingValue, bool isEnabled) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Trailing button
        if (_sendMessageConfig?.trailingButtonBuilder != null)
          _sendMessageConfig!.trailingButtonBuilder!(context) ??
              const SizedBox.shrink(),

        // Camera and Gallery buttons (only when not recording)
        if (!isRecordingValue) ...[
          if (_sendMessageConfig?.enableCameraImagePicker ?? true)
            _buildImagePickerButton(
              ImageSource.camera,
              _imagePickerIconsConfig?.cameraImagePickerIcon ??
                  Icon(
                    Icons.camera_alt_outlined,
                    color: _imagePickerIconsConfig?.cameraIconColor,
                  ),
              isEnabled,
            ),
          if (_sendMessageConfig?.enableGalleryImagePicker ?? true)
            _buildImagePickerButton(
              ImageSource.gallery,
              _imagePickerIconsConfig?.galleryImagePickerIcon ??
                  Icon(
                    Icons.image,
                    color: _imagePickerIconsConfig?.galleryIconColor,
                  ),
              isEnabled,
            ),
        ],

        // Voice recording button
        if (_isVoiceRecordingEnabled)
          _buildVoiceRecordingButton(isRecordingValue, isEnabled),

        // Cancel recording button
        if (isRecordingValue && _cancelRecordConfiguration != null)
          _buildCancelRecordingButton(),
      ],
    );
  }

  Widget _buildImagePickerButton(
      ImageSource source, Widget icon, bool isEnabled) {
    return IconButton(
      constraints: const BoxConstraints(),
      onPressed: isEnabled ? () => _onImagePickerPressed(source) : null,
      icon: icon,
    );
  }

  Widget _buildVoiceRecordingButton(bool isRecordingValue, bool isEnabled) {
    return IconButton(
      onPressed: isEnabled ? _handleVoiceRecording : null,
      icon: (isRecordingValue
              ? _voiceRecordingConfig?.stopIcon
              : _voiceRecordingConfig?.micIcon) ??
          Icon(
            isRecordingValue ? Icons.stop : Icons.mic,
            color: _voiceRecordingConfig?.recorderIconColor,
          ),
    );
  }

  Widget _buildCancelRecordingButton() {
    return IconButton(
      onPressed: () {
        _cancelRecordConfiguration?.onCancel?.call();
        _cancelRecording();
      },
      icon:
          _cancelRecordConfiguration?.icon ?? const Icon(Icons.cancel_outlined),
      color: _cancelRecordConfiguration?.iconColor ??
          _voiceRecordingConfig?.recorderIconColor,
    );
  }

  void _handleSendOrStopRecording(bool isRecordingValue) {
    if (isRecordingValue) {
      _handleVoiceRecording();
    } else {
      _handleSendMessage();
    }
  }

  Future<void> _onImagePickerPressed(ImageSource source) async {
    final config = _sendMessageConfig?.imagePickerConfiguration;
    await _pickImage(source, config: config);
  }

  Future<void> _pickImage(
    ImageSource imageSource, {
    ImagePickerConfiguration? config,
  }) async {
    if (!mounted) return;

    final hadFocus = widget.focusNode.hasFocus;

    try {
      widget.focusNode.unfocus();

      final XFile? image = await _imagePicker.pickImage(
        source: imageSource,
        maxHeight: config?.maxHeight,
        maxWidth: config?.maxWidth,
        imageQuality: config?.imageQuality,
        preferredCameraDevice:
            config?.preferredCameraDevice ?? CameraDevice.rear,
      );

      if (image == null) return;

      String? imagePath = image.path;

      // Process image if callback provided
      if (config?.onImagePicked != null) {
        final updatedPath = await config!.onImagePicked!(imagePath);
        if (updatedPath != null) {
          imagePath = updatedPath;
        }
      }

      widget.onImageSelected(imagePath, '');
    } catch (e) {
      widget.onImageSelected('', e.toString());
    } finally {
      // Handle iOS keyboard behavior
      if (mounted &&
          imageSource == ImageSource.gallery &&
          Platform.isIOS &&
          hadFocus) {
        widget.focusNode.requestFocus();
      }
    }
  }

  Future<void> _handleVoiceRecording() async {
    if (!_isVoiceRecordingSupported || _controller == null) return;

    try {
      if (!_isRecording.value) {
        await _startRecording();
      } else {
        await _stopRecording();
      }
    } catch (e) {
      // Handle recording errors
      debugPrint('Voice recording error: $e');
      _isRecording.value = false;
    }
  }

  Future<void> _startRecording() async {
    await _controller!.record(
      sampleRate: _voiceRecordingConfig?.sampleRate,
      bitRate: _voiceRecordingConfig?.bitRate,
      androidEncoder: _voiceRecordingConfig?.androidEncoder,
      iosEncoder: _voiceRecordingConfig?.iosEncoder,
      androidOutputFormat: _voiceRecordingConfig?.androidOutputFormat,
    );
    _isRecording.value = true;
  }

  Future<void> _stopRecording() async {
    final path = await _controller!.stop();
    _isRecording.value = false;
    widget.onRecordingComplete(path);
  }

  Future<void> _cancelRecording() async {
    if (!_isVoiceRecordingSupported ||
        _controller == null ||
        !_isRecording.value) return;

    try {
      final path = await _controller!.stop();

      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Error canceling recording: $e');
    } finally {
      _isRecording.value = false;
    }
  }

  void _onTextChanged(String inputText) {
    _debouncer.run(
      () => _composingStatus.value = TypeWriterStatus.typed,
      () => _composingStatus.value = TypeWriterStatus.typing,
    );
    _inputText.value = inputText;
  }
}
