import strutils

proc mfc0*(rd: uint32, rt: uint32, sel: uint32): uint32 =
    case rd:
        of 15: return 0x60
        else: echo "Unhandled mfc0 " & $rd

proc mtc0*(rd: uint32, sel: uint32, data: uint32) =
    echo "Unhandled mtc0 " & $rd & " " & $sel & " " & data.toHex()