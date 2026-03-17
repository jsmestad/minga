// Exposes sizeof(regex_t) and _Alignof(regex_t) to Zig.
// On Linux/glibc, regex_t is opaque to Zig's @cImport, so @sizeOf fails.
// The C compiler always knows the real layout from system headers.
#include <regex.h>
#include <stddef.h>

const size_t minga_regex_t_size = sizeof(regex_t);
const size_t minga_regex_t_align = _Alignof(regex_t);
