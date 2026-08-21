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
  private var elements: [NSAccessibilityElement] = []
  private var publicationGeneration: UInt64 = 0
  private var lastAnnouncement: String?

  func install(parent: NSView, rawTextView: NSTextView) {
    parent.setAccessibilityElement(true)
    configure(parent: parent, surface: .candidates)
    rawTextView.setAccessibilityElement(false)
  }

  func publish(
    parent: NSView,
    geometry: LinnetCandidateAccessibilityGeometry,
    candidates: [SquirrelInputController.CandidateItem],
    highlightedIndex: Int,
    controlMode: LinnetCandidatePresentation.CandidateControlMode,
    shouldAnnounce: Bool,
    selectCandidate: @escaping (Int) -> Bool,
    performControl: @escaping (LinnetCandidatePresentation.CandidateControlAction) -> Bool
  ) {
    let generation = nextGeneration()
    configure(parent: parent, surface: .candidates)
    var newElements: [NSAccessibilityElement] = []
    var selectedElement: NSAccessibilityElement?

    for index in candidates.indices {
      let candidate = candidates[index]
      guard let label = LinnetCandidatePresentation.accessibilityAnnouncement(
        candidate: candidate.text,
        comment: candidate.comment,
        page: candidate.page,
        indexOnPage: candidate.indexOnPage
      ) else { continue }
      let element = LinnetCandidateAccessibilityElement()
      element.setAccessibilityParent(parent)
      element.setAccessibilityRole(.button)
      element.setAccessibilityLabel(label)
      element.setAccessibilityHelp(
        NSLocalizedString("Commit current candidate", comment: "Candidate accessibility action"))
      element.setAccessibilitySelected(index == highlightedIndex)
      element.setAccessibilityFrameInParentSpace(
        index < geometry.candidateFrames.count ? geometry.candidateFrames[index] : parent.bounds)
      element.performPress = { [weak self] in
        guard self?.publicationGeneration == generation else { return false }
        return selectCandidate(candidate.absoluteIndex)
      }
      newElements.append(element)
      if index == highlightedIndex {
        selectedElement = element
      }
    }

    switch controlMode {
    case .paging(let canPageUp, let canPageDown):
      if canPageUp, let frame = geometry.previousPageFrame {
        newElements.append(controlElement(
          parent: parent,
          label: NSLocalizedString("Previous candidate page", comment: "Candidate page action"),
          frame: frame,
          generation: generation,
          action: { performControl(.pageUp) }
        ))
      }
      if canPageDown, let frame = geometry.nextPageFrame {
        newElements.append(controlElement(
          parent: parent,
          label: NSLocalizedString("Next candidate page", comment: "Candidate page action"),
          frame: frame,
          generation: generation,
          action: { performControl(.pageDown) }
        ))
      }
    case .disclosure(let expanded):
      let frame = expanded ? geometry.previousPageFrame : geometry.nextPageFrame
      if let frame {
        newElements.append(controlElement(
          parent: parent,
          label: NSLocalizedString(
            expanded ? "Show fewer candidates" : "Show more candidates",
            comment: "Candidate disclosure action"),
          frame: frame,
          generation: generation,
          action: { performControl(expanded ? .collapse : .expand) }
        ))
      }
    }

    elements = newElements
    parent.setAccessibilityChildren(newElements)
    parent.setAccessibilitySelectedChildren(selectedElement.map { [$0] } ?? [])
    NSAccessibility.post(element: parent, notification: .layoutChanged)

    if shouldAnnounce,
       let announcement = LinnetCandidatePresentation.accessibilityAnnouncement(
         candidate: candidates.indices.contains(highlightedIndex)
           ? candidates[highlightedIndex].text : "",
         comment: candidates.indices.contains(highlightedIndex)
           ? candidates[highlightedIndex].comment : "",
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
    _ = nextGeneration()
    configure(parent: parent, surface: .inputModeStatus)
    let element = NSAccessibilityElement()
    element.setAccessibilityParent(parent)
    element.setAccessibilityRole(.staticText)
    element.setAccessibilityLabel(message)
    element.setAccessibilityFrameInParentSpace(parent.bounds)
    elements = [element]
    parent.setAccessibilityChildren([element])
    parent.setAccessibilitySelectedChildren([])
    NSAccessibility.post(element: parent, notification: .layoutChanged)
    announce(message)
  }

  func clear(parent: NSView) {
    _ = nextGeneration()
    elements = []
    lastAnnouncement = nil
    parent.setAccessibilityChildren([])
    parent.setAccessibilitySelectedChildren([])
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
    parent: NSView,
    label: String,
    frame: NSRect,
    generation: UInt64,
    action: @escaping () -> Bool
  ) -> NSAccessibilityElement {
    let element = LinnetCandidateAccessibilityElement()
    element.setAccessibilityParent(parent)
    element.setAccessibilityRole(.button)
    element.setAccessibilityLabel(label)
    element.setAccessibilityFrameInParentSpace(frame)
    element.performPress = { [weak self] in
      guard self?.publicationGeneration == generation else { return false }
      return action()
    }
    return element
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
