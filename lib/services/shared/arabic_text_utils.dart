/// Returns true if [text] contains any Arabic/RTL character — used to
/// auto-detect paragraph direction when no explicit w:bidi is present.
bool hasArabic(String text) {
  for (final cp in text.runes) {
    if ((cp >= 0x0600 && cp <= 0x06FF) || // Arabic block
        (cp >= 0x0750 && cp <= 0x077F) || // Arabic Supplement
        (cp >= 0x08A0 && cp <= 0x08FF) || // Arabic Extended-A
        (cp >= 0xFB50 && cp <= 0xFDFF) || // Arabic Presentation Forms-A
        (cp >= 0xFE70 && cp <= 0xFEFF)) { // Arabic Presentation Forms-B
      return true;
    }
  }
  return false;
}

/// Returns true if [text] contains any Latin letter — used as the LTR
/// counterpart to [hasArabic] when resolving paragraph direction (a line
/// with Latin letters but no Arabic is treated as LTR). Covers Basic Latin
/// (A–Z / a–z) plus Latin-1 Supplement and Latin Extended-A/B letters so
/// accented European text (é, ñ, ü, š …) is detected too.
bool hasLatin(String text) {
  for (final cp in text.runes) {
    if ((cp >= 0x0041 && cp <= 0x005A) || // A–Z
        (cp >= 0x0061 && cp <= 0x007A) || // a–z
        (cp >= 0x00C0 && cp <= 0x00FF) || // Latin-1 Supplement letters
        (cp >= 0x0100 && cp <= 0x017F) || // Latin Extended-A
        (cp >= 0x0180 && cp <= 0x024F)) { // Latin Extended-B
      return true;
    }
  }
  return false;
}
