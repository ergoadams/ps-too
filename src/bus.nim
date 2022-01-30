import pkg/nint128
import streams, strutils
import gif, gs

var bios: array[0x400000 , uint8]
var ram: array[0x2000000, uint8]
var scratchpad: array[0x1000000, uint8]

var d_ctrl: uint32
var d_stat: uint32
var d_pcr: uint32
var d_sqwc: uint32
var d_rbsr: uint32
var d_rbor: uint32
var d_enabler: uint32
var d_enablew: uint32

var d_chcr: array[10, uint32]
var d_madr: array[10, uint32]
var d_tadr: array[10, uint32]
var d_qwc: array[10, uint32]
var d_asr0: array[10, uint32]
var d_asr1: array[10, uint32]
var d_sadr: array[10, uint32]

d_enabler = 0x1201'u32

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

    echo "Loaded bios from " & bios_location



proc dma_load32(address: uint32): uint32 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return (cast[uint32](ram[address + 3]) shl 24) or (cast[uint32](ram[address + 2]) shl 16) or (cast[uint32](ram[address + 1]) shl 8) or (cast[uint32](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return (cast[uint32](bios[offset + 3]) shl 24) or (cast[uint32](bios[offset + 2]) shl 16) or (cast[uint32](bios[offset + 1]) shl 8) or (cast[uint32](bios[offset + 0]) shl 0)
    else: 
        echo "Unhandled dma load32 " & address.toHex()
        return 0x0f0f0f0f'u32

proc do_dma(channel: uint32) =
    # tranfers quadwords (16 bytes, 4*32bits)
    let dma_mode = (d_chcr[channel] shr 2) and 0b11
    let tte = (d_chcr[channel] shr 6) and 1
    let tie = (d_chcr[channel] shr 7) and 1
    var quadword_count = d_qwc[channel] and 0xFFFF
    if dma_mode == 0:
        if channel == 2:
            var i = 0'u32
            while i < (quadword_count):
                gif_dma((u128(dma_load32(d_madr[channel] + 12)) shl 96) or 
                        (u128(dma_load32(d_madr[channel] + 8)) shl 64) or 
                        (u128(dma_load32(d_madr[channel] + 4)) shl 32) or 
                        (u128(dma_load32(d_madr[channel] + 0)) shl 0))
                d_madr[channel] += 16
                i += 1
            gif_parse_packet()
        else:
            echo "Unhandled dma channel " & $channel


    elif dma_mode == 1:
        var dma_running = true
        var tagid: uint32
        var tag_end = false
        while dma_running:
            if quadword_count == 0:
                let dmatag1 = dma_load32(d_tadr[channel]+0)
                let dmatag2 = dma_load32(d_tadr[channel]+4)
                let dmatag3 = dma_load32(d_tadr[channel]+8)
                let dmatag4 = dma_load32(d_tadr[channel]+12)
                quadword_count = dmatag1 and 0xFFFF
                d_qwc[channel] = quadword_count
                tagid = (dmatag1 shr 28) and 0b111
                let new_addr = dmatag2
                if tagid == 0:
                    d_madr[channel] = new_addr
                    d_tadr[channel] += 16
                    tag_end = true
                    if quadword_count == 0:
                        dma_running = false
                elif tagid == 1:
                    d_madr[channel] = d_tadr[channel] + 16
                else:
                    echo "Unhandled dmatag id " & $tagid
                    dma_running = false        
            else:
                if channel == 2:
                    var i = 0'u32
                    while i < quadword_count:
                        gif_dma((u128(dma_load32(d_madr[channel] + 12)) shl 96) or (u128(dma_load32(d_madr[channel] + 8)) shl 64) or (u128(dma_load32(d_madr[channel] + 4)) shl 32) or (u128(dma_load32(d_madr[channel] + 0)) shl 0))
                        d_madr[channel] += 16
                        i += 1
                    gif_parse_packet()
                    quadword_count = 0
                    if tagid == 1:
                        d_tadr[channel] = d_madr[channel]

                    if tag_end:
                        dma_running = false
                else:
                    echo "Unhandled dma channel chained " & $channel  
                    dma_running = false  



    else:
        echo "Unhandled dma mode " & $dma_mode

proc dmac_load32(address: uint32): uint32 = 
    if address == 0x1000E000'u32:   return d_ctrl
    elif address == 0x1000E010'u32: return d_stat
    elif address == 0x1000E020'u32: return d_pcr
    elif address == 0x1000E030'u32: return d_sqwc
    elif address == 0x1000E040'u32: return d_rbsr
    elif address == 0x1000E050'u32: return d_rbor
    elif (address >= 0x10008000'u32) and (address < 0x1000D500'u32):
        var channel = (address shr 12) and 0xF - 0x8
        if channel == 3 or channel == 8:
            if ((address shr 8) and 0xF) == 0x4:
                channel += 1
        elif channel == 5:
            if ((address shr 8) and 0xF) == 0x4:
                channel += 1
            elif ((address shr 8) and 0xF) == 0x8:
                channel += 2
        case address and 0xFF:
            of 0x00: return d_chcr[channel]
            of 0x10: return d_madr[channel]
            of 0x20: return d_qwc[channel]
            of 0x30: return d_tadr[channel]
            of 0x40: return d_asr0[channel]
            of 0x50: return d_asr1[channel]
            of 0x80: return d_sadr[channel]
            else: 
                echo "Unhandled dma reg " & (address and 0xFF).toHex()
                return 0x00'u32
    else:
        echo "Unhandled dmac load32 " & address.toHex()
        return 0x00'u32

proc dmac_store32(address: uint32, value: uint32) = 
    if address == 0x1000E000'u32:   d_ctrl = value
    elif address == 0x1000E010'u32: d_stat = value
    elif address == 0x1000E020'u32: d_pcr = value
    elif address == 0x1000E030'u32: d_sqwc = value
    elif address == 0x1000E040'u32: d_rbsr = value
    elif address == 0x1000E050'u32: d_rbor = value
    elif (address >= 0x10008000'u32) and (address < 0x1000D500'u32):
        var channel = (address shr 12) and 0xF - 0x8
        if channel == 3 or channel == 8:
            if ((address shr 8) and 0xF) == 0x4:
                channel += 1
        elif channel == 5:
            if ((address shr 8) and 0xF) == 0x4:
                channel += 1
            elif ((address shr 8) and 0xF) == 0x8:
                channel += 2
        case address and 0xFF:
            of 0x00: 
                #echo "Set channel " & $channel & " control to " & value.toHex()
                d_chcr[channel] = value
                if (value and 0x100) != 0:
                    do_dma(channel)
                d_chcr[channel] = value and (not 0x100'u32)
            of 0x10: d_madr[channel] = value
            of 0x20: d_qwc[channel] = value
            of 0x30: d_tadr[channel] = value
            of 0x40: d_asr0[channel] = value
            of 0x50: d_asr1[channel] = value
            of 0x80: d_sadr[channel] = value
            else: echo "Unhandled dma reg store " & (address and 0xFF).toHex()
    else:
        echo "Unhandled dmac store32 " & address.toHex() & " " & value.toHex()


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
        let offset = address - 0x70000000'u32
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
        echo "unhandled store128 " & address.toHex() & " " & value.toHex()

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
        let offset = address - 0x70000000'u32
        scratchpad[offset + 7] = cast[uint8]((value shr 56) and 0xFF)
        scratchpad[offset + 6] = cast[uint8]((value shr 48) and 0xFF)
        scratchpad[offset + 5] = cast[uint8]((value shr 40) and 0xFF)
        scratchpad[offset + 4] = cast[uint8]((value shr 32) and 0xFF)
        scratchpad[offset + 3] = cast[uint8]((value shr 24) and 0xFF)
        scratchpad[offset + 2] = cast[uint8]((value shr 16) and 0xFF)
        scratchpad[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        scratchpad[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    else:
        echo "unhandled store64 " & address.toHex() & " " & value.toHex()

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
    elif (address >= 0x10008000'u32) and (address < 0x1000D500'u32):
        dmac_store32(address, value)
    elif (address >= 0x1000E000'u32) and (address < 0x1000E060'u32):
        dmac_store32(address, value)
    elif address == 0x12001000'u32: GS_CSR = cast[uint64](value)
    else:
        echo "unhandled store32 " & address.toHex() & " " & value.toHex()

proc store16*(address: uint32, value: uint16) =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        ram[address + 1] = cast[uint8]((value shr 8) and 0xFF)
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        bios[offset + 1] = cast[uint8]((value shr 8) and 0xFF)
        bios[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    else:
        echo "unhandled store16 " & address.toHex() & " " & value.toHex()

proc store8*(address: uint32, value: uint8) =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        ram[address + 0] = cast[uint8]((value shr 0) and 0xFF)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        bios[offset + 0] = cast[uint8]((value shr 0) and 0xFF)
    else:
        echo "unhandled store8 " & address.toHex() & " " & value.toHex()

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
        echo "Unhandled load128 " & address.toHex()
        return u128(0)

proc load64*(address: uint32): uint64 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return (cast[uint64](ram[address + 7]) shl 56) or (cast[uint64](ram[address + 6]) shl 48) or (cast[uint64](ram[address + 5]) shl 40) or (cast[uint64](ram[address + 4]) shl 32) or (cast[uint64](ram[address + 3]) shl 24) or (cast[uint64](ram[address + 2]) shl 16) or (cast[uint64](ram[address + 1]) shl 8) or (cast[uint64](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return (cast[uint64](bios[offset + 7]) shl 56) or (cast[uint64](bios[offset + 6]) shl 48) or (cast[uint64](bios[offset + 5]) shl 40) or (cast[uint64](bios[offset + 4]) shl 32) or (cast[uint64](bios[offset + 3]) shl 24) or (cast[uint64](bios[offset + 2]) shl 16) or (cast[uint64](bios[offset + 1]) shl 8) or (cast[uint64](bios[offset + 0]) shl 0)
    elif address == 0x12001000'u32: return GS_CSR
    else: 
        echo "Unhandled load64 " & address.toHex()
        return 0x0f0f0f0f'u64

proc load32*(address: uint32): uint32 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return (cast[uint32](ram[address + 3]) shl 24) or (cast[uint32](ram[address + 2]) shl 16) or (cast[uint32](ram[address + 1]) shl 8) or (cast[uint32](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return (cast[uint32](bios[offset + 3]) shl 24) or (cast[uint32](bios[offset + 2]) shl 16) or (cast[uint32](bios[offset + 1]) shl 8) or (cast[uint32](bios[offset + 0]) shl 0)
    elif (address >= 0x10008000'u32) and (address < 0x1000D500'u32):
        return dmac_load32(address)
    elif (address >= 0x1000E000'u32) and (address < 0x1000E060'u32):
        return dmac_load32(address)
    elif address == 0x12001000'u32: return cast[uint32](GS_CSR)
    else: 
        echo "Unhandled load32 " & address.toHex()
        return 0x0f0f0f0f'u32

proc load16*(address: uint32): uint16 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return (cast[uint16](ram[address + 1]) shl 8) or (cast[uint16](ram[address + 0]) shl 0)
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return (cast[uint16](bios[offset + 1]) shl 8) or (cast[uint16](bios[offset + 0]) shl 0)
    else: 
        echo "Unhandled load16 " & address.toHex()
        return 0x0f'u16

proc load8*(address: uint32): uint8 =
    let address = translate_address(address)
    if (address >= 0x00000000'u32) and (address < 0x00000000'u32 + 0x2000000):
        return ram[address]
    elif (address >= 0x1FC00000'u32) and (address < 0x1FC00000'u32 + 0x400000):
        let offset = address - 0x1FC00000'u32
        return bios[offset]
    else: 
        echo "Unhandled load8 " & address.toHex()
        return 0x0f'u8



proc load_elf*(elf_location: string): uint32 =
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
    return e_entry