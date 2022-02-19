import pkg/nint128, strutils

var dram: array[0x400000, uint8]
var vram: array[1024*1024*4, uint8]
#var vram_texture = newTexture(cint(1024), cint(1024))
#var vram_sprite = newSprite(vram_texture)
#vram_sprite.scale = vec2(scale_factor, scale_factor)

#var vertex_array = newVertexArray(PrimitiveType.Triangles)

var debug* = false

type
    FRAME_t = object
        fbp, fbw, format, mask: uint32
        value: uint64
    ZBUF_t = object
        zbp, format, mask: uint32
        value: uint64
    PRIM_t = object
        prim_type: uint32
        gourand, texture, fog, alpha_blend, antialiasing, use_uv, use_context2, fix_fragment: bool
        value: uint64
    RGBAQ_t = object
        red, green, blue, alpha, q: uint32
        value: uint64
    XYZF_t = object
        x, y, z, fog: uint32
        value: uint64
    XYZ_t = object
        x, y, z: uint32
        value: uint64
    XYOFFSET_t = object
        x, y: uint32
        value: uint64
    TRXPOS_t = object
        x_source, y_source, x_dest, y_dest, transmission_order: uint32
        value: uint64
    TRXREG_t = object
        width, height: uint32
        value: uint64
    TRXDIR_t = object
        direction: uint32
        value: uint64
    VERTEX_t = object
        x, y, z, r, g, b, a: uint32
    BITBLTBUF_t = object
        sbp, sbw, sf, dbp, dbw, df: uint32
        value: uint64


var FRAME_1 = FRAME_t()
var FRAME_2 = FRAME_t()
var PRIM = PRIM_t()
var RGBAQ = RGBAQ_t()
var XYZ2F = XYZF_t()
var XYZ2 = XYZ_t()
var XYOFFSET_1 = XYOFFSET_t()
var ZBUF_1 = ZBUF_t()
var ZBUF_2 = ZBUF_t()
var TRXPOS = TRXPOS_t()
var TRXREG = TRXREG_t()
var TRXDIR = TRXDIR_t()
var BITBLTBUF = BITBLTBUF_t()

const block_layout: array[32, int] = [0,  1,  4,  5,  16, 17, 20, 21,
                                      2,  3,  6,  7,  18, 19, 22, 23,
                                      8,  9,  12, 13, 24, 25, 28, 29,
                                      10, 11, 14, 15, 26, 27, 30, 31]

var cur_transfer_x: uint32
var cur_transfer_y: uint32

var CLAMP_2: uint64
var PRMODECONT: uint64
var SCISSOR_1: uint64
var DTHE: uint64
var COLCLAMP: uint64
var TEST_1: uint64

var GS_CSR*: uint64
var GS_IMR*: uint64

#X, Y, Z, R, G, B, A
var vertex_buffer: array[4, VERTEX_t]
var cur_vertex_buffer_size: uint8 = 0


proc vertex_kick() =
    vertex_buffer[0] = vertex_buffer[1]
    vertex_buffer[1] = vertex_buffer[2]
    vertex_buffer[2] = vertex_buffer[3]
    vertex_buffer[3] = VERTEX_t()
    cur_vertex_buffer_size += 1
    

proc draw_kick() =
    if cur_vertex_buffer_size >= 3:
        #vertex_array.append vertex(vec2(cfloat((vertex_buffer[2].x - XYOFFSET_1.x) mod 620), cfloat((vertex_buffer[2].y - XYOFFSET_1.y) mod 512)), color(uint8(vertex_buffer[2].r), uint8(vertex_buffer[2].g), uint8(vertex_buffer[2].b)))
        #vertex_array.append vertex(vec2(cfloat((vertex_buffer[1].x - XYOFFSET_1.x) mod 620), cfloat((vertex_buffer[1].y - XYOFFSET_1.y) mod 512)), color(uint8(vertex_buffer[1].r), uint8(vertex_buffer[1].g), uint8(vertex_buffer[1].b)))
        #vertex_array.append vertex(vec2(cfloat((vertex_buffer[0].x - XYOFFSET_1.x) mod 620), cfloat((vertex_buffer[0].y - XYOFFSET_1.y) mod 512)), color(uint8(vertex_buffer[0].r), uint8(vertex_buffer[0].g), uint8(vertex_buffer[0].b)))
        cur_vertex_buffer_size = 2

proc write_hwreg(data: uint64) =
    case BITBLTBUF.sf:
        of 0x00: # RGBA32, each color is 8 bits, data contains 2 pixels
            let pixel1 = cast[uint32](data)
            let pixel2 = cast[uint32](data shr 32)
            let a1 = cast[uint8]((pixel1 shr 24) and 0xFF)
            let b1 = cast[uint8]((pixel1 shr 16) and 0xFF)
            let g1 = cast[uint8]((pixel1 shr 8) and 0xFF)
            let r1 = cast[uint8]((pixel1 shr 0) and 0xFF)

            let a2 = cast[uint8]((pixel2 shr 24) and 0xFF)
            let b2 = cast[uint8]((pixel2 shr 16) and 0xFF)
            let g2 = cast[uint8]((pixel2 shr 8) and 0xFF)
            let r2 = cast[uint8]((pixel2 shr 0) and 0xFF)


            var page_num = (cur_transfer_x shr 6) + ((FRAME_1.fbw shr 6)*(cur_transfer_y shr 5))
            var block_num = block_layout[((cur_transfer_x and 0x3F) shr 3) + ((cur_transfer_y and 0x1F) shr 3)*8]
            
            var offset = cur_transfer_y*1024*4 + cur_transfer_x*4
            if (offset + 7) < 4194304:
                vram[offset + 0] = r1
                vram[offset + 1] = g1
                vram[offset + 2] = b1
                vram[offset + 3] = 255

                vram[offset + 4] = r2
                vram[offset + 5] = g2
                vram[offset + 6] = b2
                vram[offset + 7] = 255

            cur_transfer_x += 2
            if (cur_transfer_x - TRXPOS.x_dest) >= TRXREG.width:
                cur_transfer_x -= TRXREG.width
                cur_transfer_y += 1


        else: echo "Unhandled GSTRANSFER data format " & BITBLTBUF.df.toHex()

proc do_vram_vram_transfer() =
    cur_transfer_y = 0
    while cur_transfer_y <= TRXREG.height:
        cur_transfer_x = 0
        while cur_transfer_x <= TRXREG.width:
            vram[(TRXPOS.y_dest+cur_transfer_y)*1024*4 + (TRXPOS.x_dest+cur_transfer_x)*4 + 0] = vram[(TRXPOS.y_source+cur_transfer_y)*1024*4 + (TRXPOS.x_source+cur_transfer_x)*4 + 0]
            vram[(TRXPOS.y_dest+cur_transfer_y)*1024*4 + (TRXPOS.x_dest+cur_transfer_x)*4 + 1] = vram[(TRXPOS.y_source+cur_transfer_y)*1024*4 + (TRXPOS.x_source+cur_transfer_x)*4 + 1]
            vram[(TRXPOS.y_dest+cur_transfer_y)*1024*4 + (TRXPOS.x_dest+cur_transfer_x)*4 + 2] = vram[(TRXPOS.y_source+cur_transfer_y)*1024*4 + (TRXPOS.x_source+cur_transfer_x)*4 + 2]
            vram[(TRXPOS.y_dest+cur_transfer_y)*1024*4 + (TRXPOS.x_dest+cur_transfer_x)*4 + 3] = vram[(TRXPOS.y_source+cur_transfer_y)*1024*4 + (TRXPOS.x_source+cur_transfer_x)*4 + 3]
            cur_transfer_x += 1
        cur_transfer_y += 1


proc set_gscrt*(n_interlaced: bool, n_mode: uint8, n_frame_mode: bool) =
    discard

proc push_image_packet*(packet: UInt128) =
    write_hwreg(cast[uint64](packet))
    write_hwreg(cast[uint64](packet shr 64))

proc push_prim_data*(prim_data: uint64) =
    let prim_type = cast[uint32](prim_data and 0b111)
    case prim_type:
        of 3: # Triangle
            discard
        else: echo "Unhandled push prim data prim type " & $prim_type
    

proc push_packed_packet*(packet: UInt128, reg: uint32) =
    # Parse the packed packet as they come in
    case reg:
        of 0x00: 
            let data = cast[uint64](packet)
            PRIM.value = data
            PRIM.prim_type = cast[uint32](data and 0b111)
            PRIM.gourand = ((data shr 3) and 1) != 0
            PRIM.texture = ((data shr 4) and 1) != 0
            PRIM.fog = ((data shr 5) and 1) != 0
            PRIM.alpha_blend = ((data shr 6) and 1) != 0
            PRIM.antialiasing = ((data shr 7) and 1) != 0
            PRIM.use_uv = ((data shr 8) and 1) != 0
            PRIM.use_context2 = ((data shr 9) and 1) != 0
            PRIM.fix_fragment = ((data shr 10) and 1) != 0
        of 0x01:
            # RGBA
            let data = cast[uint64](packet and u128(0xFFFFFFFFFFFFFFFF))
            RGBAQ.value = data
            RGBAQ.red = cast[uint32]((data shr 0) and 0xFF)
            RGBAQ.green = cast[uint32]((data shr 8) and 0xFF)
            RGBAQ.blue = cast[uint32]((data shr 16) and 0xFF)
            RGBAQ.alpha = cast[uint32]((data shr 24) and 0xFF)
            RGBAQ.q = cast[uint32](data shr 32)
            vertex_buffer[3].r = RGBAQ.red
            vertex_buffer[3].g = RGBAQ.green
            vertex_buffer[3].b = RGBAQ.blue
            vertex_buffer[3].a = RGBAQ.alpha
        of 0x03: # UV
            echo "UV"
        of 0x04: # XYZ2F
            let data = cast[uint64](packet)
            XYZ2F.value = data
            XYZ2F.x = cast[uint32]((data shr 4) and 0xFFF)
            XYZ2F.y = cast[uint32]((data shr 20) and 0xFFF)
            XYZ2F.z = cast[uint32](data shr 32)
            vertex_buffer[3].x = XYZ2F.x
            vertex_buffer[3].y = XYZ2F.y
            vertex_buffer[3].z = XYZ2F.z
            vertex_kick()
            draw_kick()
        of 0x09: CLAMP_2 = cast[uint64](packet and u128(0xFFFFFFFFFFFFFFFF))
        of 0x0E: # A + D
            let data = cast[uint64](packet and u128(0xFFFFFFFFFFFFFFFF))
            let reg_address = cast[uint8]((packet shr 64) and u128(0xFF))
            case reg_address:
                of 0x00: # PRIM
                    PRIM.value = data
                    PRIM.prim_type = cast[uint32](data and 0b111)
                    PRIM.gourand = ((data shr 3) and 1) != 0
                    PRIM.texture = ((data shr 4) and 1) != 0
                    PRIM.fog = ((data shr 5) and 1) != 0
                    PRIM.alpha_blend = ((data shr 6) and 1) != 0
                    PRIM.antialiasing = ((data shr 7) and 1) != 0
                    PRIM.use_uv = ((data shr 8) and 1) != 0
                    PRIM.use_context2 = ((data shr 9) and 1) != 0
                    PRIM.fix_fragment = ((data shr 10) and 1) != 0
                of 0x01: # RGBAQ
                    RGBAQ.value = data
                    RGBAQ.red = cast[uint32]((data shr 0) and 0xFF)
                    RGBAQ.green = cast[uint32]((data shr 8) and 0xFF)
                    RGBAQ.blue = cast[uint32]((data shr 16) and 0xFF)
                    RGBAQ.alpha = cast[uint32]((data shr 24) and 0xFF)
                    RGBAQ.q = cast[uint32](data shr 32)
                    vertex_buffer[3].r = RGBAQ.red
                    vertex_buffer[3].g = RGBAQ.green
                    vertex_buffer[3].b = RGBAQ.blue
                    vertex_buffer[3].a = RGBAQ.alpha
                of 0x05: # XYZ2
                    XYZ2.value = data
                    XYZ2.x = cast[uint32]((data shr 4) and 0xFFF)
                    XYZ2.y = cast[uint32]((data shr 20) and 0xFFF)
                    XYZ2.z = cast[uint32](data shr 32)
                    vertex_buffer[3].x = XYZ2.x
                    vertex_buffer[3].y = XYZ2.y
                    vertex_kick()
                    draw_kick()
                of 0x18: # XYOFFSET_1
                    XYOFFSET_1.value = data
                    XYOFFSET_1.x = cast[uint32]((data shr 0) and 0xFFFF)
                    XYOFFSET_1.y = cast[uint32]((data shr 32) and 0xFFFF)
                of 0x1A: 
                    #echo "Set PRMODECONT " & $data
                    PRMODECONT = data
                of 0x40: SCISSOR_1 = data
                of 0x45: DTHE = data
                of 0x46: COLCLAMP = data
                of 0x47: TEST_1 = data
                of 0x4C: # FRAME_1
                    FRAME_1.value = data
                    FRAME_1.fbp = cast[uint32](data and 0b111111111) shl 11
                    FRAME_1.fbw = cast[uint32]((data shr 16) and 0b111111) shl 6
                    FRAME_1.format = cast[uint32]((data shr 24) and 0b111111)
                    FRAME_1.mask = cast[uint32](data shr 32)
                    echo "FRAME_1: "
                    echo "  " & FRAME_1.fbp.toHex()
                    echo "  " & $FRAME_1.fbw
                    echo "  " & FRAME_1.format.toHex()
                    echo "  " & FRAME_1.mask.toHex()
                of 0x4E: # ZBUF_1 
                    ZBUF_1.value = data
                    ZBUF_1.zbp = cast[uint32](data and 0b111111111) shl 11
                    ZBUF_1.format = cast[uint32]((data shr 24) and 0b1111)
                    ZBUF_1.mask = cast[uint32](data shr 32)
                of 0x50: 
                    BITBLTBUF.value = data
                    BITBLTBUF.sbp = (cast[uint32](data shr 0) and 0x3FFF) shl 6
                    BITBLTBUF.sbw = (cast[uint32](data shr 16) and 0x3F) shl 6
                    BITBLTBUF.sf = cast[uint32](data shr 24) and 0x3F
                    BITBLTBUF.dbp = (cast[uint32](data shr 32) and 0x3FFF) shl 6
                    BITBLTBUF.dbw = (cast[uint32](data shr 48) and 0x3F) shl 6
                    BITBLTBUF.df = cast[uint32](data shr 56) and 0x3F
                    echo "BITBLTBUF:"
                    echo "  " & BITBLTBUF.sbp.toHex()
                    echo "  " & BITBLTBUF.sbw.toHex()
                    echo "  " & BITBLTBUF.sf.toHex()
                    echo "  " & BITBLTBUF.dbp.toHex()
                    echo "  " & BITBLTBUF.dbw.toHex()
                    echo "  " & BITBLTBUF.df.toHex()
                of 0x51: # TRXPOS
                    TRXPOS.value = data
                    TRXPOS.x_source = cast[uint32]((data shr 0) and 0b11111111111)
                    TRXPOS.y_source = cast[uint32]((data shr 16) and 0b11111111111)
                    TRXPOS.x_dest = cast[uint32]((data shr 32) and 0b11111111111)
                    TRXPOS.y_dest = cast[uint32]((data shr 48) and 0b11111111111)
                    TRXPOS.transmission_order = cast[uint32]((data shr 59) and 0b11)
                    cur_transfer_x = TRXPOS.x_dest
                    cur_transfer_y = TRXPOS.y_dest
                    echo "TRXPOS:"
                    echo "  " & TRXPOS.x_source.toHex()
                    echo "  " & TRXPOS.y_source.toHex()
                    echo "  " & TRXPOS.x_dest.toHex()
                    echo "  " & TRXPOS.y_dest.toHex()
                    echo "  " & TRXPOS.transmission_order.toHex()
                of 0x52: # TRXREG
                    TRXREG.value = data
                    TRXREG.width = cast[uint32](data and 0b111111111111)
                    TRXREG.height = cast[uint32](data shr 32) and 0b111111111111
                    echo "TRXREG:"
                    echo "  " & $TRXREG.width
                    echo "  " & $TRXREG.height
                of 0x53: # TRXDIR
                    TRXDIR.value = data
                    TRXDIR.direction = cast[uint32](data and 0b11)
                    if TRXDIR.direction == 2:
                        do_vram_vram_transfer()
                    echo "TRXDIR"
                    echo "  " & $TRXDIR.direction
                else:
                    echo "GS 0x0E " & reg_address.toHex() & " " & data.toHex()
        else:
            echo "Unhandled packed packet reg " & reg.toHex()