import pkg/nint128
import streams, strutils
import gif, gs, timer, cop0
import ../common/logger, ../common/sif

var templine: string

type
    DCHCR_t = object
        v: uint32
        direction, mode, stack_ptr, transfer_tag, enable_irq, running, tag: uint32

    TagAddress_t = object
        v: uint32
        address, mem_select: uint32

    Channel_t = object
        control: DCHCR_t
        tag_address: TagAddress_t
        saved_tag1: TagAddress_t
        saved_tag2: TagAddress_t
        address, qword_count, scratchpad_address: uint32
        end_transfer: bool

    DSTAT_t = object
        v: uint32
        channel_irq, dma_stall, mfifo_empty, bus_error: uint32
        channel_irq_mask, stall_irq_mask, mfifo_irq_mask: uint32

    DMAC_t = object
        ctrl, pcr, sqwc, rbsr, rbor, stadr, enable: uint32
        stat: DSTAT_t

    DMATag_t = object
        v: UInt128
        qwords, priority, id, irq, address, mem_select: uint32
        data: uint64

proc `value=`(i: var DCHCR_t, data: uint32) {.inline.} =
    i.v = data
    i.direction = (data shr 0) and 1
    i.mode = (data shr 2) and 3
    i.stack_ptr = (data shr 4) and 3
    i.transfer_tag = (data shr 6) and 1
    i.enable_irq = (data shr 7) and 1
    i.running = (data shr 8) and 1
    i.tag = (data shr 16) and 0xFFFF

proc `value`(i: DCHCR_t): uint32 {.inline.} =
    var temp: uint32
    temp = temp or (i.direction shl 0)
    temp = temp or (i.mode shl 2)
    temp = temp or (i.stack_ptr shl 4)
    temp = temp or (i.transfer_tag shl 6)
    temp = temp or (i.enable_irq shl 7)
    temp = temp or (i.running shl 8)
    temp = temp or (i.tag shl 16)
    return temp

proc `value=`(i: var TagAddress_t, data: uint32) {.inline.} =
    i.v = data
    i.address = (data shl 1) shr 1
    i.mem_select = (data shr 30) and 1

proc `value`(i: TagAddress_t): uint32 {.inline.} =
    var temp: uint32
    temp = temp or (i.address shl 0)
    temp = temp or (i.mem_select shl 30)
    return temp


proc `value=`(i: var DMATag_t, data: UInt128) {.inline.} =
    i.v = data
    i.qwords = cast[uint32](data) and 0xFFFF
    i.priority = cast[uint32](data shr 26) and 3
    i.id = cast[uint32](data shr 28) and 7
    i.irq = cast[uint32](data shr 31) and 1
    i.address = cast[uint32](data shr 32) and 0x7FFFFFFF'u32
    i.mem_select = cast[uint32](data shr 63) and 1
    i.data = cast[uint64](data shr 64)

proc `value`(i: DMATag_t): UInt128 {.inline.} =
    var temp: UInt128
    temp = temp or (u128(i.qwords) shl 0)
    temp = temp or (u128(i.priority) shl 26)
    temp = temp or (u128(i.id) shl 28)
    temp = temp or (u128(i.irq) shl 31)
    temp = temp or (u128(i.address) shl 32)
    temp = temp or (u128(i.mem_select) shl 63)
    temp = temp or (u128(i.data) shl 64)


proc `value=`(i: var DSTAT_t, data: uint32) {.inline.} =
    let temp = (i.v xor (data and 0xFFFF0000'u32)) or (i.v and (not (data and 0xFFFF)))
    i.v = temp
    i.channel_irq = (temp shr 0) and 0x3FF
    i.dma_stall = (temp shr 13) and 1
    i.mfifo_empty = (temp shr 14) and 1
    i.bus_error = (temp shr 15) and 1
    i.channel_irq_mask = (temp shr 16) and 0x3FF
    i.stall_irq_mask = (temp shr 29) and 1
    i.mfifo_irq_mask = (temp shr 30) and 1
    if (i.channel_irq and i.channel_irq_mask) != 0:
        echo "INT1"

proc `value`(i: DSTAT_t): uint32 {.inline.} =
    var temp: uint32
    temp = temp or (i.channel_irq shl 0)
    temp = temp or (i.dma_stall shl 13)
    temp = temp or (i.mfifo_empty shl 14)
    temp = temp or (i.bus_error shl 15)
    temp = temp or (i.channel_irq_mask shl 16)
    temp = temp or (i.stall_irq_mask shl 29)
    temp = temp or (i.mfifo_irq_mask shl 30)


var bios*: array[0x400000 , uint8]
var ram: array[0x2000000, uint8]
var scratchpad: array[0x4000, uint8]
var iop_ram*: array[0x200000, uint8]
var MCH_DRD: uint32
var MCH_RICM: uint32
var rdram_sdevid: uint32


var d_channels: array[10, Channel_t]
var DMAC = DMAC_t(enable: 0x1201'u32)

var vu0_code: array[0x1000, uint8]
var vu0_data: array[0x1000, uint8]

var vu1_code: array[0x4000, uint8]
var vu1_data: array[0x4000, uint8]

proc load32*(address: uint32): uint32 {.gcsafe, locks: 0.}

proc translate_address(address: uint32): uint32 = 
    if (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        return address
    else:
        return address and 0x1FFFFFFF'u32

proc load_bios*(bios_location: string) =
    var s = newFileStream(bios_location, fmRead)
    var bios_pos = 0'u32
    while not s.atEnd:
        bios[bios_pos] = uint8(s.readChar())
        bios_pos += 1

    add_log(LogType.logWarning, "Loaded bios from " & bios_location)


proc dmac_load32(address: uint32): uint32 =
    var channel: uint32
    case (address shr 8) and 0xFF:
        of 0x80: channel = 0
        of 0x90: channel = 1
        of 0xA0: channel = 2
        of 0xB0: channel = 3
        of 0xB4: channel = 4
        of 0xC0: channel = 5
        of 0xC4: channel = 6
        of 0xC8: channel = 7
        of 0xD0: channel = 8
        of 0xD4: channel = 9
        else: quit("DMAC load32 invalid channel " & address.tohex(), 0)
    let reg_index = address and 0xFF
    case reg_index:
        of 0x00: return d_channels[channel].control.value
        of 0x10: return d_channels[channel].address
        of 0x20: return d_channels[channel].qword_count
        of 0x30: return d_channels[channel].tag_address.value
        of 0x40: return d_channels[channel].saved_tag1.value
        of 0x50: return d_channels[channel].saved_tag2.value
        of 0x80: return d_channels[channel].scratchpad_address
        else: quit("DMAC load32 invalid reg_index " & $reg_index, 0)

proc dmac_store32(address: uint32, data: uint32) =
    var channel: uint32
    case (address shr 8) and 0xFF:
        of 0x80: channel = 0
        of 0x90: channel = 1
        of 0xA0: channel = 2
        of 0xB0: channel = 3
        of 0xB4: channel = 4
        of 0xC0: channel = 5
        of 0xC4: channel = 6
        of 0xC8: channel = 7
        of 0xD0: channel = 8
        of 0xD4: channel = 9
        else: quit("DMAC store32 invalid channel " & address.tohex(), 0)
    let reg_index = address and 0xFF
    let offset = (address shr 4) and 0xF
    #echo reg_index.toHex() & " " & $offset
    #echo "EE CHANNEL " & $channel & " reg " & $reg_index.toHex() & " " & data.toHex()
    case reg_index:
        of 0x00: d_channels[channel].control.value = data
        of 0x10: d_channels[channel].address = data and 0x01FFFFF0'u32
        of 0x20: d_channels[channel].qword_count = data
        of 0x30: d_channels[channel].tag_address.value = data
        of 0x40: d_channels[channel].saved_tag1.value = data
        of 0x50: d_channels[channel].saved_tag2.value = data
        of 0x80: d_channels[channel].scratchpad_address = data
        else: quit("DMAC invalid reg_index " & $reg_index, 0)

    if d_channels[channel].control.running != 0:
        add_log(LogType.logDMAC, "Started EE DMA transfer for channel " & $channel)

proc fetch_tag(id: uint32) =
    var dmatag: DMATag_t
    case id:
        of 5: # SIF0
            if sif0_fifo.len >= 2:
                var temp = u128(sif0_fifo[0]) shl 32
                temp = temp or u128(sif0_fifo[1])
                dmatag.value = temp
                sif0_fifo.delete(0)
                sif0_fifo.delete(0)
                echo "Got SIF0 tag " & temp.toHex()

                d_channels[id].qword_count = dmatag.qwords
                d_channels[id].control.tag = cast[uint32]((dmatag.value shr 16) and u128(0xFFFF))
                d_channels[id].address = dmatag.address
                d_channels[id].tag_address.address += 16
                if ((d_channels[id].control.enable_irq != 0) and (dmatag.irq != 0)):
                    d_channels[id].end_transfer = true
        else: quit("Unhandled DMAC fetch tag id " & $id)

proc dmac_tick*() =
    if (DMAC.enable and 0x10000) != 0:
        return

    var id = 0'u32
    while id < 10: # Loop through each channel
        let channel = d_channels[id]
        if channel.control.running != 0:
            if channel.qword_count > 0: # We have data left to transfer
                case id:
                    else: quit("Unhandled DMAC tick id " & $id)

            elif channel.end_transfer:
                d_channels[id].end_transfer = false
                d_channels[id].control.running = 0
                DMAC.stat.channel_irq = DMAC.stat.channel_irq or (1'u32 shl id)
                if (DMAC.stat.channel_irq and DMAC.stat.channel_irq_mask) != 0:
                    echo "INT1 FROM TICK"

            else:
                fetch_tag(id)
        id += 1


proc store128*(address: uint32, value: UInt128) =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        let offset = address
        ram[offset + 15] = cast[uint8]((value shr 120) and u128(0xFF))
        ram[offset + 14] = cast[uint8]((value shr 112) and u128(0xFF))
        ram[offset + 13] = cast[uint8]((value shr 104) and u128(0xFF))
        ram[offset + 12] = cast[uint8]((value shr 96) and u128(0xFF))
        ram[offset + 11] = cast[uint8]((value shr 88) and u128(0xFF))
        ram[offset + 10] = cast[uint8]((value shr 80) and u128(0xFF))
        ram[offset + 9] = cast[uint8]((value shr 72) and u128(0xFF))
        ram[offset + 8] = cast[uint8]((value shr 64) and u128(0xFF))
        ram[offset + 7] = cast[uint8]((value shr 56) and u128(0xFF))
        ram[offset + 6] = cast[uint8]((value shr 48) and u128(0xFF))
        ram[offset + 5] = cast[uint8]((value shr 40) and u128(0xFF))
        ram[offset + 4] = cast[uint8]((value shr 32) and u128(0xFF))
        ram[offset + 3] = cast[uint8]((value shr 24) and u128(0xFF))
        ram[offset + 2] = cast[uint8]((value shr 16) and u128(0xFF))
        ram[offset + 1] = cast[uint8]((value shr 8) and u128(0xFF))
        ram[offset + 0] = cast[uint8]((value shr 0) and u128(0xFF))
    elif (address >= 0x11000000'u32) and (address < 0x11000000'u32 + 0x1000):
        let offset = address - 0x11000000'u32
        vu0_code[offset + 15] = cast[uint8]((value shr 120) and u128(0xFF))
        vu0_code[offset + 14] = cast[uint8]((value shr 112) and u128(0xFF))
        vu0_code[offset + 13] = cast[uint8]((value shr 104) and u128(0xFF))
        vu0_code[offset + 12] = cast[uint8]((value shr 96) and u128(0xFF))
        vu0_code[offset + 11] = cast[uint8]((value shr 88) and u128(0xFF))
        vu0_code[offset + 10] = cast[uint8]((value shr 80) and u128(0xFF))
        vu0_code[offset + 9] = cast[uint8]((value shr 72) and u128(0xFF))
        vu0_code[offset + 8] = cast[uint8]((value shr 64) and u128(0xFF))
        vu0_code[offset + 7] = cast[uint8]((value shr 56) and u128(0xFF))
        vu0_code[offset + 6] = cast[uint8]((value shr 48) and u128(0xFF))
        vu0_code[offset + 5] = cast[uint8]((value shr 40) and u128(0xFF))
        vu0_code[offset + 4] = cast[uint8]((value shr 32) and u128(0xFF))
        vu0_code[offset + 3] = cast[uint8]((value shr 24) and u128(0xFF))
        vu0_code[offset + 2] = cast[uint8]((value shr 16) and u128(0xFF))
        vu0_code[offset + 1] = cast[uint8]((value shr 8) and u128(0xFF))
        vu0_code[offset + 0] = cast[uint8]((value shr 0) and u128(0xFF))
    elif (address >= 0x11004000'u32) and (address < 0x11004000'u32 + 0x1000):
        let offset = address - 0x11004000'u32
        vu0_data[offset + 15] = cast[uint8]((value shr 120) and u128(0xFF))
        vu0_data[offset + 14] = cast[uint8]((value shr 112) and u128(0xFF))
        vu0_data[offset + 13] = cast[uint8]((value shr 104) and u128(0xFF))
        vu0_data[offset + 12] = cast[uint8]((value shr 96) and u128(0xFF))
        vu0_data[offset + 11] = cast[uint8]((value shr 88) and u128(0xFF))
        vu0_data[offset + 10] = cast[uint8]((value shr 80) and u128(0xFF))
        vu0_data[offset + 9] = cast[uint8]((value shr 72) and u128(0xFF))
        vu0_data[offset + 8] = cast[uint8]((value shr 64) and u128(0xFF))
        vu0_data[offset + 7] = cast[uint8]((value shr 56) and u128(0xFF))
        vu0_data[offset + 6] = cast[uint8]((value shr 48) and u128(0xFF))
        vu0_data[offset + 5] = cast[uint8]((value shr 40) and u128(0xFF))
        vu0_data[offset + 4] = cast[uint8]((value shr 32) and u128(0xFF))
        vu0_data[offset + 3] = cast[uint8]((value shr 24) and u128(0xFF))
        vu0_data[offset + 2] = cast[uint8]((value shr 16) and u128(0xFF))
        vu0_data[offset + 1] = cast[uint8]((value shr 8) and u128(0xFF))
        vu0_data[offset + 0] = cast[uint8]((value shr 0) and u128(0xFF))
    elif (address >= 0x1100C000'u32) and (address < 0x1100C000'u32 + 0x4000):
        let offset = address - 0x1100C000'u32
        vu1_data[offset + 15] = cast[uint8]((value shr 120) and u128(0xFF))
        vu1_data[offset + 14] = cast[uint8]((value shr 112) and u128(0xFF))
        vu1_data[offset + 13] = cast[uint8]((value shr 104) and u128(0xFF))
        vu1_data[offset + 12] = cast[uint8]((value shr 96) and u128(0xFF))
        vu1_data[offset + 11] = cast[uint8]((value shr 88) and u128(0xFF))
        vu1_data[offset + 10] = cast[uint8]((value shr 80) and u128(0xFF))
        vu1_data[offset + 9] = cast[uint8]((value shr 72) and u128(0xFF))
        vu1_data[offset + 8] = cast[uint8]((value shr 64) and u128(0xFF))
        vu1_data[offset + 7] = cast[uint8]((value shr 56) and u128(0xFF))
        vu1_data[offset + 6] = cast[uint8]((value shr 48) and u128(0xFF))
        vu1_data[offset + 5] = cast[uint8]((value shr 40) and u128(0xFF))
        vu1_data[offset + 4] = cast[uint8]((value shr 32) and u128(0xFF))
        vu1_data[offset + 3] = cast[uint8]((value shr 24) and u128(0xFF))
        vu1_data[offset + 2] = cast[uint8]((value shr 16) and u128(0xFF))
        vu1_data[offset + 1] = cast[uint8]((value shr 8) and u128(0xFF))
        vu1_data[offset + 0] = cast[uint8]((value shr 0) and u128(0xFF))
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        bios[offset + 15] = cast[uint8]((value shr 120) and u128(0xFF))
        bios[offset + 14] = cast[uint8]((value shr 112) and u128(0xFF))
        bios[offset + 13] = cast[uint8]((value shr 104) and u128(0xFF))
        bios[offset + 12] = cast[uint8]((value shr 96) and u128(0xFF))
        bios[offset + 11] = cast[uint8]((value shr 88) and u128(0xFF))
        bios[offset + 10] = cast[uint8]((value shr 80) and u128(0xFF))
        bios[offset + 9] = cast[uint8]((value shr 72) and u128(0xFF))
        bios[offset + 8] = cast[uint8]((value shr 64) and u128(0xFF))
        bios[offset + 7] = cast[uint8]((value shr 56) and u128(0xFF))
        bios[offset + 6] = cast[uint8]((value shr 48) and u128(0xFF))
        bios[offset + 5] = cast[uint8]((value shr 40) and u128(0xFF))
        bios[offset + 4] = cast[uint8]((value shr 32) and u128(0xFF))
        bios[offset + 3] = cast[uint8]((value shr 24) and u128(0xFF))
        bios[offset + 2] = cast[uint8]((value shr 16) and u128(0xFF))
        bios[offset + 1] = cast[uint8]((value shr 8) and u128(0xFF))
        bios[offset + 0] = cast[uint8]((value shr 0) and u128(0xFF))
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        scratchpad[offset + 15] = cast[uint8]((value shr 120) and u128(0xFF))
        scratchpad[offset + 14] = cast[uint8]((value shr 112) and u128(0xFF))
        scratchpad[offset + 13] = cast[uint8]((value shr 104) and u128(0xFF))
        scratchpad[offset + 12] = cast[uint8]((value shr 96) and u128(0xFF))
        scratchpad[offset + 11] = cast[uint8]((value shr 88) and u128(0xFF))
        scratchpad[offset + 10] = cast[uint8]((value shr 80) and u128(0xFF))
        scratchpad[offset + 9] = cast[uint8]((value shr 72) and u128(0xFF))
        scratchpad[offset + 8] = cast[uint8]((value shr 64) and u128(0xFF))
        scratchpad[offset + 7] = cast[uint8]((value shr 56) and u128(0xFF))
        scratchpad[offset + 6] = cast[uint8]((value shr 48) and u128(0xFF))
        scratchpad[offset + 5] = cast[uint8]((value shr 40) and u128(0xFF))
        scratchpad[offset + 4] = cast[uint8]((value shr 32) and u128(0xFF))
        scratchpad[offset + 3] = cast[uint8]((value shr 24) and u128(0xFF))
        scratchpad[offset + 2] = cast[uint8]((value shr 16) and u128(0xFF))
        scratchpad[offset + 1] = cast[uint8]((value shr 8) and u128(0xFF))
        scratchpad[offset + 0] = cast[uint8]((value shr 0) and u128(0xFF))
    else:
        add_log(LogType.logWarning, "Unhandled store128 " & address.toHex() & " " & value.toHex())

proc store64*(address: uint32, value: uint64) =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        let offset = address
        ram[offset + 7] = cast[uint8]((value shr 56) and 0xFF)
        ram[offset + 6] = cast[uint8]((value shr 48) and 0xFF)
        ram[offset + 5] = cast[uint8]((value shr 40) and 0xFF)
        ram[offset + 4] = cast[uint8]((value shr 32) and 0xFF)
        ram[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        ram[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        ram[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        ram[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x11008000'u32) and (address < 0x11008000'u32 + 0x4000):
        let offset = address - 0x11008000'u32
        vu1_code[offset + 7] = cast[uint8]((value shr 56) and 0xFF)
        vu1_code[offset + 6] = cast[uint8]((value shr 48) and 0xFF)
        vu1_code[offset + 5] = cast[uint8]((value shr 40) and 0xFF)
        vu1_code[offset + 4] = cast[uint8]((value shr 32) and 0xFF)
        vu1_code[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        vu1_code[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        vu1_code[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        vu1_code[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1100C000'u32) and (address < 0x1100C000'u32 + 0x4000):
        let offset = address - 0x1100C000'u32
        vu1_data[offset + 7] = cast[uint8]((value shr 56) and 0xFF)
        vu1_data[offset + 6] = cast[uint8]((value shr 48) and 0xFF)
        vu1_data[offset + 5] = cast[uint8]((value shr 40) and 0xFF)
        vu1_data[offset + 4] = cast[uint8]((value shr 32) and 0xFF)
        vu1_data[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        vu1_data[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        vu1_data[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        vu1_data[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        bios[offset + 7] = cast[uint8]((value shr 56) and 0xFF)
        bios[offset + 6] = cast[uint8]((value shr 48) and 0xFF)
        bios[offset + 5] = cast[uint8]((value shr 40) and 0xFF)
        bios[offset + 4] = cast[uint8]((value shr 32) and 0xFF)
        bios[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        bios[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        bios[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        bios[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif address == 0x12001000'u32: 
        GS_CSR = value or 0b1000
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        scratchpad[offset + 7] = cast[uint8]((value shr 56) and 0xFF)
        scratchpad[offset + 6] = cast[uint8]((value shr 48) and 0xFF)
        scratchpad[offset + 5] = cast[uint8]((value shr 40) and 0xFF)
        scratchpad[offset + 4] = cast[uint8]((value shr 32) and 0xFF)
        scratchpad[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        scratchpad[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        scratchpad[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        scratchpad[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif address == 0x10000810: timer_store(address, cast[uint32](value))
    elif address == 0x10000800: timer_store(address, cast[uint32](value))
    else:
        add_log(LogType.logWarning, "Unhandled store64 " & address.toHex() & " " & value.toHex())


proc store32*(address: uint32, value: uint32) =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        ram[address + 3] = cast[uint8]((value shr 24) and 0xFF)
        ram[address + 2] = cast[uint8]((value shr 16) and 0xFF)
        ram[address + 1] = cast[uint8]((value shr 8) and 0xFF)
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        bios[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        bios[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        bios[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        bios[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        scratchpad[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        scratchpad[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        scratchpad[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        scratchpad[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1C000000'u32) and (address < 0x1C000000'u32 + 0x200000):
        let offset = (address - 0x1C000000'u32) and 0x1FFFFF
        iop_ram[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        iop_ram[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        iop_ram[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        iop_ram[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x10000000'u32) and (address < 0x10000000'u32 + 0xFF): timer_store(address, value)
    elif (address >= 0x10000800'u32) and (address < 0x10000800'u32 + 0xFF): timer_store(address, value)
    elif (address >= 0x10001000'u32) and (address < 0x10001000'u32 + 0xFF): timer_store(address, value)
    elif (address >= 0x10001800'u32) and (address < 0x10001800'u32 + 0xFF): timer_store(address, value)
    elif address == 0x12001000'u32: GS_CSR = cast[uint64](value)
    elif address == 0x1000F430:
        let sa = cast[uint8]((value shr 16) and 0xFFF)
        let sbc = cast[uint8]((value shr 6) and 0xF)
        if (sa == 0x21) and (sbc == 0x1) and (((MCH_DRD shr 7) and 1) == 0):
            rdram_sdevid = 0
        MCH_RICM = value and (not 0x80000000'u32)
    elif address == 0x1000F440: MCH_DRD = value
    elif address == 0x1000F000'u32: set_intc_stat(value)
    elif address == 0x1000F010'u32: set_intc_mask(value)
    elif address == 0x1000F200'u32: mscom = value
    elif address == 0x1000F220'u32: msflg = value
    elif address == 0x1000F230'u32: smflg = value
    elif address == 0x1000F240'u32: 
        if (value and 0x100) == 0:
            sif_ctrl = sif_ctrl and (not 0x100'u32)
        else:
            sif_ctrl = sif_ctrl or 0x100'u32
    elif address == 0x1000F230'u32: bd6 = value
    elif (address >= 0x10008000'u32) and (address <= 0x10008000'u32 + 0x80) or
         (address >= 0x10009000'u32) and (address <= 0x10009000'u32 + 0x80) or
         (address >= 0x1000A000'u32) and (address <= 0x1000A000'u32 + 0x80) or
         (address >= 0x1000B000'u32) and (address <= 0x1000B000'u32 + 0x80) or
         (address >= 0x1000B400'u32) and (address <= 0x1000B400'u32 + 0x80) or
         (address >= 0x1000C000'u32) and (address <= 0x1000C000'u32 + 0x80) or
         (address >= 0x1000C400'u32) and (address <= 0x1000C400'u32 + 0x80) or
         (address >= 0x1000C800'u32) and (address <= 0x1000C800'u32 + 0x80) or
         (address >= 0x1000D000'u32) and (address <= 0x1000D000'u32 + 0x80) or
         (address >= 0x1000D400'u32) and (address <= 0x1000D400'u32 + 0x80):
        dmac_store32(address, value)
    elif address == 0x1000E000'u32: DMAC.ctrl = value
    elif address == 0x1000E010'u32: DMAC.stat.value = value
    elif address == 0x1000E020'u32: DMAC.pcr = value
    elif address == 0x1000E030'u32: DMAC.sqwc = value
    elif address == 0x1000E040'u32: DMAC.rbsr = value
    elif address == 0x1000E050'u32: DMAC.rbor = value
    elif address == 0x1000F590'u32: DMAC.enable = value
    
    else:
        add_log(LogType.logWarning, "Unhandled store32 " & address.toHex() & " " & value.toHex())

proc store16*(address: uint32, value: uint16) =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        ram[address + 1] = cast[uint8]((value shr 8) and 0xFF)
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        
        bios[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        bios[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        scratchpad[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        scratchpad[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    else:
        add_log(LogType.logWarning, "Unhandled store16 " & address.toHex() & " " & value.toHex())

proc store8*(address: uint32, value: uint8) =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        bios[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        scratchpad[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif address == 0x1000F180:
        if value == 10:
            add_log(LogType.logConsole, templine)
            templine = ""
        else:
            templine = templine & char(value)

    else:
        add_log(LogType.logWarning, "Unhandled store8 " & address.toHex() & " " & value.toHex())

proc load128*(address: uint32): UInt128 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return  (cast[UInt128](ram[address + 15]) shl 120) or 
                (cast[UInt128](ram[address + 14]) shl 112) or 
                (cast[UInt128](ram[address + 13]) shl 104) or 
                (cast[UInt128](ram[address + 12]) shl 96) or 
                (cast[UInt128](ram[address + 11]) shl 88) or 
                (cast[UInt128](ram[address + 10]) shl 80) or 
                (cast[UInt128](ram[address + 9]) shl 72) or 
                (cast[UInt128](ram[address + 8]) shl 64) or
                (cast[UInt128](ram[address + 7]) shl 56) or 
                (cast[UInt128](ram[address + 6]) shl 48) or 
                (cast[UInt128](ram[address + 5]) shl 40) or 
                (cast[UInt128](ram[address + 4]) shl 32) or 
                (cast[UInt128](ram[address + 3]) shl 24) or 
                (cast[UInt128](ram[address + 2]) shl 16) or 
                (cast[UInt128](ram[address + 1]) shl 8) or 
                (cast[UInt128](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32

        return  (cast[UInt128](bios[offset + 15]) shl 120) or 
                (cast[UInt128](bios[offset + 14]) shl 112) or 
                (cast[UInt128](bios[offset + 13]) shl 104) or 
                (cast[UInt128](bios[offset + 12]) shl 96) or 
                (cast[UInt128](bios[offset + 11]) shl 88) or 
                (cast[UInt128](bios[offset + 10]) shl 80) or 
                (cast[UInt128](bios[offset + 9]) shl 72) or 
                (cast[UInt128](bios[offset + 8]) shl 64) or
                (cast[UInt128](bios[offset + 7]) shl 56) or 
                (cast[UInt128](bios[offset + 6]) shl 48) or 
                (cast[UInt128](bios[offset + 5]) shl 40) or 
                (cast[UInt128](bios[offset + 4]) shl 32) or 
                (cast[UInt128](bios[offset + 3]) shl 24) or 
                (cast[UInt128](bios[offset + 2]) shl 16) or 
                (cast[UInt128](bios[offset + 1]) shl 8) or 
                (cast[UInt128](bios[offset + 0]) shl 0)
    else: 
        add_log(LogType.logWarning, "Unhandled load128 " & address.toHex())
        return u128(0)

proc load64*(address: uint32): uint64 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return  (cast[uint64](ram[address + 7]) shl 56) or 
                (cast[uint64](ram[address + 6]) shl 48) or 
                (cast[uint64](ram[address + 5]) shl 40) or 
                (cast[uint64](ram[address + 4]) shl 32) or 
                (cast[uint64](ram[address + 3]) shl 24) or 
                (cast[uint64](ram[address + 2]) shl 16) or 
                (cast[uint64](ram[address + 1]) shl 8) or 
                (cast[uint64](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        
        return  (cast[uint64](bios[offset + 7]) shl 56) or 
                (cast[uint64](bios[offset + 6]) shl 48) or 
                (cast[uint64](bios[offset + 5]) shl 40) or 
                (cast[uint64](bios[offset + 4]) shl 32) or 
                (cast[uint64](bios[offset + 3]) shl 24) or 
                (cast[uint64](bios[offset + 2]) shl 16) or 
                (cast[uint64](bios[offset + 1]) shl 8) or 
                (cast[uint64](bios[offset + 0]) shl 0)
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        return  (cast[uint64](scratchpad[offset + 7]) shl 56) or 
                (cast[uint64](scratchpad[offset + 6]) shl 48) or 
                (cast[uint64](scratchpad[offset + 5]) shl 40) or 
                (cast[uint64](scratchpad[offset + 4]) shl 32) or 
                (cast[uint64](scratchpad[offset + 3]) shl 24) or 
                (cast[uint64](scratchpad[offset + 2]) shl 16) or 
                (cast[uint64](scratchpad[offset + 1]) shl 8) or 
                (cast[uint64](scratchpad[offset + 0]) shl 0)
    elif address == 0x12001000'u32: return GS_CSR
    else: 
        add_log(LogType.logWarning, "Unhandled load64 " & address.toHex())

proc load32*(address: uint32): uint32 =
    let new_address = address
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return  (cast[uint32](ram[address + 3]) shl 24) or 
                (cast[uint32](ram[address + 2]) shl 16) or 
                (cast[uint32](ram[address + 1]) shl 8) or 
                (cast[uint32](ram[address + 0]) shl 0)
    elif (address >= 0x10000000'u32) and (address < 0x10000000'u32 + 0xFF): return timer_load(address)
    elif (address >= 0x10000800'u32) and (address < 0x10000800'u32 + 0xFF): return timer_load(address)
    elif (address >= 0x10001000'u32) and (address < 0x10001000'u32 + 0xFF): return timer_load(address)
    elif (address >= 0x10001800'u32) and (address < 0x10001800'u32 + 0xFF): return timer_load(address)
    elif address == 0x1000F000'u32: return get_intc_stat()
    elif address == 0x1000F010'u32: return get_intc_mask()
    elif address == 0x1000F130'u32: return 0x00
    elif address == 0x1000F200'u32: return mscom
    elif address == 0x1000F210'u32: return smcom
    elif address == 0x1000F220'u32: return msflg
    elif address == 0x1000F230'u32: return smflg
    elif address == 0x1000F240'u32: return sif_ctrl
    elif address == 0x1000F410'u32: return 0'u32
    elif address == 0x1000F430: return 0x00 # MCH_DRD 
    elif address == 0x1000F440: 
        let sop = cast[uint8]((MCH_RICM shr 6) and 0xF)
        let sa = cast[uint8]((MCH_RICM shr 16) and 0xFFF)
        if sop == 0:
            case sa:
                of 0x21:
                    if rdram_sdevid < 2:
                        rdram_sdevid += 1
                        return 0x1F
                    return 0x00
                of 0x23: return 0x0D0D
                of 0x24: return 0x0090
                of 0x40: return MCH_RICM and 0x1F
                else: echo "Unhandled rdram SA"
        return 0x00
    elif address == 0x1000E000'u32: return DMAC.ctrl
    elif address == 0x1000E010'u32: return DMAC.stat.v
    elif address == 0x1000E020'u32: return DMAC.pcr
    elif address == 0x1000E030'u32: return DMAC.sqwc
    elif address == 0x1000E040'u32: return DMAC.rbsr
    elif address == 0x1000E050'u32: return DMAC.rbor
    elif address == 0x1000F590'u32: return DMAC.enable
    elif (address >= 0x10008000'u32) and (address <= 0x10008000'u32 + 0x80) or
         (address >= 0x10009000'u32) and (address <= 0x10009000'u32 + 0x80) or
         (address >= 0x1000A000'u32) and (address <= 0x1000A000'u32 + 0x80) or
         (address >= 0x1000B000'u32) and (address <= 0x1000B000'u32 + 0x80) or
         (address >= 0x1000B400'u32) and (address <= 0x1000B400'u32 + 0x80) or
         (address >= 0x1000C000'u32) and (address <= 0x1000C000'u32 + 0x80) or
         (address >= 0x1000C400'u32) and (address <= 0x1000C400'u32 + 0x80) or
         (address >= 0x1000C800'u32) and (address <= 0x1000C800'u32 + 0x80) or
         (address >= 0x1000D000'u32) and (address <= 0x1000D000'u32 + 0x80) or
         (address >= 0x1000D400'u32) and (address <= 0x1000D400'u32 + 0x80):
        dmac_load32(address)
    elif address == 0x12001000'u32: return cast[uint32](GS_CSR)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return  (cast[uint32](bios[offset + 3]) shl 24) or 
                (cast[uint32](bios[offset + 2]) shl 16) or 
                (cast[uint32](bios[offset + 1]) shl 8) or 
                (cast[uint32](bios[offset + 0]) shl 0)
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        return  (cast[uint32](scratchpad[offset + 3]) shl 24) or 
                (cast[uint32](scratchpad[offset + 2]) shl 16) or 
                (cast[uint32](scratchpad[offset + 1]) shl 8) or 
                (cast[uint32](scratchpad[offset + 0]) shl 0)
    elif (address >= 0x1C000000'u32) and (address < 0x1C000000'u32 + 0x200000):
        let offset = address - 0x1C000000'u32
        return  (cast[uint32](iop_ram[offset + 3]) shl 24) or 
                (cast[uint32](iop_ram[offset + 2]) shl 16) or 
                (cast[uint32](iop_ram[offset + 1]) shl 8) or 
                (cast[uint32](iop_ram[offset + 0]) shl 0)
    else: 
        add_log(LogType.logWarning, "Unhandled load32 " & address.toHex())
        return 0

proc load16*(address: uint32): uint16 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return  (cast[uint16](ram[address + 1]) shl 8) or 
                (cast[uint16](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return  (cast[uint16](bios[offset + 1]) shl 8) or 
                (cast[uint16](bios[offset + 0]) shl 0)
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        return  (cast[uint16](scratchpad[offset + 1]) shl 8) or 
                (cast[uint16](scratchpad[offset + 0]) shl 0)
    else: 
        add_log(LogType.logWarning, "Unhandled load16 " & address.toHex())
        return 0

proc load8*(address: uint32): uint8 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return ram[address]
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return bios[offset]
    elif (address >= 0x70000000'u32) and (address < 0x70000000'u32 + 0x1000000):
        let offset = (address - 0x70000000'u32) and 0x3FFF
        return scratchpad[offset]
    elif address == 0x1F803204'u32: return 0
    else: 
        add_log(LogType.logWarning, "Unhandled load8 " & address.toHex())


proc load_elf*(elf_location: string): uint32 =
    echo ""
    var s = newFileStream(elf_location, fmRead)
    var elf: seq[uint8]
    while not s.atEnd:
        elf.add(uint8(s.readChar()))

    var e_entry = uint32(elf[0x18]) or (uint32(elf[0x18 + 1]) shl 8) or (uint32(elf[0x18 + 2]) shl 16) or (uint32(elf[0x18 + 3]) shl 24)
    var e_phoff = uint32(elf[0x1C]) or (uint32(elf[0x1C + 1]) shl 8) or (uint32(elf[0x1C + 2]) shl 16) or (uint32(elf[0x1C + 3]) shl 24)
    var e_shoff = uint32(elf[0x20]) or (uint32(elf[0x20 + 1]) shl 8) or (uint32(elf[0x20 + 2]) shl 16) or (uint32(elf[0x20 + 3]) shl 24)
    var e_phentsize = uint16(elf[0x2A]) or (uint16(elf[0x2A + 1]) shl 8)
    var e_phnum = uint16(elf[0x2C]) or (uint16(elf[0x2C + 1]) shl 8)
    var e_shentsize = uint16(elf[0x2E]) or (uint16(elf[0x2E + 1]) shl 8)
    var e_shnum = uint16(elf[0x30]) or (uint16(elf[0x30 + 1]) shl 8)

    var i = 0'u16
    var program_headers: seq[array[3, uint32]]
    while i < e_phnum:
        var program_header: seq[uint8]
        var elf_pos = e_phoff + i*e_phentsize
        while elf_pos < (e_phoff + (i+1)*e_phentsize):
            program_header.add(elf[elf_pos])
            elf_pos += 1

        var p_offset = uint32(program_header[0x04]) or (uint32(program_header[0x04 + 1]) shl 8) or (uint32(program_header[0x04 + 2]) shl 16) or (uint32(program_header[0x04 + 3]) shl 24)
        var p_vaddr = uint32(program_header[0x08]) or (uint32(program_header[0x08 + 1]) shl 8) or (uint32(program_header[0x08 + 2]) shl 16) or (uint32(program_header[0x08 + 3]) shl 24)
        var p_filesz = uint32(program_header[0x10]) or (uint32(program_header[0x10 + 1]) shl 8) or (uint32(program_header[0x10 + 2]) shl 16) or (uint32(program_header[0x10 + 3]) shl 24)
        program_headers.add([p_offset, p_vaddr, p_filesz])
        i += 1

    i = 0'u16
    var section_headers: seq[array[3, uint32]]
    while i < e_shnum:
        var section_header: seq[uint8]
        var elf_pos = e_shoff + i*e_shentsize
        while elf_pos < (e_shoff + (i+1)*e_shentsize):
            section_header.add(elf[elf_pos])
            elf_pos += 1

        var sh_addr = uint32(section_header[0x0C]) or (uint32(section_header[0x0C + 1]) shl 8) or (uint32(section_header[0x0C + 2]) shl 16) or (uint32(section_header[0x0C + 3]) shl 24)
        var sh_offset = uint32(section_header[0x10]) or (uint32(section_header[0x10 + 1]) shl 8) or (uint32(section_header[0x10 + 2]) shl 16) or (uint32(section_header[0x10 + 3]) shl 24)
        var sh_size = uint32(section_header[0x14]) or (uint32(section_header[0x14 + 1]) shl 8) or (uint32(section_header[0x14 + 2]) shl 16) or (uint32(section_header[0x14 + 3]) shl 24)
        section_headers.add([sh_offset, sh_addr, sh_size])
        i += 1

    var x = 0
    while x < program_headers.len:
        var j = 0'u32
        echo program_headers[x]
        if program_headers[x][2] != 0:
            while j < program_headers[x][2]:
                store8(program_headers[x][1]+j, elf[program_headers[x][0]+j])
                j += 1
        x += 1


    #x = 0
    #while x < section_headers.len:
    #    var j = 0'u32
    #    echo section_headers[x]
    #    if section_headers[x][2] != 0:
    #        while j < section_headers[x][2]:
    #            store8(section_headers[x][1]+j, elf[section_headers[x][0]+j])
    #            j += 1
    #    x += 1


    echo "Loaded elf " & elf_location
    echo ""
    return e_entry