#include "mobileconfig-decoder.h"

#include <openssl/cms.h>
#include <openssl/err.h>
#include <string.h>

#define MAX_PROFILE_BYTES (5 * 1024 * 1024)

static gboolean
looks_like_xml (const guint8 *data,
                gsize         data_length)
{
    gsize offset = 0;

    if (data_length >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf)
        offset = 3;
    while (offset < data_length && g_ascii_isspace (data[offset]))
        offset++;
    return offset < data_length && data[offset] == '<';
}

static void
set_openssl_error (GError **error)
{
    unsigned long code = ERR_peek_last_error ();
    const gchar *detail = code == 0 ? NULL : ERR_reason_error_string (code);

    g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                 "The configuration profile is not valid signed CMS data%s%s",
                 detail == NULL ? "" : ": ", detail == NULL ? "" : detail);
    ERR_clear_error ();
}

gchar *
mailficient_mobileconfig_decode (const guint8 *data,
                                 gsize         data_length,
                                 GError      **error)
{
    g_return_val_if_fail (data != NULL, NULL);

    if (data_length == 0 || data_length > MAX_PROFILE_BYTES) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                     "Choose a valid, non-empty configuration profile smaller than 5 MB");
        return NULL;
    }
    if (looks_like_xml (data, data_length)) {
        if (memchr (data, '\0', data_length) != NULL) {
            g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                         "The XML configuration profile contains invalid data");
            return NULL;
        }
        return g_strndup ((const gchar *) data, data_length);
    }

    BIO *input = BIO_new_mem_buf (data, (int) data_length);
    CMS_ContentInfo *cms = input == NULL ? NULL : d2i_CMS_bio (input, NULL);
    BIO *output = BIO_new (BIO_s_mem ());
    if (input == NULL || cms == NULL || output == NULL) {
        set_openssl_error (error);
        BIO_free (output);
        CMS_ContentInfo_free (cms);
        BIO_free (input);
        return NULL;
    }

    /* Verify the content signature while allowing locally issued profile
     * certificates, which are normal for hosting-control-panel profiles. */
    if (CMS_verify (cms, NULL, NULL, NULL, output,
                    CMS_BINARY | CMS_NO_SIGNER_CERT_VERIFY) != 1) {
        set_openssl_error (error);
        BIO_free (output);
        CMS_ContentInfo_free (cms);
        BIO_free (input);
        return NULL;
    }

    char *decoded = NULL;
    long decoded_length = BIO_get_mem_data (output, &decoded);
    gchar *result = NULL;
    if (decoded_length <= 0 || decoded_length > MAX_PROFILE_BYTES ||
        memchr (decoded, '\0', (gsize) decoded_length) != NULL) {
        g_set_error (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
                     "The decoded configuration profile is empty or too large");
    } else {
        result = g_strndup (decoded, (gsize) decoded_length);
    }

    BIO_free (output);
    CMS_ContentInfo_free (cms);
    BIO_free (input);
    return result;
}
