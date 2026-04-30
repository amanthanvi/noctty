#include <stdio.h>
#include <ghostty/vt.h>

//! [modes-pack-unpack]
void modes_example() {
  // Use the typed predefined constants instead of raw mode numbers.
  GhosttyMode tag = GHOSTTY_MODE_CURSOR_VISIBLE;
  printf("value=%u ansi=%d packed=0x%04x\n",
      ghostty_mode_value(tag),
      ghostty_mode_ansi(tag),
      tag);

  GhosttyMode ansi_tag = GHOSTTY_MODE_INSERT;
  printf("value=%u ansi=%d packed=0x%04x\n",
      ghostty_mode_value(ansi_tag),
      ghostty_mode_ansi(ansi_tag),
      ansi_tag);
}
//! [modes-pack-unpack]

//! [modes-decrpm]
void decrpm_example() {
  char buf[32];
  size_t written = 0;

  // Encode a report that DEC mode 25 (cursor visible) is set
  GhosttyResult result = ghostty_mode_report_encode(
      GHOSTTY_MODE_CURSOR_VISIBLE,
      GHOSTTY_MODE_REPORT_SET,
      buf, sizeof(buf), &written);

  if (result == GHOSTTY_SUCCESS) {
    printf("Encoded %zu bytes: ", written);
    fwrite(buf, 1, written, stdout);
    printf("\n");  // prints: ESC[?25;1$y
  }
}
//! [modes-decrpm]

int main() {
  modes_example();
  decrpm_example();
  return 0;
}
