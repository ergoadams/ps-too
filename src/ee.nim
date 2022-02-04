import strutils, bus, cop0, gs
import pkg/nint128

var pc: uint32 = 0xBFC00000'u32
var opcode: uint32
var execute_delay = false
var delayed_pc: uint32

var gprs: array[32, UInt128]
var hi: uint64
var lo: uint64
var op_index: uint32
var sub_op_index: uint32 

proc fetch_opcode(pc: uint32): uint32 =
    let value = load32(pc)
    return value

proc set_pc*(new_pc: uint32) =
    pc = new_pc

proc op_unhandled() =
    quit("op_unhandled at " & pc.toHex() & " " & opcode.toHex() & " " & int64(op_index).toBin(6) & " " & int64(sub_op_index).toBin(6), 0)

proc prepare_branch_delay() =
    opcode = fetch_opcode(pc)
    op_index = opcode shr 26
    execute_delay = true

proc op_sll() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111

    let temp = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rt]) shl sa))))
    gprs[rd] = temp

proc op_dsll() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111

    let temp = cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shl sa
    gprs[rd] = u128(temp)

proc op_srl() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111

    let temp = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rt]) shr sa))))
    gprs[rd] = temp

proc op_sra() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111
    let temp2 = 0xFFFFFFFF'u32 shl (32 - sa)
    let temp = u128(cast[uint64](cast[int64](cast[int32]((cast[uint32](gprs[rt]) shr sa) or temp2))))
    gprs[rd] = temp

proc op_dsrl() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111
    gprs[rd] = u128(cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shr sa)

proc op_jr() =
    let rs = (opcode shr 21) and 0b11111
    let hint = (opcode shr 6) and 0b11111
    prepare_branch_delay()
    delayed_pc = cast[uint32](gprs[rs] and u128(0xFFFFFFFF))

proc op_jalr() =
    let rs = (opcode shr 21) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let hint = (opcode shr 6) and 0b11111
    gprs[rd] = u128(pc + 4)
    prepare_branch_delay()
    delayed_pc = cast[uint32](gprs[rs] and u128(0xFFFFFFFF))

proc op_nor() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = (gprs[rd] and (not u128(0xFFFFFFFFFFFFFFFF))) or ((not (gprs[rs] or gprs[rt])) and u128(0xFFFFFFFFFFFFFFFF)) 

proc op_or() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = (gprs[rd] and (not u128(0xFFFFFFFFFFFFFFFF))) or ((gprs[rs] or gprs[rt]) and u128(0xFFFFFFFFFFFFFFFF)) 

proc op_and() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = (gprs[rd] and (not u128(0xFFFFFFFFFFFFFFFF))) or ((gprs[rs] and gprs[rt]) and u128(0xFFFFFFFFFFFFFFFF)) 

proc op_addu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) + cast[uint32](gprs[rt])))))

proc op_daddu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(cast[uint64](gprs[rs]) + cast[uint64](gprs[rt]))

proc op_dsubu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(cast[uint64](gprs[rs]) - cast[uint64](gprs[rt]))


proc op_add() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let result = cast[uint32](gprs[rs]) + cast[uint32](gprs[rt])
    #if result > 0xFFFFFFFF'u64:
    #    discard#echo "Add overflow"
    #else:
    gprs[rd] = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](result)))))


proc op_subu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) - cast[uint32](gprs[rt])))))

proc op_sub() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let result = cast[uint32](gprs[rs]) - cast[uint32](gprs[rt])
    #if result > 0xFFFFFFFF'u64:
    #    discard#echo "sub overflow"
    #else:
    gprs[rd] = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](result)))))



proc op_sltu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    if cast[uint64](gprs[rs]) < cast[uint64](gprs[rt]):
        gprs[rd] = u128(1)
    else:
        gprs[rd] = u128(0)

proc op_mult() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let result = cast[int64](cast[int32](gprs[rs])) * cast[int64](cast[int32](gprs[rt]))
    lo = cast[uint64](cast[int64](cast[int32](result and 0xFFFFFFFF)))
    hi = cast[uint64](cast[int64](cast[int32](result shr 32)))


proc op_syscall() =
    let code = cast[uint8](gprs[3])
    case code:
        of 0x02:
            # SetGsCrt
            let interlaced = cast[uint64](gprs[4]) != 0
            let mode = cast[uint8](gprs[5])
            let frame_mode = cast[uint64](gprs[6]) != 0
            set_gscrt(interlaced, mode, frame_mode)
        of 0x64: discard # FlushCache
        of 0x71:
            # GsPutIMR
            GS_IMR = cast[uint64](gprs[4])
        else:
            echo "Unhandled syscall " & cast[uint8](gprs[3]).toHex()

proc op_sync() =
    discard

proc op_dsll32() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111

    let temp = cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shl (sa + 32)
    gprs[rd] = u128(temp)

proc op_dsrl32() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111

    let temp = cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shr (sa + 32)
    gprs[rd] = u128(temp)

proc op_dsra32() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sa = (opcode shr 6) and 0b11111
    let temp2 = 0xFFFFFFFFFFFFFFFF'u64 shl (32 - sa)
    let temp = cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shr (sa + 32)
    gprs[rd] = u128(temp)
    if (temp and (1'u64 shl 63)) != 0:
        gprs[rd] = gprs[rd] or u128(temp2)

proc op_divu() =
    let rt = (opcode shr 16) and 0b11111
    let rs = (opcode shr 21) and 0b11111
    lo = cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) div cast[uint32](gprs[rt]))))
    hi = cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) mod cast[uint32](gprs[rt]))))

proc op_mfhi() =
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(hi)

proc op_break() =
    echo "Unhandled break"
    
const SPECIAL_INSTRUCTION: array[64, proc] = [op_sll, op_unhandled, op_srl, op_sra, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_jr, op_jalr, op_unhandled, op_unhandled, op_syscall, op_break, op_unhandled, op_sync,
                                           op_mfhi, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_mult, op_unhandled, op_unhandled, op_divu, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_add, op_addu, op_sub, op_subu, op_and, op_or, op_unhandled, op_nor,
                                           op_unhandled, op_unhandled, op_unhandled, op_sltu, op_unhandled, op_daddu, op_unhandled, op_dsubu,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_dsll, op_unhandled, op_dsrl, op_unhandled, op_dsll32, op_unhandled, op_dsrl32, op_dsra32]


proc op_bltz() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    let rs = (opcode shr 21) and 0b11111
    if cast[int64](gprs[rs]) < 0:
        prepare_branch_delay()
        delayed_pc = pc + offset
        #echo "Branched to " & pc.toHex()

proc op_bgez() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    let rs = (opcode shr 21) and 0b11111
    if cast[int64](gprs[rs]) >= 0:
        prepare_branch_delay()
        delayed_pc = pc + offset
        #echo "Branched to " & pc.toHex()


const REGIMM_INSTRUCTION: array[32, proc] = [op_bltz, op_bgez, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]



proc op_mfc0() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sel = opcode and 0b111
    let data = mfc0(rd, rt, sel)
    gprs[rt] = u128(data)

proc op_mtc0() =
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let sel = opcode and 0b111
    mtc0(rd, sel, cast[uint32](gprs[rt]))

proc op_bc0() =
    let fmt = (opcode shr 16) and 0b11111
    echo "bc0 " & int64(fmt).toBin(5)

proc op_tlb() =
    let fmt = opcode and 0b111111
    echo "tlb " & int64(fmt).toBin(6)

const COP0_INSTRUCTION: array[32, proc] = [op_mfc0, op_unhandled, op_unhandled, op_unhandled, op_mtc0, op_unhandled, op_unhandled, op_unhandled,
                                           op_bc0, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_tlb, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]


proc op_special() =
    sub_op_index = opcode and 0b111111
    SPECIAL_INSTRUCTION[sub_op_index]()

proc op_regimm() =
    sub_op_index = (opcode shr 16) and 0b11111
    REGIMM_INSTRUCTION[sub_op_index]()

proc op_w() =
    if (opcode and 0b111111) != 0b100000:
        echo "Invalid FPU.W opcode"
    else:
        echo "Unhandled CVT.s"

proc op_s() =
    echo "Unhandled FPU.S opcode " & u128(opcode and 0b111111).toBin(6)

proc op_mtc1() =
    echo "Unhandled mtc1"

proc op_mfc1() =
    echo "Unhandled mfc1"
        

const COP1_INSTRUCTION: array[32, proc] = [op_mfc1, op_unhandled, op_unhandled, op_unhandled, op_mtc1, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_s, op_unhandled, op_unhandled, op_unhandled, op_w, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]



proc op_cop1() =
    sub_op_index = (opcode shr 21) and 0b11111
    COP1_INSTRUCTION[sub_op_index]()

proc op_blezl() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    let rs = (opcode shr 21) and 0b11111
    if cast[int64](gprs[rs]) <= 0:
        prepare_branch_delay()
        delayed_pc = pc + offset
        #echo "Branched to " & pc.toHex()

proc op_blez() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    let rs = (opcode shr 21) and 0b11111
    if cast[int64](gprs[rs]) <= 0:
        prepare_branch_delay()
        delayed_pc = pc + offset

proc op_sd() =
    {.gcsafe.}:
        let base = (opcode shr 21) and 0b11111
        let rt = (opcode shr 16) and 0b11111
        let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF))) + cast[uint32](gprs[base] and u128(0xFFFFFFFF))
        store64(offset and (not 3'u32), cast[uint64](gprs[rt]))

proc op_ld() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF))) + cast[uint32](gprs[base] and u128(0xFFFFFFFF))
    gprs[rt] = u128(load64(offset and (not 3'u32)))

proc op_cop0() =
    sub_op_index = (opcode shr 21) and 0b11111
    COP0_INSTRUCTION[sub_op_index]()

proc op_slti() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = opcode and 0xFFFF
    if cast[uint64](gprs[rs]) < cast[uint64](cast[int64](cast[int16](imm))):
        gprs[rt] = u128(1)
    else:
        gprs[rt] = u128(0)

proc op_sltiu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = opcode and 0xFFFF
    if cast[uint64](gprs[rs]) < cast[uint64](imm):
        gprs[rt] = u128(1)
    else:
        gprs[rt] = u128(0)

proc op_bne() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    if cast[uint64](gprs[rs]) != cast[uint64](gprs[rt]):
        prepare_branch_delay()
        delayed_pc = pc + offset
        #echo "Branched to " & pc.toHex()

proc op_bnel() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    if cast[uint64](gprs[rs]) != cast[uint64](gprs[rt]):
        prepare_branch_delay()
        delayed_pc = pc + offset
        #echo "Branched to " & pc.toHex()

proc op_beq() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    if cast[uint64](gprs[rs]) == cast[uint64](gprs[rt]):
        prepare_branch_delay()
        delayed_pc = pc + offset
        #echo "Branched to " & pc.toHex()

proc op_beql() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    if gprs[rs] == gprs[rt]:
        prepare_branch_delay()
        delayed_pc = pc + offset
        #echo "Branched to " & pc.toHex()
    
proc op_addi() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    let result = cast[uint64](cast[uint32](gprs[rs])) + cast[uint64](imm)
    if result > 0xFFFFFFFF'u64:
        echo "addi overflow"
    else:
        gprs[rt] = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](result)))))

proc op_lui() =
    let rt = (opcode shr 16) and 0b11111
    let imm = cast[uint64](cast[int64](cast[int32]((opcode and 0xFFFF) shl 16)))
    gprs[rt] = u128(imm)

proc op_ori() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = u128(opcode and 0xFFFF)
    gprs[rt] = gprs[rs] or imm

proc op_xori() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = u128(opcode and 0xFFFF)
    gprs[rt] = gprs[rs] xor imm

proc op_addiu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs] and u128(0xFFFFFFFF)) + imm))))


proc op_lw() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = u128(cast[uint64](cast[int64](cast[int32](load32(cast[uint32](gprs[base]) + offset)))))

proc op_andi() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = opcode and 0xFFFF
    gprs[rt] = gprs[rs] and u128(imm)

proc op_sw() =
    {.gcsafe.}:
        let base = (opcode shr 21) and 0b11111
        let rt = (opcode shr 16) and 0b11111
        let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
        store32((cast[uint32](gprs[base]) + offset) and (not 3'u32), cast[uint32](gprs[rt] and u128(0xFFFFFFFF)))

proc op_sb() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    store8(cast[uint32](gprs[base]) + offset, cast[uint8](gprs[rt] and u128(0xFF)))

proc op_sh() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[uint16](cast[int16](opcode and 0xFFFF)))
    store16((cast[uint32](gprs[base]) + offset) and (not 1'u32), cast[uint16](gprs[rt] and u128(0xFFFF)))

proc op_lb() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = u128(cast[uint64](cast[int64](cast[int8](load8(offset + cast[uint32](gprs[base]))))))

proc op_lh() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = u128(cast[uint64](cast[int64](cast[int16](load16(offset + cast[uint32](gprs[base]))))))

proc op_jal() =
    gprs[31] = u128(pc + 4)
    let address = (opcode shl 6) shr 4
    delayed_pc = (pc and 0xF0000000'u32) or address
    prepare_branch_delay()

proc op_j() =
    let address = (opcode shl 6) shr 4
    delayed_pc = (pc and 0xF0000000'u32) or address
    prepare_branch_delay()

proc op_lbu() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = u128(load8(offset + cast[uint32](gprs[base] and u128(0xFFFFFFFFFF))))

proc op_lhu() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = u128(load16(offset + cast[uint32](gprs[base])))

proc op_sq() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[uint16](cast[int16](opcode and 0xFFFF)))
    store128((cast[uint32](gprs[base]) + offset) and (not 0xF'u32), gprs[rt])

proc op_lq() =
    let base = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = load128(cast[uint32](gprs[base]) + offset)

proc op_lwc1() =
    echo "unhandled lwc1"

proc op_swc1() =
    echo "unhandled swc1"

proc op_mult1() =
    echo "Unhandled mult1"

const MMI_INSTRUCTION: array[64, proc] = [op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_mult1, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]


proc op_mmi() =
    sub_op_index = opcode and 0b11111
    MMI_INSTRUCTION[sub_op_index]()

const NORMAL_INSTRUCTION: array[64, proc] = [op_special, op_regimm, op_j, op_jal, op_beq, op_bne, op_blez, op_unhandled,
                                           op_addi, op_addiu, op_slti, op_sltiu, op_andi, op_ori, op_xori, op_lui,
                                           op_cop0, op_cop1, op_unhandled, op_unhandled, op_beql, op_bnel, op_blezl, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_mmi, op_unhandled, op_lq, op_sq,
                                           op_lb, op_lh, op_unhandled, op_lw, op_lbu, op_lhu, op_unhandled, op_unhandled,
                                           op_sb, op_sh, op_unhandled, op_sw, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_lwc1, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_ld,
                                           op_unhandled, op_swc1, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_sd]


proc ee_tick*() =
    gprs[0] = u128(0)
    if execute_delay:
        NORMAL_INSTRUCTION[op_index]()
        pc = delayed_pc
        execute_delay = false
        #echo pc.toHex() & " " & int64(op_index).toBin(6)

    opcode = fetch_opcode(pc)
    op_index = opcode shr 26
    #echo pc.toHex() & " " & int64(op_index).toBin(6) & " " & $gprs
    pc += 4
    NORMAL_INSTRUCTION[op_index]()
    