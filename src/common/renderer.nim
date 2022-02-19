

import imgui, imgui/[impl_opengl, impl_glfw]
import nimgl/[opengl, glfw]

import logger

proc keyProc(window: GLFWWindow, key: int32, scancode: int32, action: int32, mods: int32): void {.cdecl.} =
    discard

# graphics init
var screenWidth: int32 = 1280
var screenHeight: int32 = 720

assert glfwInit()

glfwWindowHint(GLFWContextVersionMajor, 4)
glfwWindowHint(GLFWContextVersionMinor, 1)
glfwWindowHint(GLFWOpenglForwardCompat, GLFW_TRUE)
glfwWindowHint(GLFWOpenglProfile, GLFW_OPENGL_CORE_PROFILE)
glfwWindowHint(GLFWResizable, GLFW_TRUE)

var w: GLFWWindow = glfwCreateWindow(screenWidth, screenHeight, "ps-too")
if w == nil:
    quit(-1)

discard w.setKeyCallback(keyProc)

w.makeContextCurrent()

assert glInit()

let context = igCreateContext()

assert igGlfwInitForOpenGL(w, true)
assert igOpenGL3Init()

igStyleColorsCherry()


proc display_frame*() =     
    glfwPollEvents()

    igOpenGL3NewFrame()
    igGlfwNewFrame()
    igNewFrame()

    # Begin Imgui window
    igBegin("Info")
    igText("Application average %.3f ms/frame (%.1f FPS)", 1000.0f / igGetIO().framerate, igGetIO().framerate)
    igEnd()

    igBegin("Logs")
    for logline in logs:
        igTextColored(LogTypes[logline.logtype], $logline.logtype)
        igSameLine()
        igText(logline.value)
    if should_scroll:
        igSetScrollHereY(1.0f)
        should_scroll = false
    
    igEnd()
    # End Imgui window


    # Display Imgui stuff
    igRender()

    glClearColor(0.45f, 0.55f, 0.60f, 1.00f)
    glClear(GL_COLOR_BUFFER_BIT)

    igOpenGL3RenderDrawData(igGetDrawData())

    w.swapBuffers()
    if w.windowShouldClose:
        igOpenGL3Shutdown()
        igGlfwShutdown()
        context.igDestroyContext()

        w.destroyWindow()
        glfwTerminate()
        quit()