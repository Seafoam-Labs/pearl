/* Blocking printer I/O is isolated from the portal/UI process. */
#include <cups/cups.h>
#include <gio/gio.h>
#include <gio/gunixinputstream.h>
#include <malloc.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
static int destination(void *data, unsigned flags, cups_dest_t *dest) {
  if (!(flags & CUPS_DEST_FLAGS_REMOVED) && !dest->instance) {
    GVariantBuilder *b = data;
    const char *info =
        cupsGetOption("printer-info", dest->num_options, dest->options);
    if (g_utf8_validate(dest->name, -1, NULL) &&
        (!info || g_utf8_validate(info, -1, NULL)))
      g_variant_builder_add(b, "(ss)", dest->name, info ? info : dest->name);
  }
  return 1;
}
static int capabilities(const char *name) {
  cups_dest_t *dest = cupsGetNamedDest(CUPS_HTTP_DEFAULT, name, NULL);
  if (!dest)
    return 2;
  char resource[1024];
  http_t *http = cupsConnectDest(dest, 0, 5000, NULL, resource,
                                 sizeof(resource), NULL, NULL);
  if (!http) {
    cupsFreeDests(1, dest);
    return 2;
  }
  cups_dinfo_t *info = cupsCopyDestInfo(http, dest);
  if (!info) {
    httpClose(http);
    cupsFreeDests(1, dest);
    return 2;
  }
  GVariantBuilder result, papers;
  g_variant_builder_init(&result, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_init(&papers, G_VARIANT_TYPE("a(sdddddd)"));
  int count = MIN(
      128, cupsGetDestMediaCount(http, dest, info, CUPS_MEDIA_FLAGS_DEFAULT));
  for (int i = 0; i < count; i++) {
    cups_size_t media;
    if (cupsGetDestMediaByIndex(http, dest, info, i, CUPS_MEDIA_FLAGS_DEFAULT,
                                &media) &&
        g_utf8_validate(media.media, -1, NULL))
      g_variant_builder_add(&papers, "(sdddddd)", media.media,
                            media.width / 100., media.length / 100.,
                            media.top / 100., media.bottom / 100.,
                            media.left / 100., media.right / 100.);
  }
  g_variant_builder_add(&result, "{sv}", "papers",
                        g_variant_builder_end(&papers));
  const char *keys[] = {"sides", "print-color-mode"};
  for (guint i = 0; i < 2; i++) {
    GVariantBuilder values;
    g_variant_builder_init(&values, G_VARIANT_TYPE("as"));
    ipp_attribute_t *attr = cupsFindDestSupported(http, dest, info, keys[i]);
    for (int j = 0; attr && j < MIN(32, ippGetCount(attr)); j++) {
      const char *value = ippGetString(attr, j, NULL);
      if (value && g_utf8_validate(value, -1, NULL))
        g_variant_builder_add(&values, "s", value);
    }
    g_variant_builder_add(&result, "{sv}", keys[i],
                          g_variant_builder_end(&values));
  }
  ipp_attribute_t *copies = cupsFindDestSupported(http, dest, info, "copies");
  int upper = 1;
  if (copies && ippGetValueTag(copies) == IPP_TAG_RANGE)
    ippGetRange(copies, 0, &upper);
  g_variant_builder_add(&result, "{sv}", "copies",
                        g_variant_new_uint32(CLAMP(upper, 1, 999)));
  g_autoptr(GVariant) value =
      g_variant_ref_sink(g_variant_builder_end(&result));
  g_autofree char *text = g_variant_print(value, TRUE);
  g_print("%s", text);
  cupsFreeDestInfo(info);
  httpClose(http);
  cupsFreeDests(1, dest);
  return 0;
}
int pearl_print_worker(int argc, char **argv) {
  mallopt(M_ARENA_MAX, 2);
  alarm(60);
  struct rlimit limit = {512 * 1024 * 1024, 512 * 1024 * 1024};
  setrlimit(RLIMIT_AS, &limit);
  if (argc == 3 && !strcmp(argv[2], "list")) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a(ss)"));
    cupsEnumDests(CUPS_DEST_FLAGS_NONE, 2500, NULL, 0, 0, destination, &b);
    g_autoptr(GVariant) result = g_variant_ref_sink(g_variant_builder_end(&b));
    g_autofree char *text = g_variant_print(result, TRUE);
    g_print("%s", text);
    return 0;
  }
  if (argc == 4 && !strcmp(argv[2], "capabilities"))
    return capabilities(argv[3]);
  struct stat st;
  char magic[4096];
  ssize_t length;
  if (fstat(3, &st) || !S_ISREG(st.st_mode) || st.st_size < 5 ||
      st.st_size > 256 * 1024 * 1024 ||
      (length = pread(3, magic, sizeof(magic), 0)) < 5)
    return 2;
  const char *format = !memcmp(magic, "%PDF-", 5)   ? "pdf"
                       : !memcmp(magic, "%!PS-", 5) ? "ps"
                                                    : NULL;
  if (!format && !strcmp(argv[2], "file")) {
    g_autofree char *type =
        g_content_type_guess(NULL, (guchar *)magic, length, NULL);
    if (g_strcmp0(type, "image/svg+xml") == 0)
      format = "svg";
  }
  if (!format)
    return 2;
  if (lseek(3, 0, SEEK_SET) < 0)
    return 2;
  if ((argc == 5 || argc == 6) && !strcmp(argv[2], "file")) {
    if (argc == 6 && strcmp(format, argv[5]))
      return 2;
    g_autoptr(GFile) file = g_file_new_for_uri(argv[3]);
    if (!g_file_is_native(file))
      return 2;
    g_autoptr(GFileOutputStream) output = NULL;
    if (!strcmp(argv[4], "new"))
      output = g_file_create(file, G_FILE_CREATE_NONE, NULL, NULL);
    else if (g_str_has_prefix(argv[4], "etag:"))
      output = g_file_replace(file, argv[4] + 5, FALSE, G_FILE_CREATE_NONE,
                              NULL, NULL);
    if (!output)
      return 2;
    g_autoptr(GInputStream) input = g_unix_input_stream_new(3, FALSE);
    if (g_output_stream_splice(G_OUTPUT_STREAM(output), input,
                               G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET, NULL,
                               NULL) < 0)
      return 2;
    return 0;
  }
  if (argc != 7 || strcmp(argv[2], "submit"))
    return 2;
  cups_dest_t *dest = cupsGetNamedDest(CUPS_HTTP_DEFAULT, argv[3], NULL);
  if (!dest)
    return 2;
  cups_option_t *options = NULL;
  int count = 0;
  g_autoptr(GVariant) settings =
      g_variant_parse(G_VARIANT_TYPE("a{ss}"), argv[5], NULL, NULL, NULL);
  if (!settings) {
    cupsFreeDests(1, dest);
    return 2;
  }
  GVariantIter it;
  const char *key, *value;
  g_variant_iter_init(&it, settings);
  while (g_variant_iter_next(&it, "{&s&s}", &key, &value))
    count = cupsAddOption(key, value, count, &options);
  count = cupsAddOption("document-format",
                        !memcmp(magic, "%PDF-", 5) ? "application/pdf"
                                                   : "application/postscript",
                        count, &options);
  int id =
      cupsPrintFile(dest->name, "/proc/self/fd/3", argv[4], count, options);
  cupsFreeOptions(count, options);
  cupsFreeDests(1, dest);
  return id > 0 ? 0 : 2;
}
