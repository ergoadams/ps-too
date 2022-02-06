import strutils
import cop0

type
    Timer = object
        mode: uint32
        counter: uint16

var timers: array[4, Timer]
var total_ticks: uint64

proc timer_store*(address: uint32, value: uint32) =
    if address == 0x10000010'u32:
        timers[0].mode = value
    elif address == 0x10000000'u32:
        timers[0].counter = cast[uint16](value)
    elif address == 0x10000810'u32:
        timers[1].mode = value
    elif address == 0x10000800'u32:
        timers[1].counter = cast[uint16](value)
    else:
        echo "Unhandled timer store32 " & address.toHex() & " " & value.toHex()

proc timer_load*(address:uint32):uint32 =
    if address == 0x10000000'u32:
        timers[0].counter += 1
        return timers[0].counter
    else:
        echo "Unhandled timer load32 " & address.toHex()

proc tick_timers*() =
    total_ticks += 1
    if (timers[0].mode and (1 shl 7)) != 0:
        let prev_value = timers[0].counter
        case timers[0].mode and 3:
            of 0: timers[0].counter += 1
            of 1:
                if total_ticks mod 16 == 0:
                    timers[0].counter += 1
            of 2:
                if total_ticks mod 256 == 0:
                    timers[0].counter += 1
            of 3: discard
            else:
                echo "Unhandled timer0 mode"
        if prev_value > timers[0].counter:
            int_trigger(9)
            echo "Trigger int0"
    if (timers[1].mode and (1 shl 7)) != 0:
        let prev_value = timers[1].counter
        case timers[1].mode and 3:
            of 0: timers[1].counter += 1
            of 1:
                if total_ticks mod 16 == 0:
                    timers[1].counter += 1
            of 2:
                if total_ticks mod 256 == 0:
                    timers[1].counter += 1
            else:
                echo "Unhandled timer1 mode"
        if prev_value > timers[1].counter:
            int_trigger(10)
            echo "Trigger int1"
    if (timers[2].mode and (1 shl 7)) != 0:
        let prev_value = timers[2].counter
        case timers[2].mode and 3:
            of 0: timers[2].counter += 1
            of 1:
                if total_ticks mod 16 == 0:
                    timers[2].counter += 1
            of 2:
                if total_ticks mod 256 == 0:
                    timers[2].counter += 1
            else:
                echo "Unhandled timer2 mode"
        if prev_value > timers[2].counter:
            int_trigger(11)
            echo "Trigger int2"
    if (timers[3].mode and (1 shl 7)) != 0:
        let prev_value = timers[3].counter
        case timers[3].mode and 3:
            of 0: timers[3].counter += 1
            of 1:
                if total_ticks mod 16 == 0:
                    timers[3].counter += 1
            of 2:
                if total_ticks mod 256 == 0:
                    timers[3].counter += 1
            else:
                echo "Unhandled timer3 mode"
        if prev_value > timers[2].counter:
            int_trigger(12)
            echo "Trigger int3"