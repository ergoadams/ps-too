import strutils
type
    Interrupt* = enum
        VBlank = 0
        CdRom = 2
        Dma = 3
        Timer0 = 4
        Timer1 = 5
        Timer2 = 6
        PadMemCard = 7

    pending_irq = tuple
        delay: uint32
        irq: Interrupt

var status: uint32
var mask: uint32
var ctrl: uint32
var pending_irqs: seq[pending_irq]

proc get_irq_status*(): uint32 =
    return status

proc get_irq_mask*(): uint32 =
    return mask

proc irq_ack*(value: uint32) =
    status = status and value

proc irq_set_mask*(value: uint32) =
    #echo "Set IRQ mask to ", int64(value).toBin(16)
    mask = value

proc irq_set_ctrl*(value: uint32) =
    ctrl = value

proc get_irq_ctrl*(): uint32 =
    return ctrl

proc irq_active*(): bool =
    return (status and mask) != 0

proc pend_irq*(delay: uint32, which: Interrupt) =
    #echo "Got new interrupt pending ", which
    pending_irqs.add((delay, which))

proc assert_irq*(which: Interrupt) =
    status = status or (1'u16 shl uint16(ord(which)))

proc irq_tick*() =
    if not irq_active():
        if pending_irqs.len != 0:
            var to_delete: seq[int]
            for i in (0 ..< pending_irqs.len):
                var interrupt = pending_irqs[i]
                var delay = interrupt[0]
                delay -= 1
                if delay == 0:
                    assert_irq(pending_irqs[i][1])
                    to_delete.add(i)
                else:
                    pending_irqs[i] = (delay, interrupt[1])

            if to_delete.len != 0:
                for i in (0 ..< to_delete.len):
                    pending_irqs.delete(to_delete.pop())