// Names that are not one UTF-8 text line: two that differ only in a byte
// that is not UTF-8 (council round 3 on #726, Sol: both read as U+FFFD), and
// one that holds CR LF.
test "coverage\xfe" {}

test "coverage\xff" {}

test "carriage\r\nreturn" {}
