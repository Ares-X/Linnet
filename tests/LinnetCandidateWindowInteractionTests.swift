import AppKit
import Foundation

extension NSRange {
  static let empty = NSRange(location: NSNotFound, length: 0)
}

extension NSPoint {
  static func += (lhs: inout Self, rhs: Self) {
    lhs.x += rhs.x
    lhs.y += rhs.y
  }
  static func -= (lhs: inout Self, rhs: Self) {
    lhs.x -= rhs.x
    lhs.y -= rhs.y
  }
  static func - (lhs: Self, rhs: Self) -> Self {
    Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }
  static func * (lhs: Self, rhs: CGFloat) -> Self {
    Self(x: lhs.x * rhs, y: lhs.y * rhs)
  }
  static func / (lhs: Self, rhs: CGFloat) -> Self {
    Self(x: lhs.x / rhs, y: lhs.y / rhs)
  }
  var length: CGFloat { sqrt(x * x + y * y) }
}

// This harness compiles the real candidate view without linking librime. The
// theme and candidate data are narrow boundary fixtures; layout, tracking,
// mouse hit testing, and accessibility geometry remain production code.
final class SquirrelTheme {
  static let offsetHeight: CGFloat = 5
  static let showStatusDuration: Double = 1.2
  typealias SelectionStyle = LinnetCandidatePresentation.CandidateSelectionStyle
  enum StatusMessageType { case long, short, mix }

  var available = true
  var backgroundColor = NSColor.windowBackgroundColor
  var attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 16),
    .foregroundColor: NSColor.labelColor,
  ]
  var borderColor: NSColor? = .separatorColor
  var candidateBackColor: NSColor?
  var candidateExpansionAllowed = false
  var candidateFormat = "[label] [candidate]"
  var commentAttrs: [NSAttributedString.Key: Any] = [:]
  var commentHighlightedAttrs: [NSAttributedString.Key: Any] = [:]
  var detailAttrs: [NSAttributedString.Key: Any] = [:]
  var highlightedBackColor: NSColor? = .selectedContentBackgroundColor
  var highlightedPreeditColor: NSColor?
  var preeditBackgroundColor: NSColor?
  var borderLineWidth: CGFloat = 1
  var borderWidth: CGFloat = 1
  var cornerRadius: CGFloat = 10
  var edgeInset = LinnetCandidatePresentation.candidateWindowInset
  var firstParagraphStyle: NSParagraphStyle = NSMutableParagraphStyle()
  var font = NSFont.systemFont(ofSize: 16)
  var highlightedAttrs: [NSAttributedString.Key: Any] = [:]
  var hilitedCornerRadius: CGFloat = 6
  var linear = true
  var inlineCandidate = false
  var inlinePreedit = false
  var labelAttrs: [NSAttributedString.Key: Any] = [:]
  var labelHighlightedAttrs: [NSAttributedString.Key: Any] = [:]
  var linespace = LinnetCandidatePresentation.candidateRowSpacing
  var mutualExclusive = false
  var native = false
  var paragraphStyle: NSParagraphStyle = NSMutableParagraphStyle()
  var preeditAttrs: [NSAttributedString.Key: Any] = [:]
  var preeditHighlightedAttrs: [NSAttributedString.Key: Any] = [:]
  var preeditParagraphStyle: NSParagraphStyle = NSMutableParagraphStyle()
  var preeditLinespace = LinnetCandidatePresentation.preeditSpacing
  var selectionStyle = SelectionStyle.tile
  var shadowSize: CGFloat = 0
  var surroundingExtraExpansion: CGFloat = 0
  var statusAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: LinnetPanelGeometry.statusFontPoint, weight: .medium),
    .foregroundColor: NSColor.labelColor,
  ]
  var statusMessageType = StatusMessageType.mix
  var statusParagraphStyle: NSParagraphStyle = NSMutableParagraphStyle()
  var alpha: CGFloat = 1
  var memorizeSize = false
  var showPaging = false
  var translucency = false
  var vertical = false

  var materialAppearance = LinnetClientAppearance.MaterialMode.system
  var pagingOffset: CGFloat { 15 }

  func load(config: SquirrelConfig, dark: Bool) {}
}

final class SquirrelConfig {}

final class SquirrelInputController {
  struct CandidateItem {
    let text: String
    let comment: String
    let page: Int
    let indexOnPage: Int
    let absoluteIndex: Int
    let selectionLabel: String?
  }

  struct CandidateSnapshot {
    let items: [CandidateItem]
    let pageSize: Int
    let currentPage: Int
    let isLastPage: Bool
    let isExpanded: Bool
    let canExpand: Bool
  }

  private(set) var selectedCandidateIndices: [Int] = []
  private(set) var pageDirections: [Bool] = []
  private(set) var refreshCount = 0
  private let activationRegistry = LinnetInputActivationRegistry()
  private let activationClient = NSObject()
  private var activationToken: LinnetInputActivationRegistry.Token?

  init() {
    activationToken = beginActivation()
  }

  var activeInputToken: LinnetInputActivationRegistry.Token {
    guard let activationToken else {
      preconditionFailure("candidate harness controller has no active token")
    }
    return activationToken
  }

  @discardableResult
  func beginActivation() -> LinnetInputActivationRegistry.Token {
    guard let token = activationRegistry.begin(
      controller: self,
      client: activationClient,
      retire: { _ in }
    ) else {
      preconditionFailure("candidate harness activation was rejected")
    }
    activationToken = token
    return token
  }

  func inputActivationIsCurrent(
    _ token: LinnetInputActivationRegistry.Token
  ) -> Bool {
    activationRegistry.isCurrent(
      token,
      controller: self,
      client: activationClient)
  }

  func client() -> Any? { nil }
  func page(
    up: Bool,
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Bool {
    guard inputActivationIsCurrent(activationToken) else { return false }
    pageDirections.append(up)
    return true
  }
  func refreshCandidatePresentation(
    activationToken: LinnetInputActivationRegistry.Token
  ) {
    guard inputActivationIsCurrent(activationToken) else { return }
    refreshCount += 1
  }
  func selectCandidate(
    absoluteIndex: Int,
    activationToken: LinnetInputActivationRegistry.Token
  ) -> Bool {
    guard inputActivationIsCurrent(activationToken) else { return false }
    selectedCandidateIndices.append(absoluteIndex)
    return true
  }

  func resetSelectedCandidates() {
    selectedCandidateIndices.removeAll()
  }

  func resetPageDirections() {
    pageDirections.removeAll()
  }
}

@main
struct LinnetCandidateWindowInteractionTests {
  private static var failures: [String] = []

  static func main() {
    _ = NSApplication.shared
    testTrackingArea()
    testExactCandidatePathHitTesting()
    testSyntheticHoverLifecycle()
    testCandidateControlPointerFeedback()
    testCandidatePressPublicationIdentity()
    testAccessibilitySelectionKeepsElementIdentity()
    testStaleAccessibilityDoesNotRetainController()
    testAccessibilityRejectsInvalidGeometry()
    testSameControllerReactivationInvalidatesOldPublication()
    testInputControllerOwnerSwapInvalidatesCandidateInteraction()
    testPreciseWheelPagingSemantics()
    testCandidateScrollPublicationIdentity()
    testPreeditPressDoesNotInferEngineCaret()
    testInputModeStatusNotice()
    let naturalShotPath = CommandLine.arguments.firstIndex(of: "--natural-default-shot")
      .flatMap { index in
        CommandLine.arguments.indices.contains(index + 1)
          ? CommandLine.arguments[index + 1] : nil
      }
    let pagingShotPath = CommandLine.arguments.firstIndex(of: "--paging-middle-shot")
      .flatMap { index in
        CommandLine.arguments.indices.contains(index + 1)
          ? CommandLine.arguments[index + 1] : nil
      }
    testDefaultNineCandidateNaturalSize(
      outputPath: naturalShotPath,
      middlePageOutputPath: pagingShotPath)
    testEnglishMetadataFooterNaturalSize()
    testSharedCandidateDetailSidecarGeometry()
    testVerticalPanelDoesNotMemorizeWhenDisabled()
    for point in [CGFloat(12), 16, 32] {
      for linear in [true, false] {
        for style in [
          SquirrelTheme.SelectionStyle.tile,
          .underline,
          .bar,
        ] {
          testCandidateCellGeometry(fontPoint: point, linear: linear, style: style)
        }
      }
    }
    if let option = CommandLine.arguments.firstIndex(of: "--contact-sheet"),
      CommandLine.arguments.indices.contains(option + 2)
    {
      makeContactSheet(
        yamlPath: CommandLine.arguments[option + 1],
        outputPath: CommandLine.arguments[option + 2])
    }
    if let option = CommandLine.arguments.firstIndex(of: "--readme-theme-gallery"),
      CommandLine.arguments.indices.contains(option + 2)
    {
      makeReadmeThemeGallery(
        yamlPath: CommandLine.arguments[option + 1],
        outputPath: CommandLine.arguments[option + 2])
    }
    if let option = CommandLine.arguments.firstIndex(of: "--readme-product-gallery"),
      CommandLine.arguments.indices.contains(option + 3)
    {
      makeReadmeProductGallery(
        yamlPath: CommandLine.arguments[option + 1],
        inputModesOutputPath: CommandLine.arguments[option + 2],
        bilingualOutputPath: CommandLine.arguments[option + 3])
    }
    if let option = CommandLine.arguments.firstIndex(of: "--verify-readme-render"),
      CommandLine.arguments.indices.contains(option + 3)
    {
      verifyReadmeRender(
        committedPath: CommandLine.arguments[option + 1],
        generatedPath: CommandLine.arguments[option + 2],
        label: CommandLine.arguments[option + 3])
    }
    guard failures.isEmpty else {
      for failure in failures {
        FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
      }
      exit(EXIT_FAILURE)
    }
    print("LinnetCandidateWindowInteractionTests: PASS")
  }

  private static func testInputModeStatusNotice() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    panel.updateStatus(
      long: "Smart English", short: "En",
      activationToken: controller.activeInputToken)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: .init(
        items: [], pageSize: 0, currentPage: 0, isLastPage: true,
        isExpanded: false, canExpand: false),
      highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    let text = panel.contentView?.subviews.compactMap { $0 as? NSTextView }.first?
      .textContentStorage?.attributedString?.string
    require(panel.isVisible, "input-mode status was not presented beside the caret")
    require(
      text == "En",
      "input-mode status did not render the compact language label: \(text ?? "<missing>")")
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else {
      failures.append("input-mode status lost its production presentation surface")
      panel.hide()
      return
    }
    require(
      candidateView.accessibilityRole() == .group &&
        candidateView.accessibilityLabel() == "Input mode",
      "input-mode status was exposed as a candidate list"
    )
    let children = candidateView.accessibilityChildren() ?? []
    require(
      children.count == 1 &&
        (children[0] as? NSAccessibilityElement)?.accessibilityLabel() == "En",
      "input-mode status lost its accessible language announcement"
    )
    panel.hide()
  }

  private static func testVerticalPanelDoesNotMemorizeWhenDisabled() {
    guard let screen = NSScreen.main?.visibleFrame else { return }
    let caret = NSRect(
      x: screen.maxX - 2,
      y: screen.midY,
      width: 1,
      height: 18)
    let panel = SquirrelPanel(position: caret)
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else {
      failures.append("vertical resize fixture lost its candidate view")
      return
    }
    candidateView.lightTheme.vertical = true
    candidateView.lightTheme.linear = false
    candidateView.lightTheme.memorizeSize = false
    panel.updatePosition(caret)
    let longText = String(repeating: "候选词", count: 18)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidatePublication([(text: longText, absoluteIndex: 1)]),
      highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    let longHeight = panel.frame.height
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidatePublication([(text: "词", absoluteIndex: 2)]),
      highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    let shortHeight = panel.frame.height
    require(
      shortHeight + 1 < longHeight,
      "vertical candidates retained a prior long size with memorize-size disabled")
    require(
      panel.frame.width <= screen.width * 0.95 + 0.5 &&
        panel.frame.height <= screen.height * 0.95 + 0.5,
      "candidate frame plus paging strip exceeded the 95% screen cap")
    panel.hide()
  }

  private static func testTrackingArea() {
    let view = SquirrelView(frame: NSRect(x: 0, y: 0, width: 220, height: 60))
    view.updateTrackingAreas()
    let owned = view.trackingAreas.filter { $0.owner === view }
    require(owned.count == 1, "candidate view must own exactly one pointer tracking area")
    guard let options = owned.first?.options else { return }
    for option: NSTrackingArea.Options in [
      .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .activeAlways,
    ] {
      require(options.contains(option), "candidate tracking area lost option \(option.rawValue)")
    }
  }

  private static func testExactCandidatePathHitTesting() {
    let splitCandidate = CGMutablePath()
    splitCandidate.addRect(NSRect(x: 0, y: 0, width: 10, height: 10))
    splitCandidate.addRect(NSRect(x: 30, y: 0, width: 10, height: 10))
    let middleCandidate = CGPath(
      rect: NSRect(x: 15, y: 0, width: 10, height: 10),
      transform: nil)
    let paths: [CGPath?] = [splitCandidate, middleCandidate]

    require(
      SquirrelView.candidateIndex(
        at: NSPoint(x: 20, y: 5),
        paths: paths) == 1,
      "a split candidate's bounding box stole another candidate's hit")
    require(
      SquirrelView.candidateIndex(
        at: NSPoint(x: 12, y: 5),
        paths: paths) == nil,
      "empty space inside a multi-line bounding box selected a candidate")
  }

  private static func testSyntheticHoverLifecycle() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    let candidates = SquirrelInputController.CandidateSnapshot(
      items: [
        .init(text: "输入", comment: "", page: 0, indexOnPage: 0,
              absoluteIndex: 0, selectionLabel: "1"),
        .init(text: "输入法", comment: "", page: 0, indexOnPage: 1,
              absoluteIndex: 1, selectionLabel: "2"),
      ],
      pageSize: 2,
      currentPage: 0,
      isLastPage: true,
      isExpanded: false,
      canExpand: false)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else {
      failures.append("candidate panel did not retain its production SquirrelView")
      return
    }
    let frames = candidateView.candidateAccessibilityGeometry().candidateFrames
    guard frames.count == 2 else {
      failures.append("synthetic hover fixture did not publish two candidate cells")
      panel.hide()
      return
    }
    candidateView.updateTrackingAreas()
    guard candidateView.trackingAreas.contains(where: { $0.owner === candidateView }) else {
      failures.append("synthetic hover has no production tracking area")
      panel.hide()
      return
    }
    let secondPoint = candidateView.convert(frames[1].center, to: nil)
    if let entered = NSEvent.enterExitEvent(
      with: .mouseEntered,
      location: secondPoint,
      modifierFlags: [],
      timestamp: 1,
      windowNumber: panel.windowNumber,
      context: nil,
      eventNumber: 1,
      trackingNumber: 1,
      userData: nil)
    {
      panel.sendEvent(entered)
    }
    if let moved = NSEvent.mouseEvent(
      with: .mouseMoved,
      location: secondPoint,
      modifierFlags: [],
      timestamp: 2,
      windowNumber: panel.windowNumber,
      context: nil,
      eventNumber: 2,
      clickCount: 0,
      pressure: 0)
    {
      panel.sendEvent(moved)
    }
    requireEngineHighlight(
      0, in: candidateView,
      "mouse move replaced the Rime-owned visual or accessibility selection")
    require(
      candidateView.shape.candidateIndex == 1 &&
        !candidateView.shape.isPressed,
      "mouse move did not publish hover feedback for the second candidate")
    requirePointerFeedback(
      in: candidateView, candidateIndex: 1, expectedAlpha: 0.08,
      context: "second-candidate hover")
    if let exited = NSEvent.enterExitEvent(
      with: .mouseExited,
      location: secondPoint,
      modifierFlags: [],
      timestamp: 3,
      windowNumber: panel.windowNumber,
      context: nil,
      eventNumber: 3,
      trackingNumber: 1,
      userData: nil)
    {
      panel.sendEvent(exited)
    }
    requireEngineHighlight(
      0, in: candidateView,
      "mouse exit replaced the Rime-owned visual or accessibility selection")
    require(
      candidateView.shape.candidateIndex == nil &&
        !candidateView.shape.isPressed,
      "mouse exit did not clear candidate pointer feedback")
    requireNoPointerFeedback(in: candidateView, context: "mouse exit")
    panel.hide()
  }

  private static func testAccessibilitySelectionKeepsElementIdentity() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else {
      failures.append("accessibility identity fixture lost its candidate view")
      return
    }
    candidateView.lightTheme.highlightedAttrs = candidateView.lightTheme.attrs
    candidateView.lightTheme.labelHighlightedAttrs = candidateView.lightTheme.labelAttrs
    candidateView.lightTheme.commentHighlightedAttrs = candidateView.lightTheme.commentAttrs
    let candidates = candidatePublication([
      (text: "甲", absoluteIndex: 101),
      (text: "乙", absoluteIndex: 102),
    ])
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    guard let firstChildren = candidateView.accessibilityChildren(),
      firstChildren.count >= 2
    else {
      failures.append("accessibility identity fixture did not publish candidates")
      panel.hide()
      return
    }

    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 1, update: true,
      activationToken: controller.activeInputToken)
    let secondChildren = candidateView.accessibilityChildren() ?? []
    let selected = candidateView.accessibilitySelectedChildren() ?? []
    let firstElements = firstChildren.compactMap { $0 as? NSAccessibilityElement }
    let secondElements = secondChildren.compactMap { $0 as? NSAccessibilityElement }
    let selectedElements = selected.compactMap { $0 as? NSAccessibilityElement }
    require(
      firstElements.count >= 2 && secondElements.count >= 2 &&
        firstElements[0] === secondElements[0] &&
        firstElements[1] === secondElements[1],
      "a selection-only update replaced VoiceOver candidate identities")
    require(
      selectedElements.count == 1 && selectedElements[0] === secondElements[1],
      "a selection-only update did not publish the new VoiceOver selection")
    panel.hide()
  }

  private static func testStaleAccessibilityDoesNotRetainController() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    weak var releasedController: SquirrelInputController?
    var staleElement: LinnetCandidateAccessibilityElement?
    do {
      let controller = SquirrelInputController()
      releasedController = controller
      let token = controller.activeInputToken
      panel.bind(controller: controller, activationToken: token)
      _ = panel.update(
        preedit: "", selRange: .empty, caretPos: 0,
        candidates: candidatePublication([(text: "甲", absoluteIndex: 101)]),
        highlighted: 0, update: true,
        activationToken: token)
      let candidateView = panel.contentView?.subviews.compactMap({
        $0 as? SquirrelView
      }).first
      staleElement = candidateView?.accessibilityChildren()?.first
        as? LinnetCandidateAccessibilityElement
      panel.unbind(controller: controller, activationToken: token)
    }
    require(
      releasedController == nil,
      "a stale accessibility action retained its retired input controller")
    require(
      staleElement?.accessibilityPerformPress() == false,
      "a stale accessibility action remained authoritative after unbind")
  }

  private static func testAccessibilityRejectsInvalidGeometry() {
    let view = SquirrelView(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
    let accessibility = LinnetCandidateAccessibility()
    accessibility.install(parent: view, rawTextView: view.textView)
    accessibility.publish(
      parent: view,
      geometry: .init(
        candidateFrames: [],
        previousPageFrame: nil,
        nextPageFrame: nil),
      candidates: [
        .init(
          text: "甲", comment: "", page: 0, indexOnPage: 0,
          absoluteIndex: 101, selectionLabel: "1"),
      ],
      highlightedIndex: 0,
      controlMode: .paging(canPageUp: false, canPageDown: false),
      shouldAnnounce: false,
      selectCandidate: { _ in true },
      performControl: { _ in true })
    require(
      (view.accessibilityChildren() ?? []).isEmpty,
      "invalid candidate geometry was exposed as a whole-window AX button")

    let validCandidateFrame = NSRect(x: 4, y: 4, width: 40, height: 20)
    let validControlFrame = NSRect(x: 52, y: 4, width: 20, height: 20)
    let invalidControlCases: [(
      label: String,
      mode: LinnetCandidatePresentation.CandidateControlMode,
      previous: NSRect?,
      next: NSRect?,
      expectedActions: [LinnetCandidatePresentation.CandidateControlAction]
    )] = [
      (
        label: "empty previous-page frame",
        mode: .paging(canPageUp: true, canPageDown: true),
        previous: .zero,
        next: validControlFrame,
        expectedActions: [.pageDown]
      ),
      (
        label: "zero-width next-page frame",
        mode: .paging(canPageUp: true, canPageDown: true),
        previous: validControlFrame,
        next: NSRect(x: 76, y: 4, width: 0, height: 20),
        expectedActions: [.pageUp]
      ),
      (
        label: "non-finite expand frame",
        mode: .disclosure(expanded: false),
        previous: nil,
        next: NSRect(x: CGFloat.nan, y: 4, width: 20, height: 20),
        expectedActions: []
      ),
      (
        label: "non-finite collapse frame",
        mode: .disclosure(expanded: true),
        previous: NSRect(x: 52, y: 4, width: 20, height: CGFloat.infinity),
        next: nil,
        expectedActions: []
      ),
    ]
    for invalidCase in invalidControlCases {
      var performedActions: [LinnetCandidatePresentation.CandidateControlAction] = []
      accessibility.publish(
        parent: view,
        geometry: .init(
          candidateFrames: [validCandidateFrame],
          previousPageFrame: invalidCase.previous,
          nextPageFrame: invalidCase.next),
        candidates: [
          .init(
            text: "甲", comment: "", page: 0, indexOnPage: 0,
            absoluteIndex: 101, selectionLabel: "1"),
        ],
        highlightedIndex: 0,
        controlMode: invalidCase.mode,
        shouldAnnounce: false,
        selectCandidate: { _ in true },
        performControl: { action in
          performedActions.append(action)
          return true
        })
      let children = view.accessibilityChildren() ?? []
      for control in children.dropFirst() {
        _ = (control as? LinnetCandidateAccessibilityElement)?
          .accessibilityPerformPress()
      }
      require(
        children.count == invalidCase.expectedActions.count + 1 &&
          performedActions == invalidCase.expectedActions,
        "\(invalidCase.label) published an invalid AX control frame")
    }
  }

  private static func testPreciseWheelPagingSemantics() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    func sample(
      deltaY: CGFloat,
      phase: NSEvent.Phase = [],
      momentumPhase: NSEvent.Phase = [],
      at timestamp: Date
    ) -> LinnetCandidateInteractionState<Int>.ScrollSample {
      return .init(
        delta: CGVector(dx: 0, dy: deltaY),
        hasPreciseScrollingDeltas: true,
        phase: phase,
        momentumPhase: momentumPhase,
        timestamp: timestamp)
    }

    var accumulated = LinnetCandidateInteractionState<Int>()
    let firstHalf = accumulated.processScroll(
      sample(deltaY: 6, at: start), vertical: false)
    let secondHalf = accumulated.processScroll(
      sample(deltaY: 6, at: start.addingTimeInterval(0.1)),
      vertical: false)
    require(
      firstHalf == nil && secondHalf == .previousPage,
      "two precise 6-point wheel deltas did not page exactly once")

    var reversed = LinnetCandidateInteractionState<Int>()
    let forwardHalf = reversed.processScroll(
      sample(deltaY: 6, at: start), vertical: false)
    let firstReverseHalf = reversed.processScroll(
      sample(deltaY: -6, at: start.addingTimeInterval(0.1)),
      vertical: false)
    let secondReverseHalf = reversed.processScroll(
      sample(deltaY: -6, at: start.addingTimeInterval(0.2)),
      vertical: false)
    require(
      forwardHalf == nil && firstReverseHalf == nil &&
        secondReverseHalf == .nextPage,
      "a precise direction change discarded its first reverse delta")

    var momentum = LinnetCandidateInteractionState<Int>()
    _ = momentum.processScroll(
      sample(deltaY: 6, at: start), vertical: false)
    let momentumIntent = momentum.processScroll(
      sample(
        deltaY: 12,
        momentumPhase: .changed,
        at: start.addingTimeInterval(0.1)),
      vertical: false)
    let afterMomentum = momentum.processScroll(
      sample(deltaY: 6, at: start.addingTimeInterval(0.2)),
      vertical: false)
    require(
      momentumIntent == nil && afterMomentum == nil,
      "momentum paged or retained a precise wheel remainder")

    var cancelled = LinnetCandidateInteractionState<Int>()
    _ = cancelled.processScroll(
      sample(deltaY: 0, phase: .began, at: start), vertical: false)
    _ = cancelled.processScroll(
      sample(
        deltaY: 12,
        phase: .changed,
        at: start.addingTimeInterval(0.1)),
      vertical: false)
    let cancelledIntent = cancelled.processScroll(
      sample(
        deltaY: 0,
        phase: .cancelled,
        at: start.addingTimeInterval(0.2)),
      vertical: false)
    let staleEndIntent = cancelled.processScroll(
      sample(
        deltaY: 0,
        phase: .ended,
        at: start.addingTimeInterval(0.3)),
      vertical: false)
    require(
      cancelledIntent == nil && staleEndIntent == nil,
      "a cancelled precise gesture still paged")
  }

  private static func testCandidatePressPublicationIdentity() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    let firstPublication = candidatePublication([
      (text: "甲", absoluteIndex: 101),
      (text: "乙", absoluteIndex: 102),
    ])
    let secondPublication = candidatePublication([
      (text: "丙", absoluteIndex: 201),
      (text: "丁", absoluteIndex: 202),
    ])

    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first,
      candidateView.candidateAccessibilityGeometry().candidateFrames.count == 2
    else {
      failures.append("candidate press fixture did not publish two candidate cells")
      panel.hide()
      return
    }
    let candidateFrames = candidateView.candidateAccessibilityGeometry().candidateFrames
    let secondCandidatePoint = candidateView.convert(candidateFrames[1].center, to: nil)
    let outsidePoint = candidateView.convert(
      NSPoint(x: candidateView.bounds.minX - 10, y: candidateView.bounds.minY - 10),
      to: nil)

    sendCandidateMouse(.mouseMoved, at: secondCandidatePoint, to: panel, eventNumber: 20)
    requireEngineHighlight(
      0, in: candidateView,
      "mouse move changed the engine-selected first candidate")
    require(
      candidateView.shape.candidateIndex == 1 &&
        !candidateView.shape.isPressed,
      "hovering the second candidate did not change the visual pointer index")
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    require(
      candidateView.shape.candidateIndex == nil &&
        !candidateView.shape.isPressed,
      "a replacement publication retained stale hover feedback")
    sendCandidateMouse(.leftMouseDown, at: secondCandidatePoint, to: panel, eventNumber: 21)
    requireEngineHighlight(
      0, in: candidateView,
      "mouse press changed the engine-selected first candidate")
    require(
      candidateView.shape.candidateIndex == 1 &&
        candidateView.shape.isPressed,
      "mouse-down did not immediately publish pressed feedback")
    requirePointerFeedback(
      in: candidateView, candidateIndex: 1, expectedAlpha: 0.16,
      context: "second-candidate press")
    sendCandidateMouse(.leftMouseUp, at: secondCandidatePoint, to: panel, eventNumber: 22)
    require(
      controller.selectedCandidateIndices == [102],
      "clicking the second candidate did not commit that candidate exactly once")
    requireEngineHighlight(
      0, in: candidateView,
      "committing a clicked candidate replaced the engine-owned selection")
    require(
      candidateView.shape.candidateIndex == 1 &&
        !candidateView.shape.isPressed,
      "mouse-up did not return pressed feedback to hover feedback")

    controller.resetSelectedCandidates()
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    sendCandidateMouse(.leftMouseDown, at: secondCandidatePoint, to: panel, eventNumber: 23)
    sendCandidateMouse(.mouseExited, at: outsidePoint, to: panel, eventNumber: 24)
    sendCandidateMouse(.leftMouseUp, at: outsidePoint, to: panel, eventNumber: 25)
    require(
      controller.selectedCandidateIndices.isEmpty,
      "dragging out of the second candidate committed it")
    requireEngineHighlight(
      0, in: candidateView,
      "dragging out of a candidate replaced the engine-owned selection")

    controller.resetSelectedCandidates()
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    sendCandidateMouse(.leftMouseDown, at: secondCandidatePoint, to: panel, eventNumber: 26)
    sendCandidateMouse(.mouseExited, at: outsidePoint, to: panel, eventNumber: 27)
    sendCandidateMouse(.leftMouseDragged, at: secondCandidatePoint, to: panel, eventNumber: 28)
    require(
      candidateView.shape.candidateIndex == 1 &&
        candidateView.shape.isPressed,
      "dragging back to the pressed candidate did not restore pressed feedback")
    sendCandidateMouse(.leftMouseUp, at: secondCandidatePoint, to: panel, eventNumber: 29)
    require(
      controller.selectedCandidateIndices == [102],
      "dragging away and back did not preserve the original click target")

    controller.resetSelectedCandidates()
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    sendCandidateMouse(.leftMouseDown, at: secondCandidatePoint, to: panel, eventNumber: 30)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: secondPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    require(
      candidateView.shape.candidateIndex == nil &&
        !candidateView.shape.isPressed,
      "a new publication retained the previous candidate's pressed feedback")
    requireNoPointerFeedback(in: candidateView, context: "new publication")
    sendCandidateMouse(.leftMouseUp, at: secondCandidatePoint, to: panel, eventNumber: 31)
    require(
      controller.selectedCandidateIndices.isEmpty,
      "a candidate press crossed publications and committed replacement candidate 202")
    requireEngineHighlight(
      0, in: candidateView,
      "a replacement publication did not restore its engine-owned selection")

    controller.resetSelectedCandidates()
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    sendCandidateMouse(.leftMouseDown, at: secondCandidatePoint, to: panel, eventNumber: 32)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: false,
      activationToken: controller.activeInputToken)
    sendCandidateMouse(.leftMouseUp, at: secondCandidatePoint, to: panel, eventNumber: 33)
    require(
      controller.selectedCandidateIndices == [102],
      "a hover-only redraw cancelled a press within the same publication")
    requireEngineHighlight(
      0, in: candidateView,
      "a hover-only redraw replaced the engine-owned selection")
    sendCandidateMouse(.mouseMoved, at: secondCandidatePoint, to: panel, eventNumber: 34)
    panel.hide()
    require(
      candidateView.shape.candidateIndex == nil &&
        !candidateView.shape.isPressed,
      "hiding the panel retained candidate pointer feedback")
    requireNoPointerFeedback(in: candidateView, context: "panel hide")
  }

  private static func testCandidateControlPointerFeedback() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else {
      failures.append("candidate control feedback fixture lost its view")
      return
    }
    candidateView.lightTheme.showPaging = true
    let candidates = SquirrelInputController.CandidateSnapshot(
      items: candidatePublication([
        (text: "甲", absoluteIndex: 101),
        (text: "乙", absoluteIndex: 102),
      ]).items,
      pageSize: 2,
      currentPage: 1,
      isLastPage: false,
      isExpanded: false,
      canExpand: false)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    guard let nextPage = candidateView.pagingLayout.nextPage else {
      failures.append("candidate control feedback fixture lost next-page geometry")
      panel.hide()
      return
    }
    let point = candidateView.convert(nextPage.visualCenter, to: nil)
    sendCandidateMouse(.mouseMoved, at: point, to: panel, eventNumber: 60)
    require(
      candidateView.pointerControlAction == .pageDown &&
        !candidateView.pointerControlIsPressed,
      "paging hover did not publish control feedback")
    requireControlFeedback(
      in: candidateView,
      expectedAlpha: 0.08,
      context: "next-page hover")
    sendCandidateMouse(.leftMouseDown, at: point, to: panel, eventNumber: 61)
    require(
      candidateView.pointerControlAction == .pageDown &&
        candidateView.pointerControlIsPressed,
      "paging press did not publish pressed feedback")
    requireControlFeedback(
      in: candidateView,
      expectedAlpha: 0.16,
      context: "next-page press")
    sendCandidateMouse(.mouseExited, at: point, to: panel, eventNumber: 62)
    require(
      candidateView.pointerControlAction == nil &&
        !candidateView.pointerControlIsPressed,
      "paging pointer exit retained control feedback")
    panel.hide()
  }

  private static func testPreeditPressDoesNotInferEngineCaret() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    let candidates = candidatePublication([(text: "测试", absoluteIndex: 0)])
    _ = panel.update(
      preedit: "ceshi", selRange: NSRange(location: 0, length: 5), caretPos: 5,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first,
      let preeditTextRange = candidateView.convert(range: NSRange(location: 0, length: 1))
    else {
      failures.append("preedit press fixture did not publish text geometry")
      panel.hide()
      return
    }
    candidateView.layoutSubtreeIfNeeded()
    var preeditPoint = candidateView.contentRect(range: preeditTextRange).center
    preeditPoint.x += candidateView.textView.frame.minX
      + candidateView.textView.textContainerInset.width
    preeditPoint.y += candidateView.textView.frame.minY
      + candidateView.textView.textContainerInset.height
    let windowPreeditPoint = candidateView.convert(preeditPoint, to: nil)
    let candidateFrame = candidateView.candidateAccessibilityGeometry().candidateFrames.first
    guard let candidateFrame else {
      failures.append("preedit press fixture did not publish candidate geometry")
      panel.hide()
      return
    }
    let windowCandidatePoint = candidateView.convert(candidateFrame.center, to: nil)

    sendCandidateMouse(.leftMouseDown, at: windowCandidatePoint, to: panel, eventNumber: 30)
    sendCandidateMouse(.leftMouseUp, at: windowPreeditPoint, to: panel, eventNumber: 31)
    require(
      controller.selectedCandidateIndices.isEmpty &&
        controller.pageDirections.isEmpty,
      "dragging from a candidate onto preedit text mutated the engine")

    sendCandidateMouse(.leftMouseDown, at: windowPreeditPoint, to: panel, eventNumber: 32)
    sendCandidateMouse(.leftMouseUp, at: windowPreeditPoint, to: panel, eventNumber: 33)
    require(
      controller.selectedCandidateIndices.isEmpty &&
        controller.pageDirections.isEmpty,
      "displayed preedit coordinates were incorrectly applied to raw Rime input")
    panel.hide()
  }

  private static func testSameControllerReactivationInvalidatesOldPublication() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    let firstToken = controller.activeInputToken
    panel.bind(controller: controller, activationToken: firstToken)
    let candidates = candidatePublication([
      (text: "甲", absoluteIndex: 101),
      (text: "乙", absoluteIndex: 102),
    ])
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: firstToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first,
      let staleAccessibilityAction = candidateView.accessibilityChildren()?.first
        as? LinnetCandidateAccessibilityElement,
      candidateView.candidateAccessibilityGeometry().candidateFrames.count == 2
    else {
      failures.append("same-controller reactivation fixture did not publish actions")
      panel.hide()
      return
    }
    let secondPoint = candidateView.convert(
      candidateView.candidateAccessibilityGeometry().candidateFrames[1].center,
      to: nil)
    sendCandidateMouse(.leftMouseDown, at: secondPoint, to: panel, eventNumber: 34)

    let replacementToken = controller.beginActivation()
    require(
      replacementToken != firstToken && !controller.inputActivationIsCurrent(firstToken),
      "same-controller reactivation did not retire the previous token")
    require(
      !staleAccessibilityAction.accessibilityPerformPress(),
      "an accessibility action crossed same-controller activation generations")
    sendCandidateMouse(.leftMouseUp, at: secondPoint, to: panel, eventNumber: 35)
    require(
      controller.selectedCandidateIndices.isEmpty,
      "a mouse press crossed same-controller activation generations")

    panel.bind(controller: controller, activationToken: replacementToken)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: replacementToken)
    guard let currentAccessibilityAction = candidateView.accessibilityChildren()?.first
      as? LinnetCandidateAccessibilityElement
    else {
      failures.append("replacement activation did not publish accessibility actions")
      panel.hide()
      return
    }
    require(
      currentAccessibilityAction.accessibilityPerformPress() &&
        controller.selectedCandidateIndices == [101],
      "the replacement activation did not accept its own exact action")
    panel.hide()
  }

  private static func testInputControllerOwnerSwapInvalidatesCandidateInteraction() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let oldController = SquirrelInputController()
    let newController = SquirrelInputController()
    let finalController = SquirrelInputController()
    let candidates = candidatePublication([
      (text: "甲", absoluteIndex: 101),
      (text: "乙", absoluteIndex: 102),
    ])
    panel.bind(controller: oldController, activationToken: oldController.activeInputToken)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: oldController.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first,
      candidateView.candidateAccessibilityGeometry().candidateFrames.count == 2
    else {
      failures.append("controller-swap fixture did not publish candidate geometry")
      panel.hide()
      return
    }
    let secondPoint = candidateView.convert(
      candidateView.candidateAccessibilityGeometry().candidateFrames[1].center,
      to: nil)
    guard let staleAccessibilityAction = candidateView.accessibilityChildren()?.first
      as? LinnetCandidateAccessibilityElement
    else {
      failures.append("controller-swap fixture did not publish accessibility actions")
      panel.hide()
      return
    }
    sendCandidateMouse(.leftMouseDown, at: secondPoint, to: panel, eventNumber: 35)
    panel.bind(controller: newController, activationToken: newController.activeInputToken)
    require(!panel.isVisible, "controller swap retained the previous candidate panel")
    require(
      candidateView.shape.candidateIndex == nil &&
        !candidateView.shape.isPressed,
      "controller swap retained the previous pointer interaction")
    require(
      candidateView.accessibilityChildren()?.isEmpty == true,
      "controller swap retained the previous accessibility candidates")
    sendCandidateMouse(.leftMouseUp, at: secondPoint, to: panel, eventNumber: 36)
    require(
      !staleAccessibilityAction.accessibilityPerformPress() &&
        oldController.selectedCandidateIndices.isEmpty &&
        newController.selectedCandidateIndices.isEmpty,
      "an old mouse or accessibility action crossed controller ownership")

    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: newController.activeInputToken)
    sendCandidateScroll(deltaY: 6, phase: 0, to: panel)
    panel.bind(controller: finalController, activationToken: finalController.activeInputToken)
    sendCandidateScroll(deltaY: 6, phase: 0, to: panel)
    require(
      finalController.pageDirections.isEmpty,
      "a wheel remainder crossed input-controller ownership")
    panel.hide()
  }

  private static func testCandidateScrollPublicationIdentity() {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    let firstPublication = candidatePublication([
      (text: "甲", absoluteIndex: 101),
      (text: "乙", absoluteIndex: 102),
    ])
    let secondPublication = candidatePublication([
      (text: "丙", absoluteIndex: 201),
      (text: "丁", absoluteIndex: 202),
    ])
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first,
      candidateView.candidateAccessibilityGeometry().candidateFrames.count == 2
    else {
      failures.append("candidate scroll fixture did not publish two candidate cells")
      panel.hide()
      return
    }
    let secondPoint = candidateView.convert(
      candidateView.candidateAccessibilityGeometry().candidateFrames[1].center,
      to: nil)

    sendCandidateMouse(.leftMouseDown, at: secondPoint, to: panel, eventNumber: 40)
    sendCandidateScroll(deltaY: 2, phase: 0, to: panel)
    sendCandidateMouse(.leftMouseUp, at: secondPoint, to: panel, eventNumber: 41)
    require(
      controller.selectedCandidateIndices.isEmpty,
      "a candidate press survived an intervening scroll gesture")

    controller.resetPageDirections()
    sendCandidateScroll(deltaY: 0, phase: 1, to: panel)
    sendCandidateScroll(deltaY: 8, phase: 2, to: panel)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: secondPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    sendCandidateScroll(deltaY: 8, phase: 2, to: panel)
    sendCandidateScroll(deltaY: 0, phase: 4, to: panel)
    require(
      controller.pageDirections.isEmpty,
      "a phased scroll gesture crossed candidate publications")

    sendCandidateScroll(deltaY: 0, phase: 1, to: panel)
    sendCandidateScroll(deltaY: 12, phase: 2, to: panel)
    sendCandidateScroll(deltaY: 0, phase: 4, to: panel)
    require(
      controller.pageDirections == [true],
      "a same-publication trackpad gesture did not page exactly once")

    controller.resetPageDirections()
    sendCandidateScroll(deltaY: 1, phase: 0, units: .line, to: panel)
    sendCandidateScroll(deltaY: -1, phase: 0, units: .line, to: panel)
    require(
      controller.pageDirections == [true, false],
      "ordinary wheel ticks did not page once in each direction")

    controller.resetPageDirections()
    sendCandidateScroll(deltaY: 6, phase: 0, to: panel)
    panel.hide()
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: firstPublication, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    sendCandidateScroll(deltaY: 6, phase: 0, to: panel)
    require(
      controller.pageDirections.isEmpty,
      "a mouse-wheel remainder survived hide and a new publication")
    panel.hide()
  }

  private static func candidatePublication(
    _ candidates: [(text: String, absoluteIndex: Int)]
  ) -> SquirrelInputController.CandidateSnapshot {
    .init(
      items: candidates.enumerated().map { index, candidate in
        .init(
          text: candidate.text, comment: "", page: 0, indexOnPage: index,
          absoluteIndex: candidate.absoluteIndex, selectionLabel: String(index + 1))
      },
      pageSize: candidates.count,
      currentPage: 0,
      isLastPage: true,
      isExpanded: false,
      canExpand: false)
  }

  private static func sendCandidateMouse(
    _ type: NSEvent.EventType,
    at point: NSPoint,
    to panel: SquirrelPanel,
    eventNumber: Int
  ) {
    let event: NSEvent?
    if type == .mouseEntered || type == .mouseExited {
      event = NSEvent.enterExitEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: TimeInterval(eventNumber),
        windowNumber: panel.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        trackingNumber: 1,
        userData: nil)
    } else {
      event = NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: TimeInterval(eventNumber),
        windowNumber: panel.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: type == .leftMouseDown ? 1 : 0)
    }
    guard let event
    else {
      failures.append("candidate press fixture could not create mouse event \(eventNumber)")
      return
    }
    panel.sendEvent(event)
  }

  private static func sendCandidateScroll(
    deltaY: Int32,
    phase: Int64,
    units: CGScrollEventUnit = .pixel,
    to panel: SquirrelPanel
  ) {
    guard let cgEvent = CGEvent(
      scrollWheelEvent2Source: nil,
      units: units,
      wheelCount: 2,
      wheel1: deltaY,
      wheel2: 0,
      wheel3: 0)
    else {
      failures.append("candidate scroll fixture could not create a CGEvent")
      return
    }
    cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    guard let event = NSEvent(cgEvent: cgEvent) else {
      failures.append("candidate scroll fixture could not bridge an NSEvent")
      return
    }
    panel.sendEvent(event)
  }

  private static func requireEngineHighlight(
    _ expectedIndex: Int,
    in candidateView: SquirrelView,
    _ context: String
  ) {
    let candidateElements = (candidateView.accessibilityChildren() ?? []).compactMap {
      $0 as? NSAccessibilityElement
    }
    let selectedElements = (candidateView.accessibilitySelectedChildren() ?? []).compactMap {
      $0 as? NSAccessibilityElement
    }
    require(
      candidateView.hilightedIndex == expectedIndex,
      "\(context): visual index was \(candidateView.hilightedIndex)")
    require(
      candidateElements.indices.contains(expectedIndex) &&
        selectedElements.count == 1 &&
        selectedElements[0] === candidateElements[expectedIndex],
      "\(context): accessibility selection diverged from candidate \(expectedIndex)")
  }

  private static func requirePointerFeedback(
    in candidateView: SquirrelView,
    candidateIndex: Int,
    expectedAlpha: CGFloat,
    context: String
  ) {
    guard candidateView.candidateInteractionFrames.indices.contains(candidateIndex),
      let panelLayer = candidateView.layer?.sublayers?.first as? CAShapeLayer,
      let feedbackLayer = panelLayer.sublayers?.first(where: {
        $0.name == LinnetCandidatePointerPresentation.feedbackLayerName
      }) as? CAShapeLayer,
      let path = feedbackLayer.path,
      let alpha = feedbackLayer.fillColor?.alpha
    else {
      failures.append("\(context) did not render its visual feedback layer")
      return
    }
    var transform = panelLayer.affineTransform()
    let visualFrame = path.copy(using: &transform)?.boundingBox ?? .zero
    require(
      approximatelyEqual(
        visualFrame,
        candidateView.candidateInteractionFrames[candidateIndex],
        tolerance: 0.5),
      "\(context) feedback did not cover candidate \(candidateIndex)")
    require(
      abs(alpha - expectedAlpha) < 0.001,
      "\(context) feedback alpha was \(alpha), expected \(expectedAlpha)")
  }

  private static func requireControlFeedback(
    in candidateView: SquirrelView,
    expectedAlpha: CGFloat,
    context: String
  ) {
    guard let feedbackLayer = candidateView.layer?.sublayers?.first(where: {
      $0.name == SquirrelView.controlPointerFeedbackLayerName
    }) as? CAShapeLayer,
      let alpha = feedbackLayer.fillColor?.alpha
    else {
      failures.append("\(context): missing control feedback layer")
      return
    }
    require(
      abs(alpha - expectedAlpha) <= 0.01,
      "\(context): control feedback alpha was \(alpha)")
  }

  private static func requireNoPointerFeedback(
    in candidateView: SquirrelView,
    context: String
  ) {
    let feedbackLayer = (candidateView.layer?.sublayers?.first as? CAShapeLayer)?
      .sublayers?.first(where: {
        $0.name == LinnetCandidatePointerPresentation.feedbackLayerName
      })
    require(feedbackLayer == nil, "\(context) retained a visual feedback layer")
  }

  private static func testDefaultNineCandidateNaturalSize(
    outputPath: String?,
    middlePageOutputPath: String?
  ) {
    guard let yaml = try? String(contentsOfFile: "data/squirrel.yaml", encoding: .utf8),
      let sample = parseThemeSamples(yaml)["linnet_paper_light"]
    else {
      failures.append("default natural-size fixture could not resolve Paper Light")
      return
    }

    let panel = SquirrelPanel(position: NSRect(x: 320, y: 420, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else {
      failures.append("default natural-size fixture could not locate SquirrelView")
      return
    }

    let theme = candidateView.lightTheme
    let candidateFont = LinnetCandidatePresentation.platformFont(fontNames: [], size: 16)
    let labelFont = LinnetCandidatePresentation.platformFont(
      fontNames: [], size: 10, fallback: candidateFont)
    let labelBaseline = (candidateFont.pointSize - labelFont.pointSize) / 2.5
    theme.font = candidateFont
    theme.backgroundColor = sample.background
    theme.borderColor = sample.border
    theme.highlightedBackColor = sample.selectedBackground
    theme.cornerRadius = sample.cornerRadius
    theme.hilitedCornerRadius = sample.highlightedCornerRadius
    theme.selectionStyle = sample.selectionStyle
    theme.linear = true
    theme.candidateExpansionAllowed = true
    theme.showPaging = true
    theme.linespace = LinnetCandidatePresentation.candidateRowSpacing
    theme.candidateFormat = "[label] [candidate]"
    theme.attrs = [.font: candidateFont, .foregroundColor: sample.primary]
    theme.highlightedAttrs = [.font: candidateFont, .foregroundColor: sample.selectedPrimary]
    theme.labelAttrs = [
      .font: labelFont,
      .foregroundColor: sample.label,
      .baselineOffset: labelBaseline,
    ]
    theme.labelHighlightedAttrs = [
      .font: labelFont,
      .foregroundColor: sample.selectedLabel,
      .baselineOffset: labelBaseline,
    ]
    let firstParagraph = NSMutableParagraphStyle()
    firstParagraph.paragraphSpacing = theme.linespace / 2
    firstParagraph.paragraphSpacingBefore =
      LinnetCandidatePresentation.preeditSpacing / 2 + theme.linespace / 2
    theme.firstParagraphStyle = firstParagraph
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = theme.linespace / 2
    paragraph.paragraphSpacingBefore = theme.linespace / 2
    theme.paragraphStyle = paragraph

    let values = ["截图", "解", "接", "结", "姐", "节", "界", "届", "洁"]
    let candidates = SquirrelInputController.CandidateSnapshot(
      items: values.enumerated().map { index, value in
        .init(
          text: value, comment: "", page: 0, indexOnPage: index,
          absoluteIndex: index, selectionLabel: String(index + 1))
      },
      pageSize: values.count,
      currentPage: 0,
      isLastPage: true,
      isExpanded: false,
      canExpand: true)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    render(candidateView)

    let contentRect = candidateView.contentRect
    let inset = LinnetCandidatePresentation.candidateWindowInset
    let paging = candidateView.pagingLayout
    let expectedSize = NSSize(
      width: contentRect.width + inset.width * 2 + paging.stripFrame.width,
      height: contentRect.height + inset.height * 2)
    let actualSize = panel.frame.size
    require(
      abs(actualSize.width - ceil(expectedSize.width)) <= 0.5,
      "default 16pt nine-candidate panel width \(actualSize.width) is not natural content width \(expectedSize.width)")
    require(
      abs(actualSize.height - ceil(expectedSize.height)) <= 0.5,
      "default 16pt nine-candidate panel height \(actualSize.height) is not compact content height \(expectedSize.height)")
    require(
      candidateView.textView.frame.width + 0.5 >= contentRect.width + inset.width * 2,
      "default 16pt nine-candidate text view clipped its natural content width")
    require(
      paging.previousPage == nil && paging.nextPage != nil,
      "default collapsed candidate row lost its single disclosure control")
    require(
      abs(paging.stripFrame.maxX - candidateView.bounds.maxX) <= 0.5,
      "default collapsed disclosure strip left the horizontal trailing edge")
    if let disclosure = paging.nextPage {
      require(
        candidateView.click(at: disclosure.visualCenter) == .control(.expand),
        "default collapsed disclosure control lost its expand hit target")
    }
    let stripBackgroundPoint = NSPoint(
      x: paging.stripFrame.midX,
      y: paging.stripFrame.minY + min(3, paging.stripFrame.height / 4))
    require(
      candidateView.shape.path?.contains(stripBackgroundPoint) == true,
      "default collapsed disclosure strip was left outside the panel background")
    let disclosureGlyph = candidateView.layer?.sublayers?.last?.sublayers?.first
      as? CAShapeLayer
    require(
      disclosureGlyph?.fillColor != theme.backgroundColor.cgColor,
      "default collapsed disclosure glyph disappeared into the panel background")

    let frames = candidateView.candidateAccessibilityGeometry().candidateFrames
    require(frames.count == values.count, "default 16pt row did not expose all nine candidate cells")
    if let last = frames.last {
      require(
        last.maxX <= candidateView.bounds.maxX + 0.5,
        "default 16pt ninth candidate was clipped at the trailing edge")
      require(
        candidateView.click(at: NSPoint(x: last.midX, y: last.midY)) == .candidate(8),
        "default 16pt ninth candidate lost its natural-width hit target")
    }

    if let outputPath {
      writeSnapshot(of: panel.contentView, outputPath: outputPath)
    }

    let middlePage = SquirrelInputController.CandidateSnapshot(
      items: values.enumerated().map { index, value in
        .init(
          text: value, comment: "", page: 1, indexOnPage: index,
          absoluteIndex: values.count + index, selectionLabel: String(index + 1))
      },
      pageSize: values.count,
      currentPage: 1,
      isLastPage: false,
      isExpanded: false,
      canExpand: false)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: middlePage, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    render(candidateView)

    let middlePaging = candidateView.pagingLayout
    let middleContentRect = candidateView.contentRect
    let middleNaturalHeight = ceil(middleContentRect.height + inset.height * 2)
    require(
      middlePaging.previousPage != nil && middlePaging.nextPage != nil,
      "middle-page fixture did not expose both paging controls")
    require(
      abs(panel.frame.height - middleNaturalHeight) <= 0.5,
      "switching to a middle page inflated the horizontal panel from natural height "
        + "\(middleNaturalHeight) to \(panel.frame.height)")
    if let middlePageOutputPath {
      writeSnapshot(of: panel.contentView, outputPath: middlePageOutputPath)
    }

    let lastPage = SquirrelInputController.CandidateSnapshot(
      items: values.prefix(3).enumerated().map { index, value in
        .init(
          text: value, comment: "", page: 2, indexOnPage: index,
          absoluteIndex: values.count * 2 + index, selectionLabel: String(index + 1))
      },
      pageSize: values.count,
      currentPage: 2,
      isLastPage: true,
      isExpanded: false,
      canExpand: false)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: lastPage, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    render(candidateView)
    let lastPaging = candidateView.pagingLayout
    let lastNaturalHeight = ceil(candidateView.contentRect.height + inset.height * 2)
    require(
      lastPaging.previousPage != nil && lastPaging.nextPage == nil,
      "last-page fixture did not retain only the previous-page control")
    require(
      abs(panel.frame.height - lastNaturalHeight) <= 0.5,
      "a partial last page retained stale paging height")
    require(
      candidateView.candidateAccessibilityGeometry().candidateFrames.count == 3,
      "a partial last page retained stale candidate geometry")

    let expandedValues = values + values + values.prefix(3)
    let expanded = SquirrelInputController.CandidateSnapshot(
      items: expandedValues.enumerated().map { index, value in
        .init(
          text: value, comment: "", page: index / values.count,
          indexOnPage: index % values.count, absoluteIndex: index,
          selectionLabel: String(index % values.count + 1))
      },
      pageSize: values.count,
      currentPage: 0,
      isLastPage: false,
      isExpanded: true,
      canExpand: true)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: expanded, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    render(candidateView)
    let expandedNaturalHeight = ceil(candidateView.contentRect.height + inset.height * 2)
    require(
      abs(panel.frame.height - expandedNaturalHeight) <= 0.5,
      "expanded candidates retained height beyond their three visible rows")
    require(
      candidateView.candidateAccessibilityGeometry().candidateFrames.count == 21,
      "expanded candidates lost or invented interaction geometry")

    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    render(candidateView)
    require(
      abs(panel.frame.height - actualSize.height) <= 0.5,
      "collapsing candidates did not restore the original natural height")
    print(
      "Default 16pt nine-candidate natural panel: "
        + "\(actualSize.width)×\(actualSize.height), content "
        + "\(contentRect.width)×\(contentRect.height)")
    panel.hide()
  }

  private static func testEnglishMetadataFooterNaturalSize() {
    for point in [CGFloat(12), 15, 16, 32] {
      testEnglishMetadataFooterNaturalSize(candidatePoint: point)
    }
  }

  private static func testEnglishMetadataFooterNaturalSize(candidatePoint: CGFloat) {
    let panel = SquirrelPanel(position: NSRect(x: 360, y: 460, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else {
      failures.append("English metadata fixture could not locate SquirrelView")
      return
    }

    let theme = candidateView.lightTheme
    let labelPoint = max(10, candidatePoint - 6)
    let detailPoint = max(10, candidatePoint - 4)
    let candidateFont = LinnetCandidatePresentation.platformFont(
      fontNames: [], size: candidatePoint)
    let labelFont = LinnetCandidatePresentation.platformFont(
      fontNames: [], size: labelPoint, fallback: candidateFont)
    let commentFont = LinnetCandidatePresentation.platformFont(
      fontNames: [], size: detailPoint, fallback: candidateFont)
    let labelBaseline = LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: candidateFont,
      secondaryFont: labelFont,
      baseOffset: 0,
      verticalText: false,
      placement: .inline)
    let inlineCommentBaseline = LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: candidateFont,
      secondaryFont: commentFont,
      baseOffset: 0,
      verticalText: false,
      placement: .inline)
    let detailBaseline = LinnetCandidatePresentation.secondaryBaselineOffset(
      primaryFont: candidateFont,
      secondaryFont: commentFont,
      baseOffset: 0,
      verticalText: false,
      placement: .standaloneDetail)
    theme.font = candidateFont
    theme.linear = true
    theme.candidateExpansionAllowed = false
    theme.showPaging = false
    theme.linespace = LinnetCandidatePresentation.candidateRowSpacing
    theme.candidateFormat = "[label] [candidate]"
    theme.attrs = [.font: candidateFont, .foregroundColor: NSColor.labelColor]
    theme.highlightedAttrs = [.font: candidateFont, .foregroundColor: NSColor.labelColor]
    theme.labelAttrs = [
      .font: labelFont,
      .foregroundColor: NSColor.secondaryLabelColor,
      .baselineOffset: labelBaseline,
    ]
    theme.labelHighlightedAttrs = theme.labelAttrs
    theme.commentAttrs = [
      .font: commentFont,
      .foregroundColor: NSColor.secondaryLabelColor,
      .baselineOffset: inlineCommentBaseline,
    ]
    theme.commentHighlightedAttrs = theme.commentAttrs
    theme.detailAttrs = [
      .font: commentFont,
      .foregroundColor: NSColor.secondaryLabelColor,
      .baselineOffset: detailBaseline,
    ]
    let firstParagraph = NSMutableParagraphStyle()
    firstParagraph.paragraphSpacing = theme.linespace / 2
    firstParagraph.paragraphSpacingBefore =
      LinnetCandidatePresentation.preeditSpacing / 2 + theme.linespace / 2
    theme.firstParagraphStyle = firstParagraph
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = theme.linespace / 2
    paragraph.paragraphSpacingBefore = theme.linespace / 2
    theme.paragraphStyle = paragraph

    let values = ["f", "fa", "for", "fi", "ff", "fe", "fc", "fg", "fast"]
    let detailText = "/ef/ · n. 字母 F"
    let candidates = SquirrelInputController.CandidateSnapshot(
      items: values.enumerated().map { index, value in
        .init(
          text: value, comment: index == 0 ? detailText : "",
          page: 0, indexOnPage: index, absoluteIndex: index,
          selectionLabel: String(index + 1))
      },
      pageSize: values.count,
      currentPage: 0,
      isLastPage: true,
      isExpanded: false,
      canExpand: false)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: candidates, highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    render(candidateView)

    let detailRange = candidateView.detailRange
    let attributed = candidateView.textView.textContentStorage?.attributedString
    require(detailRange.length == detailText.utf16.count,
            "\(candidatePoint)pt English footer did not publish one literal detail range")
    if let attributed, detailRange.location != NSNotFound, detailRange.length > 0 {
      require(
        attributed.attributedSubstring(from: detailRange).string == detailText,
        "\(candidatePoint)pt English footer split or rewrote the runtime comment")
      require(
        (attributed.attribute(.font, at: detailRange.location, effectiveRange: nil)
          as? NSFont)?.pointSize == detailPoint,
        "\(candidatePoint)pt English footer did not use the configured detail font")
      require(
        abs(((attributed.attribute(
          .baselineOffset, at: detailRange.location, effectiveRange: nil)
          as? NSNumber)?.doubleValue ?? .nan) - Double(detailBaseline)) < 0.0001,
        "\(candidatePoint)pt English footer inherited the inline comment baseline")
    }
    if let textRange = candidateView.convert(range: detailRange) {
      let detailRect = candidateView.contentRect(range: textRange)
      require(!detailRect.isEmpty,
              "\(candidatePoint)pt English footer has no TextKit geometry")
      require(candidateView.bounds.insetBy(dx: -0.5, dy: -0.5).contains(detailRect),
              "\(candidatePoint)pt English footer is clipped by natural panel bounds")
    } else {
      failures.append("\(candidatePoint)pt English footer range could not convert to TextKit")
    }
    let inset = LinnetCandidatePresentation.candidateWindowInset
    let contentRect = candidateView.contentRect
    require(
      abs(panel.frame.width - ceil(contentRect.width + inset.width * 2)) <= 0.5 &&
        abs(panel.frame.height - ceil(contentRect.height + inset.height * 2)) <= 0.5,
      "\(candidatePoint)pt English footer did not participate in natural panel sizing")
    panel.hide()
  }

  private static func testSharedCandidateDetailSidecarGeometry() {
    for point in [CGFloat(12), 15, 16, 32] {
      let panel = SquirrelPanel(position: NSRect(x: 0, y: 0, width: 2, height: 20))
      let controller = SquirrelInputController()
      panel.bind(controller: controller, activationToken: controller.activeInputToken)
      guard let candidateView = panel.contentView?.subviews.compactMap({
        $0 as? SquirrelView
      }).first else {
        failures.append("sidecar fixture could not locate SquirrelView")
        return
      }
      let theme = candidateView.lightTheme
      let candidateFont = NSFont.systemFont(ofSize: point)
      let detailFont = NSFont.systemFont(ofSize: max(10, point - 4))
      let candidateAttributes: [NSAttributedString.Key: Any] = [
        .font: candidateFont,
        .foregroundColor: NSColor.labelColor,
      ]
      theme.font = candidateFont
      theme.linear = false
      theme.candidateExpansionAllowed = false
      theme.showPaging = false
      theme.candidateFormat = "[label] [candidate]"
      theme.attrs = candidateAttributes
      theme.highlightedAttrs = candidateAttributes
      theme.labelAttrs = candidateAttributes
      theme.labelHighlightedAttrs = candidateAttributes
      theme.commentAttrs = candidateAttributes
      theme.commentHighlightedAttrs = candidateAttributes
      theme.detailAttrs = [
        .font: detailFont,
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
      theme.firstParagraphStyle = NSMutableParagraphStyle()
      theme.paragraphStyle = NSMutableParagraphStyle()
      let detailText = "/ef/ · n. 字母 F"
      let values = ["f", "far", "fast"]
      _ = panel.update(
        preedit: "", selRange: .empty, caretPos: 0,
        candidates: SquirrelInputController.CandidateSnapshot(
          items: values.enumerated().map { index, value in
            .init(
              text: value, comment: index == 0 ? detailText : "",
              page: 0, indexOnPage: index, absoluteIndex: index,
              selectionLabel: String(index + 1))
          },
          pageSize: values.count,
          currentPage: 0,
          isLastPage: true,
          isExpanded: false,
          canExpand: false),
        highlighted: 0,
        update: true,
        activationToken: controller.activeInputToken)
      render(candidateView)
      guard let text = candidateView.textView.textContentStorage?.attributedString,
        candidateView.candidateRanges.count == values.count
      else {
        failures.append("\(point)pt live sidecar did not publish candidate text")
        panel.hide()
        continue
      }
      let candidateWidth = candidateView.candidateRanges.reduce(CGFloat.zero) {
        width, range in
        max(
          width,
          text.attributedSubstring(from: range).boundingRect(
            with: NSSize(
              width: CGFloat.greatestFiniteMagnitude,
              height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).width)
      }
      let detailStringRange = (text.string as NSString).range(of: detailText)
      guard detailStringRange.location != NSNotFound else {
        failures.append("\(point)pt live sidecar lost its metadata text")
        panel.hide()
        continue
      }
      let detail = text.attributedSubstring(from: detailStringRange)
      let geometry = LinnetCandidatePresentation.candidateDetailGeometry(
        forLinearLayout: false)
      let dividerSize = NSAttributedString(
        string: geometry.dividerText,
        attributes: theme.detailAttrs).boundingRect(
          with: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin]).size
      let expected = geometry.frames(
        candidateSize: CGSize(width: candidateWidth, height: 0),
        detailSize: detail.boundingRect(
          with: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin]).size,
        dividerSize: dividerSize)
      let paragraph = text.attribute(
        .paragraphStyle,
        at: candidateView.candidateRanges[0].location,
        effectiveRange: nil) as? NSParagraphStyle
      let tabs = paragraph?.tabStops ?? []
      require(
        tabs.count == 2 &&
          abs(tabs[0].location - (expected.divider?.minX ?? .nan)) < 0.001 &&
          abs(tabs[1].location - expected.detail.minX) < 0.001,
        "\(point)pt live sidecar did not consume the shared candidate-detail frames")
      require(
        text.attributedSubstring(from: candidateView.detailRange).string
          == geometry.textSeparator + detail.string,
        "\(point)pt live sidecar diverged from the shared separator")
      require(
        zip(candidateView.candidateRanges, values).allSatisfy { range, value in
          text.attributedSubstring(from: range).string.hasSuffix(value)
        },
        "\(point)pt sidecar insertion changed a candidate range")
      panel.hide()
    }
  }

  private static func testCandidateCellGeometry(
    fontPoint: CGFloat,
    linear: Bool,
    style: SquirrelTheme.SelectionStyle
  ) {
    let bounds = NSRect(
      x: 0, y: 0, width: 360,
      height: linear ? fontPoint + 32 : (fontPoint + 20) * 2)
    let view = SquirrelView(frame: bounds)
    view.lightTheme.linear = linear
    view.lightTheme.selectionStyle = style
    view.lightTheme.linespace = LinnetCandidatePresentation.candidateRowSpacing
    view.separatorWidth = linear
      ? LinnetCandidatePresentation.inlineCandidateSeparatorWidth(
        font: NSFont.systemFont(ofSize: fontPoint))
      : 0
    let value = linear ? "1 输入  2 输入法" : "1 输入\n2 输入法"
    let paragraph = NSMutableParagraphStyle()
    if linear {
      paragraph.lineSpacing = LinnetCandidatePresentation.candidateRowSpacing
    } else {
      paragraph.paragraphSpacing = LinnetCandidatePresentation.candidateRowSpacing / 2
      paragraph.paragraphSpacingBefore = LinnetCandidatePresentation.candidateRowSpacing / 2
    }
    let text = NSMutableAttributedString(
      string: value,
      attributes: [
        .font: NSFont.systemFont(ofSize: fontPoint),
        .paragraphStyle: paragraph,
      ])
    let source = text.string as NSString
    let ranges = [source.range(of: "1 输入"), source.range(of: "2 输入法")]
    view.textView.textContentStorage?.attributedString = text
    view.textView.frame = bounds
    view.textView.textContainerInset = LinnetCandidatePresentation.candidateWindowInset
    view.textView.textContainer?.size = bounds.size
    view.textView.textLayoutManager?.ensureLayout(
      for: view.textView.textLayoutManager!.documentRange)
    view.applyPresentationMetrics(LinnetPanelGeometry.presentationMetrics(
      role: .candidate,
      candidateFontPoint: fontPoint,
      candidateEdgeInset: LinnetCandidatePresentation.candidateWindowInset,
      candidatePaging: .none,
      candidateVertical: false,
      candidateCornerRadius: 10))
    view.drawView(
      candidateRanges: ranges,
      detailRange: .empty,
      hilightedIndex: 0,
      preeditRange: .empty,
      highlightedPreeditRange: .empty,
      controlMode: .paging(canPageUp: false, canPageDown: false),
      usesGridLayout: false)
    render(view)

    guard let textRange = view.convert(range: ranges[0]) else {
      failures.append("\(fontPoint)pt \(style.rawValue) selection lost its TextKit range")
      return
    }
    var glyphRect = view.contentRect(range: textRange)
    glyphRect.origin.x += LinnetCandidatePresentation.candidateWindowInset.width
    glyphRect.origin.y += LinnetCandidatePresentation.candidateWindowInset.height
    guard let selectionBox = highlightedSelectionBox(in: view) else {
      failures.append("\(fontPoint)pt \(style.rawValue) selection path is missing")
      return
    }
    switch style {
    case .tile:
      let cellBox = view.candidateAccessibilityGeometry().candidateFrames.first
      require(
        cellBox.map { approximatelyEqual(selectionBox, $0) } == true,
        "\(fontPoint)pt tile selection diverged from the candidate cell path")
    case .underline:
      let expected = NSRect(
        x: glyphRect.minX,
        y: glyphRect.maxY + 1,
        width: glyphRect.width,
        height: 2)
      require(
        approximatelyEqual(selectionBox, expected),
        "\(fontPoint)pt underline selection geometry drifted: \(selectionBox) / \(expected)")
    case .bar:
      let insets = LinnetCandidatePresentation.candidateSelectionInsets(
        style: .bar,
        candidateFont: NSFont.systemFont(ofSize: fontPoint))
      let expected = NSRect(
        x: max(1, glyphRect.minX - insets.left),
        y: glyphRect.minY - insets.top,
        width: 3,
        height: glyphRect.height + insets.top + insets.bottom)
      require(
        approximatelyEqual(selectionBox, expected),
        "\(fontPoint)pt bar selection bypassed shared insets: \(selectionBox) / \(expected)")
    }

    let frames = view.candidateAccessibilityGeometry().candidateFrames
    require(frames.count == ranges.count, "AX candidate frame count changed at \(fontPoint)pt")
    guard frames.count == ranges.count else { return }
    let font = NSFont.systemFont(ofSize: fontPoint)
    let minimumRowHeight = NSLayoutManager().defaultLineHeight(for: font)
      + LinnetCandidatePresentation.candidateRowSpacing
    for (index, frame) in frames.enumerated() {
      require(
        frame.height + 0.5 >= minimumRowHeight,
        "\(fontPoint)pt \(linear ? "row" : "column") AX frame \(frame.height) is smaller than visible row \(minimumRowHeight)")
      for point in interiorSamples(frame) {
        require(
          view.click(at: point) == .candidate(index),
          "candidate \(index) frame \(frame) contains wrong hit at \(point), \(fontPoint)pt")
      }
    }
    require(
      !frames[0].intersects(frames[1]),
      "candidate interaction cells overlap: \(frames[0]) / \(frames[1])")
    require(frames.allSatisfy(bounds.contains), "candidate interaction cell escaped the panel")
  }

  private static func render(_ view: SquirrelView) {
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      failures.append("candidate view did not create a bitmap render target")
      return
    }
    view.cacheDisplay(in: view.bounds, to: representation)
  }

  private static func writeSnapshot(of view: NSView?, outputPath: String) {
    guard let view,
      let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
      failures.append("default natural-size panel could not allocate a bitmap surface")
      return
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]),
      !data.isEmpty
    else {
      failures.append("default natural-size panel bitmap was empty")
      return
    }
    do {
      try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
      print("Default natural-size screenshot: \(outputPath)")
    } catch {
      failures.append("default natural-size panel could not be written: \(error)")
    }
  }

  private struct ThemeSample {
    let identifier: String
    let background: NSColor
    let border: NSColor
    let primary: NSColor
    let label: NSColor
    let selectedBackground: NSColor
    let selectedPrimary: NSColor
    let selectedLabel: NSColor
    let cornerRadius: CGFloat
    let highlightedCornerRadius: CGFloat
    let mutuallyExclusive: Bool
    let isTranslucent: Bool
    let selectionStyle: SquirrelTheme.SelectionStyle
  }

  private static func makeContactSheet(yamlPath: String, outputPath: String) {
    guard let source = try? String(contentsOfFile: yamlPath, encoding: .utf8) else {
      failures.append("contact sheet could not read canonical squirrel.yaml")
      return
    }
    let samples = parseThemeSamples(source)
    let familyPrefixes = [
      "linnet_paper", "linnet_moon_jade", "linnet_sidecar", "linnet_clay",
      "linnet_mist_jade", "linnet_glass", "linnet_ink_cinnabar",
    ]
    guard samples.count == 14,
      familyPrefixes.allSatisfy({ samples["\($0)_light"] != nil && samples["\($0)_dark"] != nil })
    else {
      failures.append("contact sheet did not resolve all fourteen canonical palettes")
      return
    }

    let cellSize = NSSize(width: 400, height: 104)
    let sheetSize = NSSize(width: cellSize.width * 6, height: cellSize.height * 7)
    guard let sheet = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(sheetSize.width),
      pixelsHigh: Int(sheetSize.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: sheet)
    else {
      failures.append("contact sheet could not allocate a bitmap surface")
      return
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheetSize).fill()
    for (row, prefix) in familyPrefixes.enumerated() {
      for (column, variant) in [
        ("light", CGFloat(12)), ("dark", CGFloat(12)),
        ("light", CGFloat(16)), ("dark", CGFloat(16)),
        ("light", CGFloat(32)), ("dark", CGFloat(32)),
      ].enumerated() {
        guard let sample = samples["\(prefix)_\(variant.0)"],
          let candidate = renderCandidate(sample: sample, fontPoint: variant.1)
        else {
          failures.append("contact sheet failed to render \(prefix) \(variant)")
          continue
        }
        let cellX = CGFloat(column) * cellSize.width
        let cellY = sheetSize.height - CGFloat(row + 1) * cellSize.height
        let candidateImage = NSImage(size: candidate.size)
        candidateImage.addRepresentation(candidate)
        candidateImage.draw(
          in: NSRect(
            x: cellX + 12,
            y: cellY + 12,
            width: min(candidate.size.width, cellSize.width - 24),
            height: candidate.size.height),
          from: .zero,
          operation: .sourceOver,
          fraction: 1)
        let materialLabel = sample.isTranslucent ? " · material" : ""
        let label = "\(sample.identifier) · \(Int(variant.1)) pt · \(sample.selectionStyle.rawValue)\(materialLabel)" as NSString
        label.draw(
          at: NSPoint(x: cellX + 12, y: cellY + cellSize.height - 22),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1),
          ])
      }
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = sheet.representation(using: .png, properties: [:]), data.count > 10_000 else {
      failures.append("contact sheet render was empty")
      return
    }
    do {
      try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
      print("Candidate contact sheet: \(outputPath)")
    } catch {
      failures.append("contact sheet could not be written: \(error)")
    }
  }

  private static func makeReadmeProductGallery(
    yamlPath: String,
    inputModesOutputPath: String,
    bilingualOutputPath: String
  ) {
    guard let source = try? String(contentsOfFile: yamlPath, encoding: .utf8),
      let paper = parseThemeSamples(source)["linnet_paper_light"]
    else {
      failures.append("README product gallery could not resolve Paper Light")
      return
    }
    guard let chineseStatus = renderStatusNotice("中"),
      let englishStatus = renderStatusNotice("En"),
      let asciiStatus = renderStatusNotice("A")
    else {
      failures.append("README product gallery could not render input-mode notices")
      return
    }

    let modeSize = NSSize(width: 1360, height: 500)
    guard let (modeBitmap, modeContext) = bitmapSurface(
      size: modeSize, failure: "README input-mode image")
    else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = modeContext
    let ink = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.10, alpha: 1)
    let secondary = NSColor(srgbRed: 0.36, green: 0.41, blue: 0.40, alpha: 1)
    let accent = NSColor(srgbRed: 0.27, green: 0.58, blue: 0.55, alpha: 1)
    NSColor(srgbRed: 0.985, green: 0.989, blue: 0.989, alpha: 1).setFill()
    NSRect(origin: .zero, size: modeSize).fill()
    ("Shift 切换后，状态在光标旁立即出现" as NSString).draw(
      at: NSPoint(x: 64, y: 422),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
        .foregroundColor: ink,
      ])
    ("以下三枚提示均由当前 SquirrelPanel / SquirrelView 真实渲染" as NSString).draw(
      at: NSPoint(x: 66, y: 382),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 22),
        .foregroundColor: secondary,
      ])
    let columns: [(String, String, NSBitmapImageRep)] = [
      ("中文", "全拼或当前双拼 · 中文候选", chineseStatus),
      ("Smart English", "补全 · 纠错 · IPA · 中文释义", englishStatus),
      ("原始 ASCII", "代码 · 密码 · 终端 · 原样输入", asciiStatus),
    ]
    for (index, column) in columns.enumerated() {
      let originX = CGFloat(66 + index * 430)
      let width = CGFloat(360)
      (column.0 as NSString).draw(
        at: NSPoint(x: originX, y: 285),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
          .foregroundColor: ink,
        ])
      let noticeWidth = CGFloat(column.2.pixelsWide) * 2
      let noticeHeight = CGFloat(column.2.pixelsHigh) * 2
      drawBitmap(
        column.2,
        in: NSRect(
          x: originX + (width - noticeWidth) / 2,
          y: 178, width: noticeWidth, height: noticeHeight))
      (column.1 as NSString).draw(
        at: NSPoint(x: originX, y: 135),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 20),
          .foregroundColor: secondary,
        ])
      if index < columns.count - 1 {
        accent.withAlphaComponent(0.22).setFill()
        NSRect(x: originX + 394, y: 125, width: 2, height: 190).fill()
      }
    }
    ("轻按 Shift：中文 ↔ Smart English　·　Caps Lock：进入或退出 A" as NSString).draw(
      at: NSPoint(x: 64, y: 48),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .medium),
        .foregroundColor: accent,
      ])
    NSGraphicsContext.restoreGraphicsState()
    writeReadmeBitmap(
      modeBitmap, outputPath: inputModesOutputPath, label: "README input-mode image")

    let reverseItems = [
      ("algorithm", "n. 算法"),
      ("algebra", "n. 代数"),
      ("calculate", "v. 计算"),
    ]
    let englishItems = [
      ("cloud", "/klaʊd/ · n. 云；云端；云状物"),
      ("cloudy", ""),
      ("cloudless", ""),
      ("cloudburst", ""),
    ]
    guard let reverse = renderProductCandidatePanel(
      sample: paper, preedit: ";suanfa", items: reverseItems),
      let english = renderProductCandidatePanel(
        sample: paper, preedit: "cloud", items: englishItems)
    else {
      failures.append("README product gallery could not render bilingual candidates")
      return
    }
    let bilingualSize = NSSize(width: 1360, height: 660)
    guard let (bilingualBitmap, bilingualContext) = bitmapSurface(
      size: bilingualSize, failure: "README bilingual image")
    else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = bilingualContext
    NSColor(srgbRed: 0.985, green: 0.989, blue: 0.989, alpha: 1).setFill()
    NSRect(origin: .zero, size: bilingualSize).fill()
    ("双语能力，直接看真实候选窗" as NSString).draw(
      at: NSPoint(x: 64, y: 582),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
        .foregroundColor: ink,
      ])
    ("候选、选中态、释义和输入串均由当前产品渲染链生成" as NSString).draw(
      at: NSPoint(x: 66, y: 542),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 22),
        .foregroundColor: secondary,
      ])
    let panels: [(String, String, NSBitmapImageRep)] = [
      ("01 · 中文里的拼音反查", "输入 ;suanfa，不离开中文状态", reverse),
      ("02 · Smart English", "补全、IPA、中文释义与原始输入", english),
    ]
    for (index, panel) in panels.enumerated() {
      let originX = CGFloat(64 + index * 660)
      (panel.0 as NSString).draw(
        at: NSPoint(x: originX, y: 468),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
          .foregroundColor: accent,
        ])
      (panel.1 as NSString).draw(
        at: NSPoint(x: originX, y: 432),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 20),
          .foregroundColor: secondary,
        ])
      let availableWidth = CGFloat(590)
      let scale = min(1.55, availableWidth / CGFloat(panel.2.pixelsWide))
      let panelWidth = CGFloat(panel.2.pixelsWide) * scale
      let panelHeight = CGFloat(panel.2.pixelsHigh) * scale
      drawBitmap(
        panel.2,
        in: NSRect(
          x: originX + (availableWidth - panelWidth) / 2,
          y: 190, width: panelWidth, height: panelHeight))
    }
    ("真实产品渲染 · Paper Light · 20 pt" as NSString).draw(
      at: NSPoint(x: 64, y: 46),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 20),
        .foregroundColor: secondary,
      ])
    NSGraphicsContext.restoreGraphicsState()
    writeReadmeBitmap(
      bilingualBitmap, outputPath: bilingualOutputPath, label: "README bilingual image")
  }

  private static func renderStatusNotice(_ label: String) -> NSBitmapImageRep? {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    panel.updateStatus(
      long: label, short: label,
      activationToken: controller.activeInputToken)
    _ = panel.update(
      preedit: "", selRange: .empty, caretPos: 0,
      candidates: .init(
        items: [], pageSize: 9, currentPage: 0, isLastPage: true,
        isExpanded: false, canExpand: false),
      highlighted: 0, update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    defer { panel.hide() }
    return bitmapSnapshot(of: panel.contentView)
  }

  private static func renderProductCandidatePanel(
    sample: ThemeSample,
    preedit: String,
    items: [(String, String)]
  ) -> NSBitmapImageRep? {
    let panel = SquirrelPanel(position: NSRect(x: 120, y: 120, width: 2, height: 20))
    let controller = SquirrelInputController()
    panel.bind(controller: controller, activationToken: controller.activeInputToken)
    guard let candidateView = panel.contentView?.subviews.compactMap({
      $0 as? SquirrelView
    }).first else { return nil }
    let theme = candidateView.lightTheme
    let candidateFont = LinnetCandidatePresentation.platformFont(fontNames: [], size: 20)
    let labelFont = LinnetCandidatePresentation.platformFont(
      fontNames: [], size: 13, fallback: candidateFont)
    let detailFont = LinnetCandidatePresentation.platformFont(
      fontNames: [], size: 15, fallback: candidateFont)
    theme.font = candidateFont
    theme.backgroundColor = sample.background
    theme.borderColor = sample.border
    theme.highlightedBackColor = sample.selectedBackground
    theme.cornerRadius = sample.cornerRadius
    theme.hilitedCornerRadius = sample.highlightedCornerRadius
    theme.selectionStyle = sample.selectionStyle
    theme.linear = true
    theme.candidateExpansionAllowed = false
    theme.showPaging = false
    theme.linespace = LinnetCandidatePresentation.candidateRowSpacing
    theme.candidateFormat = "[label] [candidate]"
    theme.attrs = [.font: candidateFont, .foregroundColor: sample.primary]
    theme.highlightedAttrs = [
      .font: candidateFont, .foregroundColor: sample.selectedPrimary,
    ]
    theme.labelAttrs = [.font: labelFont, .foregroundColor: sample.label]
    theme.labelHighlightedAttrs = [
      .font: labelFont, .foregroundColor: sample.selectedLabel,
    ]
    theme.commentAttrs = [.font: detailFont, .foregroundColor: sample.primary]
    theme.commentHighlightedAttrs = [
      .font: detailFont, .foregroundColor: sample.selectedPrimary,
    ]
    theme.detailAttrs = [.font: detailFont, .foregroundColor: sample.primary]
    theme.preeditAttrs = [.font: candidateFont, .foregroundColor: sample.primary]
    theme.preeditHighlightedAttrs = theme.preeditAttrs
    let firstParagraph = NSMutableParagraphStyle()
    firstParagraph.paragraphSpacing = theme.linespace / 2
    firstParagraph.paragraphSpacingBefore =
      LinnetCandidatePresentation.preeditSpacing / 2 + theme.linespace / 2
    theme.firstParagraphStyle = firstParagraph
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = theme.linespace / 2
    paragraph.paragraphSpacingBefore = theme.linespace / 2
    theme.paragraphStyle = paragraph
    theme.preeditParagraphStyle = paragraph

    let snapshot = SquirrelInputController.CandidateSnapshot(
      items: items.enumerated().map { index, item in
        .init(
          text: item.0, comment: item.1, page: 0, indexOnPage: index,
          absoluteIndex: index, selectionLabel: String(index + 1))
      },
      pageSize: items.count,
      currentPage: 0,
      isLastPage: true,
      isExpanded: false,
      canExpand: false)
    _ = panel.update(
      preedit: preedit,
      selRange: NSRange(location: 0, length: preedit.utf16.count),
      caretPos: preedit.utf16.count,
      candidates: snapshot,
      highlighted: 0,
      update: true,
      activationToken: controller.activeInputToken)
    panel.displayIfNeeded()
    defer { panel.hide() }
    return bitmapSnapshot(of: panel.contentView)
  }

  private static func bitmapSurface(
    size: NSSize,
    failure: String
  ) -> (NSBitmapImageRep, NSGraphicsContext)? {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width),
      pixelsHigh: Int(size.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      failures.append("\(failure) could not allocate a bitmap surface")
      return nil
    }
    return (bitmap, context)
  }

  private static func verifyReadmeRender(
    committedPath: String,
    generatedPath: String,
    label: String
  ) {
    guard let committedData = try? Data(contentsOf: URL(fileURLWithPath: committedPath)),
      let generatedData = try? Data(contentsOf: URL(fileURLWithPath: generatedPath)),
      let committed = NSBitmapImageRep(data: committedData),
      let generated = NSBitmapImageRep(data: generatedData)
    else {
      failures.append("\(label) could not be decoded for visual verification")
      return
    }
    guard committed.pixelsWide == generated.pixelsWide,
      committed.pixelsHigh == generated.pixelsHigh
    else {
      failures.append(
        "\(label) dimensions changed from \(committed.pixelsWide)x\(committed.pixelsHigh) "
          + "to \(generated.pixelsWide)x\(generated.pixelsHigh)")
      return
    }
    guard let committedSample = normalizedReadmeSample(committed),
      let generatedSample = normalizedReadmeSample(generated),
      let committedBytes = committedSample.bitmapData,
      let generatedBytes = generatedSample.bitmapData
    else {
      failures.append("\(label) could not allocate its normalized visual sample")
      return
    }
    let byteCount = committedSample.bytesPerRow * committedSample.pixelsHigh
    guard byteCount == generatedSample.bytesPerRow * generatedSample.pixelsHigh else {
      failures.append("\(label) normalized visual samples had different storage")
      return
    }
    var difference = 0
    for index in 0..<byteCount {
      difference += abs(Int(committedBytes[index]) - Int(generatedBytes[index]))
    }
    let normalizedDifference = Double(difference) / Double(byteCount * 255)
    print(String(format: "%@ visual distance: %.4f", label, normalizedDifference))
    require(
      normalizedDifference <= 0.015,
      String(
        format: "%@ visually diverged from the current product render (distance %.4f)",
        label, normalizedDifference))
  }

  private static func normalizedReadmeSample(
    _ source: NSBitmapImageRep
  ) -> NSBitmapImageRep? {
    let width = 170
    let height = max(1, Int((Double(source.pixelsHigh) / Double(source.pixelsWide) * 170).rounded()))
    guard let sample = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: width * 4,
      bitsPerPixel: 32),
      let context = NSGraphicsContext(bitmapImageRep: sample)
    else { return nil }
    let image = NSImage(size: NSSize(width: source.pixelsWide, height: source.pixelsHigh))
    image.addRepresentation(source)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.draw(
      in: NSRect(x: 0, y: 0, width: width, height: height),
      from: .zero,
      operation: .copy,
      fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return sample
  }

  private static func bitmapSnapshot(of view: NSView?) -> NSBitmapImageRep? {
    guard let view,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
  }

  private static func drawBitmap(_ bitmap: NSBitmapImageRep, in rect: NSRect) {
    let image = NSImage(size: bitmap.size)
    image.addRepresentation(bitmap)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
  }

  private static func writeReadmeBitmap(
    _ bitmap: NSBitmapImageRep,
    outputPath: String,
    label: String
  ) {
    guard let data = bitmap.representation(using: .png, properties: [:]),
      data.count > 10_000
    else {
      failures.append("\(label) render was empty")
      return
    }
    do {
      try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
      print("\(label): \(outputPath)")
    } catch {
      failures.append("\(label) could not be written: \(error)")
    }
  }

  private static func makeReadmeThemeGallery(yamlPath: String, outputPath: String) {
    guard let source = try? String(contentsOfFile: yamlPath, encoding: .utf8) else {
      failures.append("README theme gallery could not read canonical squirrel.yaml")
      return
    }
    let samples = parseThemeSamples(source)
    let families = [
      ("linnet_paper", "宣纸青黛", "Paper Ledger", "下划线"),
      ("linnet_moon_jade", "月华玉青", "Moon Jade", "侧边栏"),
      ("linnet_sidecar", "青岩", "Sidecar Slate", "侧边栏"),
      ("linnet_clay", "陶印", "Clay Tiles", "色块"),
      ("linnet_mist_jade", "月白雾青", "Mist Jade", "色块 · 材质"),
      ("linnet_glass", "原生玻璃", "Native Glass", "色块 · 材质"),
      ("linnet_ink_cinnabar", "夜墨朱砂", "Ink Cinnabar", "下划线"),
    ]
    guard samples.count == 14,
      families.allSatisfy({
        samples["\($0.0)_light"] != nil && samples["\($0.0)_dark"] != nil
      })
    else {
      failures.append("README theme gallery did not resolve all fourteen canonical palettes")
      return
    }

    let sheetSize = NSSize(width: 1360, height: 1100)
    guard let (sheet, context) = bitmapSurface(
      size: sheetSize, failure: "README theme gallery")
    else { return }

    let titleFont = NSFont.systemFont(ofSize: 40, weight: .semibold)
    let subtitleFont = NSFont.systemFont(ofSize: 22, weight: .regular)
    let headingFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
    let familyFont = NSFont.systemFont(ofSize: 28, weight: .semibold)
    let detailFont = NSFont.systemFont(ofSize: 18, weight: .regular)
    let ink = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.10, alpha: 1)
    let secondary = NSColor(srgbRed: 0.39, green: 0.44, blue: 0.43, alpha: 1)
    let accent = NSColor(srgbRed: 0.31, green: 0.61, blue: 0.58, alpha: 1)
    let separator = NSColor(srgbRed: 0.88, green: 0.91, blue: 0.90, alpha: 1)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(srgbRed: 0.985, green: 0.989, blue: 0.989, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheetSize).fill()
    ("七套候选窗主题 · 当前产品真实渲染" as NSString).draw(
      at: NSPoint(x: 50, y: 1020),
      withAttributes: [.font: titleFont, .foregroundColor: ink])
    ("由 data/squirrel.yaml 通过当前 SquirrelView 生成 · 20 pt · Light / Dark" as NSString)
      .draw(
        at: NSPoint(x: 52, y: 980),
        withAttributes: [.font: subtitleFont, .foregroundColor: secondary])

    for (index, family) in families.enumerated() {
      let column = index % 2
      let row = index / 2
      let cardX = CGFloat(50 + column * 655)
      let cardY = CGFloat(745 - row * 230)
      let card = NSRect(x: cardX, y: cardY, width: 630, height: 210)
      let cardPath = NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22)
      NSColor.white.withAlphaComponent(0.72).setFill()
      cardPath.fill()
      separator.setStroke()
      cardPath.lineWidth = 1
      cardPath.stroke()
      guard let light = samples["\(family.0)_light"],
        let dark = samples["\(family.0)_dark"],
        let lightCandidate = renderCandidate(sample: light, fontPoint: 20),
        let darkCandidate = renderCandidate(sample: dark, fontPoint: 20)
      else {
        failures.append("README theme gallery could not render \(family.0)")
        continue
      }

      (family.1 as NSString).draw(
        at: NSPoint(x: cardX + 24, y: cardY + 164),
        withAttributes: [.font: familyFont, .foregroundColor: ink])
      ("\(family.2) · \(family.3)" as NSString).draw(
        at: NSPoint(x: cardX + 24, y: cardY + 138),
        withAttributes: [.font: detailFont, .foregroundColor: secondary])
      let candidateScale = CGFloat(1.18)
      let candidateWidth = lightCandidate.size.width * candidateScale
      let candidateHeight = lightCandidate.size.height * candidateScale
      ("LIGHT" as NSString).draw(
        at: NSPoint(x: cardX + 24, y: cardY + 70),
        withAttributes: [.font: headingFont, .foregroundColor: accent])
      drawBitmap(
        lightCandidate,
        in: NSRect(
          x: cardX + 130, y: cardY + 58,
          width: candidateWidth, height: candidateHeight))
      ("DARK" as NSString).draw(
        at: NSPoint(x: cardX + 24, y: cardY + 14),
        withAttributes: [.font: headingFont, .foregroundColor: accent])
      drawBitmap(
        darkCandidate,
        in: NSRect(
          x: cardX + 130, y: cardY + 2,
          width: candidateWidth, height: candidateHeight))
    }

    ("雾青与原生玻璃使用 macOS 材质；实际透明度会随外观和当前应用背景变化。" as NSString).draw(
      at: NSPoint(x: 705, y: 62),
      withAttributes: [.font: detailFont, .foregroundColor: secondary])
    NSGraphicsContext.restoreGraphicsState()
    writeReadmeBitmap(sheet, outputPath: outputPath, label: "README theme gallery")
  }

  private static func renderCandidate(
    sample: ThemeSample,
    fontPoint: CGFloat
  ) -> NSBitmapImageRep? {
    let frame = NSRect(x: 0, y: 0, width: 376, height: fontPoint + 26)
    let host = NSView(frame: frame)
    host.wantsLayer = true
    host.layer?.backgroundColor = (sample.identifier.hasSuffix("_dark")
      ? NSColor(calibratedWhite: 0.12, alpha: 1)
      : NSColor(calibratedWhite: 0.94, alpha: 1)).cgColor
    let material = NSVisualEffectView(frame: frame)
    if sample.isTranslucent {
      material.blendingMode = .behindWindow
      material.state = .active
      material.material = LinnetCandidatePresentation.candidateMaterial
      material.appearance = NSAppearance(
        named: sample.identifier.hasSuffix("_dark") ? .darkAqua : .aqua)
      material.wantsLayer = true
      host.addSubview(material)
    }
    let view = SquirrelView(frame: frame)
    let theme = view.lightTheme
    theme.backgroundColor = sample.background
    theme.borderColor = sample.border
    theme.cornerRadius = sample.cornerRadius
    theme.hilitedCornerRadius = sample.highlightedCornerRadius
    theme.highlightedBackColor = sample.selectedBackground
    theme.mutualExclusive = sample.mutuallyExclusive
    theme.translucency = sample.isTranslucent
    theme.selectionStyle = sample.selectionStyle
    theme.linear = true
    theme.linespace = LinnetCandidatePresentation.candidateRowSpacing
    let font = LinnetCandidatePresentation.platformFont(fontNames: [], size: fontPoint)
    let text = NSMutableAttributedString(
      string: "1 输入  2 interface",
      attributes: [.font: font, .foregroundColor: sample.primary])
    let source = text.string as NSString
    let ranges = [source.range(of: "1 输入"), source.range(of: "2 interface")]
    text.addAttribute(.foregroundColor, value: sample.selectedPrimary, range: ranges[0])
    view.textView.textContentStorage?.attributedString = text
    view.textView.frame = frame
    view.textView.textContainerInset = LinnetCandidatePresentation.candidateWindowInset
    view.textView.textContainer?.size = frame.size
    view.textView.textLayoutManager?.ensureLayout(
      for: view.textView.textLayoutManager!.documentRange)
    view.separatorWidth = LinnetCandidatePresentation.inlineCandidateSeparatorWidth(font: font)
    view.applyPresentationMetrics(LinnetPanelGeometry.presentationMetrics(
      role: .candidate,
      candidateFontPoint: fontPoint,
      candidateEdgeInset: LinnetCandidatePresentation.candidateWindowInset,
      candidatePaging: .none,
      candidateVertical: false,
      candidateCornerRadius: sample.cornerRadius))
    view.drawView(
      candidateRanges: ranges,
      detailRange: .empty,
      hilightedIndex: 0,
      preeditRange: .empty,
      highlightedPreeditRange: .empty,
      controlMode: .paging(canPageUp: false, canPageDown: false),
      usesGridLayout: false)
    if sample.isTranslucent {
      material.layer?.mask = view.shape
    }
    host.addSubview(view)
    host.addSubview(view.textView)
    guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      return nil
    }
    host.cacheDisplay(in: host.bounds, to: representation)
    return representation
  }

  private static func parseThemeSamples(_ source: String) -> [String: ThemeSample] {
    var result: [String: ThemeSample] = [:]
    var identifier: String?
    var fields: [String: String] = [:]
    func flush() {
      guard let identifier,
        let background = rimeColor(fields["back_color"]),
        let border = rimeColor(fields["border_color"]),
      let primary = rimeColor(fields["candidate_text_color"]),
        let label = rimeColor(fields["label_color"]),
        let selectedBackground = rimeColor(fields["hilited_candidate_back_color"]),
        let selectedPrimary = rimeColor(fields["hilited_candidate_text_color"]),
        let selectedLabel = rimeColor(fields["hilited_candidate_label_color"]),
        let corner = fields["corner_radius"].flatMap(Double.init),
        let highlightedCorner = fields["hilited_corner_radius"].flatMap(Double.init),
        let selectionStyle = fields["linnet_selection_style"]
          .flatMap(SquirrelTheme.SelectionStyle.init(rawValue:))
      else { return }
      result[identifier] = ThemeSample(
        identifier: identifier,
        background: background,
        border: border,
        primary: primary,
        label: label,
        selectedBackground: selectedBackground,
        selectedPrimary: selectedPrimary,
        selectedLabel: selectedLabel,
        cornerRadius: corner,
        highlightedCornerRadius: highlightedCorner,
        mutuallyExclusive: fields["mutual_exclusive"] == "true",
        isTranslucent: fields["translucency"] == "true",
        selectionStyle: selectionStyle)
    }
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine.prefix { $0 != "#" })
      let indentation = line.prefix { $0 == " " }.count
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if indentation == 2, trimmed.hasSuffix(":"), !trimmed.contains(": ") {
        flush()
        let candidate = String(trimmed.dropLast())
        identifier = candidate.hasPrefix("linnet_") ? candidate : nil
        fields = [:]
      } else if identifier != nil, indentation == 4,
        let separator = trimmed.firstIndex(of: ":")
      {
        fields[String(trimmed[..<separator])] = String(
          trimmed[trimmed.index(after: separator)...])
          .trimmingCharacters(in: .whitespaces)
      }
    }
    flush()
    return result
  }

  private static func rimeColor(_ source: String?) -> NSColor? {
    guard let source,
      let value = UInt32(source.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
    else { return nil }
    let alpha = value > 0xFF_FF_FF ? CGFloat((value >> 24) & 0xFF) / 255 : 1
    let red = CGFloat(value & 0xFF) / 255
    let green = CGFloat((value >> 8) & 0xFF) / 255
    let blue = CGFloat((value >> 16) & 0xFF) / 255
    return NSColor(
      srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  private static func interiorSamples(_ frame: NSRect) -> [NSPoint] {
    let inset = frame.insetBy(dx: min(1, frame.width / 4), dy: min(1, frame.height / 4))
    return [
      NSPoint(x: inset.midX, y: inset.minY),
      NSPoint(x: inset.midX, y: inset.midY),
      NSPoint(x: inset.midX, y: inset.maxY),
    ]
  }

  private static func approximatelyEqual(
    _ lhs: NSRect,
    _ rhs: NSRect,
    tolerance: CGFloat = 0.01
  ) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance &&
      abs(lhs.minY - rhs.minY) <= tolerance &&
      abs(lhs.width - rhs.width) <= tolerance &&
      abs(lhs.height - rhs.height) <= tolerance
  }

  private static func highlightedSelectionBox(in view: SquirrelView) -> NSRect? {
    guard let selectedColor = view.currentTheme.highlightedBackColor?.cgColor,
      let panelLayer = view.layer?.sublayers?.first as? CAShapeLayer,
      let selectionLayer = panelLayer.sublayers?.compactMap({ $0 as? CAShapeLayer })
        .last(where: { layer in
          layer.fillColor.map { CFEqual($0, selectedColor) } == true
        }),
      let path = selectionLayer.path
    else { return nil }
    return path.boundingBox
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
  }
}

private extension NSRect {
  var center: NSPoint { NSPoint(x: midX, y: midY) }
}
