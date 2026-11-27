// Every string the window shows, in one place per language.

import Cocoa

/// Every string the window shows, in one place per language.
struct Strings {
    let code: String
    let displayName: String

    let windowTitle: String
    let connecting: String
    let agentDown: String
    let agentDownHint: String
    let scheduleLine: String
    let nextChange: String
    let noPermission: String
    let captionSchedule: String
    let captionCaptured: String
    let captionAction: String

    let rowOff: String
    let rowOn: String
    let rowMode: String
    let rowColor: String
    let rowLanguage: String
    let rowDpi: String
    let actionFailed: String

    let modeCaptured: String
    let modeFixed: String
    let languageSystem: String

    let applyNow: String
    let openPrivacy: String
    let restartAgent: String
    let never: String

    let notRunning: String
    let actionOff: String
    let actionOn: String
    let actionColour: String
    let actionSave: String
    let actionScheduled: String
    let actionManual: String
    let menuAbout: String
    let menuQuit: String

    /// Added for the state selector; kept last so the memberwise initialiser
    /// order stays easy to check against both language tables.
    /// Caption above the scheduled/on/off selector.
    let rowLightState: String
    /// Segments: follow the schedule, hold on, hold off.
    let stateSchedule: String
    let stateOff: String
    let stateOn: String
    /// Quiet autosave confirmation, shown in place of the old Save button.
    let autoSaved: String
    /// Headline: what the lights are doing right now.
    let statusOnLine: String
    let statusOffLine: String
    let statusNoDevice: String
    /// Detail line while a manual choice overrides the schedule.
    let manualHold: String

    /// Menu bar item: reopen the window.
    let menuOpenWindow: String
    /// Menu bar items that mirror the three lighting states.
    let menuOff: String
    let menuOn: String
    let menuSchedule: String

    static let english = Strings(
        code: "en",
        displayName: "English",
        windowTitle: "LogiLight",
        connecting: "Connecting to the agent…",
        agentDown: "Agent is not running",
        agentDownHint: "Use “Restart agent”, or run: launchctl kickstart -k gui/%d/com.luhui.logilight",
        scheduleLine: "Schedule: off %@ → on %@",
        nextChange: "Next change: %@",
        noPermission: "Input Monitoring is NOT granted — the agent cannot reach the mouse.",
        captionSchedule: "SCHEDULE",
        captionCaptured: "NIGHT COLOUR",
        captionAction: "LAST ACTION",
        rowOff: "Lights off at",
        rowOn: "Lights on at",
        rowMode: "Morning colour",
        rowColor: "Fixed colour",
        rowLanguage: "Language",
        rowDpi: "DPI",
        actionFailed: "Action failed",
        modeCaptured: "Restore the colour it had",
        modeFixed: "Always use a fixed colour",
        languageSystem: "Follow system",
        applyNow: "Apply colour now",
        openPrivacy: "System permissions…",
        restartAgent: "Restart agent",
        never: "never",
        notRunning: "The agent is not running, so %@ did nothing.",
        actionOff: "turning the lights off",
        actionOn: "restoring the lights",
        actionColour: "applying the colour",
        actionSave: "saving the settings",
        actionScheduled: "scheduled",
        actionManual: "manual",
        menuAbout: "About LogiLight",
        menuQuit: "Quit LogiLight",
        rowLightState: "Lighting",
        stateSchedule: "Schedule",
        stateOff: "Off",
        stateOn: "On",
        autoSaved: "Saved",
        statusOnLine: "Lights are on",
        statusOffLine: "Lights are off",
        statusNoDevice: "No mouse found",
        manualHold: "set by hand — choose Schedule to follow the times again",
        menuOpenWindow: "Open LogiLight",
        menuOff: "Lights off now",
        menuOn: "Lights on now",
        menuSchedule: "Follow schedule"
    )

    static let chinese = Strings(
        code: "zh-Hans",
        displayName: "简体中文",
        windowTitle: "LogiLight 灯光控制",
        connecting: "正在连接后台服务…",
        agentDown: "后台服务未运行",
        agentDownHint: "点“重启服务”，或运行：launchctl kickstart -k gui/%d/com.luhui.logilight",
        scheduleLine: "定时：%1$@ 关灯 → %2$@ 开灯",
        nextChange: "下次切换：%@",
        noPermission: "尚未授予“输入监控”权限，后台服务无法访问鼠标。",
        captionSchedule: "定时",
        captionCaptured: "夜间颜色",
        captionAction: "上次操作",
        rowOff: "关灯时间",
        rowOn: "开灯时间",
        rowMode: "早晨颜色",
        rowColor: "固定颜色",
        rowLanguage: "语言",
        rowDpi: "DPI",
        actionFailed: "操作失败",
        modeCaptured: "恢复关灯前的颜色",
        modeFixed: "始终使用固定颜色",
        languageSystem: "跟随系统",
        applyNow: "应用当前颜色",
        openPrivacy: "系统权限设置…",
        restartAgent: "重启服务",
        never: "从未",
        notRunning: "后台服务未运行，%1$@没有执行。",
        actionOff: "关灯",
        actionOn: "恢复灯光",
        actionColour: "应用颜色",
        actionSave: "保存设置",
        actionScheduled: "定时",
        actionManual: "手动",
        menuAbout: "关于 LogiLight",
        menuQuit: "退出 LogiLight",
        rowLightState: "灯光状态",
        stateSchedule: "定时",
        stateOff: "关闭",
        stateOn: "打开",
        autoSaved: "已保存",
        statusOnLine: "灯光已打开",
        statusOffLine: "灯光已关闭",
        statusNoDevice: "未找到鼠标",
        manualHold: "手动设置中，选「定时」才恢复自动",
        menuOpenWindow: "打开 LogiLight",
        menuOff: "立即关灯",
        menuOn: "立即开灯",
        menuSchedule: "恢复按定时执行"
    )

    static func resolve() -> Strings {
        let stored = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
        if stored == "auto" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .chinese : .english
        }
        return stored.hasPrefix("zh") ? .chinese : .english
    }

    static func forStorage(_ value: String) -> Strings {
        value.hasPrefix("zh") ? .chinese : .english
    }
}
