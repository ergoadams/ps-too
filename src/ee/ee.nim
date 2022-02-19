import strutils, pkg/nint128, streams
import ee_bus, cop0, gs, timer

type
    Instruction = object
        v: uint32
        immediate: uint32
        target: uint32
        funct, sa, rd, rt, rs: uint32
        opcode: uint32

proc `value=`(i: var Instruction, value: uint32) {.inline.} =
    i.v = value
    i.opcode = value shr 26
    i.immediate = value and 0xFFFF
    i.target = (value shl 6) shr 6
    i.funct = value and 0x3F
    i.sa = (value shr 6) and 0x1F
    i.rd = (value shr 11) and 0x1F
    i.rt = (value shr 16) and 0x1F
    i.rs = (value shr 21) and 0x1F

proc value (i: Instruction): uint32 {.inline.} =
    return i.v

var pc: uint32 = 0xBFC00000'u32
var opcode: Instruction
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
var sa: uint32

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

proc set_word(index: uint32, reg: uint32, value: uint32) {.inline.} =
    if index == 0:
        gprs[reg] = gprs[reg] and (not u128(0xFFFFFFFF))
    else:
        gprs[reg] = gprs[reg] and (not (u128(0xFFFFFFFF) shl (32*index)))

    if index == 0:
        gprs[reg] = gprs[reg] or cast[UInt128](value)
    else:
        gprs[reg] = gprs[reg] or (cast[UInt128](value) shl (32*index))

proc set_dword(index: uint32, reg: uint32, value: uint64) {.inline.} =
    if index == 0:
        gprs[reg] = gprs[reg] and (u128(0xFFFFFFFFFFFFFFFF) shl 64)
    else:
        gprs[reg] = gprs[reg] and u128(0xFFFFFFFFFFFFFFFF)

    if index == 0:
        gprs[reg] = gprs[reg] or cast[UInt128](value)
    else:
        gprs[reg] = gprs[reg] or (cast[UInt128](value) shl 64)


proc get_word(index: uint32, reg: uint32): uint32 {.inline.} =
    if index == 0:
        return cast[uint32](gprs[reg] and u128(0xFFFFFFFF))
    else:
        return cast[uint32]((gprs[reg] shr (32*index)) and u128(0xFFFFFFFF))

proc get_dword(index: uint32, reg: uint32): uint64 {.inline.} =
    if index == 0:
        return cast[uint64](gprs[reg] and u128(0xFFFFFFFFFFFFFFFF))
    else:
        return cast[uint64]((gprs[reg] shr (64*index)) and u128(0xFFFFFFFFFFFFFFFF))

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
    quit("op_unhandled at " & (pc - 4).toHex() & " " & opcode.value.toHex() & " " & int64(op_index).toBin(6) & " " & int64(sub_op_index).toBin(6), 0)

proc prepare_branch_delay() =
    opcode.value = fetch_opcode(pc)
    op_index = opcode.value shr 26
    execute_delay = true

proc op_sll() =
    let rt = opcode.rt
    let rd = opcode.rd
    let sa = opcode.sa

    let value = cast[uint64](cast[int32](get_word(0, rt) shl sa))
    set_dword(0, rd, value)

proc op_sllv() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let reg = get_word(0, rt)
    let sa = get_word(0, rs) and 0x3F
    let value = cast[uint64](cast[int32](reg shl sa))
    set_dword(0, rd, value)

proc op_dsll() =
    let sa = opcode.sa
    let rd = opcode.rd
    let rt = opcode.rt

    let value = get_dword(0, rt) shl sa
    set_dword(0, rd, value)


proc op_srl() =
    let sa = opcode.sa
    let rd = opcode.rd
    let rt = opcode.rt

    let value = cast[uint64](cast[int32](get_word(0, rt) shr sa))
    set_dword(0, rd, value)

proc op_sra() =
    let sa = opcode.sa
    let rd = opcode.rd
    let rt = opcode.rt

    let reg = cast[int32](get_word(0, rt))
    let value = cast[uint64](reg shr sa)
    set_dword(0, rd, value)

proc op_srav() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let reg = cast[int32](get_word(0, rt))
    let sa = get_word(0, rs) and 0x3F
    let value = cast[uint64](reg shr sa)
    set_dword(0, rd, value)

proc op_srlv() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let sa = get_word(0, rs) and 0x3F
    let value = cast[int32](get_word(0, rt) shr sa)
    set_dword(0, rd, cast[uint64](value))

proc op_dsrl() =
    let sa = opcode.sa
    let rd = opcode.rd
    let rt = opcode.rt

    let value = get_dword(0, rt) shr sa
    set_dword(0, rd, value)

proc op_jr() =
    let rs = opcode.rs

    prepare_branch_delay()
    delayed_pc = get_word(0, rs)

proc op_jalr() =
    let rs = opcode.rs
    let rd = opcode.rd

    set_dword(0, rd, pc + 4)
    prepare_branch_delay()
    delayed_pc = get_word(0, rs)

proc op_nor() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let value = not (get_dword(0, rs) or get_dword(0, rt))
    set_dword(0, rd, value)

proc op_or() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt
    
    let value = get_dword(0, rs) or get_dword(0, rt)
    set_dword(0, rd, value)

proc op_and() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt
    
    let value = get_dword(0, rs) and get_dword(0, rt)
    set_dword(0, rd, value)

proc op_addu() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt
    
    let value = cast[int32](get_dword(0, rs) + get_dword(0, rt))
    set_dword(0, rd, cast[uint64](value))

proc op_daddu() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let reg1 = get_dword(0, rs)
    let reg2 = get_dword(0, rt)
    let value = reg1 + reg2
    set_dword(0, rd, value)

proc op_dsubu() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let value = get_dword(0, rs) - get_dword(0, rt)
    set_dword(0, rd, value)


proc op_add() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let result = cast[int32](get_dword(0, rs) + get_dword(0, rt))
    set_dword(0, rd, cast[uint64](result))


proc op_subu() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let reg1 = cast[int32](get_dword(0, rs))
    let reg2 = cast[int32](get_dword(0, rt))
    let value = reg1 - reg2
    set_dword(0, rd, cast[uint64](value))

proc op_sub() =
    # TODO: are they really the same?
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let reg1 = cast[int32](get_dword(0, rs))
    let reg2 = cast[int32](get_dword(0, rt))
    let value = reg1 - reg2
    set_dword(0, rd, cast[uint64](value))



proc op_sltu() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    if get_dword(0, rs) < get_dword(0, rt):
        set_dword(0, rd, 1)
    else:
        set_dword(0, rd, 0)

proc op_slt() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    if cast[int64](get_dword(0, rs)) < cast[int64](get_dword(0, rt)):
        set_dword(0, rd, 1)
    else:
        set_dword(0, rd, 0)

proc op_mult() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let reg1 = cast[int64](get_dword(0, rs))
    let reg2 = cast[int64](get_dword(0, rt))
    let result = reg1*reg2

    lo = cast[uint64](cast[int32](result and 0xFFFFFFFF))
    set_dword(0, rd, lo)
    hi = cast[uint64](cast[int32](result shr 32))



proc op_syscall() =
    exception(Exception.SysCall)
    

proc op_sync() =
    discard

proc op_dsll32() =
    let sa = opcode.sa
    let rd = opcode.rd
    let rt = opcode.rt

    let value = get_dword(0, rt) shl (sa + 32)
    set_dword(0, rd, value)

proc op_dsrl32() =
    let sa = opcode.sa
    let rd = opcode.rd
    let rt = opcode.rt

    let value = get_dword(0, rt) shr (sa + 32)
    set_dword(0, rd, value)

proc op_dsra32() =
    let sa = opcode.sa
    let rd = opcode.rd
    let rt = opcode.rt

    let reg = cast[int64](get_dword(0, rt))
    let value = reg shr (sa + 32)
    set_dword(0, rd, cast[uint64](value))

proc op_dsrav() =
    let rs = opcode.rs
    let rd = opcode.rd
    let rt = opcode.rt

    let reg = cast[int64](get_dword(0, rt))
    let sa = get_word(0, rs) and 0x3F
    let value = reg shr sa
    set_dword(0, rd, cast[uint64](value))

proc op_divu() =
    let rt = opcode.rt
    let rs = opcode.rs
    if get_word(0, rt) == 0:
        hi = cast[uint64](cast[int32](get_word(0, rs)))
        lo = cast[uint64](cast[int32](0xFFFFFFFF'u32))
    else:
        hi = cast[uint64](cast[int32](get_word(0, rs) mod get_word(0, rt)))
        lo = cast[uint64](cast[int32](get_word(0, rs) div get_word(0, rt)))

proc op_div() =
    let rt = opcode.rt
    let rs = opcode.rs
    let reg1 = cast[int32](get_word(0, rs))
    let reg2 = cast[int32](get_word(0, rt))
    if reg2 == 0:
        hi = cast[uint64](reg1)
        if reg1 >= 0:
            lo = cast[uint64](cast[int32](0xFFFFFFFFu32))
        else:
            lo = 1
    elif (reg1 == 0x80000000'i32) and (reg2 == -1):
        hi = 0
        lo = cast[uint64](cast[int32](0x80000000'u32))
    else:
        hi = cast[uint64](cast[int32](reg1 mod reg2))
        lo = cast[uint64](cast[int32](reg1 div reg2))

proc op_mfhi() =
    let rd = opcode.rd
    set_dword(0, rd, hi)

proc op_mflo() =
    let rd = opcode.rd
    set_dword(0, rd, lo)

proc op_movn() =
    let rs = opcode.rs
    let rt = opcode.rt
    let rd = opcode.rd
    if get_dword(0, rt) != 0:
        set_dword(0, rd, get_dword(0, rs))

proc op_break() =
    echo "Unhandled break"

proc op_movz() =
    let rs = opcode.rs
    let rt = opcode.rt
    let rd = opcode.rd
    if get_dword(0, rt) == 0:
        set_dword(0, rd, get_dword(0, rs))
    
proc op_dsllv() =
    let rs = opcode.rs
    let rt = opcode.rt
    let rd = opcode.rd

    let reg = get_dword(0, rt)
    let sa = get_word(0, rs) and 0x3F

    let value = reg shl sa
    set_dword(0, rd, value)

proc op_tge() =
    let rs = (opcode.value shr 21) and 0b11111
    let rt = (opcode.value shr 16) and 0b11111
    if cast[int64](gprs[rs]) > cast[int64](gprs[rt]):
        echo "Should trap, oops"
        #exception(Exception.Trap)

proc op_mfsa() =
    let rd = opcode.rd
    set_dword(0, rd, sa)

const SPECIAL_INSTRUCTION: array[64, proc] = [op_sll, op_unhandled, op_srl, op_sra, op_sllv, op_unhandled, op_srlv, op_srav,
                                           op_jr, op_jalr, op_movz, op_movn, op_syscall, op_unhandled, op_unhandled, op_sync,
                                           op_mfhi, op_unhandled, op_mflo, op_unhandled, op_dsllv, op_unhandled, op_unhandled, op_dsrav,
                                           op_mult, op_unhandled, op_div, op_divu, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_add, op_addu, op_unhandled, op_subu, op_and, op_or, op_unhandled, op_nor,
                                           op_mfsa, op_unhandled, op_slt, op_sltu, op_unhandled, op_daddu, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_dsll, op_unhandled, op_dsrl, op_unhandled, op_dsll32, op_unhandled, op_dsrl32, op_dsra32]


proc op_bltz() =
    let imm = cast[int32](cast[int16](opcode.immediate))
    let rs = opcode.rs

    let offset = imm shl 2
    let reg = cast[int64](get_dword(0, rs))
    if reg < 0:
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)

proc op_bltzl() =
    let imm = cast[int32](cast[int16](opcode.immediate))
    let rs = opcode.rs

    let offset = imm shl 2
    let reg = cast[int64](get_dword(0, rs))
    if reg < 0:
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)
    else:
        pc += 4

proc op_bgez() =
    let rs = opcode.rs
    let imm = cast[int32](cast[int16](opcode.immediate))

    let offset = imm shl 2
    let reg = cast[int64](get_dword(0, rs))
    if reg >= 0:
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)


const REGIMM_INSTRUCTION: array[32, proc] = [op_bltz, op_bgez, op_bltzl, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]



proc op_mfc0() =
    let rd = (opcode.value shr 11) and 0x1F
    let rt = (opcode.value shr 16) and 0x1F

    let value = mfc0(rd, rt, 0)
    set_dword(0, rt, value)

proc op_mtc0() =
    let rt = (opcode.value shr 16) and 0x1F
    let rd = (opcode.value shr 11) and 0x1F
    mtc0(rd, 0, get_word(0, rt))

proc op_bc0() =
    let fmt = (opcode.value shr 16) and 0b11111
    echo "bc0 " & int64(fmt).toBin(5)

proc op_di() =
    cop0_di()

proc op_ei() =
    cop0_ei()

proc op_eret() =
    pc = cop0_eret()

proc op_tlb() =
    let fmt = opcode.value and 0b111111
    case fmt:
        of 0b000010: op_tlbwi()
        of 0b011000: op_eret()
        of 0b111000: op_ei()
        of 0b111001: op_di()
        else:
            echo "tlb " & int64(fmt).toBin(6)

const COP0_INSTRUCTION: array[32, proc] = [op_mfc0, op_unhandled, op_unhandled, op_unhandled, op_mtc0, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_tlb, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]


proc op_special() =
    sub_op_index = opcode.value and 0b111111
    SPECIAL_INSTRUCTION[sub_op_index]()

proc op_regimm() =
    sub_op_index = (opcode.value shr 16) and 0b11111
    REGIMM_INSTRUCTION[sub_op_index]()

proc op_w() =
    if (opcode.value and 0b111111) != 0b100000:
        echo "Invalid FPU.W opcode"
    else:
        echo "Unhandled CVT.s"

proc op_adda_s() =
    echo "Unhandled adda.s"

proc op_s() =
    case opcode.value and 0b111111:
        of 0b011000: op_adda_s()
        else:
            echo "Unhandled FPU.S opcode " & u128(opcode.value and 0b111111).toBin(6)

proc op_mtc1() =
    let rt = (opcode.value shr 16) and 0b11111
    let fs = (opcode.value shr 11) and 0b11111
    fprs[fs] = cast[uint32](gprs[rt])

proc op_mfc1() =
    echo "Unhandled mfc1"
        
proc op_ctc1() =
    let rt = (opcode.value shr 16) and 0b11111
    let fs = (opcode.value shr 11) and 0b11111
    if fs == 31:
        fcr31 = cast[uint32](gprs[rt])
    else:
        echo "Unhandled ctc1 " & $fs

const COP1_INSTRUCTION: array[32, proc] = [op_mfc1, op_unhandled, op_unhandled, op_unhandled, op_mtc1, op_unhandled, op_ctc1, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_s, op_unhandled, op_unhandled, op_unhandled, op_w, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]



proc op_cop1() =
    sub_op_index = (opcode.value shr 21) and 0b11111
    COP1_INSTRUCTION[sub_op_index]()

proc op_cfc2() =
    #TODO
    let rt = (opcode.value shr 16) and 0b11111

proc op_ctc2() =
    #TODO
    let rt = (opcode.value shr 16) and 0b11111

proc op_viswr() =
    discard

proc op_vsqi() =
    discard

proc op_special2() =
    sub_op_index = (opcode.value and 0b11) or (((opcode.value shr 6) and 0b11111) shl 2)
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
    sub_op_index = opcode.value and 0b111111
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
    sub_op_index = (opcode.value shr 21) and 0b11111
    COP2_INSTRUCTION[sub_op_index]()

proc op_blezl() =
    let offset = cast[uint32](cast[int32](cast[int16](opcode.value and 0xFFFF'u32)) shl 2)
    let rs = (opcode.value shr 21) and 0b11111
    if cast[int64](gprs[rs]) <= 0:
        prepare_branch_delay()
        delayed_pc = pc + offset
    else:
        pc += 4
        #echo "Branched to " & pc.toHex()

proc op_blez() =
    let imm = cast[int32](cast[int16](opcode.immediate))
    let rs = opcode.rs
    let offset = imm shl 2
    let reg = cast[int64](get_dword(0, rs))
    if reg <= 0:
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)

proc op_bgtz() =
    let imm = cast[int32](cast[int16](opcode.immediate))
    let rs = opcode.rs
    let offset = imm shl 2
    let reg = cast[int64](get_dword(0, rs))
    if reg > 0:
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)

proc op_sd() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)
        let vaddr = cast[uint32](offset) + get_word(0, base)
        let data = get_dword(0, rt)
        store64(vaddr, data)

proc op_ld() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        let value = load64(vaddr)
        set_dword(0, rt, value)

proc op_cop0() =
    sub_op_index = (opcode.value shr 21) and 0x1F
    COP0_INSTRUCTION[sub_op_index]()

proc op_slti() =
    let rs = (opcode.value shr 21) and 0b11111
    let rt = (opcode.value shr 16) and 0b11111
    let imm = opcode.value and 0xFFFF
    if cast[uint64](gprs[rs]) < cast[uint64](cast[int64](cast[int16](imm))):
        gprs[rt] = u128(1)
    else:
        gprs[rt] = u128(0)

proc op_sltiu() =
    let rt = opcode.rt
    let rs = opcode.rs
    let imm = cast[uint64](cast[int16](opcode.immediate))

    if get_dword(0, rs) < imm:
        set_dword(0, rt, 1)
    else:
        set_dword(0, rt, 0)

proc op_bne() =
    let rt = opcode.rt
    let rs = opcode.rs
    let imm = cast[int32](cast[int16](opcode.immediate))

    let offset = imm shl 2

    if get_dword(0, rs) != get_dword(0, rt):
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)
        #echo "Branched to " & pc.toHex()

proc op_bnel() =
    let rt = opcode.rt
    let rs = opcode.rs
    let imm = cast[int32](cast[int16](opcode.immediate))
    let offset = imm shl 2

    if get_dword(0, rs) != get_dword(0, rt):
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)
    else:
        pc += 4

proc op_beq() =
    let rt = opcode.rt
    let rs = opcode.rs
    let imm = cast[int32](cast[int16](opcode.immediate))

    let offset = imm shl 2
    if get_dword(0, rs) == get_dword(0, rt):
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)

proc op_beql() =
    let rt = opcode.rt
    let rs = opcode.rs
    let imm = cast[int32](cast[int16](opcode.immediate))
    let offset = imm shl 2

    if get_dword(0, rs) == get_dword(0, rt):
        prepare_branch_delay()
        delayed_pc = pc + cast[uint32](offset)
    else:
        pc += 4
    
proc op_addi() =
    let rs = (opcode.value shr 21) and 0b11111
    let rt = (opcode.value shr 16) and 0b11111
    let imm = cast[uint32](cast[int32](cast[int16](opcode.value and 0xFFFF)))
    let result = cast[uint64](cast[uint32](gprs[rs])) + cast[uint64](imm)
    if result > 0xFFFFFFFF'u64:
        echo "addi overflow"
    else:
        gprs[rt] = u128(cast[uint64](cast[int64](cast[int32](cast[uint32](result)))))

proc op_lui() =
    let rt = opcode.rt
    let imm = opcode.immediate

    let value = cast[int32](imm shl 16)
    set_dword(0, rt, cast[uint64](value))

proc op_ori() =
    let rs = opcode.rs
    let rt = opcode.rt
    let imm = opcode.immediate

    let value = get_dword(0, rs) or cast[uint64](imm)
    set_dword(0, rt, value)

proc op_xori() =
    let rs = opcode.rs
    let rt = opcode.rs
    let imm = opcode.immediate

    let value = get_dword(0, rs) xor imm
    set_dword(0, rt, value)

proc op_addiu() =
    let rs = opcode.rs
    let rt = opcode.rt
    let imm = cast[int16](opcode.immediate)

    let result = cast[int32](get_dword(0, rs) + cast[uint64](imm))
    set_dword(0, rt, cast[uint64](result))


proc op_lw() =
    let base = opcode.rs
    let rt = opcode.rt
    let offset = cast[int16](opcode.immediate)

    let vaddr = cast[uint32](offset) + get_word(0, base)

    let value = cast[uint64](cast[int32](load32(vaddr)))
    set_dword(0, rt, value)

proc op_lwu() =
    let base = opcode.rs
    let rt = opcode.rt
    let offset = cast[int16](opcode.immediate)

    let vaddr = cast[uint32](offset) + get_word(0, base)

    let value = cast[uint64](load32(vaddr))
    set_dword(0, rt, value)

proc op_andi() =
    let rt = opcode.rt
    let rs = opcode.rs
    let imm = opcode.immediate
    let value = get_dword(0, rs) and imm
    set_dword(0, rt, value)

proc op_sw() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        let data = get_word(0, rt)
        store32(vaddr, data)
        
proc op_sb() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        let data = get_word(0, rt) and 0xFF
        store8(vaddr, cast[uint8](data))

proc op_sh() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        let data = get_word(0, rt) and 0xFFFF
        store16(vaddr, cast[uint16](data))

proc op_lb() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)
        
        let vaddr = cast[uint32](offset) + get_word(0, base)
        let value = cast[uint64](cast[int8](load8(vaddr)))
        set_dword(0, rt, value)

proc op_lh() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)
        
        let vaddr = cast[uint32](offset) + get_word(0, base)
        let value = cast[uint64](cast[int16](load16(vaddr)))
        set_dword(0, rt, value)

proc op_jal() =
    let index = opcode.target
    set_dword(0, 31, pc + 4)

    prepare_branch_delay()
    delayed_pc = (pc and 0xF0000000'u32) or (index shl 2)

proc op_j() =
    let index = opcode.target
    prepare_branch_delay()
    delayed_pc = (pc and 0xF0000000'u32) or (index shl 2)

proc op_lbu() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        let value = cast[uint64](load8(vaddr))
        set_dword(0, rt, value)

proc op_lhu() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)

        let value = load16(vaddr)
        set_dword(0, rt, cast[uint64](value))

proc op_sq() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        store128(vaddr, gprs[rt])

proc op_lq() =
    {.gcsafe.}:
        let base = opcode.rs
        let rt = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        gprs[rt] = load128(vaddr)

proc op_lwc1() =
    echo "unhandled lwc1"

proc op_swc1() = 
    {.gcsafe.}:
        let base = opcode.rs
        let ft = opcode.rt
        let offset = cast[int16](opcode.immediate)

        let vaddr = cast[uint32](offset) + get_word(0, base)
        let data = fprs[ft]

        store32(vaddr, data)

proc op_mult1() =
    let rs = opcode.rs
    let rt = opcode.rt
    let rd = opcode.rd

    let reg1 = cast[int64](get_dword(0, rs))
    let reg2 = cast[int64](get_dword(0, rt))
    let result = reg1*reg2
    lo1 = cast[uint64](cast[int32](result and 0xFFFFFFFF))
    set_dword(0, rd, lo1)
    hi1 = cast[uint64](cast[int32](result shr 32))

proc op_div1() =
    let rt = (opcode.value shr 16) and 0b11111
    let rs = (opcode.value shr 21) and 0b11111
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
    let rt = opcode.rt
    let rs = opcode.rs
    lo1 = cast[uint64](cast[int64](cast[int32](get_word(0, rs) div get_word(0, rt))))
    hi1 = cast[uint64](cast[int64](cast[int32](get_word(0, rs) mod get_word(0, rt))))


proc op_mflo1() =
    let rd = opcode.rd
    set_dword(0, rd, lo1)

proc op_pmflo() =
    let rd = (opcode.value shr 11) and 0b11111
    gprs[rd] = (u128(lo1) shl 32) or u128(lo)

proc op_pabsh() =
    # TODO: FIX
    let rd = (opcode.value shr 11) and 0b11111
    let rt = (opcode.value shr 16) and 0b11111
    gprs[rd] = gprs[rt]

proc op_mmi2() =
    sub_op_index = (opcode.value shr 6) and 0b11111
    case sub_op_index:
        of 0b00101: op_pabsh()
        of 0b01001: op_pmflo()
        else: echo "Unhandled MMI2 instruction " & u128(sub_op_index).toBin(5)

proc op_por() =
    let rs = opcode.rs
    let rt = opcode.rt
    let rd = opcode.rd
    gprs[rd] = gprs[rs] or gprs[rt]

proc op_mmi3() =
    sub_op_index = (opcode.value shr 6) and 0b11111
    case sub_op_index:
        of 0b10010: op_por()
        else: echo "Unhandled MMI3 instruction " & u128(sub_op_index).toBin(5)

proc op_padduw() =
    let rt = opcode.rt
    let rs = opcode.rs
    let rd = opcode.rd

    var i = 0'u32
    while i < 4:
        let result = cast[uint64](get_word(i, rt)) + cast[uint64](get_word(i, rs))
        if result > 0xFFFFFFFF'u64:
            set_word(i, rd, 0xFFFFFFFF'u32)
        else:
            set_word(i, rd, cast[uint32](result))
        i += 1


proc op_mmi1() =
    sub_op_index = (opcode.value shr 6) and 0b11111
    case sub_op_index:
        of 0b10000: op_padduw()
        else: echo "Unhandled MMI1 instruction " & u128(sub_op_index).toBin(5)

proc op_plzcw() =
    let rd = opcode.rd
    let rs = opcode.rs

    var i = 0'u32
    while i < 2:
        var word = get_word(i, rs)
        let msb = (word and (1 shl 31)) != 0
        if msb:
            word = not word
        if word != 0:
            set_word(i, rd, cast[uint32](countLeadingZeroBits(u128(word)) - 97))
        else:
            set_word(i, rd, 0x1f)
        i += 1

proc op_mfhi1() =
    let rd = opcode.rd
    set_dword(0, rd, hi1)

const MMI_INSTRUCTION: array[64, proc] = [op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_plzcw, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_mfhi1, op_unhandled, op_mflo1, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_mult1, op_unhandled, op_unhandled, op_divu1, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_mmi1, op_mmi3, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled]


proc op_mmi() =
    {.gcsafe.}:
        sub_op_index = opcode.value and 0b111111
        MMI_INSTRUCTION[sub_op_index]()

proc op_daddiu() =
    let rs = opcode.rs
    let rt = opcode.rt
    let offset = cast[int16](opcode.immediate)

    let reg = cast[int64](get_dword(0, rs))
    let value = reg + offset

    set_dword(0, rt, cast[uint64](value))

proc op_cache() =
    discard

proc op_ldl() =
    {.gcsafe.}:
        const LDL_MASK: array[8, uint64] = [0x00FFFFFFFFFFFFFF'u64, 0x0000FFFFFFFFFFFF'u64, 0x000000FFFFFFFFFF'u64, 0x00000000FFFFFFFF'u64,
                                            0x0000000000FFFFFF'u64, 0x000000000000FFFF'u64, 0x00000000000000FF'u64, 0x0000000000000000'u64]
        const LDL_SHIFT: array[8, uint32] = [56'u32, 48'u32, 40'u32, 32'u32, 24'u32, 16'u32, 8'u32, 0'u32]

        let rt = opcode.rt
        let base = opcode.rs
        let offset = cast[int16](opcode.immediate)

        let address = cast[uint32](offset) + get_word(0, base)
        let alligned_addr = address and (not 0x7'u32)  
        let shift = address and 0x7

        let dword = load64(alligned_addr)
        let result = (get_dword(0, rt) and LDL_MASK[shift]) or (dword shl LDL_SHIFT[shift])

        set_dword(0, rt, result)     

proc op_sdl() =
    {.gcsafe.}:
        const SDL_MASK: array[8, uint64] = [0xFFFFFFFFFFFFFF00'u64, 0xFFFFFFFFFFFF0000'u64, 0xFFFFFFFFFF000000'u64, 0xFFFFFFFF00000000'u64,
                                            0xFFFFFF0000000000'u64, 0xFFFF000000000000'u64, 0xFF00000000000000'u64, 0x0000000000000000'u64]
        const SDL_SHIFT: array[8, uint32] = [56'u32, 48'u32, 40'u32, 32'u32, 24'u32, 16'u32, 8'u32, 0'u32]

        let rt = opcode.rt
        let base = opcode.rs
        let offset = cast[int16](opcode.immediate)

        let address = cast[uint32](offset) + get_word(0, base)
        let alligned_addr = address and (not 0x7'u32)  
        let shift = address and 0x7

        let dword = load64(alligned_addr)
        let result = (get_dword(0, rt) shr SDL_SHIFT[shift]) or (dword and SDL_MASK[shift])

        store64(alligned_addr, result)  

proc op_ldr() =
    {.gcsafe.}:
        const LDR_MASK: array[8, uint64] = [0x0000000000000000'u64, 0xFF00000000000000'u64, 0xFFFF000000000000'u64, 0xFFFFFF0000000000'u64,
                                            0xFFFFFFFF00000000'u64, 0xFFFFFFFFFF000000'u64, 0xFFFFFFFFFFFF0000'u64, 0xFFFFFFFFFFFFFF00'u64]
        const LDR_SHIFT: array[8, uint32] = [0'u32, 8'u32, 16'u32, 24'u32, 32'u32, 40'u32, 48'u32, 56'u32]

        let rt = opcode.rt
        let base = opcode.rs
        let offset = cast[int16](opcode.immediate)

        let address = cast[uint32](offset) + get_word(0, base)
        let alligned_addr = address and (not 0x7'u32)  
        let shift = address and 0x7

        let dword = load64(alligned_addr)
        let result = (get_dword(0, rt) and LDR_MASK[shift]) or (dword shr LDR_SHIFT[shift])

        set_dword(0, rt, result)   

proc op_sdr() =
    {.gcsafe.}:
        const SDR_MASK: array[8, uint64] = [0x0000000000000000'u64, 0x00000000000000FF'u64, 0x000000000000FFFF'u64, 0x0000000000FFFFFF'u64,
                                            0x00000000FFFFFFFF'u64, 0x000000FFFFFFFFFF'u64, 0x0000FFFFFFFFFFFF'u64, 0x00FFFFFFFFFFFFFF'u64]
        const SDR_SHIFT: array[8, uint32] = [0'u32, 8'u32, 16'u32, 24'u32, 32'u32, 40'u32, 48'u32, 56'u32]

        let rt = opcode.rt
        let base = opcode.rs
        let offset = cast[int16](opcode.immediate)

        let address = cast[uint32](offset) + get_word(0, base)
        let alligned_addr = address and (not 0x7'u32)  
        let shift = address and 0x7

        let dword = load64(alligned_addr)
        let result = (get_dword(0, rt) shl SDR_SHIFT[shift]) or (dword and SDR_MASK[shift])

        store64(alligned_addr, result)                             

const NORMAL_INSTRUCTION: array[64, proc] = [op_special, op_regimm, op_j, op_jal, op_beq, op_bne, op_blez, op_bgtz,
                                           op_unhandled, op_addiu, op_slti, op_sltiu, op_andi, op_ori, op_xori, op_lui,
                                           op_cop0, op_cop1, op_cop2, op_unhandled, op_beql, op_bnel, op_unhandled, op_unhandled,
                                           op_unhandled, op_daddiu, op_ldl, op_ldr, op_mmi, op_unhandled, op_lq, op_sq,
                                           op_lb, op_lh, op_unhandled, op_lw, op_lbu, op_lhu, op_unhandled, op_lwu,
                                           op_sb, op_sh, op_unhandled, op_sw, op_sdl, op_sdr, op_unhandled, op_cache,
                                           op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_unhandled, op_ld,
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
            while i < 0x20000:
                s.write(load8(0x80000000'u32 + i))
                i += 1
            s.close()
            should_dump = false
            echo "Dumped RAM"

    

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

    opcode.value = fetch_opcode(pc)
    op_index = opcode.opcode
    #echo pc.toHex() & " " & int64(op_index).toBin(6) & " " & $gprs
    if debug:
        echo pc.toHex() & " " & opcode.value.toHex() & " " & int64(op_index).toBin(6)
    pc += 4
    NORMAL_INSTRUCTION[op_index]()


    if irq_active():
        exception(Exception.Interrupt)

    cop0_tick_counter()
    tick_timers()
    dmac_tick()
    