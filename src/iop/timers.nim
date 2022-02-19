import strutils
import interrupt

type
    TimerMode_t = object
        v: uint64
        gate_enable, gate_mode: uint64
        reset_on_intr, compare_intr, overflow_intr, repeat_intr: uint64
        levl, external_signal, tm2_prescaler, intr_enabled: uint64
        compare_intr_raised, overflow_intr_raised, tm4_prescalar, tm5_prescalar: uint64
    
    Timer_t = object
        counter: uint64
        mode: TimerMode_t
        target: uint64

proc `value=`(i: var TimerMode_t, data: uint32) {.inline.} =
    i.v = data
    i.gate_enable = (data shr 0) and 1
    i.gate_mode = (data shr 1) and 3
    i.reset_on_intr = (data shr 3) and 1
    i.compare_intr = (data shr 4) and 1
    i.overflow_intr = (data shr 5) and 1
    i.repeat_intr = (data shr 6) and 1
    i.levl = (data shr 7) and 1
    i.external_signal = (data shr 8) and 1
    i.tm2_prescaler = (data shr 9) and 1
    i.intr_enabled = (data shr 10) and 1
    i.compare_intr_raised = (data shr 11) and 1
    i.overflow_intr_raised = (data shr 12) and 1
    i.tm4_prescalar = (data shr 13) and 1
    i.tm5_prescalar = (data shr 14) and 1

proc `value`(i: TimerMode_t): uint32 {.inline.} =
    var temp: uint64
    temp = temp or (i.gate_enable shl 0)
    temp = temp or (i.gate_mode shl 1)
    temp = temp or (i.reset_on_intr shl 3)
    temp = temp or (i.compare_intr shl 4)
    temp = temp or (i.overflow_intr shl 5)
    temp = temp or (i.repeat_intr shl 6)
    temp = temp or (i.levl shl 7)
    temp = temp or (i.external_signal shl 8)
    temp = temp or (i.tm2_prescaler shl 9)
    temp = temp or (i.intr_enabled shl 10)
    temp = temp or (i.compare_intr_raised shl 11)
    temp = temp or (i.overflow_intr_raised shl 12)
    temp = temp or (i.tm4_prescalar shl 13)
    temp = temp or (i.tm5_prescalar shl 14)
    return uint32(temp)

var timers: array[6, Timer_t]

proc tick_timers*() =
    let old_count = timers[5].counter
    timers[5].counter += 1
    if (timers[5].counter >= timers[5].target) and (old_count < timers[5].target):
        timers[5].mode.compare_intr_raised = 1
        if (timers[5].mode.compare_intr != 0) and (timers[5].mode.intr_enabled != 0):
            echo "IOP timer should trigger int"
        if timers[5].mode.reset_on_intr != 0:
            timers[5].counter = 0

    if timers[5].counter > 0xFFFFFFFF'u32:
        timers[5].mode.overflow_intr_raised = 1
        if (timers[5].mode.overflow_intr != 0) and (timers[5].mode.intr_enabled != 0):
            echo "IOP timer should trigger int overflow"
        timers[5].counter -= 0xFFFFFFFF'u32


proc timers_load*(address: uint32): uint32 =
    echo "Unhandled IOP timer load"


proc timers_store*(address: uint32, data: uint32) =
    let group = (address shr 10) and 1
    let timer_index = ((address and 0x30) shr 4) + 3*group
    let offset = (address and 0xF) shr 2
    case offset:
        of 0: timers[timer_index].counter = data
        of 1: 
            timers[timer_index].mode.value = data
            timers[timer_index].mode.intr_enabled = 1
            timers[timer_index].counter = 0
        of 2:
            timers[timer_index].mode.value = data
            if timers[timer_index].mode.levl == 0:
                timers[timer_index].mode.intr_enabled = 1
        else: quit("Unhandled IOP timers store offset " & $offset)

    