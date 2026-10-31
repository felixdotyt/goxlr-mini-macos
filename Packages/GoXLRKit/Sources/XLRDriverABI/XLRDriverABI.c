// Layout checks for XLRDriverABI.h; the dext and GoXLRKit must agree byte for byte.

#include "XLRDriverABI.h"

_Static_assert(sizeof(XLRDriverInfo) == 136, "XLRDriverInfo layout");
_Static_assert(sizeof(XLRCommandHeader) == 12, "XLRCommandHeader layout");
_Static_assert(sizeof(XLRCommandReplyHeader) == 24, "XLRCommandReplyHeader layout");
