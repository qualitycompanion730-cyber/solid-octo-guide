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
