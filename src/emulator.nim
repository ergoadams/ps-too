import ee/ee_bus, ee/ee, ee/gs
import iop/iop
import times

var running = true

let bios_location = "roms/scph10000.bin"
let elf_location = "roms/3stars.elf"

load_bios(bios_location)
set_elf(elf_location, true)
var prev_time = cpuTime()

while running:
    ee_tick()
    #ee_tick()
    #iop_tick()
    let cur_time = cpuTime()
    if (cur_time - prev_time) > 0.016:
        prev_time = cur_time
        parse_events()
        display_frame()