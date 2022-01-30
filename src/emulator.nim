import bus, ee, gs
import times

var running = true

let bios_location = "roms/scph39001.bin"
let elf_location = "roms/3stars.elf"

load_bios(bios_location)
let entry_pc = load_elf(elf_location)
set_pc(entry_pc)

var prev_time = cpuTime()

while running:
    ee_tick()
    let cur_time = cpuTime()
    if (cur_time - prev_time) > 0.016:
        prev_time = cur_time
        parse_events()
        display_frame()