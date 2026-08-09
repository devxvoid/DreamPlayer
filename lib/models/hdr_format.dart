enum HdrFormat {
  sdr('SDR'),
  hdr10('HDR10'),
  hdr10plus('HDR10+'),
  dolbyVision('Dolby Vision'),
  hlg('HLG');

  const HdrFormat(this.label);

  final String label;
}
