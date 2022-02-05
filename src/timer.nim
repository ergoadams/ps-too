import strutils

var mode: uint32
var counter: uint32

proc timer_store32*(address: uint32, value: uint32) =
    if address == 0x10000010'u32:
        mode = value
    else:
        echo "Unhandled timer store32 " & address.toHex() & " " & value.toHex()

proc timer_load32*(address:uint32):uint32 =
    if address == 0x10000000'u32:
        counter += 1
        return counter
