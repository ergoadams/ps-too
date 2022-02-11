import strutils
import cop0

type
    TMode_t = object
        v: uint32
        clock, gate_enable, gate_type, gate_mode, clear_when_cmp, enable, cmp_intr_enable: uint32
        overflow_intr_enable, cmp_flag, overflow_flag: uint32
    
    Timer = object
        mode: TMode_t
        counter: uint32
        compare: uint32
        hold: uint16
        ratio: uint32

proc `value=`(t: var TMode_t, data: uint32) =
    t.v = data
    t.clock = data and 0b11
    t.gate_enable = (data shr 2) and 1
    t.gate_type = (data shr 3) and 1
    t.gate_mode = (data shr 4) and 3
    t.clear_when_cmp = (data shr 6) and 1
    t.enable = (data shr 7) and 1
    t.cmp_intr_enable = (data shr 8) and 1
    t.overflow_intr_enable = (data shr 9) and 1
    t.cmp_flag = (data shr 10) and 1
    t.overflow_flag = (data shr 11) and 1


var timers: array[4, Timer]
var total_ticks: uint64

proc timer_store*(address: uint32, data: uint32) =
    let timer_index = (address and 0xFF00) shr 11
    let reg_index = (address and 0xF0) shr 4
    case reg_index:
        of 0:
            # TN_COUNT
            timers[timer_index].counter = data and 0xFFFF
        of 1:
            # TN_MODE
            case data and 0x3:
                of 0: timers[timer_index].ratio = 1
                of 1: timers[timer_index].ratio = 16
                of 2: timers[timer_index].ratio = 256
                of 3: timers[timer_index].ratio = 9372 # BUS_CLOCK / HBLANK_NTSC
                else: quit("timerstore")
            timers[timer_index].mode.value = data and 0x3FF
        of 2:
            # TN_COMP
            timers[timer_index].compare = data and 0xFFFF
        of 3:
            # TN_HOLD
            timers[timer_index].hold = cast[uint16](data and 0xFFFF)
        else:
            quit("Unhandled timer store " & $timer_index & " " & $reg_index)

proc timer_load*(address:uint32): uint32 =
    let timer_index = (address and 0xFF00) shr 11
    let reg_index = (address and 0xF0) shr 4
    case reg_index:
        of 0: return timers[timer_index].counter
        else:
            quit("Unhandled timer load " & $timer_index & " " & $reg_index)

proc tick_timers*() =
    total_ticks += 1
    
    var i = 0
    while i < 3:
        let timer = timers[i]
        if timer.mode.enable != 0:
            let old_count = timer.counter
            if (total_ticks mod timer.ratio) == 0:
                timers[i].counter += 1
            
            if (timer.counter >= timer.compare) and (old_count < timer.compare):
                if (timer.mode.cmp_intr_enable != 0) and (timer.mode.cmp_flag == 0):
                    echo "timer comp"
                    timers[i].mode.cmp_flag = 1
                
                if timer.mode.clear_when_cmp != 0:
                    timers[i].counter = 0
            if timer.counter >= 0xFFFF:
                if (timer.mode.overflow_intr_enable != 0) and (timer.mode.overflow_flag == 0):
                    echo "timer overflow"
                    timers[i].mode.overflow_flag = 1
                timers[i].counter = 0
        i += 1