//
//  LinnetCandidateAccessibility.swift
//  Linnet
//
//  The single AppKit accessibility projection for the Rime-owned candidate
//  snapshot. It owns AX element lifetime and invalidates stale press actions.
//

import AppKit

struct LinnetCandidateAccessibilityGeometry {
  let candidateFrames: [NSRect]
  let previousPageFrame: NSRect?
  let nextPageFrame: NSRect?
}

struct LinnetCandidateAccessibilityPublication {
  let geometry: LinnetCandidateAccessibilityGeometry
  let candidates: [SquirrelInputController.CandidateItem]
  let highlightedIndex: Int
  let controlMode: LinnetCandidatePresentation.CandidateControlMode
  let shouldAnnounce: Bool
}

extension SquirrelView {
  func candidateAccessibilityGeometry() -> LinnetCandidateAccessibilityGeometry {
    return LinnetCandidateAccessibilityGeometry(
      candidateFrames: candidateInteractionFrames,
      previousPageFrame: pagingLayout.previousPage?.cell,
      nextPageFrame: pagingLayout.nextPage?.cell
    )
  }
}

final class LinnetCandidateAccessibilityElement: NSAccessibilityElement {
  var performPress: (() -> Bool)?

  override func accessibilityPerformPress() -> Bool {
    performPress?() ?? false
  }
}

final class LinnetCandidateAccessibility {
  private struct CandidateLayout: Equatable {
    let absoluteIndex: Int
    let text: String
    let comment: String
    let page: Int
    let indexOnPage: Int
  }

  private struct LayoutSignature: Equatable {
    let candidates: [CandidateLayout]
    let candidateFrames: [NSRect]
    let previousPageFrame: NSRect?
    let nextPageFrame: NSRect?
    let controlMode: LinnetCandidatePresentation.CandidateControlMode
  }

  private struct ControlPublication {
    let action: LinnetCandidatePresentation.CandidateControlAction
    let label: String
    let frame: NSRect
  }

  private var elements: [NSAccessibilityElement] = []
  private var candidateElements: [Int: LinnetCandidateAccessibilityElement] = [:]
  private var controlElements:
    [LinnetCandidatePresentation.CandidateControlAction:
      LinnetCandidateAccessibilityElement] = [:]
  private var layoutSignature: LayoutSignature?
  private var selectedAbsoluteIndex: Int?
  private var publicationGeneration: UInt64 = 0
  private var lastAnnouncement: String?

  func install(parent: NSView, rawTextView: NSTextView) {
    parent.setAccessibilityElement(true)
    configure(parent: parent, surface: .candidates)
    rawTextView.setAccessibilityElement(false)
  }

  func publish(
    parent: NSView,
    publication: LinnetCandidateAccessibilityPublication,
    selectCandidate: @escaping (Int) -> Bool,
    performControl: @escaping (LinnetCandidatePresentation.CandidateControlAction) -> Bool
  ) {
    let geometry = publication.geometry
    let candidates = publication.candidates
    let highlightedIndex = publication.highlightedIndex
    let controlMode = publication.controlMode
    let shouldAnnounce = publication.shouldAnnounce
    guard geometry.candidateFrames.count == candidates.count,
      geometry.candidateFrames.allSatisfy(validFrame),
      Set(candidates.map(\.absoluteIndex)).count == candidates.count
    else {
      clear(parent: parent)
      return
    }
    let previousPageFrame = geometry.previousPageFrame.flatMap {
      validFrame($0) ? $0 : nil
    }
    let nextPageFrame = geometry.nextPageFrame.flatMap {
      validFrame($0) ? $0 : nil
    }
    let generation = nextGeneration()
    configure(parent: parent, surface: .candidates)
    let signature = LayoutSignature(
      candidates: candidates.map {
        CandidateLayout(
          absoluteIndex: $0.absoluteIndex,
          text: $0.text,
          comment: $0.comment,
          page: $0.page,
          indexOnPage: $0.indexOnPage)
      },
      candidateFrames: geometry.candidateFrames,
      previousPageFrame: previousPageFrame,
      nextPageFrame: nextPageFrame,
      controlMode: controlMode)
    let reusesLayout = layoutSignature == signature
    if !reusesLayout {
      candidateElements.removeAll(keepingCapacity: true)
      controlElements.removeAll(keepingCapacity: true)
    }
    var newElements: [NSAccessibilityElement] = []
    var selectedElement: NSAccessibilityElement?
    var nextCandidateElements: [Int: LinnetCandidateAccessibilityElement] = [:]

    for index in candidates.indices {
      let candidate = candidates[index]
      guard let label = LinnetCandidatePresentation.accessibilityAnnouncement(
        candidate: candidate.text,
        comment: LinnetCandidatePresentation.candidateComment(candidate.comment).displayText,
        page: candidate.page,
        indexOnPage: candidate.indexOnPage
      ) else { continue }
      let element = candidateElements[candidate.absoluteIndex] ??
        LinnetCandidateAccessibilityElement()
      element.setAccessibilityParent(parent)
      element.setAccessibilityRole(.button)
      element.setAccessibilityLabel(label)
      element.setAccessibilityHelp(
        NSLocalizedString("Commit current candidate", comment: "Candidate accessibility action"))
      element.setAccessibilitySelected(index == highlightedIndex)
      element.setAccessibilityFrameInParentSpace(geometry.candidateFrames[index])
      element.performPress = { [weak self] in
        guard self?.publicationGeneration == generation else { return false }
        return selectCandidate(candidate.absoluteIndex)
      }
      newElements.append(element)
      nextCandidateElements[candidate.absoluteIndex] = element
      if index == highlightedIndex {
        selectedElement = element
      }
    }

    for publication in controlPublications(
      mode: controlMode,
      previousPageFrame: previousPageFrame,
      nextPageFrame: nextPageFrame
    ) {
      newElements.append(controlElement(
        existing: controlElements[publication.action],
        publication: publication,
        parent: parent,
        generation: generation,
        performControl: performControl
      ))
    }

    candidateElements = nextCandidateElements
    controlElements = controlElements.filter { _, element in
      newElements.contains { ($0 as AnyObject) === element }
    }
    elements = newElements
    parent.setAccessibilityChildren(elements)
    parent.setAccessibilitySelectedChildren(selectedElement.map { [$0] } ?? [])
    let nextSelectedAbsoluteIndex = candidates.indices.contains(highlightedIndex)
      ? candidates[highlightedIndex].absoluteIndex : nil
    postAccessibilityChange(
      parent: parent,
      elements: newElements,
      reusesLayout: reusesLayout,
      selectionChanged: selectedAbsoluteIndex != nextSelectedAbsoluteIndex)
    layoutSignature = signature
    selectedAbsoluteIndex = nextSelectedAbsoluteIndex
    guard publicationGeneration == generation else { return }

    if shouldAnnounce,
       let announcement = LinnetCandidatePresentation.accessibilityAnnouncement(
         candidate: candidates.indices.contains(highlightedIndex)
           ? candidates[highlightedIndex].text : "",
         comment: candidates.indices.contains(highlightedIndex)
           ? LinnetCandidatePresentation.candidateComment(
             candidates[highlightedIndex].comment).displayText : "",
         page: candidates.indices.contains(highlightedIndex)
           ? candidates[highlightedIndex].page : -1,
         indexOnPage: candidates.indices.contains(highlightedIndex)
           ? candidates[highlightedIndex].indexOnPage : -1
       ),
       announcement != lastAnnouncement {
      announce(announcement)
    }
  }

  func publishStatus(parent: NSView, message: String) {
    let generation = nextGeneration()
    configure(parent: parent, surface: .inputModeStatus)
    let element = NSAccessibilityElement()
    element.setAccessibilityParent(parent)
    element.setAccessibilityRole(.staticText)
    element.setAccessibilityLabel(message)
    element.setAccessibilityFrameInParentSpace(parent.bounds)
    resetCandidateElements()
    elements = [element]
    parent.setAccessibilityChildren(elements)
    parent.setAccessibilitySelectedChildren([])
    NSAccessibility.post(element: parent, notification: .layoutChanged)
    guard publicationGeneration == generation else { return }
    announce(message)
  }

  func clear(parent: NSView) {
    _ = nextGeneration()
    resetCandidateElements()
    elements = []
    lastAnnouncement = nil
    parent.setAccessibilityChildren(elements)
    parent.setAccessibilitySelectedChildren([])
    NSAccessibility.post(element: parent, notification: .layoutChanged)
  }

  private func nextGeneration() -> UInt64 {
    publicationGeneration &+= 1
    return publicationGeneration
  }

  private func configure(
    parent: NSView,
    surface: LinnetCandidatePresentation.AccessibilitySurface
  ) {
    parent.setAccessibilityRole(surface.exposesCandidateList ? .list : .group)
    parent.setAccessibilityLabel(NSLocalizedString(
      surface.localizedLabelKey,
      comment: surface.exposesCandidateList ? "Candidate panel" : "Input mode status"
    ))
  }

  private func controlElement(
    existing: LinnetCandidateAccessibilityElement?,
    publication: ControlPublication,
    parent: NSView,
    generation: UInt64,
    performControl: @escaping (LinnetCandidatePresentation.CandidateControlAction) -> Bool
  ) -> NSAccessibilityElement {
    let element = existing ?? LinnetCandidateAccessibilityElement()
    element.setAccessibilityParent(parent)
    element.setAccessibilityRole(.button)
    element.setAccessibilityLabel(publication.label)
    element.setAccessibilityFrameInParentSpace(publication.frame)
    element.performPress = { [weak self] in
      guard self?.publicationGeneration == generation else { return false }
      return performControl(publication.action)
    }
    controlElements[publication.action] = element
    return element
  }

  private func controlPublications(
    mode: LinnetCandidatePresentation.CandidateControlMode,
    previousPageFrame: NSRect?,
    nextPageFrame: NSRect?
  ) -> [ControlPublication] {
    switch mode {
    case .paging(let canPageUp, let canPageDown):
      var publications: [ControlPublication] = []
      if canPageUp, let previousPageFrame {
        publications.append(ControlPublication(
          action: .pageUp,
          label: NSLocalizedString(
            "Previous candidate page",
            comment: "Candidate page action"),
          frame: previousPageFrame))
      }
      if canPageDown, let nextPageFrame {
        publications.append(ControlPublication(
          action: .pageDown,
          label: NSLocalizedString(
            "Next candidate page",
            comment: "Candidate page action"),
          frame: nextPageFrame))
      }
      return publications
    case .disclosure(let expanded):
      guard let frame = expanded ? previousPageFrame : nextPageFrame
      else { return [] }
      return [ControlPublication(
        action: expanded ? .collapse : .expand,
        label: NSLocalizedString(
          expanded ? "Show fewer candidates" : "Show more candidates",
          comment: "Candidate disclosure action"),
        frame: frame)]
    }
  }

  private func resetCandidateElements() {
    candidateElements.removeAll(keepingCapacity: true)
    controlElements.removeAll(keepingCapacity: true)
    layoutSignature = nil
    selectedAbsoluteIndex = nil
  }

  private func postAccessibilityChange(
    parent: NSView,
    elements: [NSAccessibilityElement],
    reusesLayout: Bool,
    selectionChanged: Bool
  ) {
    if reusesLayout {
      guard selectionChanged else { return }
      NSAccessibility.post(
        element: parent,
        notification: .selectedChildrenChanged)
      return
    }
    NSAccessibility.post(
      element: parent,
      notification: .layoutChanged,
      userInfo: [.uiElements: elements])
  }

  private func validFrame(_ frame: NSRect) -> Bool {
    frame.width > 0 && frame.height > 0 &&
      frame.origin.x.isFinite && frame.origin.y.isFinite &&
      frame.width.isFinite && frame.height.isFinite
  }

  private func announce(_ message: String) {
    lastAnnouncement = message
    NSAccessibility.post(
      element: NSApplication.shared,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue
      ]
    )
  }
}
