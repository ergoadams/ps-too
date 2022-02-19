import imgui

type
    LogType* = enum
        logInfo = "INFO:",
        logDebug = "DEBUG:"
        logWarning = "WARN:"
        logDMAC = "DMAC:"
        logConsole = ""

var LogTypes*: array[LogType, ImVec4]
LogTypes[logInfo] = ImVec4(x: 0.0f, y: 1.0f, z: 0.0f, w: 1.0f)
LogTypes[logDebug] = ImVec4(x: 0.4f, y: 1.0f, z: 0.9f, w: 1.0f)
LogTypes[logWarning] = ImVec4(x: 1.0f, y: 0.0f, z: 0.0f, w: 1.0f)
LogTypes[logDMAC] = ImVec4(x: 1.0f, y: 0.7f, z: 0.4f, w: 1.0f)
LogTypes[logConsole] = ImVec4(x: 0.0f, y: 0.0f, z: 0.0f, w: 0.0f)

var logs*: seq[tuple[logtype: LogType, value: string]]

var should_scroll*: bool

proc add_log*(log_data_type: LogType, data: string) =
    logs.add((log_data_type, data))
    should_scroll = true