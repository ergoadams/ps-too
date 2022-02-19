import pkg/nint128
import strutils
import ../ee/ee_bus
import interrupt, timers, ../common/sif

# for pointer arithmetics in fastmem stuff
template `+`*[T](p: ptr T, off: int): ptr T =
  cast[ptr type(p[])](cast[ByteAddress](p) +% off * sizeof(p[]))


const REGION_MASK = [0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x7FFFFFFF'u32, 0x1FFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32]

var scratchpad: array[1024 , uint8]
var irq_en: bool
var channel_irq_en: uint8
var channel_irq_flags: uint8
var force_irq: bool
var irq_dummy: uint8

type
    DMABlockReg = object
        v: uint32
        size, count: uint32

    DCHCR = object
        v: uint32
        direction, increment, bit_8, transfer_mode: uint32
        chop_dma, chop_cpu, running, trigger: uint32

    DMAChannel_t = object
        address, tadr: uint32
        block_conf: DMABlockReg
        control: DCHCR
        end_transfer: bool

    DICR_t = object
        v: uint32
        completion, force, enable, master_enable, flags, master_flag: uint32

    DICR2_t = object
        v: uint32
        tag, mask, flags: uint32

proc `value=`(i: var DICR2_t, data: uint32) {.inline.} =
    i.v = data
    i.tag = (data shr 0) and 0x1FFF
    i.mask = (data shr 16) and 0x3F
    i.flags = (data shr 24) and 0x3F
    

proc `value=`(i: var DICR_t, data: uint32) {.inline.} =
    i.v = data
    i.completion = (data shr 0) and 0x7F
    i.force = (data shr 15) and 1
    i.enable = (data shr 16) and 0x7F
    i.master_enable = (data shr 23) and 1
    i.flags = (data shr 24) and 0x7F
    i.master_flag = (data shr 31) and 1

proc `value=`(i: var DMABlockReg, data: uint32) {.inline.} =
    i.v = data
    i.size = data and 0xFFFF
    i.count = data shr 16

proc `value=`(i: var DCHCR, data: uint32) {.inline.} =
    i.v = data
    i.direction = (data shr 0) and 1
    i.increment = (data shr 1) and 1
    i.bit_8 = (data shr 8) and 1
    i.transfer_mode = (data shr 9) and 3
    i.chop_dma = (data shr 16) and 7
    i.chop_cpu = (data shr 20) and 7
    i.running = (data shr 24) and 1
    i.trigger = (data shr 28) and 1

var channels: array[13, DMAChannel_t]

#Global
var dpcr, dpcr2, dmacen, dmacinten: uint32
var dicr: DICR_t
var dicr2: DICR2_t

proc get_char*(address: uint32): uint8 =
    return iop_ram[address]

proc irq(): bool =
    let channel_irq = channel_irq_flags and channel_irq_en
    return force_irq or (irq_en and (channel_irq != 0))

proc interrupt(): uint32 =
    var r = 0'u32
    r = r or cast[uint32](irq_dummy)
    if force_irq:
        r = r or (1 shl 15)

    r = r or (cast[uint32](channel_irq_en) shl 16)
    if irq_en:
        r = r or (1 shl 23)

    r = r or (cast[uint32](channel_irq_flags) shl 24)
    if irq():
        r = r or (1 shl 31)

proc set_interrupt(value: uint32) =
    let prev_irq = irq()

    irq_dummy = uint8(value and 0x3F)
    force_irq = ((value shr 15) and 1) != 0
    channel_irq_en = uint8((value shr 16) and 0x7F)
    irq_en = ((value shr 24) and 1) != 0
    let ack = uint8((value shr 24) and 0x3F)
    channel_irq_flags = channel_irq_flags and (not ack)

    if (not prev_irq) and irq():
        pend_irq(1, Interrupt.Dma)

proc set_dma_reg(offset: uint32, value: uint32) =
    let group = (offset shr 8) and 1
    if (offset and 0x70) == 0x70:
        let global_offset = ((offset and 0xF) shr 2) + 2*group
        if global_offset == 1:
            let original_flags = dicr.flags
            dicr.value = value
            dicr.flags = original_flags and (not ((value shr 24) and 0x7F))
            if (dicr.force != 0) or ((dicr.master_enable != 0) and ((dicr.enable and dicr.flags) > 0)):
                dicr.master_flag = 1
            else:
                dicr.master_flag = 0
        elif global_offset == 3:
            let original_flags = dicr2.flags
            dicr2.value = value
            dicr2.flags = original_flags and (not ((value shr 24) and 0x7F))
        else:
            case global_offset
                of 0: dpcr = value
                of 2: dpcr2 = value
                of 4: dmacen = value
                of 5: dmacinten = value
                else: echo "Unhandled set dma reg global " & $global_offset
    else:
        let channel = ((offset and 0x70) shr 4) + group*7
        let channel_offset = (offset and 0xF) shr 2 
        case channel_offset:
            of 0: channels[channel].address = value
            of 1: channels[channel].block_conf.value = value
            of 2: 
                channels[channel].control.value = value
                if channels[channel].control.running != 0:
                    echo "Should start IOP dma on channel " & $channel
            of 3: channels[channel].tadr = value
            else:
                echo "Unhandled dma channel_offset set " & $channel_offset
                
proc dma_reg(address: uint32): uint32 =
    let group = (address shr 8) and 1
    if (address and 0x70) == 0x70:
        #Globals
        let offset = ((address and 0xF) shr 2) + 2*group
        case offset:
            of 0: return dpcr
            of 1: return dicr.v
            of 2: return dpcr2
            of 3: return dicr2.v
            of 4: return dmacen
            of 5: return dmacinten
            else: echo "Unhandled dmareg global read offset " & $offset
    else:
        let channel = ((address and 0x70) shr 4) + group*7
        let offset = (address and 0xF) shr 2
        case offset:
            of 0: return channels[channel].address
            of 1: return channels[channel].block_conf.v             
            of 2: return channels[channel].control.v
            of 3: return channels[channel].tadr
            else: echo "Unhandled dmareg read offset " & $offset

proc fetch_tag_iop(id: uint32) =
    #echo "Unhandled IOP fetchtag id " & $id
    case id:
        of 10: # SIF1
            if sif1_fifo.len >= 4:
                var temp = u128(sif1_fifo[0]) shl 32
                temp = temp or u128(sif1_fifo[1])
                #dmatag.value = temp
                sif1_fifo.delete(0)
                sif1_fifo.delete(0)
                echo "Got IOP SIF1 tag " & temp.toHex()
        else: quit()


proc dma_tick*() =
    var id = 7'u32
    while id < 13:
        let channel = channels[id]
        let enable = (dpcr2 and (1'u32 shl ((id - 7)*4 + 3))) != 0
        if (channel.control.running != 0) and enable:
            if channel.block_conf.count > 0:
                case id:
                    else: echo "DATA TO TRANSFER ON CHANNEL " & $id
            elif channel.end_transfer:
                channels[id].control.running = 0
                channels[id].end_transfer = false
                dicr2.flags = dicr2.flags or (1'u32 shl (id - 7))
                if (dicr2.flags and dicr2.mask) != 0:
                    echo "IOP DMA INT!!"
            else:
                fetch_tag_iop(id)

        id += 1

# LOADS/STORES

proc load32*(vaddr: uint32): uint32 =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        return  (cast[uint32](iop_ram[address + 3]) shl 24) or 
                (cast[uint32](iop_ram[address + 2]) shl 16) or 
                (cast[uint32](iop_ram[address + 1]) shl 8) or 
                (cast[uint32](iop_ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return  (cast[uint32](bios[offset + 3]) shl 24) or 
                (cast[uint32](bios[offset + 2]) shl 16) or 
                (cast[uint32](bios[offset + 1]) shl 8) or 
                (cast[uint32](bios[offset + 0]) shl 0)
    elif address in 0x1F801070'u32 .. 0x1F801078'u32:
        case address:
            of 0x1F801070: return get_irq_status()
            of 0x1F801074: return get_irq_mask()
            of 0x1F801078: return get_irq_ctrl()
            else: quit("Invalid irq load32 address " & address.toHex(), QuitSuccess)
    elif address == 0x1D000000'u32: return mscom
    elif address == 0x1D000010'u32: return smcom
    elif address == 0x1D000020'u32: return msflg
    elif address == 0x1D000030'u32: return smflg
    elif address == 0x1D000040'u32: return sif_ctrl
    elif address == 0x1D000060'u32: return bd6

    elif address == 0x1F801578'u32: return 0x00
    elif address == 0x1F801450'u32: return 0x00
    elif address == 0xFFFE0130'u32: return 0x00

    elif address in 0x1F801080'u32 ..< 0x1F801100'u32: return dma_reg(address)
    elif address in 0x1F8010F0'u32 .. 0x1F8010F4'u32: return dma_reg(address)
    elif address in 0x1F801500'u32 ..< 0x1F801560'u32: return dma_reg(address)
    elif address in 0x1F801570'u32 .. 0x1F80157C'u32: return dma_reg(address)
    elif address in 0x1F801100'u32 ..< 0x1F80112C'u32: return timers_load(address)
    elif address in 0x1F801480'u32 ..< 0x1F8014AC'u32: return timers_load(address)
    else:
        echo "Unhandled IOP load32 " & address.toHex()
        return 0x00'u32

proc load16*(vaddr: uint32): uint16 =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        return  (cast[uint16](iop_ram[address + 1]) shl 8) or 
                (cast[uint16](iop_ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return  (cast[uint16](bios[offset + 1]) shl 8) or 
                (cast[uint16](bios[offset + 0]) shl 0)
    else:
        echo "Unhandled IOP load16 " & address.toHex()
        return 0x00'u16

proc load8*(vaddr: uint32): uint8 =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        return  (cast[uint8](iop_ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return  (cast[uint8](bios[offset + 0]) shl 0)
    elif address == 0x1F402005'u32: return 0x40
    else:
        echo "Unhandled IOP load8 " & address.toHex()
        return 0x00'u8

proc store32*(vaddr: uint32, value: uint32) =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x800000):
        let offset = address and 0x001FFFFF'u32
        iop_ram[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        iop_ram[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        iop_ram[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        iop_ram[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif address in 0x1F801070'u32 .. 0x1F801078'u32:
        case address:
            of 0x1F801070: irq_ack(value)
            of 0x1F801074: irq_set_mask(value)
            of 0x1F801078: irq_set_ctrl(value)
            else: quit("Invalid irq store32 address " & address.toHex(), QuitSuccess)
    elif address == 0x1D000010'u32: smcom = value
    elif address == 0x1D000030'u32: smflg = smflg xor value
    elif address == 0x1D000040'u32:
        var temp = value and 0xF0
        if (value and 0xA0) != 0:
            sif_ctrl = sif_ctrl and (not 0xF000'u32)
            sif_ctrl = sif_ctrl or 0x2000
        
        if (sif_ctrl and temp) != 0:
            sif_ctrl = sif_ctrl and (not temp)
        else:
            sif_ctrl = sif_ctrl or temp
    elif address == 0x1F801578'u32: return
    elif address == 0x1F801450'u32: return
    elif address in 0x1F801080'u32 ..< 0x1F801100'u32: set_dma_reg(address, value)
    elif address in 0x1F8010F0'u32 .. 0x1F8010F4'u32: set_dma_reg(address, value)
    elif address in 0x1F801500'u32 ..< 0x1F801560'u32: set_dma_reg(address, value)
    elif address in 0x1F801570'u32 .. 0x1F80157C'u32: set_dma_reg(address, value)
    elif address in 0x1F801000'u32 ..< 0x1F801024'u32: return
    elif address in 0x1F801100'u32 ..< 0x1F80112C'u32: timers_store(address, value)
    elif address in 0x1F801480'u32 ..< 0x1F8014AC'u32: timers_store(address, value)
    elif address in 0xFFFE0130'u32 ..< 0xFFFE0134'u32: return
    else:
        echo "Unhandled IOP store32 " & address.toHex() & " " & value.toHex()

proc store16*(vaddr: uint32, value: uint16) =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        iop_ram[address + 1] = cast[uint8]((value shr 8) and 0xFF)
        iop_ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    else:
        echo "Unhandle IOP store16 " & address.toHex() & " " & value.toHex()

proc store8*(vaddr: uint32, value: uint8) =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        iop_ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    else:
        echo "Unhandle IOP store8 " & address.toHex() & " " & value.toHex()