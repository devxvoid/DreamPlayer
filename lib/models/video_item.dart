class VideoItem {
  const VideoItem({
    required this.id,
    required this.title,
    required this.path,
    required this.duration,
    this.sizeBytes,
    this.resolution,
    this.audioCodec,
    this.videoCodec,
    this.thumbnailPath,
  });

  final String id;
  final String title;
  final String path;
  final Duration duration;
  final int? sizeBytes;
  final String? resolution;
  final String? audioCodec;
  final String? videoCodec;
  final String? thumbnailPath;

  String get durationLabel {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
