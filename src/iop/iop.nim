import iop_bus, interrupt, timers
import strutils

const PROCESSOR_ID = 0x1F'u32

var cycle_count: uint32

var pc = 0xBFC00000'u32
var next_pc = pc + 4
var current_instruction: uint32
var regs: array[32, uint32]

var function, t, imm, s, d, subfunction, shift: uint32
var load: (uint32, uint32)

var sr: uint32
var hi: uint32
var lo: uint32

var branch_bool: bool
var delay_slot: bool

var current_pc: uint32
var cause: uint32
var epc: uint32

type
    Exception = enum
        Interrupt = 0x0,
        LoadAddressError = 0x4,
        StoreAddressError = 0x5,
        SysCall = 0x8,
        Break = 0x9,
        IllegalInstruction = 0xA,
        CoprocessorError = 0xB,
        Overflow = 0xC

proc exception(cause_a: Exception) =

    #echo "EXCEPTION"

    let mode = sr and 0x3F
    sr = sr and (not 0x3F'u32)
    sr = sr or ((mode shl 2) and 0x3F)

    cause = cause and (not 0x7C'u32)
    cause = cause or (uint32(ord(cause_a)) shl 2)


    if delay_slot:
        epc = current_pc - 4
        cause = cause or (1 shl 31)
    else:
        epc = current_pc
        cause = cause and (not (1'u32 shl 31))

    var handler = 0'u32
    if (sr and (1 shl 22)) != 0:
        handler = 0xBFC00180'u32
    else:
        handler = 0x80000080'u32

    pc = handler
    next_pc = pc + 4

proc imm_se: uint32 =
    let v = cast[int16](current_instruction and 0xFFFF)
    return cast[uint32](v)

proc set_reg(index: uint32, val: uint32) =
    regs[index] = val
    regs[0] = 0'u32

proc delayed_load_chain(reg: uint32, value: uint32) =
    if load[0] != reg:
        set_reg(load[0], load[1])

    load = (reg, value)

proc delayed_load() =
    set_reg(load[0], load[1])
    load = (0'u32, 0'u32)


proc imm_jump(): uint32 =
    return current_instruction and 0x3FFFFFF'u32

proc op_lui() =
    let v = imm shl 16
    delayed_load()
    set_reg(t, v)

proc op_ori() =
    let v = regs[s] or imm
    delayed_load()
    set_reg(t, v)

proc op_sw() =
    if (sr and 0x10000) != 0:
        #echo "Ignoring store while cache is isolated"
        return
    imm = imm_se()
    let address = regs[s] + imm
    let v = regs[t]
    delayed_load()
    if (address mod 4) == 0:
        store32(address, v)
    else:
        exception(Exception.StoreAddressError)

proc op_sll() =
    let v = regs[t] shl shift
    delayed_load()
    set_reg(d, v)

proc op_addiu() =
    imm = imm_se()
    let v = regs[s] + imm
    delayed_load()
    set_reg(t, v)

proc op_j() =
    imm = imm_jump()
    next_pc = (pc and 0xF0000000'u32) or (imm shl 2)
    branch_bool = true
    delayed_load()

proc op_or() =
    let v = regs[s] or regs[t]
    delayed_load()
    set_reg(d, v)

proc op_mtc0() =
    let v = regs[t]
    delayed_load()
    case d:
        of 3, 5, 6, 7, 9, 11:
            if v != 0: quit("Unhandled write to cop0r", QuitSuccess)
        of 12: sr = v
        of 13: cause = v
        else: quit("Unhandled cop0 register " & d.toHex(), QuitSuccess)

proc op_mfc0() =
    let v = case d:
        of 6, 7, 8: 0'u32
        of 12: sr
        of 13: cause
        of 14: epc
        of 15: PROCESSOR_ID
        else: quit("Unhandled read from cop0r " & d.toHex(), QuitSuccess)

    delayed_load_chain(t, v)

proc op_rfe() =
    delayed_load()
    if (current_instruction and 0x3F) != 0b010000:
        quit("Invalid cop0 instruction " & current_instruction.toHex(), QuitSuccess)

    let mode = sr and 0x3F
    sr = sr and (not 0xF'u32)
    sr = sr or (mode shr 2)

proc op_cop0() =
    case s:
        of 0b00000: op_mfc0()
        of 0b00100: op_mtc0()
        of 0b10000: op_rfe()
        else: quit("Unhandled cop0 instruction " & current_instruction.toHex(), QuitSuccess)

proc branch(offset: uint32) =
    let offset_a = offset shl 2
    next_pc = pc + offset_a
    branch_bool = true

proc op_bne() =
    imm = imm_se()
    if regs[s] != regs[t]:
        branch(imm)

    delayed_load()

proc op_addi() =
    imm = imm_se()
    imm = (imm xor 0x80000000'u32) - 0x80000000'u32
    let i = uint64(imm)
    let s = uint64(regs[s])
    let v = s + i
    delayed_load()
    if (((v xor s) and (v xor i)) and 0x80000000'u64) != 0:
        exception(Exception.Overflow)
    else:
        set_reg(t, uint32(v and 0xFFFFFFFF'u32))

proc op_lw() =
    if (sr and 0x10000) != 0:
        #echo "Ignoring load while cache is isolated"
        return

    imm = imm_se()
    let address = regs[s] + imm

    if (address mod 4) == 0:
        let v = load32(address)
        delayed_load_chain(t, v)
    else:
        delayed_load()
        exception(Exception.LoadAddressError)

proc op_sltu() =
    if regs[s] < regs[t]:
        delayed_load()
        set_reg(d, 1)
    else:
        delayed_load()
        set_reg(d, 0)

proc op_addu() =
    let v = regs[s] + regs[t]
    delayed_load()
    set_reg(d, v)

proc op_sh() =
    if (sr and 0x10000) != 0:
        #echo "Ignoring store while cache is isolated"
        return

    imm = imm_se()
    let address = regs[s] + imm
    let v = regs[t]
    delayed_load()
    if (address mod 2) == 0:
        store16(address, uint16(v and 0xFFFF))
    else:
        exception(Exception.StoreAddressError)

proc op_jal() =
    let ra = next_pc
    op_j()
    set_reg(31, ra)
    branch_bool = true

proc op_andi() =
    let v = regs[s] and imm
    delayed_load()
    set_reg(t, v)

proc op_sb() =
    if (sr and 0x10000) != 0:
        #echo "Ignoring store while cache is isolated"
        return

    imm = imm_se()
    let address = regs[s] + imm
    let v = regs[t]
    delayed_load()
    store8(address, uint8(v and 0xFF))

proc op_jr() =
    next_pc = regs[s]
    delayed_load()
    branch_bool = true

proc op_lb() =
    imm = imm_se()
    let address = regs[s] + imm
    let v = cast[int8](load8(address))
    delayed_load_chain(t, cast[uint32](v))

proc op_beq() =
    imm = imm_se()
    if regs[s] == regs[t]:
        branch(imm)

    delayed_load()

proc op_and() =
    let v = regs[s] and regs[t]
    delayed_load()
    set_reg(d, v)

proc op_add() =
    let s = cast[int32](regs[s])
    let t = cast[int32](regs[t])
    delayed_load()
    try:
        let v = s + t
        set_reg(d, cast[uint32](v))
    except OverflowDefect:
        exception(Exception.Overflow)


proc op_bgtz() =
    imm = imm_se()
    let v = cast[int32](regs[s])
    if v > 0:
        branch(imm)

    delayed_load()

proc op_blez() =
    imm = imm_se()
    let v = cast[int32](regs[s])
    if v <= 0:
        branch(imm)

    delayed_load()

proc op_lbu() =
    imm = imm_se()
    let address = regs[s] + imm
    let v = load8(address)
    delayed_load_chain(t, uint32(v))

proc op_jalr() =
    let ra = next_pc
    next_pc = regs[s]
    delayed_load()
    set_reg(d, ra)
    branch_bool = true

proc op_bxx() =
    imm = imm_se()
    let is_bgez = (current_instruction shr 16) and 1
    let is_link = ((current_instruction shr 17) and 0xF) == 0x8
    let v = cast[int32](regs[s])
    var test = 0'u32
    if v < 0:
        test = 1'u32

    test = test xor is_bgez

    delayed_load()

    if is_link:
        set_reg(31, next_pc)

    if test != 0:
        branch(imm)

proc op_slti() =
    let i = cast[int32](imm_se())
    if cast[int32](regs[s]) < i:
        delayed_load()
        set_reg(t, 1)
    else:
        delayed_load()
        set_reg(t, 0)

proc op_subu() =
    let v = regs[s] - regs[t]
    delayed_load()
    set_reg(d, v)

proc op_sra() =
    let v = cast[int32](regs[t]) shr shift
    delayed_load()
    set_reg(d, cast[uint32](v))

proc op_div() =
    let n = cast[int32](regs[s])
    let d = cast[int32](regs[t])

    delayed_load()

    if d == 0:
        hi = cast[uint32](n)
        if n >= 0:
            lo = 0xFFFFFFFF'u32
        else:
            lo = 1
    elif (cast[uint32](n) == 0x80000000'u32) and (d == -1):
        hi = 0
        lo = 0x80000000'u32
    else:
        hi = cast[uint32](n mod d)
        lo = cast[uint32](n div d)

proc op_mflo() =
    delayed_load()
    set_reg(d, lo)

proc op_srl() =
    let v = regs[t] shr shift
    delayed_load()
    set_reg(d, v)

proc op_sltiu() =
    imm = imm_se()
    if regs[s] < imm:
        delayed_load()
        set_reg(t, 1)
    else:
        delayed_load()
        set_reg(t, 0)

proc op_divu() =
    let n = regs[s]
    let d = regs[t]

    delayed_load()

    if d == 0:
        hi = n
        lo = 0xFFFFFFFF'u32
    else:
        hi = n mod d
        lo = n div d

proc op_mfhi() =
    delayed_load()
    set_reg(d, hi)

proc op_slt() =
    if cast[int32](regs[s]) < cast[int32](regs[t]):
        delayed_load()
        set_reg(d, 1)
    else:
        delayed_load()
        set_reg(d, 0)

proc op_mtlo() =
    lo = regs[s]
    delayed_load()

proc op_mthi() =
    hi = regs[s]
    delayed_load()

proc op_lhu() =
    imm = imm_se()
    let address = regs[s] + imm
    if (address mod 2) == 0:
        let v = load16(address)
        delayed_load_chain(t, uint32(v))
    else:
        delayed_load()
        exception(Exception.LoadAddressError)

proc op_sllv() =
    let v = regs[t] shl (regs[s] and 0x1F)
    delayed_load()
    set_reg(d, v)

proc op_lh() =
    imm = imm_se()
    let address = regs[s] + imm
    if (address mod 2) == 0:
        let v = cast[int16](load16(address))
        delayed_load_chain(t, cast[uint32](v))
    else:
        delayed_load()
        exception(Exception.LoadAddressError)

proc op_nor() =
    let v = not (regs[s] or regs[t])
    delayed_load()
    set_reg(d, v)

proc op_srav() =
    let v = cast[int32](regs[t]) shr (regs[s] and 0x1F)
    delayed_load()
    set_reg(d, cast[uint32](v))

proc op_srlv() =
    let v = regs[t] shr (regs[s] and 0x1F)
    delayed_load()
    set_reg(d, v)

proc op_multu() =
    let a = uint64(regs[s])
    let b = uint64(regs[t])

    delayed_load()

    let v = a*b
    hi = uint32(v shr 32)
    lo = uint32(v and 0xFFFFFFFF'u32)

proc op_xor() =
    let v = regs[s] xor regs[t]
    delayed_load()
    set_reg(d, v)

proc op_break() =
    delayed_load()
    exception(Exception.Break)

proc op_mult() =
    let a = int64(cast[int32](regs[s]))
    let b = int64(cast[int32](regs[t]))

    delayed_load()

    let v = cast[uint64](a*b)
    hi = uint32(v shr 32)
    lo = uint32(v and 0xFFFFFFFF'u32)

proc op_sub() =
    let a = regs[s]
    let b = regs[t]
    delayed_load()
    let v = a - b
    if (((v xor a) and (a xor b)) and 0x80000000'u32) != 0:
        exception(Exception.Overflow)
    else:
        set_reg(d, v)

proc op_xori() =
    let v = regs[s] xor imm
    delayed_load()
    set_reg(t, v)

proc op_cop1() =
    delayed_load()
    exception(Exception.CoprocessorError)

proc op_cop3() =
    delayed_load()
    exception(Exception.CoprocessorError)

proc op_lwl() =
    imm = imm_se()
    let address = regs[s] + imm

    let pending_reg = load[0]
    let pending_value = load[1]

    var cur_v = regs[t]
    if pending_reg == t:
        cur_v = pending_value

    let aligned_addr = address and (not 3'u32)
    let aligned_word = load32(aligned_addr)

    let v = case (address and 3):
        of 0: (cur_v and 0x00FFFFFF'u32) or (aligned_word shl 24)
        of 1: (cur_v and 0x0000FFFF'u32) or (aligned_word shl 16)
        of 2: (cur_v and 0x000000FF'u32) or (aligned_word shl 8)
        of 3: (cur_v and 0x00000000'u32) or (aligned_word shl 0)
        else: quit("unreachable", QuitSuccess)

    delayed_load_chain(t, v)

proc op_lwr() =
    imm = imm_se()
    let address = regs[s] + imm

    let pending_reg = load[0]
    let pending_value = load[1]

    var cur_v = regs[t]
    if pending_reg == t:
        cur_v = pending_value

    let aligned_addr = address and (not 3'u32)
    let aligned_word = load32(aligned_addr)

    let v = case (address and 3):
        of 0: (cur_v and 0x00000000'u32) or (aligned_word shr 0)
        of 1: (cur_v and 0xFF000000'u32) or (aligned_word shr 8)
        of 2: (cur_v and 0xFFFF0000'u32) or (aligned_word shr 16)
        of 3: (cur_v and 0xFFFFFF00'u32) or (aligned_word shr 24)
        else: quit("unreachable", QuitSuccess)

    delayed_load_chain(t, v)

proc op_swl() =
    imm = imm_se()
    let address = regs[s] + imm
    let v = regs[t]
    let aligned_addr = address and (not 3'u32)
    let cur_mem = load32(aligned_addr)
    let mem = case (address and 3):
        of 0: (cur_mem and 0xFFFFFF00'u32) or (v shr 24)
        of 1: (cur_mem and 0xFFFF0000'u32) or (v shr 16)
        of 2: (cur_mem and 0xFF000000'u32) or (v shr 8)
        of 3: (cur_mem and 0x00000000'u32) or (v shr 0)
        else: quit("unreachable", QuitSuccess)

    delayed_load()
    store32(aligned_addr, mem)

proc op_swr() =
    imm = imm_se()
    let address = regs[s] + imm
    let v = regs[t]
    let aligned_addr = address and (not 3'u32)
    let cur_mem = load32(aligned_addr)
    let mem = case (address and 3):
        of 0: (cur_mem and 0x00000000'u32) or (v shl 0)
        of 1: (cur_mem and 0x000000FF'u32) or (v shl 8)
        of 2: (cur_mem and 0x0000FFFF'u32) or (v shl 16)
        of 3: (cur_mem and 0x00FFFFFF'u32) or (v shl 24)
        else: quit("unreachable", QuitSuccess)

    delayed_load()
    store32(aligned_addr, mem)

proc op_syscall() =
    delayed_load()
    exception(Exception.SysCall)

proc cop0_cause(): uint32 =
    var active = 0'u32
    if irq_active():
        active = 1'u32
    return cause or (active shl 10)

proc cop0_irq_active(): bool =
    let irq_cause = cop0_cause()
    let pending = (irq_cause and sr) and 0x700
    let irq_enabled = (sr and 1) != 0
    if pending != 0:
        if irq_enabled:
            return true
    return false

proc execute() =
    function = current_instruction shr 26
    t = (current_instruction shr 16) and 0x1F
    imm = current_instruction and 0xFFFF
    s = (current_instruction shr 21) and 0x1F
    d = (current_instruction shr 11) and 0x1F
    subfunction = current_instruction and 0x3F
    shift = (current_instruction shr 6) and 0x1F
    case function:
        of 0b000000:
            case subfunction:
                of 0b000000: op_sll()
                of 0b000010: op_srl()
                of 0b000011: op_sra()
                of 0b000100: op_sllv()
                of 0b000110: op_srlv()
                of 0b000111: op_srav()
                of 0b001000: op_jr()
                of 0b001001: op_jalr()
                of 0b001100: op_syscall()
                of 0b001101: op_break()
                of 0b010000: op_mfhi()
                of 0b010001: op_mthi()
                of 0b010010: op_mflo()
                of 0b010011: op_mtlo()
                of 0b011000: op_mult()
                of 0b011001: op_multu()
                of 0b011010: op_div()
                of 0b011011: op_divu()
                of 0b100000: op_add()
                of 0b100001: op_addu()
                of 0b100010: op_sub()
                of 0b100011: op_subu()
                of 0b100100: op_and()
                of 0b100101: op_or()
                of 0b100110: op_xor()
                of 0b100111: op_nor()
                of 0b101010: op_slt()
                of 0b101011: op_sltu()
                else: quit("Unhandled IOP 0b000000 subfunction " & int64(subfunction).toBin(6), 0)
        of 0b000001: op_bxx()
        of 0b000010: op_j()
        of 0b000011: op_jal()
        of 0b000100: op_beq()
        of 0b000101: op_bne()
        of 0b000110: op_blez()
        of 0b000111: op_bgtz()
        of 0b001000: op_addi()
        of 0b001001: op_addiu()
        of 0b001010: op_slti()
        of 0b001011: op_sltiu()
        of 0b001100: op_andi()
        of 0b001101: op_ori()
        of 0b001110: op_xori()
        of 0b001111: op_lui()
        of 0b010000: op_cop0()
        of 0b010001: op_cop1()
        of 0b010011: op_cop3()
        of 0b100000: op_lb()
        of 0b100001: op_lh()
        of 0b100010: op_lwl()
        of 0b100011: op_lw()
        of 0b100100: op_lbu()
        of 0b100101: op_lhu()
        of 0b100110: op_lwr()
        of 0b101000: op_sb()
        of 0b101001: op_sh()
        of 0b101010: op_swl()
        of 0b101011: op_sw()
        of 0b101110: op_swr()
        else: quit("Unhandled IOP function " & int64(function).toBin(6), 0)

proc iop_tick*() =
    current_pc = pc
    if (current_pc mod 4) != 0:
        exception(Exception.LoadAddressError)
        return
    current_instruction = load32(pc)
    pc = next_pc
    next_pc = pc + 4
    delay_slot = branch_bool
    branch_bool = false

    cycle_count += 1
    if (cycle_count and 7) == 0:
        #discard
        tick_timers()

    if cop0_irq_active():
        exception(Exception.Interrupt)
    else:
        irq_tick()
        execute()

    if (pc == 0x12C48) or (pc == 0x1420C) or (pc == 0x1430C):
        var text_pointer = regs[5]
        var text_size = regs[6]
        while text_size > 0:
            stdout.write char(load8(text_pointer and 0x1FFFFF))
            text_pointer += 1'u32
            text_size -= 1'u32

    if pc == 0xB0:
        if regs[9] == 0x3D:
            stdout.write char(regs[4])