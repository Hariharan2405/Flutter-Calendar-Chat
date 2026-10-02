import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../constants/app_theme.dart';
import '../providers/app_provider.dart';
import '../services/status_service.dart';
import '../utils/snack_util.dart';
import 'image_edit_screen.dart';
import 'video_trim_screen.dart';
import 'text_status_screen.dart';

class StatusCreateScreen extends StatefulWidget {
  final String uid;
  const StatusCreateScreen({super.key, required this.uid});

  @override
  State<StatusCreateScreen> createState() => _StatusCreateScreenState();
}

class _StatusCreateScreenState extends State<StatusCreateScreen> {
  final StatusService _statusService = StatusService();
  final TextEditingController _captionCtrl = TextEditingController();
  final AudioPlayer _previewPlayer = AudioPlayer();

  File? _mediaFile;
  String? _mediaType; // 'photo' | 'video'
  VideoPlayerController? _videoCtrl;
  String? _musicUrl;
  String? _musicName;
  String? _musicArtist;
  double _musicStartSec = 0;
  double _musicDurationSec = 0;
  bool _isPreviewingMusic = false;

  @override
  void dispose() {
    _captionCtrl.dispose();
    _videoCtrl?.dispose();
    _previewPlayer.dispose();
    super.dispose();
  }

  // ── Pick / edit media ─────────────────────────────────────────────────────────

  Future<void> _pickMedia(ImageSource source, String type) async {
    XFile? file;
    if (type == 'photo') {
      file = await ImagePicker().pickImage(source: source, imageQuality: 85);
    } else {
      // 60-second cap matches WhatsApp
      file = await ImagePicker()
          .pickVideo(source: source, maxDuration: const Duration(seconds: 60));
    }
    if (file == null || !mounted) return;

    _videoCtrl?.dispose();
    _videoCtrl = null;

    if (type == 'video') {
      // Push the trim screen; it returns the trimmed File (or null on cancel).
      final trimmed = await Navigator.push<File>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoTrimScreen(videoFile: File(file!.path)),
        ),
      );
      if (!mounted) return;
      if (trimmed == null) return; // user cancelled trim

      final ctrl = VideoPlayerController.file(trimmed);
      await ctrl.initialize();
      ctrl.setLooping(true);
      ctrl.play();
      if (mounted) {
        setState(() {
          _videoCtrl = ctrl;
          _mediaFile = trimmed;
          _mediaType = 'video';
          _musicUrl = null;
          _musicName = null;
          _musicArtist = null;
          _musicStartSec = 0;
          _musicDurationSec = 0;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _mediaFile = File(file!.path);
        _mediaType = type;
        _musicUrl = null;
        _musicName = null;
        _musicArtist = null;
        _musicStartSec = 0;
        _musicDurationSec = 0;
      });
    }
  }

  Future<void> _editImage() async {
    if (_mediaFile == null) return;
    final edited = await Navigator.push<File>(
      context,
      MaterialPageRoute(builder: (_) => ImageEditScreen(imageFile: _mediaFile!)),
    );
    if (edited != null && mounted) {
      setState(() => _mediaFile = edited);
    }
  }

  void _showPickerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
            _sheetTile(Icons.text_fields_rounded, 'Text — no photo needed', () {
              Navigator.pop(ctx);
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                    builder: (_) => TextStatusScreen(uid: widget.uid)),
              );
            }),
            const Divider(height: 8),
            _sheetTile(Icons.photo_camera_rounded, 'Photo — Camera', () {
              Navigator.pop(ctx);
              _pickMedia(ImageSource.camera, 'photo');
            }),
            _sheetTile(Icons.photo_library_rounded, 'Photo — Gallery', () {
              Navigator.pop(ctx);
              _pickMedia(ImageSource.gallery, 'photo');
            }),
            _sheetTile(Icons.videocam_rounded, 'Video — Camera (max 60s)', () {
              Navigator.pop(ctx);
              _pickMedia(ImageSource.camera, 'video');
            }),
            _sheetTile(Icons.video_library_rounded, 'Video — Gallery (max 60s)',
                () {
              Navigator.pop(ctx);
              _pickMedia(ImageSource.gallery, 'video');
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  ListTile _sheetTile(IconData icon, String label, VoidCallback onTap) =>
      ListTile(
        leading: Icon(icon, color: AppColors.primary),
        title: Text(label),
        onTap: onTap,
      );

  // ── Music ─────────────────────────────────────────────────────────────────────

  void _showMusicPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _MusicPickerSheet(
        statusService: _statusService,
        uid: widget.uid,
        previewPlayer: _previewPlayer,
        onSelected: (url, name, artist) async {
          Navigator.pop(ctx);
          await _previewPlayer.stop();
          setState(() {
            _musicUrl = url;
            _musicName = name;
            _musicArtist = artist;
            _musicStartSec = 0;
            _musicDurationSec = 0;
            _isPreviewingMusic = false;
          });
          // Play briefly to get track duration for trim slider
          try {
            await _previewPlayer.play(UrlSource(url));
            final dur = await _previewPlayer.onDurationChanged.first
                .timeout(const Duration(seconds: 8));
            await _previewPlayer.stop();
            if (mounted) {
              setState(() => _musicDurationSec = dur.inMilliseconds / 1000.0);
            }
          } catch (_) {
            try {
              await _previewPlayer.stop();
            } catch (_) {}
          }
        },
      ),
    );
  }

  Future<void> _toggleMusicPreview() async {
    if (_musicUrl == null) return;
    if (_isPreviewingMusic) {
      await _previewPlayer.stop();
      setState(() => _isPreviewingMusic = false);
    } else {
      setState(() => _isPreviewingMusic = true);
      await _previewPlayer.play(UrlSource(_musicUrl!));
      _previewPlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _isPreviewingMusic = false);
      });
    }
  }

  // ── Upload ────────────────────────────────────────────────────────────────────

  void _upload() {
    if (_mediaFile == null) return;
    _previewPlayer.stop();
    final caption =
        _captionCtrl.text.trim().isEmpty ? null : _captionCtrl.text.trim();
    // Hand off to AppProvider so the upload continues in the background and the
    // create screen can close immediately. Progress/failure shows on the status
    // screen.
    context.read<AppProvider>().enqueueStatusUpload(
          uid: widget.uid,
          mediaFile: _mediaFile!,
          mediaType: _mediaType!,
          caption: caption,
          musicUrl: _musicUrl,
          musicName: _musicName,
          musicArtist: _musicArtist,
          musicStartMs: _musicStartSec > 0
              ? (_musicStartSec * 1000).round()
              : null,
        );
    context.showSuccess('Posting status…');
    Navigator.pop(context);
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('New Status', style: TextStyle(color: Colors.white)),
        actions: [
          if (_mediaFile != null)
            IconButton(
              icon: const Icon(Icons.send_rounded, color: AppColors.primary),
              onPressed: _upload,
              tooltip: 'Post',
            ),
        ],
      ),
      body: _mediaFile == null ? _buildPickerPrompt() : _buildEditor(),
    );
  }

  Widget _buildPickerPrompt() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.add_photo_alternate_rounded,
                size: 48, color: AppColors.primary),
          ),
          const SizedBox(height: 20),
          const Text('Add photo or video',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('Your status disappears after 24 hours',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            icon: const Icon(Icons.add_rounded),
            label: const Text('Choose Media'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30)),
            ),
            onPressed: _showPickerSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Column(
      children: [
        // Preview
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_mediaType == 'video' && _videoCtrl != null)
                Center(
                  child: AspectRatio(
                    aspectRatio: _videoCtrl!.value.aspectRatio,
                    child: VideoPlayer(_videoCtrl!),
                  ),
                )
              else
                Image.file(_mediaFile!, fit: BoxFit.contain),
              // Caption overlay
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    // Strong dark backing so the white caption stays readable
                    // even over bright photos.
                    color: Colors.black.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _captionCtrl,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    cursorColor: Colors.white,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(
                      hintText: 'Add a caption...',
                      hintStyle: TextStyle(color: Colors.white70),
                      // Override the global theme's light fill — otherwise a
                      // light rectangle is painted over the dark box and the
                      // white caption text becomes invisible.
                      filled: false,
                      fillColor: Colors.transparent,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Bottom toolbar
        Container(
          color: const Color(0xFF1A1A1A),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _toolBtn(
                    icon: Icons.photo_library_rounded,
                    label: 'Change',
                    onTap: _showPickerSheet,
                  ),
                  const SizedBox(width: 8),
                  // Edit button for images
                  if (_mediaType == 'photo')
                    _toolBtn(
                      icon: Icons.edit_rounded,
                      label: 'Edit',
                      onTap: _editImage,
                    ),
                  const SizedBox(width: 8),
                  if (_mediaType == 'photo') ...[
                    Expanded(
                      child: GestureDetector(
                        onTap: _showMusicPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: _musicUrl != null
                                ? AppColors.primary.withValues(alpha: 0.2)
                                : Colors.white10,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _musicUrl != null
                                  ? AppColors.primary
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.music_note_rounded,
                                color: _musicUrl != null
                                    ? AppColors.primary
                                    : Colors.white54,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _musicName != null
                                      ? '$_musicName — $_musicArtist'
                                      : 'Add Music',
                                  style: TextStyle(
                                    color: _musicUrl != null
                                        ? Colors.white
                                        : Colors.white54,
                                    fontSize: 13,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (_musicUrl != null) ...[
                                GestureDetector(
                                  onTap: _toggleMusicPreview,
                                  child: Icon(
                                    _isPreviewingMusic
                                        ? Icons.stop_rounded
                                        : Icons.play_arrow_rounded,
                                    color: AppColors.primary,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () => setState(() {
                                    _musicUrl = null;
                                    _musicName = null;
                                    _musicArtist = null;
                                    _musicStartSec = 0;
                                    _musicDurationSec = 0;
                                    _previewPlayer.stop();
                                  }),
                                  child: const Icon(Icons.close_rounded,
                                      color: Colors.white54, size: 18),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ] else
                    const Expanded(child: SizedBox()),
                ],
              ),
              // Music trim slider — shown when a track is selected and duration known
              if (_musicUrl != null && _musicDurationSec > 5) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.content_cut_rounded,
                        color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    const Text('Start:',
                        style:
                            TextStyle(color: Colors.white70, fontSize: 12)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: _musicStartSec,
                          min: 0,
                          max: (_musicDurationSec - 5)
                              .clamp(0.0, _musicDurationSec),
                          label: '${_musicStartSec.round()}s',
                          activeColor: AppColors.primary,
                          inactiveColor: Colors.white24,
                          onChanged: (v) =>
                              setState(() => _musicStartSec = v),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        '${_musicStartSec.round()}s',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _toolBtn(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 18),
            const SizedBox(width: 6),
            Text(label,
                style:
                    const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

// ── Music Picker Sheet ────────────────────────────────────────────────────────

class _MusicPickerSheet extends StatefulWidget {
  final StatusService statusService;
  final String uid;
  final AudioPlayer previewPlayer;
  final void Function(String url, String name, String artist) onSelected;

  const _MusicPickerSheet({
    required this.statusService,
    required this.uid,
    required this.previewPlayer,
    required this.onSelected,
  });

  @override
  State<_MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends State<_MusicPickerSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<MusicTrack> _results = [];
  bool _loading = false;
  String? _playingUrl;
  bool _uploadingLocal = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    widget.previewPlayer.stop();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _results = [];
    });
    final results = await widget.statusService.searchMusic(q.trim());
    if (mounted) setState(() {
      _loading = false;
      _results = results;
    });
  }

  Future<void> _togglePreview(MusicTrack track) async {
    if (_playingUrl == track.previewUrl) {
      await widget.previewPlayer.stop();
      setState(() => _playingUrl = null);
    } else {
      setState(() => _playingUrl = track.previewUrl);
      await widget.previewPlayer.play(UrlSource(track.previewUrl));
      widget.previewPlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playingUrl = null);
      });
    }
  }

  Future<void> _pickLocalFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || !mounted) return;

    setState(() => _uploadingLocal = true);
    try {
      final url = await widget.statusService.uploadLocalMusic(
          widget.uid, File(path));
      final name = result.files.first.name.split('.').first;
      if (mounted) widget.onSelected(url, name, 'Local');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to upload music')));
      }
    } finally {
      if (mounted) setState(() => _uploadingLocal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('Add Music',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (_uploadingLocal)
                  const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: const Text('From Device'),
                    onPressed: _pickLocalFile,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search songs...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
                filled: true,
                fillColor: const Color(0xFFF3F0FA),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onSubmitted: _search,
              textInputAction: TextInputAction.search,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.music_note_rounded,
                            size: 48,
                            color: AppColors.textSecondary
                                .withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(
                            'Search for a song to add to your status',
                            style: TextStyle(
                                color: AppColors.textSecondary
                                    .withValues(alpha: 0.6),
                                fontSize: 13),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: scrollCtrl,
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final t = _results[i];
                      final isPlaying = _playingUrl == t.previewUrl;
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: t.artworkUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: t.artworkUrl,
                                  width: 46,
                                  height: 46,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => Container(
                                    width: 46,
                                    height: 46,
                                    color: AppColors.divider,
                                    child: const Icon(
                                        Icons.music_note_rounded,
                                        size: 22,
                                        color: AppColors.textSecondary),
                                  ),
                                )
                              : Container(
                                  width: 46,
                                  height: 46,
                                  color: AppColors.divider,
                                  child: const Icon(Icons.music_note_rounded,
                                      size: 22,
                                      color: AppColors.textSecondary),
                                ),
                        ),
                        title: Text(t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(t.artist,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                isPlaying
                                    ? Icons.stop_rounded
                                    : Icons.play_arrow_rounded,
                                color: AppColors.primary,
                              ),
                              onPressed: () => _togglePreview(t),
                              tooltip: isPlaying ? 'Stop' : 'Preview',
                            ),
                            IconButton(
                              icon: const Icon(Icons.check_circle_rounded,
                                  color: AppColors.primary),
                              onPressed: () => widget.onSelected(
                                  t.previewUrl, t.name, t.artist),
                              tooltip: 'Use this song',
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
