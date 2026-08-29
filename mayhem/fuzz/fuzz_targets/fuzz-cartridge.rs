// Additive in-process libFuzzer harness for boytacean's Game Boy ROM/cartridge
// loader (src/rom.rs).
//
// `Cartridge::from_data(&[u8])` is boytacean's self-contained cartridge parser:
// it validates the ROM size, decodes the cartridge header (title, CGB/SGB flags,
// cartridge/MBC type at 0x0147, ROM size at 0x0148, RAM size at 0x0149, licensee),
// selects the Memory Bank Controller and allocates the external RAM. That header +
// MBC parsing is the rich, self-contained attack surface. On a successfully parsed
// cartridge we also exercise the read accessors across the whole 0x0000-0x7FFF ROM
// address window, which drives the selected MBC's bank-mapping read handler.
//
// Bytes come only from the fuzzer — no file I/O (net-new brief §3). Upstream source
// is untouched: this crate only CALLS boytacean.
//
// We do NOT guard any panic / abort / over-allocation: an input that makes the
// loader panic or over-allocate is a genuine boytacean defect (the product), which
// is exactly what we want the fuzzer to surface.
#![no_main]

use libfuzzer_sys::fuzz_target;

use boytacean::rom::Cartridge;

fuzz_target!(|data: &[u8]| {
    if let Ok(cart) = Cartridge::from_data(data) {
        // Exercise the header decoders over the parsed cartridge.
        let _ = cart.title();
        let _ = cart.rom_type();
        let _ = cart.rom_size();
        let _ = cart.ram_size();
        let _ = cart.cgb_flag();
        let _ = cart.sgb_flag();
        let _ = cart.gb_mode();
        let _ = cart.is_legacy();
        let _ = cart.licensee();
        let _ = cart.region();
        let _ = cart.valid_checksum();
        let _ = cart.mbc();

        // Drive the MBC read handler across the whole ROM address window.
        let mut addr: u16 = 0x0000;
        loop {
            let _ = cart.read(addr);
            if addr >= 0x7f00 {
                break;
            }
            addr = addr.wrapping_add(0x0100);
        }
    }
});
