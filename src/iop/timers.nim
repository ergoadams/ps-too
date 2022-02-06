import strutils
import interrupt

type
    Timer = ref object
        counter: uint16
        target: uint16
        wrap_irq: bool
        use_sync: bool
        sync: uint16
        target_wrap: bool
        target_irq: bool
        repeat_irq: bool
        negate_irq: bool
        clock_source: uint16
        interrupt: bool
        target_reached: bool
        overflow_reached: bool

var timers = [Timer(), Timer(), Timer()]
var timer_debug* = false
var timer_temp = false

proc timer_set_mode(timer: Timer, value: uint16) =
    timer.use_sync = (value and 1) != 0
    timer.sync = (value shr 1) and 3
    timer.target_wrap = ((value shr 3) and 1) != 0
    timer.target_irq = ((value shr 4) and 1) != 0
    timer.wrap_irq = ((value shr 5) and 1) != 0
    timer.repeat_irq = ((value shr 6) and 1) != 0
    timer.negate_irq = ((value shr 7) and 1) != 0
    timer.clock_source = (value shr 8) and 1
    timer.interrupt = false
    timer.counter = 0'u16

    if timer.wrap_irq:
        quit("Wrap IRQ not supported", QuitSuccess)

    if (timer.wrap_irq or timer.target_irq) and (not timer.repeat_irq):
        quit("One shot timer interrupts are not supported", QuitSuccess)

    if timer.negate_irq:
        quit("Only pulse interrupts are supported", QuitSuccess)

    if timer.use_sync:
        discard
        #echo "Sync mode is not supported"

proc timer_mode(timer: Timer): uint16 =
    var r = 0'u16
    if timer.use_sync:
        r = r or 1'u16
    r = r or (timer.sync shl 1)
    if timer.target_wrap:
        r = r or (1'u16 shl 3)
    if timer.target_irq:
        r = r or (1'u16 shl 4)
    if timer.wrap_irq:
        r = r or (1'u16 shl 5)
    if timer.repeat_irq:
        r = r or (1'u16 shl 6)
    if timer.negate_irq:
        r = r or (1'u16 shl 7)
    r = r or (timer.clock_source shl 8)
    if not timer.interrupt:
        r = r or (1'u16 shl 10)
    if timer.target_reached:
        r = r or (1'u16 shl 11)
    if timer.overflow_reached:
        r = r or (1'u16 shl 12)
    timer.target_reached = false
    timer.overflow_reached = false
    timer.interrupt = false
    return r

proc tick_timers*() =
    # Timer 2 (sysclk or sysclk/8) is enabled in bios
    # Timer 2 target is set to 0xFFFF
    # Timer 2 mode: free run
    #               reset after timer = target
    #               IRQ repeat mode
    #               pulse mode
    #               source sysclk/8
    if timers[2].counter != 0xFFFF'u16:
        timers[2].counter += 1
        timers[2].overflow_reached = false
    else:
        timers[2].overflow_reached = true

    if (timers[2].counter == timers[2].target) and (not timers[2].interrupt):
        timers[2].target_reached = true
        pend_irq(1, Interrupt.Timer2)
        timers[2].interrupt = true

    if timers[2].target_wrap:
        timers[2].counter = 0
        timers[2].interrupt = false

    if timers[2].counter == 0xFFFF'u16:
        if timers[2].wrap_irq:
            pend_irq(1, Interrupt.Timer2)
        timers[2].counter = 0'u16
        timers[2].interrupt = false
        timers[2].overflow_reached = false
        timers[2].target_reached = false

proc timers_load32*(offset: uint32): uint32 =
    let instance = offset shr 4
    #echo "Timer", instance, " load32"
    case offset and 0xF:
        of 0: return uint32(timers[instance].counter)
        of 4: return uint32(timer_mode(timers[instance]))
        of 8: return uint32(timers[instance].target)
        else: quit("Unhandled timer register read " & (offset and 0xF).toHex(), QuitSuccess)

proc timers_store16*(offset: uint32, value: uint16) =
    let instance = offset shr 4
    case offset and 0xF:
        of 0:
            #echo "Set timer", instance, " value to ", value.toHex()
            if instance == 2 and value == 0:
                #if timer_temp:
                    #timer_debug = true
                timer_temp = true
            timers[instance].counter = value
            timers[instance].target_reached = false
            timers[instance].overflow_reached = false
            timers[instance].interrupt = false
        of 4:
            #echo "Set timer", instance, " mode to ", int64(value).toBin(16)
            timer_set_mode(timers[instance], value)
        of 8:
            #echo "Set timer", instance, " target to ", value.toHex()
            timers[instance].target = value
            timers[instance].target_reached = false
            timers[instance].overflow_reached = false
            timers[instance].interrupt = false
            timers[instance].counter = 0'u16
        else: quit("Unhandled timer register read " & (offset and 0xF).toHex(), QuitSuccess)