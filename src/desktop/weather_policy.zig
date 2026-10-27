//! Pure weather configuration, Open-Meteo parsing and WMO presentation.
//! Network access belongs to the service layer; everything here is testable.
const std = @import("std");

pub const Units = enum {
    celsius,
    fahrenheit,
    pub fn label(self: Units) [:0]const u8 {
        return switch (self) {
            .celsius => @import("i18n").dtr("pearl", "Celsius (°C)"),
            .fahrenheit => @import("i18n").dtr("pearl", "Fahrenheit (°F)"),
        };
    }
    pub fn query(self: Units) []const u8 {
        return switch (self) {
            .celsius => "celsius",
            .fahrenheit => "fahrenheit",
        };
    }
};

/// Defaults to New York until the user picks a location in Bar & dock settings.
pub const Config = struct {
    location: []const u8 = "New York",
    latitude: f64 = 40.71427,
    longitude: f64 = -74.00597,
    units: Units = .celsius,
    pub fn validate(self: Config) !void {
        if (self.location.len == 0 or self.location.len > 128) return error.InvalidWeatherLocation;
        if (!std.unicode.utf8ValidateSlice(self.location)) return error.InvalidWeatherLocation;
        for (self.location) |ch| if (ch < 32 or ch == 127) return error.InvalidWeatherLocation;
        if (!(self.latitude >= -90 and self.latitude <= 90)) return error.InvalidWeatherCoordinates;
        if (!(self.longitude >= -180 and self.longitude <= 180)) return error.InvalidWeatherCoordinates;
    }
    /// Content equality; meta.eql compares slices by pointer identity, which
    /// would read every rotated preferences arena as a location change.
    pub fn eql(a: Config, b: Config) bool {
        return std.mem.eql(u8, a.location, b.location) and a.latitude == b.latitude and a.longitude == b.longitude and a.units == b.units;
    }
};

pub const Current = struct { temperature: f64, code: i32, is_day: bool };
pub const Place = struct { name: []const u8, region: []const u8, latitude: f64, longitude: f64 };
pub const Hour = struct { time: i64, temperature: f64, code: i32, is_day: bool };
pub const Day = struct { time: i64, code: i32, min: f64, max: f64 };
pub const max_hours = 24;
pub const max_days = 7;
/// Plain data so the service can own a snapshot by value. `utc_offset` shifts
/// the location's unix timestamps into its own local wall time.
pub const Forecast = struct {
    current: Current,
    utc_offset: i32 = 0,
    hour_count: usize = 0,
    hours: [max_hours]Hour = undefined,
    day_count: usize = 0,
    days: [max_days]Day = undefined,
};

pub fn forecastUrl(alloc: std.mem.Allocator, config: Config) ![:0]const u8 {
    try config.validate();
    return std.fmt.allocPrintSentinel(alloc, "https://api.open-meteo.com/v1/forecast?latitude={d}&longitude={d}&current=temperature_2m,weather_code,is_day&hourly=temperature_2m,weather_code,is_day&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_hours=24&forecast_days=7&temperature_unit={s}&timezone=auto&timeformat=unixtime", .{ config.latitude, config.longitude, config.units.query() }, 0);
}

pub fn searchUrl(alloc: std.mem.Allocator, query: []const u8) ![:0]const u8 {
    if (query.len == 0 or query.len > 128) return error.InvalidWeatherLocation;
    const hex_digits = "0123456789ABCDEF";
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(alloc);
    for (query) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') try encoded.append(alloc, ch) else {
            try encoded.appendSlice(alloc, &[_]u8{ '%', hex_digits[ch >> 4], hex_digits[ch & 0xf] });
        }
    }
    return std.fmt.allocPrintSentinel(alloc, "https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&format=json&name={s}", .{encoded.items}, 0);
}

pub fn parseForecast(alloc: std.mem.Allocator, bytes: []const u8) ?Forecast {
    const Hourly = struct { time: []const i64 = &.{}, temperature_2m: []const f64 = &.{}, weather_code: []const i32 = &.{}, is_day: []const u8 = &.{} };
    const Daily = struct { time: []const i64 = &.{}, weather_code: []const i32 = &.{}, temperature_2m_max: []const f64 = &.{}, temperature_2m_min: []const f64 = &.{} };
    const Response = struct {
        utc_offset_seconds: i32 = 0,
        current: struct { temperature_2m: f64, weather_code: i32, is_day: u8 },
        hourly: Hourly = .{},
        daily: Daily = .{},
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const response = std.json.parseFromSliceLeaky(Response, arena.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return null;
    var forecast: Forecast = .{
        .current = .{ .temperature = response.current.temperature_2m, .code = response.current.weather_code, .is_day = response.current.is_day != 0 },
        .utc_offset = response.utc_offset_seconds,
    };
    const h = response.hourly;
    forecast.hour_count = @min(@min(@min(h.time.len, h.temperature_2m.len), @min(h.weather_code.len, h.is_day.len)), max_hours);
    for (forecast.hours[0..forecast.hour_count], h.time[0..forecast.hour_count], h.temperature_2m[0..forecast.hour_count], h.weather_code[0..forecast.hour_count], h.is_day[0..forecast.hour_count]) |*slot, time, temperature, code, day| {
        slot.* = .{ .time = time, .temperature = temperature, .code = code, .is_day = day != 0 };
    }
    const d = response.daily;
    forecast.day_count = @min(@min(@min(d.time.len, d.weather_code.len), @min(d.temperature_2m_max.len, d.temperature_2m_min.len)), max_days);
    for (forecast.days[0..forecast.day_count], d.time[0..forecast.day_count], d.weather_code[0..forecast.day_count], d.temperature_2m_max[0..forecast.day_count], d.temperature_2m_min[0..forecast.day_count]) |*slot, time, code, max, min| {
        slot.* = .{ .time = time, .code = code, .max = max, .min = min };
    }
    return forecast;
}

pub fn parsePlaces(alloc: std.mem.Allocator, bytes: []const u8, max: usize) ![]Place {
    const Entry = struct { name: []const u8, admin1: ?[]const u8 = null, country: ?[]const u8 = null, latitude: f64, longitude: f64 };
    const Response = struct { results: []const Entry = &.{} };
    // The parser's own allocations live and die in this arena; only the Place
    // fields escape, each a standalone `alloc` allocation callers can free.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const response = try std.json.parseFromSliceLeaky(Response, arena.allocator(), bytes, .{ .ignore_unknown_fields = true });
    var list: std.ArrayList(Place) = .empty;
    for (response.results[0..@min(response.results.len, max)]) |entry| {
        const region: []const u8 = if (entry.admin1) |admin| if (entry.country) |country| try std.fmt.allocPrint(alloc, "{s}, {s}", .{ admin, country }) else try alloc.dupe(u8, admin) else if (entry.country) |country| try alloc.dupe(u8, country) else try alloc.dupe(u8, "");
        errdefer alloc.free(region);
        try list.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .region = region, .latitude = entry.latitude, .longitude = entry.longitude });
    }
    return try list.toOwnedSlice(alloc);
}

/// WMO weather interpretation codes, as published by Open-Meteo.
pub fn icon(code: i32, night: bool) [:0]const u8 {
    return switch (code) {
        0 => if (night) "pearl-weather-clear-night-symbolic" else "pearl-weather-clear-symbolic",
        1, 2 => if (night) "pearl-weather-few-clouds-night-symbolic" else "pearl-weather-few-clouds-symbolic",
        3 => "pearl-weather-overcast-symbolic",
        45, 48 => "pearl-weather-fog-symbolic",
        51...57, 61...67, 80...82 => "pearl-weather-showers-symbolic",
        71...77, 85, 86 => "pearl-weather-snow-symbolic",
        95, 96, 99 => "pearl-weather-storm-symbolic",
        else => if (night) "pearl-weather-clear-night-symbolic" else "pearl-weather-clear-symbolic",
    };
}

pub fn condition(code: i32) [:0]const u8 {
    return switch (code) {
        0 => @import("i18n").dtr("pearl", "Clear sky"),
        1 => @import("i18n").dtr("pearl", "Mainly clear"),
        2 => @import("i18n").dtr("pearl", "Partly cloudy"),
        3 => @import("i18n").dtr("pearl", "Overcast"),
        45, 48 => @import("i18n").dtr("pearl", "Fog"),
        51, 53, 55 => @import("i18n").dtr("pearl", "Drizzle"),
        56, 57 => @import("i18n").dtr("pearl", "Freezing drizzle"),
        61, 63, 65 => @import("i18n").dtr("pearl", "Rain"),
        66, 67 => @import("i18n").dtr("pearl", "Freezing rain"),
        71, 73, 75 => @import("i18n").dtr("pearl", "Snowfall"),
        77 => @import("i18n").dtr("pearl", "Snow grains"),
        80, 81, 82 => @import("i18n").dtr("pearl", "Rain showers"),
        85, 86 => @import("i18n").dtr("pearl", "Snow showers"),
        95 => @import("i18n").dtr("pearl", "Thunderstorm"),
        96, 99 => @import("i18n").dtr("pearl", "Thunderstorm with hail"),
        else => @import("i18n").dtr("pearl", "Weather"),
    };
}

test "weather config defaults to New York and rejects unsafe or out-of-range values" {
    const t = std.testing;
    try (Config{}).validate();
    try t.expectError(error.InvalidWeatherLocation, (Config{ .location = "" }).validate());
    try t.expectError(error.InvalidWeatherLocation, (Config{ .location = "a" ** 129 }).validate());
    try t.expectError(error.InvalidWeatherLocation, (Config{ .location = "Berlin\x7f" }).validate());
    try t.expectError(error.InvalidWeatherCoordinates, (Config{ .latitude = 90.5 }).validate());
    try t.expectError(error.InvalidWeatherCoordinates, (Config{ .longitude = -181 }).validate());
    try t.expectError(error.InvalidWeatherLocation, forecastUrl(t.allocator, .{ .location = "" }));
}

test "open-meteo urls are built from coordinates, units and escaped queries" {
    const t = std.testing;
    const forecast = try forecastUrl(t.allocator, .{});
    defer t.allocator.free(forecast);
    try t.expectEqualStrings("https://api.open-meteo.com/v1/forecast?latitude=40.71427&longitude=-74.00597&current=temperature_2m,weather_code,is_day&hourly=temperature_2m,weather_code,is_day&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_hours=24&forecast_days=7&temperature_unit=celsius&timezone=auto&timeformat=unixtime", forecast);
    const fahrenheit = try forecastUrl(t.allocator, .{ .units = .fahrenheit });
    defer t.allocator.free(fahrenheit);
    try t.expect(std.mem.indexOf(u8, fahrenheit, "temperature_unit=fahrenheit") != null);
    const search = try searchUrl(t.allocator, "New York");
    defer t.allocator.free(search);
    try t.expectEqualStrings("https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&format=json&name=New%20York", search);
    try t.expectError(error.InvalidWeatherLocation, searchUrl(t.allocator, ""));
}

test "forecast parsing fills current, hourly and daily series from one payload" {
    const t = std.testing;
    const forecast = parseForecast(t.allocator,
        \\{"utc_offset_seconds":-14400,"timezone":"America/New_York",
        \\ "current":{"time":1782000000,"interval":900,"temperature_2m":18.3,"weather_code":61,"is_day":1},
        \\ "hourly":{"time":[1782000000,1782003600,1782007200],"temperature_2m":[18.3,17.8,17.1],"weather_code":[61,63,3],"is_day":[1,1,0]},
        \\ "daily":{"time":[1781985600,1782072000],"weather_code":[95,0],"temperature_2m_max":[22.5,19.0],"temperature_2m_min":[12.1,9.8]}}
    ).?;
    try t.expectApproxEqAbs(@as(f64, 18.3), forecast.current.temperature, 0.001);
    try t.expectEqual(@as(i32, 61), forecast.current.code);
    try t.expect(forecast.current.is_day);
    try t.expectEqual(@as(i32, -14400), forecast.utc_offset);
    try t.expectEqual(@as(usize, 3), forecast.hour_count);
    try t.expectEqual(@as(i64, 1782003600), forecast.hours[1].time);
    try t.expectApproxEqAbs(@as(f64, 17.1), forecast.hours[2].temperature, 0.001);
    try t.expect(!forecast.hours[2].is_day);
    try t.expectEqual(@as(usize, 2), forecast.day_count);
    try t.expectEqual(@as(i32, 95), forecast.days[0].code);
    try t.expectApproxEqAbs(@as(f64, 12.1), forecast.days[0].min, 0.001);
    try t.expectApproxEqAbs(@as(f64, 19.0), forecast.days[1].max, 0.001);
    // A payload without series still yields the current conditions.
    const bare = parseForecast(t.allocator, "{\"current\":{\"temperature_2m\":1,\"weather_code\":0,\"is_day\":0}}").?;
    try t.expectEqual(@as(usize, 0), bare.hour_count);
    try t.expectEqual(@as(usize, 0), bare.day_count);
    try t.expect(parseForecast(t.allocator, "{\"current\":{}}") == null);
    try t.expect(parseForecast(t.allocator, "not json") == null);
}

test "geocoding results join region parts and honor the result cap" {
    const t = std.testing;
    const places = try parsePlaces(t.allocator,
        \\{"results":[{"name":"Paris","admin1":"Île-de-France","country":"France","latitude":48.85,"longitude":2.35},{"name":"Oslo","country":"Norway","latitude":59.91,"longitude":10.75},{"name":"Extra","latitude":1,"longitude":2}]}
    , 2);
    defer {
        for (places) |place| {
            t.allocator.free(place.name);
            t.allocator.free(place.region);
        }
        t.allocator.free(places);
    }
    try t.expectEqual(@as(usize, 2), places.len);
    try t.expectEqualStrings("Paris", places[0].name);
    try t.expectEqualStrings("Île-de-France, France", places[0].region);
    try t.expectEqualStrings("Norway", places[1].region);
    const empty = try parsePlaces(t.allocator, "{}", 8);
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
}

test "wmo codes map onto day and night icon sets" {
    const t = std.testing;
    try t.expectEqualStrings("pearl-weather-clear-symbolic", icon(0, false));
    try t.expectEqualStrings("pearl-weather-clear-night-symbolic", icon(0, true));
    try t.expectEqualStrings("pearl-weather-few-clouds-night-symbolic", icon(2, true));
    try t.expectEqualStrings("pearl-weather-overcast-symbolic", icon(3, true));
    try t.expectEqualStrings("pearl-weather-fog-symbolic", icon(48, false));
    try t.expectEqualStrings("pearl-weather-showers-symbolic", icon(65, false));
    try t.expectEqualStrings("pearl-weather-snow-symbolic", icon(77, true));
    try t.expectEqualStrings("pearl-weather-storm-symbolic", icon(99, false));
    try t.expect(condition(0).len > 0);
}
