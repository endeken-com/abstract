#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(AppKit) && !targetEnvironment(macCatalyst)
  import SwiftUI

  // MARK: - Overview
  //
  // `NSTextInteractionView` implements selection and link interaction on macOS.
  //
  // The view sits in an overlay above one or more rendered `Text` fragments. It uses
  // `TextSelectionModel` for hit testing and range manipulation, and it respects `exclusionRects`
  // so embedded scrollable regions continue to receive input events. Link taps are forwarded to
  // `openURL`.

  final class NSTextInteractionView: NSView {
    var model: TextSelectionModel
    var exclusionRects: [CGRect]
    var openURL: OpenURLAction
    /// The selection this text shares with others, if any.
    weak var group: (any TextSelectionGroup)? {
      didSet {
        guard oldValue !== group else { return }
        oldValue?.unregister(self)
        if window != nil { group?.register(self) }
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil { group?.register(self) } else { group?.unregister(self); stopScrolling() }
    }

    override var acceptsFirstResponder: Bool { true }
    // A drag selects even in a window that isn't active yet, as a web page does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    fileprivate var dragStart: TextPosition?
    private var selectionAnchor: TextPosition?
    /// While a drag holds past the edge of the list it's in, the list keeps scrolling.
    private var lastDrag: NSEvent?
    private var scrollTimer: Timer?

    init(
      model: TextSelectionModel,
      exclusionRects: [CGRect],
      openURL: OpenURLAction
    ) {
      self.model = model
      self.exclusionRects = exclusionRects
      self.openURL = openURL

      super.init(frame: .zero)
      self.wantsLayer = false
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      let localPoint = convert(point, from: superview)
      let isExcluded = exclusionRects.contains {
        $0.contains(localPoint)
      }

      if isExcluded {
        return nil
      } else {
        return super.hitTest(point)
      }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      let location = convert(event.locationInWindow, from: nil)

      switch event.clickCount {
      case 1:
        if let url = model.url(for: location) {
          openURL(url)
        } else {
          resetSelection()
        }
        dragStart = model.closestPosition(to: location)
      case 2:
        if let position = model.closestPosition(to: location) {
          model.selectedRange = model.wordRange(for: position)
        }
        dragStart = nil
      case 3:
        if let position = model.closestPosition(to: location) {
          model.selectedRange = model.blockRange(for: position)
        }
        dragStart = nil
      default:
        break
      }
      group?.selectionBegan(in: self)
    }

    override func mouseDragged(with event: NSEvent) {
      guard dragStart != nil else {
        return
      }
      extendSelection(with: event)
      keepScrolling(with: event)
    }

    private func extendSelection(with event: NSEvent) {
      guard let dragStart else {
        return
      }
      if let group, group.selectionDragged(from: self, to: event.locationInWindow) {
        autoscroll(with: event)
        return
      }

      let location = convert(event.locationInWindow, from: nil)

      guard let currentPosition = model.closestPosition(to: location) else {
        return
      }

      model.selectedRange = TextRange(from: dragStart, to: currentPosition)
      autoscroll(with: event)
    }

    /// AppKit sends no drags while the pointer holds still, so past the
    /// list's edge a timer goes on scrolling and selecting.
    private func keepScrolling(with event: NSEvent) {
      lastDrag = event
      guard let clip = outerClipView else { return }
      if clip.convert(clip.bounds, to: nil).contains(event.locationInWindow) {
        stopScrolling()
      } else if scrollTimer == nil {
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.dragStart != nil, let drag = self.lastDrag else {
              self?.stopScrolling()
              return
            }
            self.extendSelection(with: drag)
          }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
      }
    }

    private func stopScrolling() {
      scrollTimer?.invalidate()
      scrollTimer = nil
      lastDrag = nil
    }

    /// The list that scrolls up and down, past any that only scroll sideways (a code block).
    private var outerClipView: NSClipView? {
      var scroll = enclosingScrollView
      while let current = scroll, !current.hasVerticalScroller, let outer = current.superview?.enclosingScrollView {
        scroll = outer
      }
      return scroll?.contentView
    }

    override func mouseUp(with event: NSEvent) {
      dragStart = nil
      stopScrolling()
      group?.selectionEnded(in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
      let location = convert(event.locationInWindow, from: nil)
      updateSelectionForContextMenu(at: location)

      NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      let location = convert(event.locationInWindow, from: nil)
      updateSelectionForContextMenu(at: location)

      return makeContextMenu()
    }

    override func selectAll(_ sender: Any?) {
      if group?.selectAll() == true { return }
      model.selectedRange = TextRange(start: model.startPosition, end: model.endPosition)
    }

    override func keyDown(with event: NSEvent) {
      interpretKeyEvents([event])
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.position(from: position, offset: 1)
      }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.position(from: position, offset: -1)
      }
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
      modifySelection { position, anchor in
        model.positionAbove(position, anchor: anchor)
      }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
      modifySelection { position, anchor in
        model.positionBelow(position, anchor: anchor)
      }
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.nextWord(from: position)
      }
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.previousWord(from: position)
      }
    }

    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.blockStart(for: position)
      }
    }

    override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.blockEnd(for: position)
      }
    }

    private func updateSelectionForContextMenu(at location: CGPoint) {
      guard let position = model.closestPosition(to: location) else {
        resetSelection()
        return
      }

      if let selectedRange = model.selectedRange, selectedRange.contains(position) {
        // do nothing
        return
      }

      model.selectedRange = model.wordRange(for: position)
    }

    private func makeContextMenu() -> NSMenu {
      let contextMenu = NSMenu()

      guard let selectedRange = model.selectedRange, !selectedRange.isCollapsed else {
        return contextMenu
      }

      // Get the localized title for the share action
      let sharingPicker = NSSharingServicePicker(items: [])
      let shareActionTitle = sharingPicker.standardShareMenuItem.title

      // Get the localized title for the copy action
      let copyActionTitle =
        if let defaultMenu = NSTextView.defaultMenu,
          let copyAction = defaultMenu.items.first(where: { $0.action == #selector(copy(_:)) })
        {
          copyAction.title
        } else {
          NSLocalizedString("Copy", bundle: .main, comment: "")
        }

      contextMenu.addItem(
        .init(
          title: shareActionTitle,
          action: #selector(share(_:)),
          keyEquivalent: ""
        )
      )
      contextMenu.addItem(.separator())
      contextMenu.addItem(
        .init(
          title: copyActionTitle,
          action: #selector(copy(_:)),
          keyEquivalent: ""
        )
      )

      return contextMenu
    }

    private func modifySelection(
      _ transform: (_ position: TextPosition, _ anchor: TextPosition) -> TextPosition?
    ) {
      guard let selectedRange = model.selectedRange else {
        return
      }

      // set anchor on first move
      selectionAnchor = selectionAnchor ?? selectedRange.start

      guard let selectionAnchor else {
        return
      }

      // modify the non-anchor end of the selection
      let position =
        selectionAnchor == selectedRange.start
        ? selectedRange.end
        : selectedRange.start

      guard let newPosition = transform(position, selectionAnchor) else {
        return
      }
      model.selectedRange = TextRange(from: selectionAnchor, to: newPosition)

      // scroll to make the new position visible
      let caretRect = model.caretRect(for: newPosition)
      scrollToVisible(caretRect)
    }

    fileprivate func resetSelection() {
      model.selectedRange = nil
      selectionAnchor = nil
    }

    @objc private func share(_ sender: Any?) {
      guard let selectedRange = model.selectedRange else {
        return
      }

      let attributedText = model.attributedText(in: selectedRange)
      let transferableText = TransferableText(attributedString: attributedText)
      let itemProvider = NSItemProvider(object: transferableText)

      let sharingPicker = NSSharingServicePicker(items: [itemProvider])
      let rect =
        model.selectionRects(for: selectedRange)
        .last?.rect.integral ?? .zero

      sharingPicker.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    @objc private func copy(_ sender: Any?) {
      if group?.copySelection() == true { return }
      guard let selectedRange = model.selectedRange else {
        return
      }

      let attributedText = model.attributedText(in: selectedRange)

      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()

      let formatter = Formatter(attributedText)
      pasteboard.setString(formatter.plainText(), forType: .string)
      pasteboard.setString(formatter.html(), forType: .html)
    }
  }

  extension NSTextInteractionView: TextSelectionGroupMember {
    var frameInWindow: CGRect { convert(bounds, to: nil) }
    var memberView: NSView { self }

    func selectAllText() {
      guard model.hasText else { return }
      model.selectedRange = TextRange(start: model.startPosition, end: model.endPosition)
    }

    func clearSelection() {
      if model.selectedRange != nil { resetSelection() }
    }

    func selectFromDragStart(toEnd: Bool) {
      guard let dragStart, model.hasText else { return }
      model.selectedRange = TextRange(from: dragStart, to: toEnd ? model.endPosition : model.startPosition)
    }

    func select(to windowPoint: CGPoint, fromStart: Bool) {
      guard model.hasText else { return }
      let edge = fromStart ? model.startPosition : model.endPosition
      guard let position = model.closestPosition(to: convert(windowPoint, from: nil)) else {
        model.selectedRange = TextRange(start: model.startPosition, end: model.endPosition)
        return
      }
      model.selectedRange = TextRange(from: edge, to: position)
    }

    var selectedPlainText: String? {
      guard let range = model.selectedRange, !range.isCollapsed else { return nil }
      return Formatter(model.attributedText(in: range)).plainText()
    }

    var plainText: String {
      guard model.hasText else { return "" }
      return Formatter(model.attributedText(in: TextRange(start: model.startPosition, end: model.endPosition))).plainText()
    }
  }

  extension NSTextInteractionView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
      switch item.action {
      case #selector(selectAll(_:)):
        return model.hasText
      case #selector(copy(_:)):
        if group?.hasSpanningSelection == true { return true }
        guard let selectedRange = model.selectedRange else {
          return false
        }
        return !selectedRange.isCollapsed
      case #selector(moveRightAndModifySelection(_:)),
        #selector(moveLeftAndModifySelection(_:)),
        #selector(moveUpAndModifySelection(_:)),
        #selector(moveDownAndModifySelection(_:)),
        #selector(moveWordRightAndModifySelection(_:)),
        #selector(moveWordLeftAndModifySelection(_:)),
        #selector(moveParagraphBackwardAndModifySelection(_:)),
        #selector(moveParagraphForwardAndModifySelection(_:)):
        return model.selectedRange != nil
      default:
        return true
      }
    }
  }
#endif
