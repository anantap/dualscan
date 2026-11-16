#include <sane/sane.h>
#include <sane/saneopts.h>

/* Where the SANE build lives; set by the build settings. */
static inline const char *dualscan_sane_dir(void) { return SANE_DIR; }
