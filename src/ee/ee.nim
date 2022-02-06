import strutils, pkg/nint128, streams
import ee_bus, cop0, gs, timer

var pc: uint32 = 0xBFC00000'u32
var opcode: uint32
var execute_delay = false
var delayed_pc: uint32

var gprs: array[32, UInt128]
var fprs: array[32, uint32]
var fcr0, fcr31: uint32
var hi: uint64
var lo: uint64
var hi1: uint64
var lo1: uint64
var op_index: uint32
var sub_op_index: uint32 

var elf_load_path: string
var should_load_elf: bool
var should_dump = false

type
    Exception = enum
        Interrupt = 0x0,
        LoadAddressError = 0x4,
        StoreAddressError = 0x5,
        SysCall = 0x8,
        Break = 0x9,
        CoprocessorError = 0xB,
        Overflow = 0xC,
        Trap = 0xD

proc exception(exception: Exception) =
    echo "Got exception " & $exception
    set_exccode(cast[uint32](ord(exception)))
    var vector = 0x180'u32
    if not get_exl():
        set_epc(pc)
        case exception:
            of Exception.Interrupt:
                vector = 0x200'u32
            of Exception.SysCall: discard
            else:
                echo "Unhandled exception " & $exception
        set_exl(1)
    if get_bev():
        pc = 0xBFC00200'u32 + vector
    else:
        pc = 0x80000000'u32 + vector
    echo "Set PC to " & pc.toHex()

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

proc op_sllv() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111

    let temp = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rt]) shl (cast[uint32](gprs[rs]) and 0b11111)))))
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
    let temp2 = u128(0xFFFFFFFF'u32 shl (32 - sa))
    let is_sign = (cast[uint32](gprs[rt]) shr 31) != 0
    var temp = u128(cast[uint64](cast[int64](cast[int32]((cast[uint32](gprs[rt]) shr sa)))))
    if is_sign:
        temp = temp or temp2
    gprs[rd] = temp

proc op_srav() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let temp2 = u128(0xFFFFFFFF'u32 shl (32 - (cast[uint32](gprs[rs]) and 0b11111)))
    let is_sign = (cast[uint32](gprs[rt]) shr 31) != 0
    var temp = u128(cast[uint64](cast[int64](cast[int32]((cast[uint32](gprs[rt]) shr (cast[uint32](gprs[rs]) and 0b11111))))))
    if is_sign:
        temp = temp or temp2
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
    gprs[rd] = u128(cast[uint64](cast[int64](cast[int32](gprs[rs]) - cast[int32](gprs[rt]))))

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

proc op_slt() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    if cast[int64](gprs[rs]) < cast[int64](gprs[rt]):
        gprs[rd] = u128(1)
    else:
        gprs[rd] = u128(0)

proc op_mult() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let result = cast[int64](cast[int32](gprs[rs])) * cast[int64](cast[int32](gprs[rt]))
    lo = cast[uint64](cast[int64](cast[int32](result and 0xFFFFFFFF)))
    gprs[rd] = u128(lo)
    hi = cast[uint64](cast[int64](cast[int32](result shr 32)))


proc op_syscall() =
    exception(Exception.SysCall)
    

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
    let is_sign = (cast[uint64](gprs[rt]) and (1'u64 shl 63)) != 0
    let temp = cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shr (sa + 32)
    gprs[rd] = u128(temp)
    if is_sign:
        gprs[rd] = gprs[rd] or u128(temp2)

proc op_dsrav() =
    let rs = (opcode shr 16) and 0b11111
    let rt = (opcode shr 11) and 0b11111
    let rd = (opcode shr 6) and 0b11111
    let temp2 = 0xFFFFFFFFFFFFFFFF'u64 shl (64 - cast[uint64](gprs[rs]))
    let is_sign = (cast[uint64](gprs[rt]) and (1'u64 shl 63)) != 0
    let temp = cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shr cast[uint64](gprs[rs])
    gprs[rd] = u128(temp)
    if is_sign:
        gprs[rd] = gprs[rd] or u128(temp2)

proc op_divu() =
    let rt = (opcode shr 16) and 0b11111
    let rs = (opcode shr 21) and 0b11111
    if gprs[rt] == u128(0):
        lo = cast[uint64](cast[int64](cast[int32](cast[uint32](0xFFFFFFFF))))
        hi = cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rt]))))
    else:
        lo = cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) div cast[uint32](gprs[rt]))))
        hi = cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) mod cast[uint32](gprs[rt]))))

proc op_div() =
    let rt = (opcode shr 16) and 0b11111
    let rs = (opcode shr 21) and 0b11111
    let reg1 = cast[int32](gprs[rs])
    let reg2 = cast[int32](gprs[rt])
    if reg2 == 0:
        hi = cast[uint64](cast[uint32](reg1))
        if reg1 >= 0:
            lo = cast[uint64](cast[uint32](0xFFFFFFFF'i32))
        else:
            lo = 1
    elif (reg1 == 0x80000000'i32) and (reg2 == -1):
        hi = 0
        lo = cast[uint64](cast[uint32](0x80000000'i32))
    else:
        hi = cast[uint64](cast[uint32](reg1 mod reg2))
        lo = cast[uint64](cast[uint32](reg1 div reg2))

proc op_mfhi() =
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(hi)

proc op_mflo() =
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(lo)

proc op_movn() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    if cast[uint64](gprs[rt]) != 0:
        gprs[rd] = gprs[rs] 

proc op_break() =
    echo "Unhandled break"

proc op_movz() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    if cast[uint64](gprs[rt]) == 0:
        gprs[rd] = gprs[rs]
    
proc op_dsllv() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let temp = cast[uint64](gprs[rt] and u128(0xFFFFFFFFFFFFFFFF)) shl cast[uint64](gprs[rs] and u128(0b111111))
    gprs[rd] = u128(temp)

proc op_tge() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    if cast[int64](gprs[rs]) > cast[int64](gprs[rt]):
        echo "Should trap, oops"
        #exception(Exception.Trap)

const SPECIAL_INSTRUCTION: array[64, proc] = [op_sll, op_unhandled, op_srl, op_sra, op_sllv, op_unhandled, op_unhandled, op_srav,
                                           op_jr, op_jalr, op_movz, op_movn, op_syscall, op_break, op_unhandled, op_sync,
                                           op_mfhi, op_unhandled, op_mflo, op_unhandled, op_dsllv, op_unhandled, op_unhandled, op_dsrav,
                                           op_mult, op_unhandled, op_div, op_divu, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_add, op_addu, op_sub, op_subu, op_and, op_or, op_unhandled, op_nor,
                                           op_unhandled, op_unhandled, op_slt, op_sltu, op_unhandled, op_daddu, op_unhandled, op_dsubu,
                                           op_tge, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
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
    case fmt:
        of 0b000010: op_tlbwi()
        else:
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

proc op_adda_s() =
    echo "Unhandled adda.s"

proc op_s() =
    case opcode and 0b111111:
        of 0b011000: op_adda_s()
        else:
            echo "Unhandled FPU.S opcode " & u128(opcode and 0b111111).toBin(6)

proc op_mtc1() =
    let rt = (opcode shr 16) and 0b11111
    let fs = (opcode shr 11) and 0b11111
    fprs[fs] = cast[uint32](gprs[rt])

proc op_mfc1() =
    echo "Unhandled mfc1"
        
proc op_ctc1() =
    let rt = (opcode shr 16) and 0b11111
    let fs = (opcode shr 11) and 0b11111
    if fs == 31:
        fcr31 = cast[uint32](gprs[rt])
    else:
        echo "Unhandled ctc1 " & $fs

const COP1_INSTRUCTION: array[32, proc] = [op_mfc1, op_unhandled, op_unhandled, op_unhandled, op_mtc1, op_unhandled, op_ctc1, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_s, op_unhandled, op_unhandled, op_unhandled, op_w, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]



proc op_cop1() =
    sub_op_index = (opcode shr 21) and 0b11111
    COP1_INSTRUCTION[sub_op_index]()

proc op_cfc2() =
    let rt = (opcode shr 16) and 0b11111

proc op_ctc2() =
    let rt = (opcode shr 16) and 0b11111

proc op_viswr() =
    discard

proc op_vsqi() =
    discard

proc op_special2() =
    sub_op_index = (opcode and 0b11) or (((opcode shr 6) and 0b11111) shl 2)
    case sub_op_index:
        of 0b0110101: op_vsqi()
        of 0b0111111: op_viswr()
        else:
            echo "Unhandled special2 " & u128(sub_op_index).toBin(7)

proc op_vsub() =
    discard

proc op_viadd() =
    discard

proc op_special1() =
    sub_op_index = opcode and 0b111111
    case sub_op_index:
        of 0b101100: op_vsub()
        of 0b110000: op_viadd()
        of 0b111100: op_special2()
        of 0b111101: op_special2()
        of 0b111110: op_special2()
        of 0b111111: op_special2()
        else:
            echo "Unhandled special1 " & u128(sub_op_index).toBin(6)

proc op_qmfc2() =
    discard

proc op_qmtc2() =
    discard

const COP2_INSTRUCTION: array[32, proc] = [op_unhandled, op_qmfc2, op_cfc2, op_unhandled, op_unhandled, op_qmtc2, op_ctc2, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_special1, op_special1, op_special1, op_special1, op_special1, op_special1, op_special1, op_special1,
                                           op_special1, op_special1, op_special1, op_special1, op_special1, op_special1, op_special1, op_special1]

proc op_cop2() =
    sub_op_index = (opcode shr 21) and 0b11111
    COP2_INSTRUCTION[sub_op_index]()

proc op_blezl() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    let rs = (opcode shr 21) and 0b11111
    if cast[int64](gprs[rs]) <= 0:
        prepare_branch_delay()
        delayed_pc = pc + offset
    else:
        pc += 4
        #echo "Branched to " & pc.toHex()

proc op_blez() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    let rs = (opcode shr 21) and 0b11111
    if cast[int64](gprs[rs]) <= 0:
        prepare_branch_delay()
        delayed_pc = pc + offset

proc op_bgtz() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode and 0xFFFF'u32)) shl 2)
    let rs = (opcode shr 21) and 0b11111
    if cast[int64](gprs[rs]) > 0:
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
    let imm = cast[int16](opcode and 0xFFFF)
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
    else:
        pc += 4
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
    else:
        pc += 4
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
    let address = cast[uint32](gprs[base]) + offset
    gprs[rt] = u128(cast[uint64](cast[int64](cast[int32](load32(address)))))

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
    let address = cast[uint32](gprs[base]) + offset
    store8(address, cast[uint8](gprs[rt] and u128(0xFF)))

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
    prepare_branch_delay()
    delayed_pc = (pc and 0xF0000000'u32) or address

proc op_j() =
    let address = (opcode shl 6) shr 4
    prepare_branch_delay()
    delayed_pc = (pc and 0xF0000000'u32) or address

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
    {.gcsafe.}:
        let base = (opcode shr 21) and 0b11111
        let ft = (opcode shr 16) and 0b11111
        let offset = cast[uint32](cast[int16](opcode and 0xFFFF))
        store32(cast[uint32](gprs[base]) + offset, fprs[ft])

proc op_mult1() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    let result = cast[int64](cast[int32](gprs[rs])) * cast[int64](cast[int32](gprs[rt]))
    lo1 = cast[uint64](cast[int64](cast[int32](result and 0xFFFFFFFF)))
    gprs[rd] = u128(lo1)
    hi1 = cast[uint64](cast[int64](cast[int32](result shr 32)))

proc op_div1() =
    let rt = (opcode shr 16) and 0b11111
    let rs = (opcode shr 21) and 0b11111
    let reg1 = cast[int32](gprs[rs])
    let reg2 = cast[int32](gprs[rt])
    if reg2 == 0:
        hi1 = cast[uint64](cast[uint32](reg1))
        if reg1 >= 0:
            lo1 = cast[uint64](cast[uint32](0xFFFFFFFF'i32))
        else:
            lo1 = 1
    elif (reg1 == 0x80000000'i32) and (reg2 == -1):
        hi1 = 0
        lo1 = cast[uint64](cast[uint32](0x80000000'i32))
    else:
        hi1 = cast[uint64](cast[uint32](reg1 mod reg2))
        lo1 = cast[uint64](cast[uint32](reg1 div reg2))

proc op_divu1() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    lo1 = cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) div cast[uint32](gprs[rt]))))
    hi1 = cast[uint64](cast[int64](cast[int32](cast[uint32](gprs[rs]) mod cast[uint32](gprs[rt]))))

proc op_mflo1() =
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = u128(lo1)

proc op_pmflo() =
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = (u128(lo1) shl 32) or u128(lo)

proc op_pabsh() =
    # TODO: FIX
    let rd = (opcode shr 11) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    gprs[rd] = gprs[rt]

proc op_mmi2() =
    sub_op_index = (opcode shr 6) and 0b11111
    case sub_op_index:
        of 0b00101: op_pabsh()
        of 0b01001: op_pmflo()
        else: echo "Unhandled MMI2 instruction " & u128(sub_op_index).toBin(5)

proc op_por() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let rd = (opcode shr 11) and 0b11111
    gprs[rd] = gprs[rs] or gprs[rt]

proc op_mmi3() =
    sub_op_index = (opcode shr 6) and 0b11111
    case sub_op_index:
        of 0b10010: op_por()
        else: echo "Unhandled MMI3 instruction " & u128(sub_op_index).toBin(5)

const MMI_INSTRUCTION: array[64, proc] = [op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_mmi2, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_mflo1, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_mult1, op_unhandled, op_div1, op_divu1, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_mmi3, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]


proc op_mmi() =
    sub_op_index = opcode and 0b111111
    MMI_INSTRUCTION[sub_op_index]()

proc op_daddiu() =
    let rs = (opcode shr 21) and 0b11111
    let rt = (opcode shr 16) and 0b11111
    let imm = cast[uint64](cast[int64](cast[int16](opcode and 0xFFFF)))
    gprs[rt] = u128(cast[uint64](gprs[rs]) + imm)

proc op_cache() =
    let base = (opcode shr 21) and 0b11111
    let op = (opcode shr 16) and 0b11111


const NORMAL_INSTRUCTION: array[64, proc] = [op_special, op_regimm, op_j, op_jal, op_beq, op_bne, op_blez, op_bgtz,
                                           op_addi, op_addiu, op_slti, op_sltiu, op_andi, op_ori, op_xori, op_lui,
                                           op_cop0, op_cop1, op_cop2, op_unhandled, op_beql, op_bnel, op_blezl, op_unhandled,
                                           op_unhandled, op_daddiu, op_unhandled, op_unhandled, op_mmi, op_unhandled, op_lq, op_sq,
                                           op_lb, op_lh, op_unhandled, op_lw, op_lbu, op_lhu, op_unhandled, op_nor,
                                           op_sb, op_sh, op_unhandled, op_sw, op_unhandled, op_unhandled, op_unhandled, op_cache,
                                           op_unhandled, op_lwc1, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_ld,
                                           op_unhandled, op_swc1, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_sd]




proc set_elf*(elf_location: string, load_elf: bool) =
    elf_load_path = elf_location
    should_load_elf = load_elf

proc ee_tick*() =
    #echo pc.toHex()
    if pc > 0x80000000'u32 and pc < 0x80020000'u32:
        if should_dump:
            var s = newFileStream("ramdump.bin", fmWrite)
            var i = 0'u32
            while i < 0xB000:
                s.write(load8(0x80000000'u32 + i))
                i += 1
            s.close()
            should_dump = false
            echo "Dumped RAM"

    if debug:
        echo pc.toHex() & " " & $gprs[18].toHex()
    gprs[0] = u128(0)
    if execute_delay:
        NORMAL_INSTRUCTION[op_index]()
        pc = delayed_pc
        execute_delay = false
        #echo pc.toHex() & " " & int64(op_index).toBin(6)

    if (pc < 0x80000000'u32) and (pc > 0x00100000'u32) and should_load_elf:
        pc = load_elf(elf_load_path)
        echo "Jumped into elf at location " & pc.toHex()
        should_load_elf = false

    opcode = fetch_opcode(pc)
    op_index = opcode shr 26
    #echo pc.toHex() & " " & int64(op_index).toBin(6) & " " & $gprs
    pc += 4
    NORMAL_INSTRUCTION[op_index]()

    if irq_active():
        exception(Exception.Interrupt)

    cop0_tick_counter()
    tick_timers()
    