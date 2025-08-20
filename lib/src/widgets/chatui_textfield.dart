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
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' hide Category;
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
    required this.onKeyboardChange,
  });

  final SendMessageConfiguration? sendMessageConfig;
  final FocusNode focusNode;
  final MarkdownTextEditingController textEditingController;
  final VoidCallback onPressed;
  final ValueSetter<String?> onRecordingComplete;
  final StringsCallBack onImageSelected;
  final ValueSetter<bool> onKeyboardChange;

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

  // Emoji Picker state
  bool _isEmojiPickerVisible = false;
  final ScrollController _emojiScrollController = ScrollController();

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

    // Emoji Picker smart hiding when text field gains focus
    widget.focusNode.addListener(() {
      if (widget.focusNode.hasFocus && _isEmojiPickerVisible) {
        setState(() => _isEmojiPickerVisible = false);
      }
    });
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
    _debouncer = Debouncer(_textFieldConfig?.compositionThresholdTime ??
        const Duration(seconds: 1));
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
    _emojiScrollController.dispose();
    if (_isEmojiPickerVisible) {
      setState(() => _isEmojiPickerVisible = false);
    }
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

  // --- WhatsApp-Style Emoji Picker Integration ---
  void _toggleEmojiPicker() {
    setState(() => _isEmojiPickerVisible = !_isEmojiPickerVisible);
    if (_isEmojiPickerVisible) {
      widget.focusNode.unfocus();
    } else {
      widget.focusNode.requestFocus();
    }
    widget.onKeyboardChange(_isEmojiPickerVisible);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = _sendMessageConfig?.defaultSendButtonColor ??
        theme.iconTheme.color ??
        Colors.grey.shade600;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: _textFieldConfig?.padding ?? EdgeInsets.zero,
          margin: _textFieldConfig?.margin,
          decoration: BoxDecoration(
            borderRadius: _textFieldConfig?.borderRadius ??
                BorderRadius.circular(textFieldBorderRadius),
            color: _sendMessageConfig?.textFieldBackgroundColor ??
                theme.colorScheme.surface,
          ),
          child: ValueListenableBuilder<bool>(
            valueListenable: _isRecording,
            builder: (context, isRecordingValue, _) {
              return Row(
                children: [
                  // Leading button
                  if (_sendMessageConfig?.leadingButtonBuilder != null ||
                      !isRecordingValue)
                    _sendMessageConfig?.leadingButtonBuilder?.call(context) ??
                        // --- Emoji toggle button ---
                        IconButton(
                          icon: Icon(
                            _isEmojiPickerVisible
                                ? Icons.keyboard
                                : Icons.emoji_emotions_outlined,
                            color: iconColor,
                          ),
                          onPressed: _toggleEmojiPicker,
                        )
                  else
                    _buildCancelRecordingButton(),

                  // Main input area
                  Expanded(
                    child: isRecordingValue && _controller != null
                        ? _buildVoiceRecordingWaveform()
                        : _buildTextInput(),
                  ),

                  // --- Action buttons ---
                  _buildActionButtons(isRecordingValue, iconColor),
                ],
              );
            },
          ),
        ),
        if (_isEmojiPickerVisible) const SizedBox(height: 8),
        // --- Emoji Picker Bottom Sheet ---
        if (_isEmojiPickerVisible)
          SizedBox(
            height: 270,
            child: EmojiPicker(
              textEditingController: widget.textEditingController,
              scrollController: _emojiScrollController,
              config: Config(
                height: 256,
                checkPlatformCompatibility: true,
                viewOrderConfig: const ViewOrderConfig(
                  top: EmojiPickerItem.searchBar,
                  middle: EmojiPickerItem.emojiView,
                  bottom: EmojiPickerItem.categoryBar,
                ),
                emojiTextStyle: _textFieldConfig?.textStyle,
                emojiViewConfig: EmojiViewConfig(
                  backgroundColor: theme.colorScheme.surface,
                ),
                skinToneConfig: const SkinToneConfig(),
                categoryViewConfig: CategoryViewConfig(
                  backgroundColor: theme.colorScheme.surface,
                  dividerColor: theme.colorScheme.surface,
                  indicatorColor: iconColor,
                  iconColorSelected: iconColor,
                  iconColor: iconColor,
                  backspaceColor: iconColor,
                  tabBarHeight: 50,
                  customCategoryView: (
                    config,
                    state,
                    tabController,
                    pageController,
                  ) {
                    return WhatsAppCategoryView(
                      config,
                      state,
                      tabController,
                      pageController,
                    );
                  },
                  categoryIcons: const CategoryIcons(
                    recentIcon: Icons.access_time_outlined,
                    smileyIcon: Icons.emoji_emotions_outlined,
                    animalIcon: Icons.cruelty_free_outlined,
                    foodIcon: Icons.coffee_outlined,
                    activityIcon: Icons.sports_soccer_outlined,
                    travelIcon: Icons.directions_car_filled_outlined,
                    objectIcon: Icons.lightbulb_outline,
                    symbolIcon: Icons.emoji_symbols_outlined,
                    flagIcon: Icons.flag_outlined,
                  ),
                ),
                bottomActionBarConfig: BottomActionBarConfig(
                  backgroundColor: theme.colorScheme.surface,
                  buttonColor: theme.colorScheme.surface,
                  buttonIconColor: iconColor,
                ),
                searchViewConfig: SearchViewConfig(
                  backgroundColor: theme.colorScheme.surface,
                  buttonIconColor: iconColor,
                  customSearchView: (
                    config,
                    state,
                    showEmojiView,
                  ) {
                    return WhatsAppSearchView(
                      config,
                      state,
                      showEmojiView,
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVoiceRecordingWaveform() {
    final theme = Theme.of(context);
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
                      theme.colorScheme.onSurface,
                ),
          ),
        ),
        StreamBuilder<Duration>(
          stream: _controller!.onCurrentDuration,
          builder: (context, snapshot) {
            return Text(
              snapshot.data?.toMMSS() ?? '00:00',
              style: Theme.of(context).textTheme.bodyMedium,
            );
          },
        ),
      ],
    );
  }

  Widget _buildTextInput() {
    final theme = Theme.of(context);
    return TextField(
      focusNode: widget.focusNode,
      controller: widget.textEditingController,
      style: _textFieldConfig?.textStyle ?? theme.textTheme.bodyMedium,
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
        fillColor: _sendMessageConfig?.textFieldBackgroundColor ??
            theme.colorScheme.surface,
        filled: true,
        hintStyle: _textFieldConfig?.hintStyle ??
            theme.textTheme.bodyMedium?.copyWith(
              color: theme.hintColor,
              fontSize: 16,
            ),
        contentPadding: _textFieldConfig?.contentPadding ?? EdgeInsets.zero,
        border: _outLineBorder,
        focusedBorder: _outLineBorder,
        enabledBorder: _outLineBorder,
        disabledBorder: _outLineBorder,
      ),
    );
  }

  Widget _buildActionButtons(bool isRecordingValue, Color iconColor) {
    return ValueListenableBuilder<String>(
      valueListenable: _inputText,
      builder: (context, inputTextValue, _) {
        final hasContent = inputTextValue.trim().isNotEmpty || isRecordingValue;
        final isEnabled = _textFieldConfig?.enabled ?? true;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasContent)
              _buildSendButton(isRecordingValue, isEnabled, iconColor)
            else
              _buildUtilityButtons(isRecordingValue, isEnabled),
          ],
        );
      },
    );
  }

  Widget _buildSendButton(
      bool isRecordingValue, bool isEnabled, Color iconColor) {
    return IconButton(
      color: iconColor,
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
          Icon(isRecordingValue ? Icons.stop : Icons.mic,
              color: _voiceRecordingConfig?.recorderIconColor),
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

  Future<void> _pickImage(ImageSource imageSource,
      {ImagePickerConfiguration? config}) async {
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
        !_isRecording.value) {
      return;
    }
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

/// Customized Whatsapp category view
class WhatsAppCategoryView extends CategoryView {
  const WhatsAppCategoryView(
    super.config,
    super.state,
    super.tabController,
    super.pageController, {
    super.key,
  });

  @override
  WhatsAppCategoryViewState createState() => WhatsAppCategoryViewState();
}

class WhatsAppCategoryViewState extends State<WhatsAppCategoryView>
    with SkinToneOverlayStateMixin {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: widget.config.categoryViewConfig.backgroundColor,
      height: 60,
      alignment: Alignment.topCenter,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: WhatsAppTabBar(
              widget.config,
              widget.tabController,
              widget.pageController,
              widget.state.categoryEmoji,
              closeSkinToneOverlay,
            ),
          ),
          _buildExtraTab(widget.config.categoryViewConfig.extraTab),
        ],
      ),
    );
  }

  Widget _buildExtraTab(extraTab) {
    if (extraTab == CategoryExtraTab.BACKSPACE) {
      return BackspaceButton(
        widget.config,
        widget.state.onBackspacePressed,
        widget.state.onBackspaceLongPressed,
        widget.config.categoryViewConfig.backspaceColor,
      );
    } else if (extraTab == CategoryExtraTab.SEARCH) {
      return SearchButton(
        widget.config,
        widget.state.onShowSearchView,
        widget.config.categoryViewConfig.iconColor,
      );
    } else {
      return const SizedBox.shrink();
    }
  }
}

class WhatsAppTabBar extends StatelessWidget {
  const WhatsAppTabBar(
    this.config,
    this.tabController,
    this.pageController,
    this.categoryEmojis,
    this.closeSkinToneOverlay, {
    super.key,
  });

  final Config config;

  final TabController tabController;

  final PageController pageController;

  final List<CategoryEmoji> categoryEmojis;

  final VoidCallback closeSkinToneOverlay;

  @override
  Widget build(BuildContext context) {
    return TabBar(
      labelColor: config.categoryViewConfig.iconColorSelected,
      indicatorColor: config.categoryViewConfig.indicatorColor,
      unselectedLabelColor: config.categoryViewConfig.iconColor,
      dividerColor: config.categoryViewConfig.dividerColor,
      controller: tabController,
      labelPadding: const EdgeInsets.only(top: 1.0),
      indicatorSize: TabBarIndicatorSize.label,
      automaticIndicatorColorAdjustment: true,
      enableFeedback: true,
      padding: EdgeInsets.zero,
      indicator: BoxDecoration(
        shape: BoxShape.circle,
        color: config.categoryViewConfig.indicatorColor.withValues(alpha: 0.15),
      ),
      onTap: (index) {
        closeSkinToneOverlay();
        pageController.jumpToPage(index);
      },
      tabs: categoryEmojis
          .asMap()
          .entries
          .map<Widget>((item) => _buildCategory(item.key, item.value.category))
          .toList(),
    );
  }

  Widget _buildCategory(int index, Category category) {
    return Tab(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.all(6.0),
        child: Icon(
          getIconForCategory(
            config.categoryViewConfig.categoryIcons,
            category,
          ),
        ),
      ),
    );
  }
}

/// Custom Whatsapp Search view implementation
class WhatsAppSearchView extends SearchView {
  const WhatsAppSearchView(super.config, super.state, super.showEmojiView,
      {super.key});

  @override
  WhatsAppSearchViewState createState() => WhatsAppSearchViewState();
}

class WhatsAppSearchViewState extends SearchViewState {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final emojiSize =
          widget.config.emojiViewConfig.getEmojiSize(constraints.maxWidth);
      final emojiBoxSize =
          widget.config.emojiViewConfig.getEmojiBoxSize(constraints.maxWidth);
      return Container(
        color: widget.config.searchViewConfig.backgroundColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: emojiBoxSize + 8.0,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                scrollDirection: Axis.horizontal,
                itemCount: results.length,
                itemBuilder: (context, index) {
                  return buildEmoji(
                    results[index],
                    emojiSize,
                    emojiBoxSize,
                  );
                },
              ),
            ),
            Row(
              children: [
                IconButton(
                  onPressed: widget.showEmojiView,
                  color: widget.config.searchViewConfig.buttonIconColor,
                  icon: const Icon(
                    Icons.arrow_back,
                    size: 20.0,
                  ),
                ),
                Expanded(
                  child: TextField(
                    onChanged: onTextInputChanged,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: widget.config.searchViewConfig.hintText,
                      hintStyle: TextStyle(
                        color: widget.config.emojiTextStyle?.color ??
                            Theme.of(context).hintColor,
                        fontWeight: FontWeight.normal,
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}
