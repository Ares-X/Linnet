/// The single projection from a live Rime menu/context into the typed candidate
/// snapshot consumed by the panel. The input controller owns the session; this
/// builder owns page bounds, labels, and bounded expanded iteration.
enum LinnetRimeCandidateSnapshotBuilder {
  static func build(
    context: RimeContext_stdbool,
    labels: [String],
    expansionAnchorPage: Int?,
    session: RimeSessionId,
    rimeAPI: RimeApi_stdbool
  ) -> SquirrelInputController.CandidateSnapshot? {
    guard let menuPage = LinnetCandidatePresentation.candidateMenuPage(
      currentPage: context.menu.page_no,
      pageSize: context.menu.page_size,
      candidateCount: context.menu.num_candidates,
      highlighted: context.menu.highlighted_candidate_index)
    else { return nil }
    guard menuPage.pageSize > 0 else {
      return .init(
        items: [], currentPage: 0, pageSize: 0, highlightedItemIndex: 0,
        isLastPage: true, canExpand: false, isExpanded: false)
    }
    let currentPage = menuPage.currentPage
    let pageSize = menuPage.pageSize
    let currentCount = menuPage.candidateCount
    let highlightedOnPage = menuPage.highlighted
    guard let compactBounds = LinnetCandidatePresentation.expandedCandidateRange(
      anchorPage: currentPage,
      currentPage: currentPage,
      pageSize: pageSize)
    else { return nil }

    let currentPageStart = compactBounds.lowerBound
    var compactItems = [SquirrelInputController.CandidateItem]()
    compactItems.reserveCapacity(currentCount)
    for indexOnPage in 0..<currentCount {
      let candidate = context.menu.candidates[indexOnPage]
      compactItems.append(.init(
        absoluteIndex: currentPageStart + indexOnPage,
        page: currentPage,
        indexOnPage: indexOnPage,
        text: candidate.text.map { String(cString: $0) } ?? "",
        comment: candidate.comment.map { String(cString: $0) } ?? "",
        selectionLabel: LinnetCandidatePresentation.candidateSelectionLabel(
          at: indexOnPage, labels: labels)
      ))
    }
    let compact = SquirrelInputController.CandidateSnapshot(
      items: compactItems,
      currentPage: currentPage,
      pageSize: pageSize,
      highlightedItemIndex: highlightedOnPage,
      isLastPage: context.menu.is_last_page,
      canExpand: currentPage > 0 || !context.menu.is_last_page,
      isExpanded: false)
    guard let expansionAnchorPage,
      let expandedBounds = LinnetCandidatePresentation.expandedCandidateRange(
        anchorPage: expansionAnchorPage,
        currentPage: currentPage,
        pageSize: pageSize),
      let iteratorStart = Int32(exactly: expandedBounds.lowerBound)
    else { return compact }

    var iterator = RimeCandidateListIterator()
    guard rimeAPI.candidate_list_from_index(session, &iterator, iteratorStart) else {
      return compact
    }
    defer { rimeAPI.candidate_list_end(&iterator) }

    var expandedItems = [SquirrelInputController.CandidateItem]()
    expandedItems.reserveCapacity(expandedBounds.count)
    while expandedItems.count < expandedBounds.count,
      rimeAPI.candidate_list_next(&iterator) {
      let absoluteIndex = Int(iterator.index)
      guard expandedBounds.contains(absoluteIndex) else { break }
      let page = absoluteIndex / pageSize
      let indexOnPage = absoluteIndex % pageSize
      expandedItems.append(.init(
        absoluteIndex: absoluteIndex,
        page: page,
        indexOnPage: indexOnPage,
        text: iterator.candidate.text.map { String(cString: $0) } ?? "",
        comment: iterator.candidate.comment.map { String(cString: $0) } ?? "",
        selectionLabel: nil
      ))
    }
    let highlightedAbsolute = currentPageStart + highlightedOnPage
    guard !expandedItems.isEmpty,
      let expandedHighlighted = expandedItems.firstIndex(where: {
        $0.absoluteIndex == highlightedAbsolute
      })
    else { return compact }
    return .init(
      items: expandedItems,
      currentPage: currentPage,
      pageSize: pageSize,
      highlightedItemIndex: expandedHighlighted,
      isLastPage: context.menu.is_last_page,
      canExpand: currentPage > 0 || !context.menu.is_last_page,
      isExpanded: true)
  }
}
