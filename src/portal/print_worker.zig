const ffi = @import("ffi.zig");
const identity = @import("identity.zig");

pub fn destination(data: ?*anyopaque, flags: c_uint, dest: [*c]ffi.cups_dest_t) callconv(.c) c_int {
    if (!((flags & @as(c_uint, 4)) != 0) and dest.*.instance == null) {
        const b: [*c]ffi.GVariantBuilder = @ptrCast(@alignCast(data));
        const info: [*c]const u8 = ffi.cupsGetOption("printer-info", dest.*.num_options, dest.*.options);
        if ((ffi.g_utf8_validate(dest.*.name, -1, null) != 0) and (info == null or (ffi.g_utf8_validate(info, -1, null) != 0))) {
            ffi.g_variant_builder_add(b, "(ss)", dest.*.name, if (info != null) info else ffi.cast([*c]const u8, dest.*.name));
        }
    }
    return 1;
}

pub fn capabilities(name: [*c]const u8) callconv(.c) c_int {
    const dest: [*c]ffi.cups_dest_t = ffi.cupsGetNamedDest(null, name, null);
    if (dest == null) return 2;
    var resource: [1024]u8 = undefined;
    const http: ?*ffi.http_t = ffi.cupsConnectDest(dest, 0, 5000, null, @ptrCast(@alignCast(&resource)), @sizeOf(@TypeOf(resource)), null, null);
    if (http == null) {
        ffi.cupsFreeDests(1, dest);
        return 2;
    }
    const info: ?*ffi.cups_dinfo_t = ffi.cupsCopyDestInfo(http, dest);
    if (info == null) {
        ffi.httpClose(http);
        ffi.cupsFreeDests(1, dest);
        return 2;
    }
    var result: ffi.GVariantBuilder = undefined;
    var papers: ffi.GVariantBuilder = undefined;
    ffi.g_variant_builder_init(&result, ffi.cast(?*const ffi.GVariantType, "a{sv}"));
    ffi.g_variant_builder_init(&papers, ffi.g_variant_type_checked_("a(sdddddd)"));
    const count: c_int = if (@as(c_int, 128) < ffi.cupsGetDestMediaCount(http, dest, info, 0)) @as(c_int, 128) else ffi.cupsGetDestMediaCount(http, dest, info, 0);
    {
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            var media: ffi.cups_size_t = undefined;
            if ((ffi.cupsGetDestMediaByIndex(http, dest, info, i, 0, &media) != 0) and (ffi.g_utf8_validate(@ptrCast(@alignCast(&media.media)), -1, null) != 0)) {
                ffi.g_variant_builder_add(&papers, "(sdddddd)", ffi.cast([*c]u8, &media.media), @as(f64, @floatFromInt(media.width)) / @as(f64, 100.0), @as(f64, @floatFromInt(media.length)) / @as(f64, 100.0), @as(f64, @floatFromInt(media.top)) / @as(f64, 100.0), @as(f64, @floatFromInt(media.bottom)) / @as(f64, 100.0), @as(f64, @floatFromInt(media.left)) / @as(f64, 100.0), @as(f64, @floatFromInt(media.right)) / @as(f64, 100.0));
            }
        }
    }
    ffi.g_variant_builder_add(&result, "{sv}", @constCast("papers"), ffi.g_variant_builder_end(&papers));
    const keys: [2][*c]const u8 = [2][*c]const u8{
        "sides",
        "print-color-mode",
    };
    {
        var i: ffi.guint = 0;
        while (i < @as(ffi.guint, 2)) : (i +%= 1) {
            var values: ffi.GVariantBuilder = undefined;
            ffi.g_variant_builder_init(&values, ffi.g_variant_type_checked_("as"));
            const attr: ?*ffi.ipp_attribute_t = ffi.cupsFindDestSupported(http, dest, info, keys[i]);
            {
                var j: c_int = 0;
                while ((attr != null) and (j < (if (@as(c_int, 32) < ffi.ippGetCount(attr)) @as(c_int, 32) else ffi.ippGetCount(attr)))) : (j += 1) {
                    const value: [*c]const u8 = ffi.ippGetString(attr, j, null);
                    if ((value != null) and (ffi.g_utf8_validate(value, -1, null) != 0)) {
                        ffi.g_variant_builder_add(&values, "s", value);
                    }
                }
            }
            ffi.g_variant_builder_add(&result, "{sv}", keys[i], ffi.g_variant_builder_end(&values));
        }
    }
    const copies: ?*ffi.ipp_attribute_t = ffi.cupsFindDestSupported(http, dest, info, "copies");
    var upper: c_int = 1;
    if ((copies != null) and (ffi.ippGetValueTag(copies) == ffi.IPP_TAG_RANGE)) {
        _ = ffi.ippGetRange(copies, 0, &upper);
    }
    ffi.g_variant_builder_add(&result, "{sv}", @constCast("copies"), ffi.g_variant_new_uint32(@bitCast(@as(c_int, if (upper > @as(c_int, 999)) @as(c_int, 999) else if (upper < 1) 1 else upper))));
    const value: ?*ffi.GVariant = ffi.g_variant_ref_sink(ffi.g_variant_builder_end(&result));
    defer if (value != null) ffi.g_variant_unref(@ptrCast(value));
    const text: [*c]u8 = ffi.g_variant_print(value, 1);
    defer if (text != null) ffi.g_free(@ptrCast(text));
    ffi.g_print("%s", text);
    ffi.cupsFreeDestInfo(info);
    ffi.httpClose(http);
    ffi.cupsFreeDests(1, dest);
    return 0;
}

pub fn pearl_print_worker(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    _ = ffi.mallopt(-@as(c_int, 8), 2);
    _ = ffi.alarm(60);
    var limit: ffi.struct_rlimit = ffi.struct_rlimit{
        .rlim_cur = @bitCast(@as(c_long, (@as(c_int, 512) * @as(c_int, 1024)) * @as(c_int, 1024))),
        .rlim_max = @bitCast(@as(c_long, (@as(c_int, 512) * @as(c_int, 1024)) * @as(c_int, 1024))),
    };
    _ = ffi.setrlimit(ffi.RLIMIT_AS, &limit);
    if ((argc == @as(c_int, 3)) and ffi.strcmp(argv[@as(c_int, 2)], "list") == 0) {
        var b: ffi.GVariantBuilder = undefined;
        ffi.g_variant_builder_init(&b, ffi.g_variant_type_checked_("a(ss)"));
        _ = ffi.cupsEnumDests(0, 2500, null, 0, 0, destination, @ptrCast(@alignCast(&b)));
        const result: ?*ffi.GVariant = ffi.g_variant_ref_sink(ffi.g_variant_builder_end(&b));
        defer if (result != null) ffi.g_variant_unref(@ptrCast(result));
        const text: [*c]u8 = ffi.g_variant_print(result, 1);
        defer if (text != null) ffi.g_free(@ptrCast(text));
        ffi.g_print("%s", text);
        return 0;
    }
    if ((argc == @as(c_int, 4)) and ffi.strcmp(argv[@as(c_int, 2)], "capabilities") == 0) return capabilities(argv[@as(c_int, 3)]);
    var st: ffi.struct_stat = undefined;
    var magic: [4096]u8 = undefined;
    var length: isize = undefined;
    if (((((ffi.fstat(3, &st) != 0) or !((st.st_mode & @as(ffi.__mode_t, 61440)) == @as(ffi.__mode_t, @bitCast(@as(c_int, @as(c_int, 32768)))))) or (st.st_size < @as(ffi.__off_t, 5))) or (st.st_size > @as(ffi.__off_t, (@as(c_int, 256) * @as(c_int, 1024)) * @as(c_int, 1024)))) or ((blk: {
        const tmp = ffi.pread(3, @ptrCast(@alignCast(ffi.cast([*c]u8, &magic))), @sizeOf(@TypeOf(magic)), 0);
        length = tmp;
        break :blk tmp;
    }) < @as(isize, 5))) return 2;
    var format: [*c]const u8 = @ptrCast(@alignCast(if (ffi.memcmp(@ptrCast(@alignCast(ffi.cast([*c]u8, &magic))), @ptrCast(@alignCast(@constCast("%PDF-"))), 5) == 0) ffi.cast(?*anyopaque, "pdf") else if (ffi.memcmp(@ptrCast(@alignCast(ffi.cast([*c]u8, &magic))), @ptrCast(@alignCast(@constCast("%!PS-"))), 5) == 0) ffi.cast(?*anyopaque, "ps") else null));
    if (format == null and ffi.strcmp(argv[@as(c_int, 2)], "file") == 0) {
        const @"type": [*c]u8 = ffi.g_content_type_guess(null, @ptrCast(@alignCast(ffi.cast([*c]u8, &magic))), @bitCast(@as(c_long, length)), null);
        defer if (@"type" != null) ffi.g_free(@ptrCast(@"type"));
        if (ffi.g_strcmp0(@"type", "image/svg+xml") == 0) {
            format = "svg";
        }
    }
    if (format == null) return 2;
    if (ffi.lseek(3, 0, 0) < @as(ffi.__off_t, 0)) return 2;
    if (((argc == @as(c_int, 5)) or (argc == @as(c_int, 6))) and ffi.strcmp(argv[@as(c_int, 2)], "file") == 0) {
        if ((argc == @as(c_int, 6)) and (ffi.strcmp(format, argv[@as(c_int, 5)]) != 0)) return 2;
        const file: ?*ffi.GFile = ffi.g_file_new_for_uri(argv[@as(c_int, 3)]);
        defer if (file != null) ffi.g_object_unref(@ptrCast(file));
        if (ffi.g_file_is_native(file) == 0) return 2;
        var output: [*c]ffi.GFileOutputStream = null;
        defer if (output != null) ffi.g_object_unref(@ptrCast(output));
        if (ffi.strcmp(argv[@as(c_int, 4)], "new") == 0) {
            output = ffi.g_file_create(file, ffi.G_FILE_CREATE_NONE, null, null);
        } else if ((ffi.g_str_has_prefix(argv[@as(c_int, 4)], "etag:")) != 0) {
            output = ffi.g_file_replace(file, argv[@as(c_int, 4)] + @as(usize, @bitCast(@as(isize, @intCast(@as(c_int, 5))))), 0, ffi.G_FILE_CREATE_NONE, null, null);
        }
        if (output == null) return 2;
        const input: [*c]ffi.GInputStream = ffi.g_unix_input_stream_new(3, 0);
        defer if (input != null) ffi.g_object_unref(@ptrCast(input));
        if (ffi.g_output_stream_splice(ffi.cast([*c]ffi.GOutputStream, output), input, ffi.G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET, null, null) < @as(ffi.gssize, 0)) return 2;
        return 0;
    }
    if ((argc != @as(c_int, 7)) or (ffi.strcmp(argv[@as(c_int, 2)], "submit") != 0)) return 2;
    const dest: [*c]ffi.cups_dest_t = ffi.cupsGetNamedDest(null, argv[@as(c_int, 3)], null);
    if (dest == null) return 2;
    var options: [*c]ffi.cups_option_t = null;
    var count: c_int = 0;
    const settings: ?*ffi.GVariant = ffi.g_variant_parse(ffi.g_variant_type_checked_("a{ss}"), argv[@as(c_int, 5)], null, null, null);
    defer if (settings != null) ffi.g_variant_unref(@ptrCast(settings));
    if (settings == null) {
        ffi.cupsFreeDests(1, dest);
        return 2;
    }
    var it: ffi.GVariantIter = undefined;
    var key: [*c]const u8 = undefined;
    var value: [*c]const u8 = undefined;
    _ = ffi.g_variant_iter_init(&it, settings);
    while (ffi.g_variant_iter_next(&it, "{&s&s}", &key, &value) != 0) {
        count = ffi.cupsAddOption(key, value, count, &options);
    }
    count = ffi.cupsAddOption("document-format", if (ffi.memcmp(@ptrCast(@alignCast(ffi.cast([*c]u8, &magic))), @ptrCast(@alignCast(@constCast("%PDF-"))), 5) == 0) @constCast("application/pdf") else @constCast("application/postscript"), count, &options);
    const id: c_int = ffi.cupsPrintFile(dest.*.name, "/proc/self/fd/3", argv[@as(c_int, 4)], count, options);
    ffi.cupsFreeOptions(count, options);
    ffi.cupsFreeDests(1, dest);
    return if (id > 0) 0 else @as(c_int, 2);
}
