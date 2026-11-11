//! Real subprocess/pipe integration tests. Python is test fixture code ONLY.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const os = @import("../terminal/ownership.zig").os;
const a = std.testing.allocator;
const Value = std.json.Value;

fn now() u64 {
    return @intCast(os.nowMs());
}
fn pause() void {
    var fds: [0]os.PollFd = .{};
    _ = os.poll(&fds, 0, 1);
}
fn config(argv: []const []const u8) client.Config {
    return .{ .transport = .{ .authorization = .approved, .argv = argv, .cwd = "/", .timeout_ms = 5000, .input_limit = 1024 * 1024, .output_limit = 1024 * 1024 }, .root = "/tmp/project space", .language_id = "zig" };
}
fn start(mode: []const u8) !*client.Client {
    return client.Client.init(a, config(&.{ "/bin/python3", "-u", "-c", server, mode }));
}
fn cleanup(c: *client.Client) void {
    c.stop() catch {};
    const deadline = now() + 7000;
    while (!c.isDrained()) {
        c.tick(now()) catch {};
        while (c.nextEvent()) |e| {
            var event = e;
            event.deinit();
        }
        if (now() >= deadline) @panic("client cleanup timed out");
        pause();
    }
    c.destroy() catch unreachable;
}
fn eventOf(c: *client.Client, kind: client.Event.Kind) !client.Event {
    const deadline = now() + 3500;
    while (now() < deadline) {
        try c.tick(now());
        while (c.nextEvent()) |e| {
            var event = e;
            if (event.kind == kind) return event;
            event.deinit();
        }
        if (c.isDrained()) return error.UnexpectedCompletion;
        pause();
    }
    return error.TestTimeout;
}
fn ready(c: *client.Client) !void {
    var event = try eventOf(c, .ready);
    defer event.deinit();
    try std.testing.expectEqual(client.State.ready, c.state);
}
fn parsed(bytes: []const u8) !std.json.Parsed(Value) {
    return protocol.parseMessage(a, bytes);
}
fn result(event: *const client.Event) Value {
    return protocol.field(event.value(), "result") orelse .null;
}
fn finish(c: *client.Client) !void {
    const deadline = now() + 6500;
    while (!c.isDrained()) {
        c.tick(now()) catch {};
        if (now() > deadline) return error.TestTimeout;
        pause();
    }
}

const server =
    \\import sys, json, os, time, signal
    \\mode = sys.argv[1]
    \\def send(v):
    \\    b=json.dumps(v,separators=(',',':')).encode()
    \\    frame=b'Content-Length: '+str(len(b)).encode()+b'\r\n\r\n'+b
    \\    if mode == 'fragmented':
    \\        for i in range(0,len(frame),7): os.write(1,frame[i:i+7]); time.sleep(.0001)
    \\    else: sys.stdout.buffer.write(frame); sys.stdout.buffer.flush()
    \\def response(i,r): send({'jsonrpc':'2.0','id':i,'result':r})
    \\def note(m,p): send({'jsonrpc':'2.0','method':m,'params':p})
    \\def req(i,m,p): send({'jsonrpc':'2.0','id':i,'method':m,'params':p})
    \\def close_output(trailer=b''):
    \\    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    \\    if trailer: os.write(1,trailer)
    \\    os.close(1)
    \\    time.sleep(20)
    \\def read():
    \\    h={}
    \\    while True:
    \\        l=sys.stdin.buffer.readline()
    \\        if not l: sys.exit(0)
    \\        if l==b'\r\n': break
    \\        k,v=l.decode().split(':',1); h[k.lower()]=v.strip()
    \\    return json.loads(sys.stdin.buffer.read(int(h['content-length'])))
    \\init=read()
    \\assert init['method']=='initialize'
    \\assert init['params']['rootUri']=='file:///tmp/project%20space'
    \\if mode!='custom': assert 'completion' not in init['params']['capabilities']['textDocument']
    \\assert init['params']['capabilities']['general']['positionEncodings']==['utf-8','utf-16','utf-32']
    \\assert os.environ.get('SECRET_HOST_TOKEN') is None
    \\if mode=='silent': time.sleep(20)
    \\if mode=='eof_init': close_output()
    \\if mode=='eof_init_truncated': close_output(b'Content-Length: 42\r\n\r\n{')
    \\if mode=='rejected': send({'jsonrpc':'2.0','id':1,'error':{'code':-32002,'message':'no'}}); time.sleep(20)
    \\encoding={'utf8':'utf-8','utf32':'utf-32','bad_encoding':'unknown'}.get(mode,'utf-16')
    \\sync={'openClose':True,'change':2,'save':{'includeText':True},'willSave':True}
    \\if mode=='full': sync=1
    \\if mode=='none': sync=0
    \\caps={'positionEncoding':encoding,'textDocumentSync':sync,'hoverProvider':True,'completionProvider':{'triggerCharacters':['.']},'workspace':{'workspaceFolders':{'supported':True}}}
    \\if mode=='large_caps': caps['extension']='x'*270000
    \\if mode=='default_encoding': del caps['positionEncoding']
    \\if mode=='save_no_text': caps['textDocumentSync']['save']=True
    \\response(init['id'],{'capabilities':caps})
    \\assert read()['method']=='initialized'
    \\if mode=='blocked': note('test/blocked',{}); time.sleep(20)
    \\docs={}; held=[]; seen=[]
    \\while True:
    \\    m=read(); method=m.get('method'); p=m.get('params'); i=m.get('id')
    \\    if method is None:
    \\        note('test/serverResponse',m); continue
    \\    if method=='shutdown':
    \\        if mode=='ignore_shutdown': signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)
    \\        if mode=='eof_shutdown_no_response': close_output()
    \\        if mode=='eof_shutdown_burst':
    \\            for n in range(40): note('window/logMessage',{'type':3,'message':'shutdown'})
    \\        response(i,None)
    \\        if mode.startswith('eof_shutdown'):
    \\            signal.signal(signal.SIGTERM,signal.SIG_IGN)
    \\            if mode=='eof_shutdown_truncated': os.write(1,b'Content-Length: 42\r\n\r\n{')
    \\            os.close(1)
    \\            assert read()['method']=='exit'
    \\            assert sys.stdin.buffer.read()==b''
    \\            if mode=='eof_shutdown_exit': sys.exit(0)
    \\            time.sleep(20)
    \\    elif method=='exit': sys.exit(0)
    \\    elif method=='test/echo': response(i,p)
    \\    elif method=='test/init': response(i,init['params'])
    \\    elif method=='test/hold': held.append(m)
    \\    elif method=='test/release':
    \\        for r in reversed(held): response(r['id'],r['params']); response(r['id'],r['params'])
    \\        held=[]
    \\        if i is not None: response(i,None)
    \\    elif method=='test/diagnostics':
    \\        for d in p: note('textDocument/publishDiagnostics',d)
    \\    elif method=='test/serverRequests':
    \\        req('cfg','workspace/configuration',{'items':[{'section':'a'},{'section':'b'}]})
    \\        req(801,'workspace/workspaceFolders',None)
    \\        req(802,'window/workDoneProgress/create',{'token':'p'})
    \\        req(803,'unknown/method',{})
    \\        req('edit','workspace/applyEdit',{'edit':{'changes':{}}})
    \\        req('exec','workspace/executeCommand',{'command':'must-not-execute'})
    \\        note('$/progress',{'token':'p','value':{'kind':'begin','title':'indexing'}})
    \\        note('window/logMessage',{'type':3,'message':'hello'})
    \\    elif method=='test/review': req('review','workspace/applyEdit',{'edit':{}})
    \\    elif method=='test/cancelReview': note('$/cancelRequest',{'id':'review'})
    \\    elif method=='test/reviewId': req(p,'workspace/applyEdit',{'edit':{}})
    \\    elif method=='test/cancelReviewId': note('$/cancelRequest',{'id':p})
    \\    elif method=='test/manyReviews':
    \\        for n in range(p['count']): req(p['start']+n,'workspace/applyEdit',{'edit':{}})
    \\    elif method=='test/flood': note('window/logMessage',{'type':3,'message':'x'*200000})
    \\    elif method=='test/closeStdout': close_output()
    \\    elif method=='test/truncateStdout': close_output(b'Content-Length: 42\r\n\r\n{')
    \\    elif method=='test/truncateHeaderStdout': close_output(b'Content-Length: 42\r\n')
    \\    elif method=='test/eofBurst':
    \\        frames=[]
    \\        for n in range(40):
    \\            b=json.dumps({'jsonrpc':'2.0','method':'test/n','params':{'n':n}}).encode()
    \\            frames.append(b'Content-Length: '+str(len(b)).encode()+b'\r\n\r\n'+b)
    \\        os.write(1,b''.join(frames))
    \\        close_output()
    \\    elif method=='test/error': send({'jsonrpc':'2.0','id':i,'error':{'code':-32803,'message':'server detail','data':{'extra':42}}})
    \\    elif method=='test/burst':
    \\        for n in range(p): note('test/n',{'n':n})
    \\    elif method=='test/crash': os._exit(7)
    \\    elif method=='test/truncate': os.write(1,b'Content-Length: 42\r\n\r\n{'); sys.exit(0)
    \\    elif method=='test/badEnvelope': send({'jsonrpc':'1.0','id':i,'result':None})
    \\    elif method=='test/snapshot': response(i,seen)
    \\    elif method=='$/cancelRequest': seen.append(m)
    \\    elif method.startswith('textDocument/'):
    \\        seen.append(m)
    \\        if method=='textDocument/didOpen': docs[p['textDocument']['uri']]=p['textDocument']['text']
    \\        if method=='textDocument/didChange':
    \\            changes=p['contentChanges']; assert len(changes)==1
    \\            if mode=='full': assert 'range' not in changes[0]
    \\            else: assert changes[0]['range']['start']=={'line':0,'character':0}
    \\            docs[p['textDocument']['uri']]=changes[0]['text']
    \\    elif i is not None: response(i,None)
;

test "client trust, config validation, destroy requires drain" {
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "normal" });
    cfg.transport.authorization = .denied;
    try std.testing.expectError(error.Unauthorized, client.Client.init(a, cfg));
    cfg.transport.authorization = .approved;
    cfg.root = "relative";
    try std.testing.expectError(error.NotAbsolute, client.Client.init(a, cfg));
    cfg.root = "/tmp/project space";
    cfg.additional_capabilities = "{\"workspace\":{\"workspaceFolders\":false}}";
    try std.testing.expectError(error.CapabilityConflict, client.Client.init(a, cfg));
    const c = try start("normal");
    defer cleanup(c);
    try std.testing.expectError(error.NotDrained, c.destroy());
    try std.testing.expectError(error.NotReady, c.request("hover", .null, .{}));
}

test "client initialize fragmented pipes, raw responses, options, graceful shutdown" {
    const c = try start("fragmented");
    defer cleanup(c);
    try ready(c);
    try std.testing.expect(c.capabilities.supports("hoverProvider"));
    try std.testing.expect(c.capabilities.supports("completionProvider"));
    try std.testing.expect(!c.capabilities.supports("renameProvider"));
    try std.testing.expectEqual(client.Sync.incremental, c.capabilities.sync);
    try std.testing.expect(c.capabilities.workspace_folders);
    const params = try parsed("{\"opaque\":[1,true,\"text\"]}");
    defer params.deinit();
    const id = try c.request("test/echo", params.value, .{});
    var event = try eventOf(c, .response);
    defer event.deinit();
    try std.testing.expectEqual(id, event.id.?);
    try std.testing.expectEqualStrings("test/echo", event.method);
    try std.testing.expectEqual(@as(usize, 3), protocol.field(result(&event), "opaque").?.array.items.len);
    try c.stop();
    try finish(c);
    try std.testing.expectEqual(client.State.stopped, c.state);
    try std.testing.expect(c.failure == null);
    var end = c.nextEvent().?;
    defer end.deinit();
    try std.testing.expectEqual(client.Event.Kind.finished, end.kind);
    try std.testing.expect(end.result.?.reaped);
    try std.testing.expect(c.nextEvent() == null);
}

test "client full and incremental document sync all position encodings" {
    for ([_][]const u8{ "normal", "utf8", "utf32", "full" }) |mode| {
        const c = try start(mode);
        defer cleanup(c);
        try ready(c);
        const doc_uri = "file:///tmp/a.zig";
        const ctx = try c.open(doc_uri, 19, 1, "a\r\n😀");
        try std.testing.expect(c.isCurrent(ctx));
        _ = try c.change(doc_uri, 2, "new");
        try std.testing.expect(!c.isCurrent(ctx));
        try c.save(doc_uri);
        try c.close(doc_uri);
        try std.testing.expectError(error.StaleVersion, c.open(doc_uri, 19, 2, "again"));
        const newer = try c.open(doc_uri, 19, 3, "again");
        try std.testing.expect(newer.generation != ctx.generation);
        _ = try c.request("test/snapshot", .null, .{});
        var event = try eventOf(c, .response);
        defer event.deinit();
        const seen = result(&event).array.items;
        const change = protocol.field(seen[1], "params").?;
        const edit = protocol.field(change, "contentChanges").?.array.items[0];
        if (!std.mem.eql(u8, mode, "full")) {
            const end = protocol.field(protocol.field(edit, "range").?, "end").?;
            try std.testing.expectEqual(@as(i64, 1), protocol.integer(protocol.field(end, "line").?).?);
            const units: i64 = if (std.mem.eql(u8, mode, "utf8")) 4 else if (std.mem.eql(u8, mode, "utf32")) 1 else 2;
            try std.testing.expectEqual(units, protocol.integer(protocol.field(end, "character").?).?);
            try std.testing.expectEqualStrings("new", protocol.string(protocol.field(protocol.field(seen[2], "params").?, "text").?).?);
        } else try std.testing.expect(protocol.field(edit, "range") == null);
    }
}

test "client no-sync server still tracks local document context" {
    const c = try start("none");
    defer cleanup(c);
    try ready(c);
    _ = try c.open("file:///tmp/a", 1, 0, "x");
    _ = try c.change("file:///tmp/a", 1, "y");
    try c.save("file:///tmp/a");
    try c.close("file:///tmp/a");
    _ = try c.request("test/snapshot", .null, .{});
    var event = try eventOf(c, .response);
    defer event.deinit();
    try std.testing.expectEqual(@as(usize, 0), result(&event).array.items.len);
}

test "client cancellation, out-of-order duplicate and late replies" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    const ctx = try c.open("file:///tmp/a", 7, 1, "old");
    const stale = try c.request("test/hold", .{ .integer = 10 }, ctx);
    const first = try c.request("test/hold", .{ .integer = 20 }, .{});
    const second = try c.request("test/hold", .{ .integer = 30 }, .{});
    _ = try c.change("file:///tmp/a", 2, "new");
    var cancelled = c.nextEvent().?;
    defer cancelled.deinit();
    try std.testing.expectEqual(stale, cancelled.id.?);
    try std.testing.expectEqual(client.Event.Kind.cancelled, cancelled.kind);
    try std.testing.expectError(error.StaleContext, c.request("test/hold", .null, ctx));
    try c.notify("test/release", .null);
    var e2 = try eventOf(c, .response);
    defer e2.deinit();
    var e1 = try eventOf(c, .response);
    defer e1.deinit();
    try std.testing.expectEqual(second, e2.id.?);
    try std.testing.expectEqual(first, e1.id.?);
    const fence = try c.request("test/echo", .null, .{});
    var e3 = try eventOf(c, .response);
    defer e3.deinit();
    try std.testing.expectEqual(fence, e3.id.?);
    try c.cancel(stale);
}

test "client request table bound and deadlines" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    for (0..client.max_requests) |_| _ = try c.request("test/hold", .null, .{});
    try std.testing.expectError(error.RequestLimit, c.request("test/hold", .null, .{}));
    // Give only the next request a short deadline; the table remains full.
    c.request_timeout_ms = 1;
    try c.cancel(2);
    var cancelled = c.nextEvent().?;
    cancelled.deinit();
    const id = try c.request("test/hold", .null, .{});
    pause();
    pause();
    var event = try eventOf(c, .timed_out);
    defer event.deinit();
    try std.testing.expectEqual(id, event.id.?);
    try std.testing.expectEqualStrings("test/hold", event.method);
}

test "client diagnostics version, queued revision and reopen guards" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    _ = try c.open("file:///tmp/a", 1, 5, "a");
    const params = try parsed("[{\"uri\":\"file:///tmp/a\",\"version\":4,\"diagnostics\":[]},{\"uri\":\"file:///tmp/a\",\"diagnostics\":[]},{\"uri\":\"file:///tmp/closed\",\"version\":5,\"diagnostics\":[]},{\"uri\":\"file:///tmp/a\",\"version\":5,\"diagnostics\":[]}]");
    defer params.deinit();
    try c.notify("test/diagnostics", params.value);
    var event = try eventOf(c, .diagnostics);
    defer event.deinit();
    try std.testing.expect(event.verified);
    try std.testing.expectEqual(@as(?i32, 5), event.version);
    try std.testing.expect(c.isCurrent(event.context));
    try c.notify("test/diagnostics", params.value);
    const fence = try c.request("test/echo", .null, .{});
    const deadline = now() + 2000;
    while (c.event_count < 2 and now() < deadline) {
        try c.tick(now());
        pause();
    }
    _ = try c.change("file:///tmp/a", 6, "b");
    try std.testing.expect(!c.isCurrent(event.context));
    var response = c.nextEvent().?;
    defer response.deinit();
    try std.testing.expectEqual(fence, response.id.?);
    try std.testing.expectEqual(client.Event.Kind.response, response.kind);
    try std.testing.expect(c.nextEvent() == null);
}

test "client server safe defaults, explicit edit/execute review, progress and status" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    try c.notify("test/serverRequests", .null);
    var edits: usize = 0;
    var replies: usize = 0;
    var progress = false;
    var status = false;
    const deadline = now() + 3000;
    while ((edits < 2 or replies < 6 or !progress or !status) and now() < deadline) {
        try c.tick(now());
        while (c.nextEvent()) |e| {
            var event = e;
            defer event.deinit();
            switch (event.kind) {
                .server_request => {
                    edits += 1;
                    const token = event.token.?;
                    if (std.mem.eql(u8, event.method, "workspace/applyEdit")) {
                        const denied = try parsed("{\"applied\":false,\"failureReason\":\"not approved\"}");
                        defer denied.deinit();
                        try c.respond(token, denied.value);
                    } else try c.reject(token, -32601, "Not approved");
                    try std.testing.expectError(error.UnknownServerRequest, c.respond(token, .null));
                },
                .progress => progress = true,
                .status => status = true,
                .notification => {
                    if (std.mem.eql(u8, event.method, "test/serverResponse")) {
                        replies += 1;
                        const r = protocol.field(event.value(), "params").?;
                        const id = try protocol.responseId(r);
                        if (id == .string and std.mem.eql(u8, id.string, "cfg")) {
                            const items = protocol.field(r, "result").?.array.items;
                            try std.testing.expectEqual(@as(usize, 2), items.len);
                            try std.testing.expect(items[0] == .null and items[1] == .null);
                        }
                    }
                },
                else => return error.UnexpectedEvent,
            }
        }
        pause();
    }
    try std.testing.expectEqual(@as(usize, 2), edits);
    try std.testing.expectEqual(@as(usize, 6), replies);
    try std.testing.expect(progress and status);
}

test "client visible initialization errors, crash and truncated framing" {
    for ([_][]const u8{ "rejected", "bad_encoding", "large_caps", "normal", "normal", "normal" }, 0..) |mode, index| {
        const c = try start(mode);
        defer cleanup(c);
        if (index >= 3) {
            try ready(c);
            try c.notify(switch (index) {
                3 => "test/crash",
                4 => "test/truncate",
                else => "test/badEnvelope",
            }, .null);
        }
        try finish(c);
        try std.testing.expectEqual(client.State.crashed, c.state);
        const expected: anyerror = switch (index) {
            0 => error.InitializeRejected,
            1 => error.UnsupportedEncoding,
            2 => error.CapabilityLimit,
            3 => error.ServerExited,
            4 => error.TruncatedFrame,
            else => error.InvalidEnvelope,
        };
        try std.testing.expectEqual(expected, c.failure.?);
        var event = c.nextEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(client.Event.Kind.finished, event.kind);
    }
}

test "client initialization and shutdown deadlines terminate ignoring servers" {
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "silent" });
    cfg.initialize_timeout_ms = 30;
    const c = try client.Client.init(a, cfg);
    defer cleanup(c);
    try finish(c);
    try std.testing.expectEqual(error.InitializeTimeout, c.failure.?);
    const other = try start("ignore_shutdown");
    defer cleanup(other);
    try ready(other);
    other.shutdown_timeout_ms = 30;
    try other.stop();
    const started = now();
    try finish(other);
    try std.testing.expect(now() - started < 2000);
    try std.testing.expect(other.pipe.result().?.reaped);
}

test "client event saturation fails closed, final event cannot be lost" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    try c.notify("test/burst", .{ .integer = 100 });
    const deadline = now() + 3000;
    var previous: usize = 0;
    while (c.failure == null and now() < deadline) {
        c.tick(now()) catch {};
        try std.testing.expect(c.event_count - previous <= client.messages_per_tick);
        previous = c.event_count;
        pause();
    }
    try std.testing.expectEqual(error.EventLimit, c.failure.?);
    try finish(c);
    var found = false;
    while (c.nextEvent()) |e| {
        var event = e;
        defer event.deinit();
        if (event.kind == .finished) found = true;
    }
    try std.testing.expect(found);
}

test "client transport send limit fails safely and can still drain" {
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "normal" });
    cfg.transport.input_limit = 1024;
    const c = try client.Client.init(a, cfg);
    defer cleanup(c);
    try ready(c);
    const large = try a.alloc(u8, 2000);
    defer a.free(large);
    @memset(large, 'a');
    try std.testing.expectError(error.MessageTooLarge, c.request("test/echo", .{ .string = large }, .{}));
    try std.testing.expectEqual(client.State.crashed, c.state);
    try finish(c);
}

test "client event JSON outlives session" {
    const c = try start("normal");
    var destroyed = false;
    defer if (!destroyed) cleanup(c);
    try ready(c);
    _ = try c.request("test/echo", .{ .string = "owned forever" }, .{});
    var event = try eventOf(c, .response);
    defer event.deinit();
    try c.stop();
    try finish(c);
    try c.destroy();
    destroyed = true;
    try std.testing.expectEqualStrings("owned forever", protocol.string(result(&event)).?);
    try std.testing.expectEqualStrings("test/echo", event.method);
}

test "client copied configuration, opt-in advanced capabilities and default UTF16" {
    var options = "{\"feature\":true}".*;
    var advanced = "{\"textDocument\":{\"completion\":{\"completionItem\":{\"snippetSupport\":true}}},\"window\":{\"workDoneProgress\":true}}".*;
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "custom" });
    cfg.initialization_options = &options;
    cfg.additional_capabilities = &advanced;
    const c = try client.Client.init(a, cfg);
    defer cleanup(c);
    @memset(&options, 'x');
    @memset(&advanced, 'x');
    try ready(c);
    _ = try c.request("test/init", .null, .{});
    var event = try eventOf(c, .response);
    defer event.deinit();
    const init_params = result(&event);
    try std.testing.expect(protocol.field(protocol.field(init_params, "initializationOptions").?, "feature").?.bool);
    const caps = protocol.field(init_params, "capabilities").?;
    const completion = protocol.field(protocol.field(caps, "textDocument").?, "completion").?;
    try std.testing.expect(protocol.field(protocol.field(completion, "completionItem").?, "snippetSupport").?.bool);
    const other = try start("default_encoding");
    defer cleanup(other);
    try ready(other);
    try std.testing.expectEqual(@import("positions.zig").Encoding.utf16, other.capabilities.encoding);
}

test "client responses, diagnostics and review tokens cannot cross sessions" {
    const c = try start("normal");
    defer cleanup(c);
    const replacement = try start("normal");
    defer cleanup(replacement);
    try ready(c);
    try ready(replacement);
    const ctx = try c.open("file:///tmp/same", 1, 1, "same");
    const other_ctx = try replacement.open("file:///tmp/same", 1, 1, "same");
    try std.testing.expect(ctx.generation == other_ctx.generation);
    try std.testing.expect(!replacement.isCurrent(ctx));
    try std.testing.expectError(error.StaleContext, replacement.request("test/echo", .null, ctx));
    try c.notify("test/review", .null);
    try replacement.notify("test/review", .null);
    var event = try eventOf(c, .server_request);
    defer event.deinit();
    var other_event = try eventOf(replacement, .server_request);
    defer other_event.deinit();
    try std.testing.expect(event.token.? != other_event.token.?);
    try std.testing.expectError(error.UnknownServerRequest, replacement.respond(event.token.?, .null));
}

test "client unversioned diagnostics are opt-in and explicitly unverified" {
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "normal" });
    cfg.unversioned_diagnostics = .surface_unverified;
    const c = try client.Client.init(a, cfg);
    defer cleanup(c);
    try ready(c);
    _ = try c.open("file:///tmp/a", 1, 1, "a");
    const params = try parsed("[{\"uri\":\"file:///tmp/a\",\"diagnostics\":[]}]");
    defer params.deinit();
    try c.notify("test/diagnostics", params.value);
    var event = try eventOf(c, .diagnostics);
    defer event.deinit();
    try std.testing.expect(!event.verified and event.version == null);
    try c.close("file:///tmp/a");
    _ = try c.open("file:///tmp/a", 1, 2, "a");
    try std.testing.expect(!c.isCurrent(event.context));
}

test "client reviewed server request expiry and cancellation" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    try c.notify("test/review", .null);
    var event = try eventOf(c, .server_request);
    defer event.deinit();
    try c.notify("test/cancelReview", .null);
    _ = try c.request("test/echo", .null, .{});
    var fence = try eventOf(c, .response);
    defer fence.deinit();
    try std.testing.expectError(error.UnknownServerRequest, c.respond(event.token.?, .null));
    c.request_timeout_ms = 20;
    try c.notify("test/review", .null);
    var expires = try eventOf(c, .server_request);
    defer expires.deinit();
    var timeout = try eventOf(c, .notification);
    defer timeout.deinit();
    const reply = protocol.field(timeout.value(), "params").?;
    const rpc_error = protocol.field(reply, "error").?;
    try std.testing.expectEqual(@as(i64, -32800), protocol.integer(protocol.field(rpc_error, "code").?).?);
    try std.testing.expectError(error.UnknownServerRequest, c.reject(expires.token.?, -32601, "late"));
}

test "client server request table bound independently of drained event queue" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    var tokens: [client.max_requests]u64 = undefined;
    for (0..4) |batch| {
        const bytes = try std.fmt.allocPrint(a, "{{\"start\":{d},\"count\":16}}", .{batch * 16});
        defer a.free(bytes);
        const params = try parsed(bytes);
        defer params.deinit();
        try c.notify("test/manyReviews", params.value);
        for (0..16) |i| {
            var event = try eventOf(c, .server_request);
            defer event.deinit();
            tokens[batch * 16 + i] = event.token.?;
        }
    }
    const params = try parsed("{\"start\":100,\"count\":1}");
    defer params.deinit();
    try c.notify("test/manyReviews", params.value);
    var event = try eventOf(c, .notification);
    defer event.deinit();
    const reply = protocol.field(event.value(), "params").?;
    try std.testing.expectEqual(@as(i64, -32000), protocol.integer(protocol.field(protocol.field(reply, "error").?, "code").?).?);
    try c.reject(tokens[0], -32800, "declined");
}

test "client bounded caller JSON preflight prevents cycles and number injection" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    try std.testing.expectError(error.InvalidJson, c.request("test/echo", .{ .number_string = "0,\"injected\":true" }, .{}));
    try std.testing.expectError(error.InvalidJson, c.notify("test/echo", .{ .float = std.math.inf(f64) }));
    try std.testing.expectError(error.InvalidUtf8, c.request("test/echo", .{ .string = "\xff" }, .{}));
    var array: std.array_list.Managed(Value) = .init(a);
    defer array.deinit();
    try array.append(.null);
    const cycle: Value = .{ .array = array };
    array.items[0] = cycle;
    try std.testing.expectError(error.JsonTooDeep, c.request("test/echo", cycle, .{}));
    const huge = try a.alloc(u8, protocol.max_message_bytes);
    defer a.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.MessageTooLarge, c.notify("test/echo", .{ .string = huge }));
    try std.testing.expectEqual(client.State.ready, c.state);
    for ([_][]const u8{ "initialize", "exit", "textDocument/didChange" }) |method| {
        try std.testing.expectError(error.ReservedMethod, c.request(method, .null, .{}));
        try std.testing.expectError(error.ReservedMethod, c.notify(method, .null));
    }
    _ = try c.request("test/error", .null, .{});
    var event = try eventOf(c, .response);
    defer event.deinit();
    try std.testing.expectEqualStrings("server detail", protocol.string(protocol.field(protocol.field(event.value(), "error").?, "message").?).?);
}

test "client actual backpressure on blocked server stops and reaps" {
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "blocked" });
    cfg.transport.input_limit = 1024;
    const c = try client.Client.init(a, cfg);
    defer cleanup(c);
    try ready(c);
    var blocked = try eventOf(c, .notification);
    defer blocked.deinit();
    const payload: [800]u8 = @splat('x');
    var failure: ?anyerror = null;
    for (0..128) |_| {
        c.notify("test/echo", .{ .string = &payload }) catch |err| {
            failure = err;
            break;
        };
    }
    try std.testing.expectEqual(error.Backpressure, failure.?);
    try finish(c);
    try std.testing.expect(c.pipe.result().?.reaped);
}

test "client output overflow retains transport outcome and final notification" {
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "normal" });
    cfg.transport.output_limit = 1024;
    const c = try client.Client.init(a, cfg);
    defer cleanup(c);
    try ready(c);
    try c.notify("test/flood", .null);
    for (0..60) |_| pause();
    try finish(c);
    try std.testing.expectEqual(@import("transport.zig").Outcome.output_limit, c.pipe.result().?.outcome);
    try std.testing.expect(c.failure != null);
    var event = c.nextEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(client.Event.Kind.finished, event.kind);
}

test "client lifecycle stop before first tick is not a crash; monotonic clock" {
    const c = try start("normal");
    defer cleanup(c);
    try c.stop();
    try c.stop();
    try finish(c);
    try std.testing.expectEqual(client.State.stopped, c.state);
    try std.testing.expect(c.failure == null);
    try std.testing.expectError(error.NonMonotonicTime, c.tick(c.now.? - 1));
}

test "client document URI, text, lifetime slot and byte budgets" {
    const c = try start("none");
    defer cleanup(c);
    try ready(c);
    try std.testing.expectError(error.NonCanonicalUri, c.open("file:/tmp/a", 1, 1, "a"));
    try std.testing.expectError(error.RemoteHost, c.open("file://remote/tmp/a", 1, 1, "a"));
    try std.testing.expectError(error.InvalidUtf8, c.open("file:///tmp/a", 1, 1, "\xff"));
    const text = try a.alloc(u8, 3 * 1024 * 1024);
    defer a.free(text);
    @memset(text, 'a');
    _ = try c.open("file:///tmp/a", 1, 1, text);
    _ = try c.open("file:///tmp/b", 2, 1, text);
    try std.testing.expectError(error.DocumentLimit, c.open("file:///tmp/c", 3, 1, text));
    try c.close("file:///tmp/a");
    _ = try c.open("file:///tmp/c", 3, 1, text);
    for (3..client.max_documents) |i| {
        const uri = try std.fmt.allocPrint(a, "file:///tmp/doc{d}", .{i});
        defer a.free(uri);
        _ = try c.open(uri, @intCast(i + 1), 1, "");
        try c.close(uri);
    }
    try std.testing.expectError(error.DocumentLimit, c.open("file:///tmp/extra", 999, 1, ""));
}

fn allocationAttempt(allocator: std.mem.Allocator) !void {
    const c = try client.Client.init(allocator, config(&.{ "/bin/python3", "-u", "-c", server, "normal" }));
    defer cleanup(c);
}

test "client init releases every partially allocated configuration" {
    try std.testing.checkAllAllocationFailures(a, allocationAttempt, .{});
}

test "client deadline wins over an already queued late response" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    c.request_timeout_ms = 1;
    const id = try c.request("test/echo", .null, .{});
    for (0..20) |_| pause();
    var event = try eventOf(c, .timed_out);
    defer event.deinit();
    try std.testing.expectEqual(id, event.id.?);
    try std.testing.expect(c.nextEvent() == null);
}

test "client save boolean omits text and queued document response is invalidated" {
    const c = try start("save_no_text");
    defer cleanup(c);
    try ready(c);
    const ctx = try c.open("file:///tmp/a", 1, 1, "text");
    try c.save("file:///tmp/a");
    _ = try c.request("test/snapshot", .null, .{});
    var snapshot = try eventOf(c, .response);
    defer snapshot.deinit();
    const save_params = protocol.field(result(&snapshot).array.items[1], "params").?;
    try std.testing.expect(protocol.field(save_params, "text") == null);
    _ = try c.request("test/echo", .null, ctx);
    const deadline = now() + 2000;
    while (c.event_count == 0 and now() < deadline) {
        try c.tick(now());
        pause();
    }
    try std.testing.expectEqual(@as(usize, 1), c.event_count);
    _ = try c.change("file:///tmp/a", 2, "changed");
    try std.testing.expect(c.nextEvent() == null);
}

test "client event bytes and per-tick input bytes are bounded independently of count" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    for (0..22) |_| {
        const previous = c.event_count;
        try c.notify("test/flood", .null);
        const deadline = now() + 2000;
        while (c.failure == null and c.event_count == previous and now() < deadline) {
            const before = c.framer.body_len;
            c.tick(now()) catch {};
            if (c.framer.body_len >= before) try std.testing.expect(c.framer.body_len - before <= client.bytes_per_tick);
            pause();
        }
        try std.testing.expect(c.event_bytes <= client.max_event_bytes);
        if (c.failure != null) break;
        try std.testing.expectEqual(previous + 1, c.event_count);
    }
    try std.testing.expectEqual(error.EventLimit, c.failure.?);
    try std.testing.expect(c.event_count < client.max_events);
    try finish(c);
}

test "client inbound allocation failures fail closed and drain without allocation" {
    for (0..24) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        const c = try client.Client.init(failing.allocator(), config(&.{ "/bin/python3", "-u", "-c", server, "normal" }));
        defer cleanup(c);
        try ready(c);
        _ = try c.request("test/echo", .{ .string = "owned response" }, .{});
        failing.fail_index = failing.alloc_index + offset;
        const deadline = now() + 2000;
        while (c.failure == null and c.event_count == 0 and now() < deadline) {
            c.tick(now()) catch |err| try std.testing.expectEqual(error.OutOfMemory, err);
            pause();
        }
        if (c.failure != null) {
            try std.testing.expectEqual(error.OutOfMemory, c.failure.?);
            // Deliberately leave the allocator failing throughout cleanup.
            try finish(c);
            try std.testing.expect(c.isDrained());
        }
        failing.fail_index = std.math.maxInt(usize);
    }
}

test "client stdout EOF validates framing and reaps live servers without lifetime timeout" {
    for ([_][]const u8{ "test/closeStdout", "test/truncateStdout", "test/truncateHeaderStdout" }, 0..) |method, index| {
        var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "normal" });
        cfg.transport.timeout_ms = 0;
        const c = try client.Client.init(a, cfg);
        defer cleanup(c);
        try ready(c);
        const ctx = try c.open("file:///tmp/a", 1, 1, "a");
        _ = try c.request("test/hold", .null, ctx);
        try c.notify("test/review", .null);
        var review = try eventOf(c, .server_request);
        defer review.deinit();
        try c.notify(method, .null);
        const deadline = now() + 2000;
        while (c.failure == null and now() < deadline) {
            c.tick(now()) catch {};
            pause();
        }
        const expected: anyerror = if (index == 0) error.ServerExited else error.TruncatedFrame;
        try std.testing.expect(c.failure != null);
        try std.testing.expectEqual(expected, c.failure.?);
        try std.testing.expectEqual(client.State.crashed, c.state);
        try std.testing.expect(!c.isCurrent(ctx));
        for (c.pending) |slot| try std.testing.expect(slot == null);
        for (c.incoming) |slot| try std.testing.expect(slot == null);
        try std.testing.expectError(error.NotReady, c.respond(review.token.?, .null));
        if (!c.isDrained()) try std.testing.expectError(error.NotDrained, c.destroy());
        while (!c.isDrained() and now() < deadline) {
            c.tick(now()) catch {};
            pause();
        }
        try std.testing.expect(c.isDrained());
        var end = c.nextEvent().?;
        defer end.deinit();
        try std.testing.expectEqual(client.Event.Kind.finished, end.kind);
        try std.testing.expectEqual(expected, end.failure.?);
        try std.testing.expect(end.result.?.reaped);
        try std.testing.expectEqual(@as(?u8, 9), end.result.?.term_signal);
        try c.tick(now());
        try std.testing.expect(c.nextEvent() == null);
    }
}

test "client stdout EOF during initialization is not left until initialize deadline" {
    for ([_][]const u8{ "eof_init", "eof_init_truncated" }, 0..) |mode, index| {
        var cfg = config(&.{ "/bin/python3", "-u", "-c", server, mode });
        cfg.transport.timeout_ms = 0;
        const c = try client.Client.init(a, cfg);
        defer cleanup(c);
        const deadline = now() + 2000;
        while (!c.isDrained() and now() < deadline) {
            c.tick(now()) catch {};
            pause();
        }
        try std.testing.expect(c.isDrained());
        try std.testing.expectEqual(client.State.crashed, c.state);
        const expected: anyerror = if (index == 0) error.ServerExited else error.TruncatedFrame;
        try std.testing.expectEqual(expected, c.failure.?);
        try std.testing.expect(c.pipe.result().?.reaped);
    }
}

test "client stdout EOF dispatches complete queued frames within per-tick budget" {
    var cfg = config(&.{ "/bin/python3", "-u", "-c", server, "normal" });
    cfg.transport.timeout_ms = 0;
    const c = try client.Client.init(a, cfg);
    defer cleanup(c);
    try ready(c);
    try c.notify("test/eofBurst", .null);
    var received: usize = 0;
    var finished = false;
    const deadline = now() + 2000;
    while (!finished and now() < deadline) {
        c.tick(now()) catch {};
        var dispatched: usize = 0;
        while (c.nextEvent()) |e| {
            var event = e;
            defer event.deinit();
            if (event.kind == .finished) {
                try std.testing.expectEqual(@as(usize, 40), received);
                try std.testing.expect(event.result.?.reaped);
                finished = true;
            } else {
                try std.testing.expectEqual(client.Event.Kind.notification, event.kind);
                const n = protocol.integer(protocol.field(protocol.field(event.value(), "params").?, "n").?).?;
                try std.testing.expectEqual(@as(i64, @intCast(received)), n);
                received += 1;
                dispatched += 1;
            }
        }
        try std.testing.expect(dispatched <= client.messages_per_tick);
        pause();
    }
    try std.testing.expect(finished);
    try std.testing.expectEqual(error.ServerExited, c.failure.?);
}

test "client graceful stdout EOF flushes exit and bounds reaping without reporting a crash" {
    for ([_][]const u8{ "eof_shutdown_exit", "eof_shutdown_hang", "eof_shutdown_burst", "eof_shutdown_no_response", "eof_shutdown_truncated" }, 0..) |mode, index| {
        var cfg = config(&.{ "/bin/python3", "-u", "-c", server, mode });
        cfg.transport.timeout_ms = 0;
        cfg.shutdown_timeout_ms = 300;
        const c = try client.Client.init(a, cfg);
        defer cleanup(c);
        try ready(c);
        try c.stop();
        const deadline = now() + 2000;
        while (!c.isDrained() and now() < deadline) {
            c.tick(now()) catch {};
            if (index < 3) try std.testing.expect(c.failure == null);
            if (!c.isDrained() and c.failure == null) try std.testing.expectEqual(client.State.stopping, c.state);
            pause();
        }
        try std.testing.expect(c.isDrained());
        var end = c.nextEvent().?;
        defer end.deinit();
        try std.testing.expectEqual(client.Event.Kind.finished, end.kind);
        try std.testing.expect(end.result.?.reaped);
        if (index < 3) {
            try std.testing.expectEqual(client.State.stopped, c.state);
            try std.testing.expect(end.failure == null);
            try std.testing.expect(c.exit_sent);
            if (index == 0) {
                try std.testing.expectEqual(@import("transport.zig").Outcome.success, end.result.?.outcome);
            } else try std.testing.expectEqual(@as(?u8, 9), end.result.?.term_signal);
        } else {
            try std.testing.expectEqual(client.State.crashed, c.state);
            const expected: anyerror = if (index == 3) error.ServerExited else error.TruncatedFrame;
            try std.testing.expectEqual(expected, end.failure.?);
        }
        try c.tick(now());
        try std.testing.expect(c.nextEvent() == null);
    }
}

test "client diagnostic guards survive close, document ID reuse, reopen and replacement session" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    const old = try c.open("file:///tmp/a", 7, 1, "a");
    const stale_request = try c.request("test/hold", .null, old);
    const old_diagnostics = try parsed("[{\"uri\":\"file:///tmp/a\",\"version\":1,\"diagnostics\":[]}]");
    defer old_diagnostics.deinit();
    try c.notify("test/diagnostics", old_diagnostics.value);
    const deadline = now() + 2000;
    while (c.event_count == 0 and now() < deadline) {
        try c.tick(now());
        pause();
    }
    try std.testing.expectEqual(@as(usize, 1), c.event_count);
    try c.close("file:///tmp/a");
    _ = try c.open("file:///tmp/b", 7, 1, "b");
    try std.testing.expect(!c.isCurrent(old));
    // The queued diagnostic is discarded; close cancels the old request once.
    var cancelled = c.nextEvent().?;
    defer cancelled.deinit();
    try std.testing.expectEqual(client.Event.Kind.cancelled, cancelled.kind);
    try std.testing.expectEqual(stale_request, cancelled.id.?);
    try c.cancel(stale_request);
    try std.testing.expect(c.nextEvent() == null);
    try c.notify("test/release", .null);
    const fence_id = try c.request("test/echo", .null, .{});
    var fence = try eventOf(c, .response);
    defer fence.deinit();
    try std.testing.expectEqual(fence_id, fence.id.?);
    try c.close("file:///tmp/b");
    try std.testing.expectError(error.StaleVersion, c.open("file:///tmp/a", 7, 1, "a"));
    _ = try c.open("file:///tmp/a", 7, 2, "new");
    const diagnostics = try parsed("[{\"uri\":\"file:///tmp/a\",\"version\":1,\"diagnostics\":[]},{\"uri\":\"file:///tmp/a\",\"version\":3,\"diagnostics\":[]},{\"uri\":\"file:///tmp/a\",\"diagnostics\":[]},{\"uri\":\"file:///tmp/a\",\"version\":2,\"diagnostics\":[]}]");
    defer diagnostics.deinit();
    try c.notify("test/diagnostics", diagnostics.value);
    var diagnostic = try eventOf(c, .diagnostics);
    defer diagnostic.deinit();
    try std.testing.expectEqual(@as(?i32, 2), diagnostic.version);
    try std.testing.expect(diagnostic.verified and c.isCurrent(diagnostic.context));
    const replacement = try start("normal");
    defer cleanup(replacement);
    try ready(replacement);
    _ = try replacement.open("file:///tmp/a", 7, 2, "new");
    try std.testing.expect(!replacement.isCurrent(diagnostic.context));
    try c.stop();
    try std.testing.expect(!c.isCurrent(diagnostic.context));
}

test "client cancellation keeps incoming and outgoing ID namespaces separate" {
    const c = try start("normal");
    defer cleanup(c);
    try ready(c);
    const outbound = try c.request("test/hold", .null, .{});
    try c.notify("test/reviewId", .{ .integer = outbound });
    var review = try eventOf(c, .server_request);
    defer review.deinit();
    try c.notify("test/cancelReviewId", .{ .integer = outbound });
    try c.notify("test/cancelReviewId", .{ .integer = outbound });
    var cancellation = try eventOf(c, .notification);
    defer cancellation.deinit();
    const reply = protocol.field(cancellation.value(), "params").?;
    try std.testing.expectEqual(outbound, (try protocol.responseId(reply)).integer);
    try std.testing.expectEqual(@as(i64, -32800), protocol.integer(protocol.field(protocol.field(reply, "error").?, "code").?).?);
    try std.testing.expectError(error.UnknownServerRequest, c.respond(review.token.?, .null));
    try c.notify("test/release", .null);
    const fence_id = try c.request("test/echo", .null, .{});
    var received: usize = 0;
    const deadline = now() + 2000;
    while (received < 2 and now() < deadline) {
        try c.tick(now());
        while (c.nextEvent()) |e| {
            var event = e;
            defer event.deinit();
            // No second cancellation reply, duplicate response, or cancelled
            // outgoing request may appear after cancelling the incoming ID.
            try std.testing.expectEqual(client.Event.Kind.response, event.kind);
            try std.testing.expectEqual(if (received == 0) outbound else fence_id, event.id.?);
            received += 1;
        }
        pause();
    }
    try std.testing.expectEqual(@as(usize, 2), received);
    try c.cancel(outbound);
    try std.testing.expect(c.nextEvent() == null);
}

test "client request allocation failures are transactional or fail closed" {
    for (0..8) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        const c = try client.Client.init(failing.allocator(), config(&.{ "/bin/python3", "-u", "-c", server, "normal" }));
        defer cleanup(c);
        try ready(c);
        failing.fail_index = failing.alloc_index + offset;
        if (c.request("test/echo", .{ .string = "request" }, .{})) |_| {} else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            for (c.pending) |slot| try std.testing.expect(slot == null);
        }
        failing.fail_index = std.math.maxInt(usize);
    }
}
