import AppKit

/// Owns pointer and scroll identity for one published candidate snapshot.
/// A gesture can produce an action only while its originating publication is
/// still current; replacing or hiding candidates retires every pending input.
struct LinnetCandidateInteractionState<Hit: Equatable> {
  enum PagingIntent: Equatable {
    case previousPage
    case nextPage
  }

  struct ScrollSample {
    let delta: CGVector
    let hasPreciseScrollingDeltas: Bool
    let phase: NSEvent.Phase
    let momentumPhase: NSEvent.Phase
    let timestamp: Date

    init(event: NSEvent) {
      self.init(
        delta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY),
        hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
        phase: event.phase,
        momentumPhase: event.momentumPhase,
        timestamp: .now)
    }

    init(
      delta: CGVector,
      hasPreciseScrollingDeltas: Bool,
      phase: NSEvent.Phase,
      momentumPhase: NSEvent.Phase,
      timestamp: Date
    ) {
      self.delta = delta
      self.hasPreciseScrollingDeltas = hasPreciseScrollingDeltas
      self.phase = phase
      self.momentumPhase = momentumPhase
      self.timestamp = timestamp
    }
  }

  private var publicationGeneration: UInt64 = 0
  private var scrollPublicationGeneration: UInt64?
  private var pressedHit: Hit?
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private(set) var pointerHit: Hit?

  var pointerHitIsPressed: Bool {
    guard let pointerHit else { return false }
    return pointerHit == pressedHit
  }

  mutating func movePointer(to hit: Hit?) {
    pointerHit = hit
  }

  mutating func beginPress(_ hit: Hit) {
    pointerHit = hit
    pressedHit = hit
  }

  mutating func finishPress(_ hit: Hit) -> Hit? {
    defer {
      pointerHit = hit
      pressedHit = nil
    }
    return hit == pressedHit ? hit : nil
  }

  mutating func cancelPress() {
    pressedHit = nil
  }

  mutating func leavePointer() {
    pointerHit = nil
  }

  mutating func advancePublication() {
    publicationGeneration &+= 1
    leavePointer()
    cancelPress()
    scrollTime = .distantPast
    cancelScrollGesture()
  }

  mutating func processScroll(
    _ sample: ScrollSample,
    vertical: Bool
  ) -> PagingIntent? {
    cancelPress()
    if !sample.momentumPhase.isEmpty {
      cancelScrollGesture()
      return nil
    }
    if sample.phase.contains(.began) {
      scrollPublicationGeneration = publicationGeneration
      scrollDirection = sample.delta
      return nil
    }
    if sample.phase.contains(.ended) || sample.phase.contains(.cancelled) {
      let intent = scrollPublicationGeneration == publicationGeneration &&
        sample.phase.contains(.ended)
        ? trackpadPagingIntent(vertical: vertical) : nil
      cancelScrollGesture()
      return intent
    }
    if sample.phase.isEmpty {
      if !sample.hasPreciseScrollingDeltas {
        cancelScrollGesture()
        guard sample.delta.dy != 0 else { return nil }
        return intent(pageUp: sample.delta.dy > 0)
      }
      return preciseWheelPagingIntent(
        deltaY: sample.delta.dy,
        now: sample.timestamp)
    }
    guard scrollPublicationGeneration == publicationGeneration else { return nil }
    scrollDirection = CGVector(
      dx: scrollDirection.dx + sample.delta.dx,
      dy: scrollDirection.dy + sample.delta.dy)
    return nil
  }

  private func trackpadPagingIntent(vertical: Bool) -> PagingIntent? {
    if abs(scrollDirection.dx) > abs(scrollDirection.dy),
      abs(scrollDirection.dx) > 10 {
      return intent(pageUp: (scrollDirection.dx < 0) == vertical)
    }
    if abs(scrollDirection.dy) > abs(scrollDirection.dx),
      abs(scrollDirection.dy) > 10 {
      return intent(pageUp: scrollDirection.dy > 0)
    }
    return nil
  }

  private mutating func preciseWheelPagingIntent(
    deltaY: CGFloat,
    now: Date
  ) -> PagingIntent? {
    if scrollPublicationGeneration != nil {
      cancelScrollGesture()
    }
    if now.timeIntervalSince(scrollTime) > 1 {
      scrollDirection = .zero
    }
    scrollTime = now
    let continuesDirection =
      (scrollDirection.dy >= 0 && deltaY > 0) ||
      (scrollDirection.dy <= 0 && deltaY < 0)
    scrollDirection.dy = continuesDirection
      ? scrollDirection.dy + deltaY : deltaY
    guard abs(scrollDirection.dy) > 10 else { return nil }
    let pagingIntent = intent(pageUp: scrollDirection.dy > 0)
    scrollDirection = .zero
    return pagingIntent
  }

  private func intent(pageUp: Bool) -> PagingIntent {
    pageUp ? .previousPage : .nextPage
  }

  private mutating func cancelScrollGesture() {
    scrollDirection = .zero
    scrollPublicationGeneration = nil
  }
}

/// Owns only the transient pointer layer. The engine-selected index remains
/// on SquirrelView and its accessibility projection; this layer never feeds
/// candidate state back into Rime.
final class LinnetCandidatePointerPresentation: CAShapeLayer {
  static let feedbackLayerName = "linnetCandidatePointerFeedback"

  private(set) var candidateIndex: Int?
  private(set) var isPressed = false
  private var candidatePath: CGPath?

  override init() {
    super.init()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func update(
    candidateIndex: Int?,
    isPressed: Bool,
    validIndices: Range<Int>
  ) -> Bool {
    let validIndex = candidateIndex.flatMap {
      validIndices.contains($0) ? $0 : nil
    }
    let validPressed = validIndex != nil && isPressed
    guard self.candidateIndex != validIndex || self.isPressed != validPressed
    else { return false }
    self.candidateIndex = validIndex
    self.isPressed = validPressed
    return true
  }

  func beginDrawing() {
    candidatePath = nil
  }

  func capture(
    _ path: CGPath?,
    candidateIndex: Int,
    horizontalOffset: CGFloat,
    bounds: NSRect
  ) -> NSRect? {
    if candidateIndex == self.candidateIndex {
      candidatePath = path
    }
    guard let path else { return nil }
    var frame = path.boundingBox
    frame.origin.x += horizontalOffset
    return frame.intersection(bounds)
  }

  func render(in parentLayer: CAShapeLayer) {
    guard let candidatePath else { return }
    let layer = CAShapeLayer()
    layer.name = Self.feedbackLayerName
    layer.path = candidatePath
    layer.fillColor = NSColor.labelColor.withAlphaComponent(
      isPressed ? 0.16 : 0.08).cgColor
    layer.strokeColor = NSColor.labelColor.withAlphaComponent(
      isPressed ? 0.28 : 0.16).cgColor
    layer.lineWidth = 0.5
    parentLayer.addSublayer(layer)
  }
}

extension SquirrelView {
  /// Presents direct pointer feedback without changing the Rime-owned
  /// candidate highlight or its accessibility selection.
  func updateCandidatePointerFeedback(
    hit: CandidateHit?,
    isPressed: Bool
  ) {
    let candidateIndex: Int?
    let controlAction: LinnetCandidatePresentation.CandidateControlAction?
    switch hit {
    case .candidate(let index):
      candidateIndex = index
      controlAction = nil
    case .control(let action):
      candidateIndex = nil
      controlAction = action
    case .some(.none):
      candidateIndex = nil
      controlAction = nil
    case nil:
      candidateIndex = nil
      controlAction = nil
    }
    let candidateChanged = shape.update(
      candidateIndex: candidateIndex,
      isPressed: isPressed,
      validIndices: candidateRanges.indices)
    let validControlPressed = controlAction != nil && isPressed
    let controlChanged = pointerControlAction != controlAction ||
      pointerControlIsPressed != validControlPressed
    pointerControlAction = controlAction
    pointerControlIsPressed = validControlPressed
    guard candidateChanged || controlChanged else { return }
    needsDisplay = true
    displayIfNeeded()
  }
}
