import pkg/nint128, csfml, strutils

# CSFML init
var screenWidth: float32 = 512
var screenHeight: float32  = 512
let scale_factor: float32 = 1
let videoMode = videoMode(cint(screenWidth*scale_factor), cint(screenHeight*scale_factor))
let settings = contextSettings(depth=32, antialiasing=8)
var window* = newRenderWindow(videoMode, "ps-too", settings=settings)
let clear_color = color(0, 0, 0)
window.clear clear_color
window.display()

var vram_buffer: array[1024*1024*4, uint8]
var vram_texture = newTexture(cint(1024), cint(1024))
var vram_sprite = newSprite(vram_texture)
vram_sprite.scale = vec2(scale_factor, scale_factor)

var vertex_array = newVertexArray(PrimitiveType.Triangles)
var x_offset: uint64
var y_offset: uint64

proc display_frame*() =     
    updateFromPixels(vram_texture, vram_buffer[0].addr, cint(1024), cint(1024), cint(0), cint(0))
    window.clear clear_color
    window.draw(vram_sprite)
    window.draw(vertex_array)
    window.display()
    vertex_array.clear()

proc parse_events*() =
    var event: Event
    while window.pollEvent(event):
        case event.kind:
            of EventType.Closed:
                window.close()
                vertex_array.destroy()
                vram_texture.destroy()
                vram_sprite.destroy()
                quit()
            else: discard

var PRIM: uint64
var RGBAQ: uint64
var CLAMP_2: uint64
var XYZ2: uint64
var XYZ2F: uint64
var XYOFFSET_1: uint64
var PRMODECONT: uint64
var SCISSOR_1: uint64
var DTHE: uint64
var COLCLAMP: uint64
var TEST_1: uint64
var FRAME_1: uint64
var ZBUF_1: uint64
var BITBLTBUF: uint64
var TRXPOS: uint64
var TRXREG: uint64
var TRXDIR: uint64

var dest_x: uint64
var dest_y: uint64
var width: uint64
var height: uint64

var GS_CSR*: uint64
var GS_IMR*: uint64

var vertex_queue: seq[array[2, uint64]]
var color_queue: seq[array[3, uint64]]



proc write_hwreg(data: uint64) =
    let data_format = cast[uint32]((BITBLTBUF shr 24) and 0b111111)
    case data_format:
        of 0x00: # RGBA32, each color is 8 bits, data contains 2 pixels
            let pixel1 = cast[uint32](data)
            let pixel2 = cast[uint32](data shr 32)
            let r1 = cast[uint8]((pixel1 shr 24) and 0xFF)
            let g1 = cast[uint8]((pixel1 shr 16) and 0xFF)
            let b1 = cast[uint8]((pixel1 shr 8) and 0xFF)
            let a1 = cast[uint8]((pixel1 shr 0) and 0xFF)

            let r2 = cast[uint8]((pixel2 shr 24) and 0xFF)
            let g2 = cast[uint8]((pixel2 shr 16) and 0xFF)
            let b2 = cast[uint8]((pixel2 shr 8) and 0xFF)
            let a2 = cast[uint8]((pixel2 shr 0) and 0xFF)

            var offset = dest_y*1024*4 + dest_x*4
            vram_buffer[offset + 0] = r1
            vram_buffer[offset + 1] = g1
            vram_buffer[offset + 2] = b1
            vram_buffer[offset + 3] = a1

            vram_buffer[offset + 4] = r2
            vram_buffer[offset + 5] = g2
            vram_buffer[offset + 6] = b2
            vram_buffer[offset + 7] = a2

            dest_x += 2
            if (dest_x - (TRXPOS shr 32) and 0b11111111111) >= width:
                dest_x -= width
                dest_y += 1

        else: echo "Unhandled GSTRANSFER data format " & data_format.toHex()

proc set_gscrt*(n_interlaced: bool, n_mode: uint8, n_frame_mode: bool) =
    discard

proc push_image_packet*(packet: UInt128) =
    write_hwreg(cast[uint64](packet))
    write_hwreg(cast[uint64](packet shr 64))

proc push_prim_data*(prim_data: uint64) =
    let prim_type = cast[uint32](prim_data and 0b111)
    case prim_type:
        of 3: # Triangle
            if color_queue.len != 0 and vertex_queue.len != 0:
                vertex_array.append vertex(vec2(cfloat((vertex_queue[0][0] - x_offset) and 0x1FF), cfloat((vertex_queue[0][1] - y_offset) and 0x1FF)), color(uint8(color_queue[0][0]), uint8(color_queue[0][1]), uint8(color_queue[0][2])))
                vertex_array.append vertex(vec2(cfloat((vertex_queue[1][0] - x_offset) and 0x1FF), cfloat((vertex_queue[1][1] - y_offset) and 0x1FF)), color(uint8(color_queue[0][0]), uint8(color_queue[0][1]), uint8(color_queue[0][2])))
                vertex_array.append vertex(vec2(cfloat((vertex_queue[2][0] - x_offset) and 0x1FF), cfloat((vertex_queue[2][1] - y_offset) and 0x1FF)), color(uint8(color_queue[0][0]), uint8(color_queue[0][1]), uint8(color_queue[0][2])))
                vertex_queue = newSeq[array[2, uint64]](0)
                color_queue = newSeq[array[3, uint64]](0)
        else: echo "Unhandled push prim data prim type " & $prim_type
    

proc push_packed_packet*(packet: UInt128, reg: uint32) =
    # Parse the packed packet as they come in
    case reg:
        of 0x00: PRIM = cast[uint64](packet and u128(0b11111111111))
        of 0x01:
            # RGBA
            let r = cast[uint64]((packet shr 0) and u128(0xFF))
            let g = cast[uint64]((packet shr 32) and u128(0xFF))
            let b = cast[uint64]((packet shr 64) and u128(0xFF))
            let a = cast[uint64]((packet shr 96) and u128(0xFF))
            color_queue.add([r, g, b])
            push_prim_data(0b11)
            RGBAQ = RGBAQ and (not 0xFFFFFFFF'u64)
            RGBAQ = RGBAQ or r or (g shl 8) or (b shl 16) or (a shl 24)
        of 0x03: 
            echo "UV"
            discard # UV
        of 0x04:
            # XYZ2F/XYZ3F
            let x = cast[uint64]((packet shr 0) and u128(0xFFF))
            let y = cast[uint64]((packet shr 32) and u128(0xFFF))
            let z = cast[uint64]((packet shr 64) and u128(0xFFFFFF))
            let f = cast[uint64]((packet shr 96) and u128(0xF))
            vertex_queue.add([x, y])
            if vertex_queue.len == 3:
                push_prim_data(0b11)
            XYZ2F = 0
            XYZ2F = x or (y shl 16) or (z shl 32) or (f shl 56)
        of 0x09: CLAMP_2 = cast[uint64](packet and u128(0xFFFFFFFFFFFFFFFF))
        of 0x0E:
            # A + D
            let data = cast[uint64](packet and u128(0xFFFFFFFFFFFFFFFF))
            let reg_address = cast[uint8]((packet shr 64) and u128(0xFF))
            case reg_address:
                of 0x00: 
                    let value = cast[uint64](data and 0b11111111111)
                    #echo "Set PRIM " & u128(value).toBin(11)
                    PRIM = value
                of 0x01: RGBAQ = data
                of 0x05: 
                    let x = cast[uint64]((data shr 0) and 0xFFF)
                    let y = cast[uint64]((data shr 32) and 0xFFF)
                    vertex_queue.add([x, y])
                    if vertex_queue.len == 3:
                        push_prim_data(0b11)
                    XYZ2 = data
                of 0x18: 
                    XYOFFSET_1 = data
                    x_offset = ((XYOFFSET_1 shr 0) and 0xFFF)
                    y_offset = ((XYOFFSET_1 shr 32) and 0xFFF)
                of 0x1A: 
                    #echo "Set PRMODECONT " & $data
                    PRMODECONT = data
                of 0x40: SCISSOR_1 = data
                of 0x45: DTHE = data
                of 0x46: COLCLAMP = data
                of 0x47: TEST_1 = data
                of 0x4C: FRAME_1 = data
                of 0x4E: ZBUF_1 = data
                of 0x50: BITBLTBUF = data
                of 0x51: 
                    TRXPOS = data
                    dest_x = (TRXPOS shr 32) and 0b11111111111
                    dest_y = (TRXPOS shr 48) and 0b11111111111
                of 0x52: 
                    TRXREG = data
                    width = TRXREG and 0b111111111111
                    height = (TRXREG shr 32) and 0b111111111111
                of 0x53: TRXDIR = data
                else:
                    echo "GS 0x0E " & reg_address.toHex() & " " & data.toHex()
        else:
            echo "Unhandled packed packet reg " & reg.toHex()