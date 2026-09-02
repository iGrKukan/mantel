import AppKit
import CoreGraphics
import SwiftUI
import Combine

// MARK: - Панель полки

/// Безрамочная плавающая панель — не активируется, не отбирает фокус у других приложений.
/// Это критично: пользователь тащит файл из полки в другое окно, и полка не должна
/// перехватывать key window при наведении.
final class ShelfPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // На уровень выше статус-бара, чтобы быть поверх всего постоянно.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // тень рисует SwiftUI, иначе окно даёт серые прямоугольные углы
        isMovable = false
    }

    // Панель не должна становиться key/main — иначе она перехватит фокус у активного
    // приложения и перетаскивание файлов наружу сломается.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Состояние для SwiftUI-содержимого

/// Развёрнута полка или свёрнута в «пилюлю» — ShelfView реагирует на это.
final class ShelfUIState: ObservableObject {
    @Published var isExpanded: Bool = false
}

// MARK: - Геометрия

private enum ShelfGeometry {
    static let collapsedHeight: CGFloat = 6
    /// Отступ развёрнутой панели от верхнего края экрана — чтобы были видны скруглённые
    /// верхние углы. Свёрнутая «пилюля» остаётся прижатой к самому верху (отступ 0).
    static let expandedTopGap: CGFloat = 8
    static let hotZoneWidth: CGFloat = 260
    static let hotZoneHeight: CGFloat = 6
    /// Запас вокруг развёрнутой панели, за пределами которого считаем, что курсор ушёл.
    static let hideMargin: CGFloat = 40
    static let hideDelay: TimeInterval = 0.45
    static let animationDuration: TimeInterval = 0.18
    static let autoShowDuration: TimeInterval = 2.5
    /// Радиус вокруг горячей зоны, в котором пилюля считается «рядом» и не гаснет.
    static let pillNearRadius: CGFloat = 80
}

// MARK: - Контроллер полки

final class ShelfController {
    static let shared = ShelfController()

    /// true пока идёт перетаскивание файла ИЗ полки наружу — на это время скрытие запрещено.
    /// Ставится/снимается DragCatcherView в ShelfView.swift.
    var isDragging = false

    /// Состояние развёрнутости для SwiftUI-содержимого панели.
    let uiState = ShelfUIState()

    private(set) var isExpanded: Bool = false

    private var panel: ShelfPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private var autoShowWorkItem: DispatchWorkItem?
    private var libraryCancellable: AnyCancellable?
    private var sizeCancellable: AnyCancellable?

    private init() {}

    // MARK: запуск

    func start() {
        guard panel == nil else { return }

        let screen = ShelfController.currentScreen()
        let panel = ShelfPanel(contentRect: collapsedFrame(on: screen))
        let hostingView = NSHostingView(rootView: ShelfView().environmentObject(uiState))
        // Тень и скругление рисует SwiftUI поверх .clear — хостинг-вью не должен подкладывать
        // свой непрозрачный фон, иначе будут видны прямоугольные углы позади панели.
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.panel = panel
        panel.orderFrontRegardless()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.handleMouseMoved()
        }
        // Локальный монитор — чтобы отслеживание работало и когда курсор уже над своей панелью.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseMoved()
            return event
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screenParamsChanged),
                                                 name: NSApplication.didChangeScreenParametersNotification,
                                                 object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemAdded),
                                                 name: .shelfDidAddItem, object: nil)

        libraryCancellable = Library.shared.$items.sink { [weak self] _ in
            self?.updatePillAlpha()
        }
        updatePillAlpha()

        // Изменение ширины/высоты в настройках должно быть видно сразу, если полка
        // сейчас развёрнута (перетаскивание краёв применяет размер напрямую через
        // applySize и тоже пишет сюда же — так что этот сабскрайб покрывает и его).
        sizeCancellable = AppSettings.shared.$shelfWidth
            .combineLatest(AppSettings.shared.$shelfHeight)
            .sink { [weak self] width, height in
                guard let self = self, self.isExpanded else { return }
                self.applySize(width: CGFloat(width), height: CGFloat(height), live: false)
            }
    }

    // MARK: показ/скрытие

    func show(animated: Bool = true) {
        guard panel != nil else { return }
        cancelHide()
        autoShowWorkItem?.cancel()
        autoShowWorkItem = nil

        let screen = ShelfController.currentScreen()
        isExpanded = true
        uiState.isExpanded = true
        reposition(to: expandedFrame(on: screen), animated: animated)
    }

    func hide(animated: Bool = true) {
        guard panel != nil else { return }
        cancelHide()

        let screen = ShelfController.currentScreen()
        isExpanded = false
        uiState.isExpanded = false
        reposition(to: collapsedFrame(on: screen), animated: animated)
        updatePillAlpha()
    }

    /// Пересчитывает и ставит кадр развёрнутой панели под новый размер — позиция
    /// остаётся «верх по центру текущего экрана», отступ сверху прежний.
    /// `live == true` — во время перетаскивания края мышью (без анимации, кадр за кадром),
    /// иначе — обычная анимация (после mouseUp или после правки в настройках).
    /// Ничего не делает, если полка сейчас свёрнута — новый размер применится при следующем show().
    func applySize(width: CGFloat, height: CGFloat, live: Bool) {
        guard panel != nil, isExpanded else { return }
        let w = min(max(width, CGFloat(ShelfSizeLimits.minWidth)), CGFloat(ShelfSizeLimits.maxWidth))
        let h = min(max(height, CGFloat(ShelfSizeLimits.minHeight)), CGFloat(ShelfSizeLimits.maxHeight))
        let screen = ShelfController.currentScreen()
        let target = frame(on: screen, width: w, height: h, topGap: ShelfGeometry.expandedTopGap)
        reposition(to: target, animated: !live)
    }

    /// Служебное: отрисовать текущее содержимое панели в PNG (без снимка экрана).
    func writeSnapshot(to url: URL) {
        guard let view = panel?.contentView else { NSLog("Mantel: нет contentView"); return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: url); NSLog("Mantel: снимок панели -> %@", url.path) }
        catch { NSLog("Mantel: снимок не записан: %@", error.localizedDescription) }
    }

    func toggle() {
        if isExpanded { hide() } else { show() }
    }

    private func reposition(to target: NSRect, animated: Bool) {
        guard let panel = panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = ShelfGeometry.animationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    // MARK: мышь / горячая зона

    private func handleMouseMoved() {
        guard panel != nil else { return }
        let mouseLoc = NSEvent.mouseLocation
        let screen = ShelfController.currentScreen()

        if isExpanded {
            let bigRect = expandedFrame(on: screen).insetBy(dx: -ShelfGeometry.hideMargin, dy: -ShelfGeometry.hideMargin)
            if NSMouseInRect(mouseLoc, bigRect, false) {
                cancelHide()
            } else {
                scheduleHide()
            }
        } else {
            updatePillAlpha()
            guard AppSettings.shared.hotZoneEnabled else { return }
            if NSMouseInRect(mouseLoc, hotZoneRect(on: screen), false) {
                show(animated: true)
            }
        }
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.hideWorkItem = nil
            if self.isDragging {
                // Перетаскивание наружу ещё идёт — откладываем скрытие ещё раз.
                self.scheduleHide()
            } else {
                self.hide(animated: true)
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfGeometry.hideDelay, execute: work)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    // MARK: реакция на новый элемент / смену экранов

    @objc private func itemAdded(_ note: Notification) {
        show(animated: true)
        autoShowWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.autoShowWorkItem = nil
            let mouseLoc = NSEvent.mouseLocation
            let screen = ShelfController.currentScreen()
            let bigRect = self.expandedFrame(on: screen).insetBy(dx: -ShelfGeometry.hideMargin, dy: -ShelfGeometry.hideMargin)
            if !NSMouseInRect(mouseLoc, bigRect, false) {
                self.hide(animated: true)
            }
        }
        autoShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfGeometry.autoShowDuration, execute: work)
    }

    @objc private func screenParamsChanged() {
        guard panel != nil else { return }
        let screen = ShelfController.currentScreen()
        reposition(to: isExpanded ? expandedFrame(on: screen) : collapsedFrame(on: screen), animated: false)
    }

    // MARK: пилюля — почти прозрачна, если пусто и курсор далеко

    private func updatePillAlpha() {
        guard let panel = panel, !isExpanded else { return }
        guard Library.shared.items.isEmpty else {
            panel.alphaValue = 1.0
            return
        }
        let screen = ShelfController.currentScreen()
        let nearRect = hotZoneRect(on: screen).insetBy(dx: -ShelfGeometry.pillNearRadius, dy: -ShelfGeometry.pillNearRadius)
        let near = NSMouseInRect(NSEvent.mouseLocation, nearRect, false)
        panel.alphaValue = near ? 1.0 : 0.25
    }

    // MARK: геометрия

    private func width() -> CGFloat { CGFloat(AppSettings.shared.shelfWidth) }
    private func height() -> CGFloat { CGFloat(AppSettings.shared.shelfHeight) }

    private func frame(on screen: NSScreen, width: CGFloat, height: CGFloat, topGap: CGFloat) -> NSRect {
        let topInset = screen.safeAreaInsets.top
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - topInset - topGap - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func frame(on screen: NSScreen, height: CGFloat, topGap: CGFloat) -> NSRect {
        frame(on: screen, width: width(), height: height, topGap: topGap)
    }

    private func expandedFrame(on screen: NSScreen) -> NSRect {
        frame(on: screen, height: height(), topGap: ShelfGeometry.expandedTopGap)
    }
    private func collapsedFrame(on screen: NSScreen) -> NSRect {
        frame(on: screen, height: ShelfGeometry.collapsedHeight, topGap: 0)
    }

    private func hotZoneRect(on screen: NSScreen) -> NSRect {
        let topInset = screen.safeAreaInsets.top
        let x = screen.frame.midX - ShelfGeometry.hotZoneWidth / 2
        let y = screen.frame.maxY - topInset - ShelfGeometry.hotZoneHeight
        return NSRect(x: x, y: y, width: ShelfGeometry.hotZoneWidth, height: ShelfGeometry.hotZoneHeight)
    }

    /// Экран, на котором сейчас находится курсор.
    private static func currentScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLoc, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
