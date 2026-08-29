// Additive in-process libFuzzer harness for boytacean's full emulation loop over a
// fuzzer-supplied ROM (src/gb.rs + src/mmu.rs + src/cpu.rs + src/ppu.rs + ...).
//
// The fuzzer bytes are loaded as a Game Boy ROM (`GameBoy::load_rom`, which routes
// through `Cartridge::from_data`), then the emulator is clocked a FIXED, small number
// of CPU steps. `GameBoy::clocks(N)` runs exactly N `clock()` calls — one CPU
// instruction each — so execution is bounded by construction and cannot loop forever
// (unlike a cycle-count or run-to-address bound, which a pathological ROM could
// stretch). Each step drives the CPU, MMU banking, PPU, APU, timer and DMA, so this
// exercises far more of the emulator than the header parser alone.
//
// No boot ROM is loaded, so the CPU starts at PC=0x0000 executing the cartridge
// bytes directly (a real boot ROM would lock up on an invalid Nintendo logo and
// starve coverage). Bytes come only from the fuzzer — no file I/O (net-new brief §3).
// Upstream source is untouched.
//
// We do NOT guard any panic / abort / over-allocation from the emulated hardware:
// those are genuine boytacean defects, which is what we want to surface.
#![no_main]

use libfuzzer_sys::fuzz_target;

use boytacean::devices::buffer::BufferDevice;
use boytacean::gb::{GameBoy, GameBoyMode};

// Bounded number of CPU instructions to emulate per input. Large enough to reach
// deep into cartridge code, small enough to stay fast.
const MAX_STEPS: usize = 30_000;

fuzz_target!(|data: &[u8]| {
    let mut game_boy = GameBoy::new(Some(GameBoyMode::Dmg));
    game_boy.attach_serial(Box::<BufferDevice>::default());

    // Allocate the DMG memory map (no boot ROM).
    if game_boy.load(false).is_err() {
        return;
    }

    // Load the fuzz bytes as a cartridge; most invalid inputs are rejected here
    // (size / header checks), and the fuzzer learns to produce loadable ROMs.
    if game_boy.load_rom(data, None).is_err() {
        return;
    }

    // Bounded emulation: exactly MAX_STEPS CPU instructions.
    game_boy.clocks(MAX_STEPS);
});
