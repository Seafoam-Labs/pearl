#![no_std]
extern crate alloc;
#[global_allocator]
static ALLOCATOR: dlmalloc::GlobalDlmalloc = dlmalloc::GlobalDlmalloc;
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { core::arch::wasm32::unreachable() }
use alloc::{string::String, format, vec};
use core::sync::atomic::{AtomicU32, Ordering};
wit_bindgen::generate!({ path: "../../wit", world: "plugin" });
struct Counter;
static COUNT: AtomicU32 = AtomicU32::new(0);
impl exports::pearl::plugin::guest::Guest for Counter {
    fn handle_event(event: pearl::plugin::types::Event) -> Result<(), String> {
        use pearl::plugin::{host, types::{Node, NodeKind, Scene, EventKind}};
        if event.kind == EventKind::Click { COUNT.fetch_add(1, Ordering::Relaxed); }
        host::publish(&Scene { nodes: vec![Node { id: 1, kind: NodeKind::Button,
            text: format!("Rust clicks: {}", COUNT.load(Ordering::Relaxed)), asset: String::new(), clip: String::new() }] })
    }
}
export!(Counter);
// wasm32-wasip2 normally gets this export from std. A freestanding guest
// provides it explicitly using the same global allocator as generated bindings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cabi_realloc(old: *mut u8, old_len: usize, align: usize, new_len: usize) -> *mut u8 {
    use alloc::alloc::{Layout, alloc, realloc, dealloc, handle_alloc_error};
    let layout = Layout::from_size_align(old_len.max(new_len), align).unwrap();
    if new_len == 0 {
        if old_len != 0 { unsafe { dealloc(old, Layout::from_size_align(old_len, align).unwrap()) }; }
        return align as *mut u8;
    }
    let result = if old_len == 0 { unsafe { alloc(layout) } }
        else { unsafe { realloc(old, Layout::from_size_align(old_len, align).unwrap(), new_len) } };
    if result.is_null() { handle_alloc_error(layout) }
    result
}
