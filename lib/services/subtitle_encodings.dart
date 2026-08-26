// Subtitle text encoding (charset) options, mirroring Nova's `codepage_entries`
// / `codepage_entryvalues` in `res/values/arrays.xml`.
// Nova exposes: Default (auto) + 15 explicit Windows codepages for subtitle
// text files. `0` is Auto (UTF-8 BOM/strict -> CP1252 fallback in
// `SubtitleFormats.toUtf8`); the rest are Windows codepage numbers.
library;

class SubtitleEncoding {
  const SubtitleEncoding({required this.displayName, required this.codepage});

  final String displayName;
  final int codepage; // 0 = Auto/Default, else Windows codepage number

  @override
  String toString() => '$displayName ($codepage)';
}

const List<SubtitleEncoding> subtitleEncodings = [
  SubtitleEncoding(displayName: 'Auto (Default)', codepage: 0),
  SubtitleEncoding(displayName: 'Eastern European (CP1250)', codepage: 1250),
  SubtitleEncoding(displayName: 'Cyrillic (CP1251)', codepage: 1251),
  SubtitleEncoding(displayName: 'Western European (CP1252)', codepage: 1252),
  SubtitleEncoding(displayName: 'Greek (CP1253)', codepage: 1253),
  SubtitleEncoding(displayName: 'Turkish (CP1254)', codepage: 1254),
  SubtitleEncoding(displayName: 'Hebrew (CP1255)', codepage: 1255),
  SubtitleEncoding(displayName: 'Arabic (CP1256)', codepage: 1256),
  SubtitleEncoding(displayName: 'Baltic (CP1257)', codepage: 1257),
  SubtitleEncoding(displayName: 'Vietnamese (CP1258)', codepage: 1258),
  SubtitleEncoding(displayName: 'Thai (CP874)', codepage: 874),
  SubtitleEncoding(displayName: 'Simplified Chinese (CP936)', codepage: 936),
  SubtitleEncoding(displayName: 'Traditional Chinese (CP950)', codepage: 950),
  SubtitleEncoding(displayName: 'Japanese (CP932)', codepage: 932),
  SubtitleEncoding(displayName: 'Korean (CP949)', codepage: 949),
];

final Map<int, SubtitleEncoding> _byCodepage = {
  for (final e in subtitleEncodings) e.codepage: e,
};

SubtitleEncoding encodingForCodepage(int cp) => _byCodepage[cp] ?? _byCodepage[0]!;
String displayNameForCodepage(int cp) => encodingForCodepage(cp).displayName;
