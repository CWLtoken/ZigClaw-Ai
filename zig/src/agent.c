// Minimal agent runtime implementation for verification
#include <stdint.h>

__attribute__((visibility("default")))
uint32_t execute_agent_default(uint32_t precision, void* entry) {
    (void)precision;
    (void)entry;
    return 0;
}

__attribute__((visibility("default")))
uint32_t execute_agent_explicit(uint32_t precision, void* entry, void* temp_store) {
    (void)precision;
    (void)entry;
    (void)temp_store;
    return 0;
}
