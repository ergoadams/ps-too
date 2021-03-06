import strutils

type
    COP0_t = object
        index, entry_lo0, entry_lo1, page_mask, wired, badvaddr: uint32
        count, entry_hi, compare, status, cause, epc, config: uint32
        pr_id, tag_lo, error_epc: uint32

var cop0 = COP0_t(pr_id: 0x2E20, status: 0x400004)
var intc_stat: uint32
var intc_mask: uint32

proc get_intc_mask*(): uint32 =
    return intc_mask

proc get_intc_stat*(): uint32 =
    return intc_stat

proc get_bev*(): bool =
    return ((cop0.status shr 22) and 1) != 0

proc set_epc*(pc: uint32) =
    cop0.epc = pc

proc set_exccode*(code: uint32) =
    cop0.cause = cop0.cause and (not 0b1111100'u32)
    cop0.cause = cop0.cause or (code shl 2)

proc get_exl*(): bool =
    return (cop0.status and 0b10) != 0

proc set_exl*(value: uint32) =
    cop0.status = cop0.status and (not 0b10'u32)
    cop0.status = cop0.status or ((value and 1) shl 1)

proc set_ip0() =
    cop0.cause = cop0.cause or (1 shl 10)

proc irq_active*(): bool =
    let int_enabled =   (((cop0.status shr 16) and 1) != 0) and   
                        ((cop0.status and 1) != 0) and
                        (((cop0.status shr 2) and 1) == 0) and
                        (((cop0.status shr 1) and 1) == 0)
    let pending =   ((((cop0.cause shr 10) and 1) != 0) and (((cop0.status shr 10) and 1) != 0)) or 
                    ((((cop0.cause shr 11) and 1) != 0) and (((cop0.status shr 11) and 1) != 0)) or 
                    ((((cop0.cause shr 15) and 1) != 0) and (((cop0.status shr 15) and 1) != 0))
    return int_enabled and pending

proc mfc0*(rd: uint32, rt: uint32, sel: uint32): uint32 =
    case rd:
        of 0: return cop0.index
        of 8: return cop0.badvaddr
        of 9: return cop0.count
        of 11: return cop0.compare
        of 12: return cop0.status
        of 13: return cop0.cause
        of 14: return cop0.epc
        of 15: return cop0.pr_id
        of 16: return cop0.config
        of 28: return cop0.tag_lo
        else: 
            echo "Unhandled mfc0 " & $rd
            return 0x00

proc mtc0*(rd: uint32, sel: uint32, data: uint32) =
    case rd:
        of 0:  cop0.index = data
        of 2:  cop0.entry_lo0 = data
        of 3:  cop0.entry_lo1 = data
        of 5:  cop0.page_mask = data
        of 6:  cop0.wired = data
        of 9:  cop0.count = data
        of 10: cop0.entry_hi = data
        of 11: cop0.compare = data
        of 12: cop0.status = data
        of 14: cop0.epc = data
        of 16: cop0.config = data
        else:
            echo "Unhandled mtc0 " & $rd & " " & $sel & " " & data.toHex()

proc cop0_tick_counter*() =
    cop0.count += 1

proc op_tlbwi*() =
    discard
    #echo "tlbwi should access tlb entry " & $cop0.index

proc set_intc_mask*(bit: uint32) =
    intc_mask = intc_mask or (1'u32 shl bit)
    #echo "intcmask " & intc_mask.toHex()
    if (intc_mask and intc_stat) != 0:
        set_ip0()

proc set_intc_stat*(bit: uint32) =
    intc_stat = intc_stat or (1'u32 shl bit)
    #echo "intcstat " & intc_stat.toHex()
    if (intc_mask and intc_stat) != 0:
        #echo "setting ip0"
        set_ip0()

proc int_trigger*(value: uint32) =
    set_intc_stat(value)

proc cop0_di*() =
    if  (((cop0.status shr 17) and 1) != 0) or
        (((cop0.status shr 1) and 1) != 0) or
        (((cop0.status shr 2) and 1) != 0) or
        (((cop0.status shr 3) and 3) == 0):
        
        cop0.status = cop0.status and (not (1'u32 shl 16))

proc cop0_ei*() =
    if  (((cop0.status shr 17) and 1) != 0) or
        (((cop0.status shr 1) and 1) != 0) or
        (((cop0.status shr 2) and 1) != 0) or
        (((cop0.status shr 3) and 3) == 0):

        cop0.status = cop0.status or (1'u32 shl 16)

proc cop0_eret*(): uint32 =
    let erl = ((cop0.status shr 2) and 1) != 0
    if erl:
        cop0.status = cop0.status and (not (1'u32 shl 2))
        return cop0.error_epc
    else:
        cop0.status = cop0.status and (not (1'u32 shl 1))
        return cop0.epc