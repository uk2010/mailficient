#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

gchar *mailficient_mobileconfig_decode (const guint8 *data,
                                        gsize         data_length,
                                        GError      **error);

G_END_DECLS
