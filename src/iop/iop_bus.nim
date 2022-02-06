import strutils
import ../ee/ee_bus
import interrupt, timers

# for pointer arithmetics in fastmem stuff
template `+`*[T](p: ptr T, off: int): ptr T =
  cast[ptr type(p[])](cast[ByteAddress](p) +% off * sizeof(p[]))


const REGION_MASK = [0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32, 0x7FFFFFFF'u32, 0x1FFFFFFF'u32, 0xFFFFFFFF'u32, 0xFFFFFFFF'u32]

var ram: array[0x200000, uint8]
var scratchpad: array[1024 , uint8]

type
    Step = enum
        Increment = 0,
        Decrement = 1

    Direction = enum
        ToRam = 0,
        FromRam = 1

    Sync = enum
        Manual = 0,
        Request = 1,
        LinkedList = 2

    Port = enum
        MdecIn = 0,
        MdecOut = 1,
        Gpu = 2,
        CdRom = 3,
        Spu = 4,
        Pio = 5,
        Otc = 6

    Channel = ref object
        enable: bool
        direction: Direction
        step: Step
        sync: Sync
        trigger: bool
        chop: bool
        chop_dma_sz: uint8
        chop_cpu_sz: uint8
        dummy: uint8

        base: uint32
        block_size: uint16
        block_count: uint16

var channels = [Channel(), Channel(), Channel(), Channel(), Channel(), Channel(), Channel()]
var dma_control = 0x07654321'u32
var irq_en: bool
var channel_irq_en: uint8
var channel_irq_flags: uint8
var force_irq: bool
var irq_dummy: uint8
var irq_ctrl: uint32

proc irq(): bool =
    let channel_irq = channel_irq_flags and channel_irq_en
    return force_irq or (irq_en and (channel_irq != 0))

proc channel_control(channel: Channel): uint32 =
    var r = 0'u32
    r = r or cast[uint32](ord(channel.direction))
    r = r or cast[uint32](ord(channel.step) shl 1)
    if channel.chop:
        r = r or (1 shl 8)
    r = r or cast[uint32](ord(channel.sync) shl 9)
    r = r or (cast[uint32](channel.chop_dma_sz) shl 16)
    r = r or (cast[uint32](channel.chop_cpu_sz) shl 20)
    if channel.enable:
        r = r or (1 shl 24)
    if channel.trigger:
        r = r or (1 shl 28)
    r = r or (cast[uint32](channel.dummy) shl 29)

proc channel_block_control(channel: Channel): uint32 =
    return (cast[uint32](channel.block_count) shl 16) or cast[uint32](channel.block_size)

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

proc dma_reg(offset: uint32) : uint32 =
    let major = (offset and 0x70) shr 4
    let minor = offset and 0xF
    case major:
        of 0 .. 6:
            let channel = channels[major]
            case minor:
                of 0: return channel.base
                of 4: return channel_block_control(channel)
                of 8: return channel_control(channel)
                else: quit("Unhandled DMA read at " & offset.toHex(), QuitSuccess)
        of 7:
            case minor:
                of 0: return dma_control
                of 4: return interrupt()
                else: quit("Unhandled DMA read at " & offset.toHex(), QuitSuccess)
        else: quit("Unhandled DMA read at " & offset.toHex(), QuitSuccess)

proc set_channel_base(channel: Channel, value: uint32) =
    channel.base = value and 0xFFFFFF

proc set_channel_block_control(channel: Channel, value: uint32) =
    channel.block_size = cast[uint16](value)
    channel.block_count = cast[uint16](value shr 16)

proc set_channel_control(channel: Channel, value: uint32) =
    channel.direction = case ((value and 1) != 0):
        of true: Direction.FromRam
        of false: Direction.ToRam

    channel.step = case (((value shr 1) and 1) != 0):
        of true: Step.Decrement
        of false: Step.Increment

    channel.chop = ((value shr 8) and 1) != 0

    channel.sync = case ((value shr 9) and 3):
        of 0: Sync.Manual
        of 1: Sync.Request
        of 2: Sync.LinkedList
        else: quit("Unknown DMA sync mode " & ((value shr 9) and 3).toHex(), QuitSuccess)

    channel.chop_dma_sz = cast[uint8]((value shr 16) and 7)
    channel.chop_cpu_sz = cast[uint8]((value shr 20) and 7)

    channel.enable = ((value shr 24) and 1) != 0
    channel.trigger = ((value shr 28) and 1) != 0

    channel.dummy = cast[uint8]((value shr 29) and 3)

proc channel_active(channel: Channel): bool =
    let trigger = case channel.sync:
        of Sync.Manual: channel.trigger
        else: true
    return channel.enable and trigger

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
    let major = (offset and 0x70) shr 4
    let minor = offset and 0xF
    var active_port = 0xFF'u32
    case major:
        of 0 .. 6:
            let channel = channels[major]
            case minor:
                of 0: set_channel_base(channel, value)
                of 4: set_channel_block_control(channel, value)
                of 8: set_channel_control(channel, value)
                else: echo "Unhandled DMA write at " & $major & " " & $minor & " " & value.toHex()
            if channel_active(channel):
                active_port = major
        of 7:
            case minor:
                of 0: dma_control = value
                of 4: set_interrupt(value)
                else: quit("Unhandled DMA write at " & offset.toHex() & " " & value.toHex(), QuitSuccess)
        else: quit("Unhandled DMA write at " & offset.toHex() & " " & value.toHex(), QuitSuccess)

    if active_port != 0xFF'u8:
        echo "IOP DMA?"
        #do_dma(major)

# LOADS/STORES

proc load32*(vaddr: uint32): uint32 =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        return  (cast[uint32](ram[address + 3]) shl 24) or 
                (cast[uint32](ram[address + 2]) shl 16) or 
                (cast[uint32](ram[address + 1]) shl 8) or 
                (cast[uint32](ram[address + 0]) shl 0)
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
    elif address in 0x1F801480'u32 .. 0x1F8014AC'u32: return 0x00'u32 # TImers
    elif address == 0x1F801450'u32: return 0x00'u32
    elif address == 0x1F801578'u32: return 0x00'u32
    elif address in 0xFFFE0000'u32 .. 0xFFFE0200'u32: return 0x00'u32
    elif address == 0x1D000020'u32: return 0'u32

    else:
        echo "Unhandled IOP load32 " & address.toHex()
        return 0x00'u32

proc load16*(vaddr: uint32): uint16 =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        return  (cast[uint16](ram[address + 1]) shl 8) or 
                (cast[uint16](ram[address + 0]) shl 0)
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
        return  (cast[uint8](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return  (cast[uint8](bios[offset + 0]) shl 0)
    elif address == 0x1F402005'u32: return 0x40'u8
    else:
        echo "Unhandled IOP load8 " & address.toHex()
        return 0x00'u8

proc store32*(vaddr: uint32, value: uint32) =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        ram[address + 3] = cast[uint8]((value shr 24) and 0xFF)
        ram[address + 2] = cast[uint8]((value shr 16) and 0xFF)
        ram[address + 1] = cast[uint8]((value shr 8) and 0xFF)
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif address in 0x1F801000'u32 .. 0x1F801020'u32: echo "Unhandled Memory Control store32 " & address.toHex() & " " & value.toHex()
    elif address == 0x1F801060'u32: discard # RAM_SIZE
    elif address in 0x1F801070'u32 .. 0x1F801078'u32:
        case address:
            of 0x1F801070: irq_ack(value)
            of 0x1F801074: irq_set_mask(value)
            of 0x1F801078: irq_set_ctrl(value)
            else: quit("Invalid irq store32 address " & address.toHex(), QuitSuccess)
    elif address == 0x1F801450'u32: discard
    elif address in 0x1F801480'u32 .. 0x1F8014AC'u32: discard # Timers
    elif address == 0x1F801578'u32: discard
    elif address == 0x1F802070'u32: discard # POST2?
    elif address in 0xFFFE0000'u32 .. 0xFFFE0200'u32: discard
    else:
        echo "Unhandled IOP store32 " & address.toHex() & " " & value.toHex()

proc store16*(vaddr: uint32, value: uint16) =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        ram[address + 1] = cast[uint8]((value shr 8) and 0xFF)
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif address in 0x1F801480'u32 .. 0x1F8014AC'u32: discard # Timers
    else:
        echo "Unhandle IOP store16 " & address.toHex() & " " & value.toHex()

proc store8*(vaddr: uint32, value: uint8) =
    let address = vaddr and REGION_MASK[vaddr shr 29]
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x200000):
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif address == 0x1F802070'u32: discard # POST2?
    else:
        echo "Unhandle IOP store8 " & address.toHex() & " " & value.toHex()