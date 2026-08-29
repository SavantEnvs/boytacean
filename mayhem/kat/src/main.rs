// Known-answer-test probe for boytacean's Game Boy cartridge loader (the Mayhem
// behavioral oracle). We hand-encode a canonical, minimal 32 KiB Game Boy ROM
// (ROM-only, DMG, no RAM) byte-for-byte per the cartridge-header layout, parse it
// with the UNMODIFIED boytacean::rom::Cartridge, and both assert and PRINT the
// decoded fields.
//
// mayhem/test.sh greps the printed `KAT_RESULT ...` line for fixed expected values.
// If the loader is neutered to exit(0) (the gate's sabotage shim) or otherwise
// broken, this probe never prints the expected values and the oracle FAILS.
//
// This is a genuine known-answer test of the LOADER: the input bytes are built by
// hand (not by boytacean's own writer), so a correct decode of specific field
// values is what is being asserted. No file I/O — bytes are passed in memory.

use boytacean::rom::{Cartridge, CgbMode, MbcType, RamSize, RomSize, RomType};

// A valid Game Boy ROM must be >= 0x7FFF bytes and a multiple of 16 KiB; the
// smallest such ROM is 32 KiB (two 16 KiB banks).
const ROM_SIZE: usize = 32 * 1024;

fn build_rom() -> Vec<u8> {
    let mut rom = vec![0u8; ROM_SIZE];

    // Cartridge title at 0x0134.. — set_title_offset() stops at the first NUL, so a
    // plain ASCII title followed by the pre-zeroed bytes decodes back exactly.
    let title = b"TESTROM";
    rom[0x0134..0x0134 + title.len()].copy_from_slice(title);

    // Header fields (all left at 0x00 => the canonical minimal cartridge):
    rom[0x0143] = 0x00; // CGB flag        -> NoCgb (DMG)
    rom[0x0146] = 0x00; // SGB flag        -> NoSgb
    rom[0x0147] = 0x00; // cartridge type  -> RomOnly (MBC = NoMbc)
    rom[0x0148] = 0x00; // ROM size        -> Size32K
    rom[0x0149] = 0x00; // RAM size        -> NoRam

    rom
}

fn main() {
    let bytes = build_rom();

    let cart = Cartridge::from_data(&bytes).expect("KAT: loader rejected canonical ROM");

    let title = cart.title();
    let rom_type = cart.rom_type();
    let rom_size = cart.rom_size();
    let ram_size = cart.ram_size();
    let cgb = cart.cgb_flag();
    let mbc = rom_type.mbc_type();
    let gb_mode = cart.gb_mode();

    // Known-answer assertions on the decoded header.
    assert_eq!(title, "TESTROM", "title");
    assert_eq!(rom_type, RomType::RomOnly, "rom_type");
    assert_eq!(rom_size, RomSize::Size32K, "rom_size");
    assert_eq!(ram_size, RamSize::NoRam, "ram_size");
    assert_eq!(cgb, CgbMode::NoCgb, "cgb_flag");
    assert_eq!(mbc, MbcType::NoMbc, "mbc_type");
    assert!(gb_mode.is_dmg(), "gb_mode");

    // Canonical result line (parsed by mayhem/test.sh). Debug-formatted enums give
    // single-token, space-free values so bash word-matching is unambiguous.
    println!(
        "KAT_RESULT title={} rom_type={:?} rom_size={:?} ram_size={:?} cgb={:?} mbc={:?} rom_banks={}",
        title,
        rom_type,
        rom_size,
        ram_size,
        cgb,
        mbc,
        rom_size.rom_banks(),
    );
}
