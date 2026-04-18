// main.rs - Call Zig functions and print return codes
#[link(name = "agent_rt", kind = "static")]
extern "C" {
    fn execute_agent_default(precision: u32, entry: *mut std::ffi::c_void) -> u32;
    fn execute_agent_explicit(
        precision: u32,
        entry: *mut std::ffi::c_void,
        temp_store: *mut std::ffi::c_void,
    ) -> u32;
}

fn main() {
    unsafe {
        let result_default = execute_agent_default(42, std::ptr::null_mut());
        println!("execute_agent_default returned: {}", result_default);

        let result_explicit =
            execute_agent_explicit(42, std::ptr::null_mut(), std::ptr::null_mut());
        println!("execute_agent_explicit returned: {}", result_explicit);
    }
}
