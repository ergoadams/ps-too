import strutils
import pkg/nint128
import gs

var cur_packet: seq[UInt128]

var nloop: uint32
var data_format: uint32
var nregs: uint32

var cur_nloop: uint32
var cur_nreg: uint32

var need_new_giftag: bool = true
var current_giftag: UInt128
var data_position: uint32
var data_left: uint32

proc gif_dma*(value: UInt128) =
    cur_packet.add(value)

proc gif_parse_packet*() =
    while data_position < uint32(cur_packet.len):
        if need_new_giftag:
            current_giftag = cur_packet[data_position]
            nloop = cast[uint32](current_giftag and (u128(0xFFFF) shr 1))
            data_format = cast[uint32]((current_giftag shr 58) and u128(0b11))
            nregs = cast[uint32]((current_giftag shr 60) and u128(0b1111))
            let enable_prim = ((current_giftag shr 46) and u128(1)) != u128(0)
            if enable_prim:
                let prim_data = cast[uint64]((current_giftag shr 47) and u128(0b11111111111))
                push_prim_data(prim_data)
            if nregs == 0:
                nregs = 16
            case data_format:
                of 0: data_left = nloop*nregs
                of 1:
                    echo "Unhandled REGLIST format"
                    data_left = nloop*nregs
                else: data_left = nloop
            data_position += 1
            need_new_giftag = nloop == 0
        else:
            if data_format == 0: # PACKED format
                let dest_reg = cast[uint32]((current_giftag shr (64 + (cur_nreg*4))) and u128(0b1111))
                push_packed_packet(cur_packet[data_position], dest_reg)
                data_position += 1
                cur_nloop += 1
                if cur_nloop == nloop:
                    cur_nloop = 0
                    cur_nreg += 1
                    if cur_nreg == nregs:
                        cur_nreg = 0
                        need_new_giftag = true
            elif data_format == 2: # IMAGE format
                push_image_packet(cur_packet[data_position])
                data_position += 1
                data_left -= 1
                if data_left == 0:
                    need_new_giftag = true

            else:
                echo "Unhandled gif data format " & $data_format
    
    # Finished the data, clear the packet buffer
    cur_packet = newSeq[UInt128](0)
    data_position = 0