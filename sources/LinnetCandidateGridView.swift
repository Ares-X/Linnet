//
//  LinnetCandidateGridView.swift
//  Linnet
//
//  Native expanded-candidate grid. Rime owns candidate state; this view owns
//  only the real AppKit cells and their resulting layout geometry.
//

import AppKit

final class LinnetCandidateGridView: NSView {
  private typealias Placement = LinnetCandidatePresentation.ExpandedGrid.Placement

  struct CellGeometry {
    let itemIndex: Int
    let cellFrame: NSRect
    let textFrame: NSRect
  }

  private final class CandidateCellView: NSView {
    private(set) var itemIndex: Int?
    let textView = NSTextView(frame: .zero)
    private var measuredSize: NSSize = .zero
    private var textSize: NSSize = .zero
    private var labelPrefixExtent: CGFloat = 0
    private var leadingPadding: CGFloat = 0
    private var verticalText = false
    private var sourceLine: LinnetCandidatePresentation.CandidateLine?

    init() {
      super.init(frame: .zero)
      textView.drawsBackground = false
      textView.isEditable = false
      textView.isSelectable = false
      textView.isHorizontallyResizable = false
      textView.isVerticallyResizable = false
      textView.textContainerInset = .zero
      textView.textContainer?.lineFragmentPadding = 0
      textView.textContainer?.lineBreakMode = .byTruncatingTail
      textView.setAccessibilityElement(false)
      addSubview(textView)
      setAccessibilityElement(false)
      setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      setContentCompressionResistancePriority(.defaultLow, for: .vertical)
      isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func publish(
      itemIndex: Int,
      line: LinnetCandidatePresentation.CandidateLine,
      labelGutter: CGFloat,
      verticalText: Bool
    ) {
      self.itemIndex = itemIndex
      sourceLine = line
      let measured = line.attributedString.boundingRect(
        with: NSSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
      let horizontalSize = NSSize(
        width: max(1, ceil(measured.width)),
        height: max(1, ceil(measured.height)))
      labelPrefixExtent = ceil(Self.width(of: line.labelPrefix))
      leadingPadding = max(0, labelGutter - labelPrefixExtent)
      self.verticalText = verticalText
      textSize = verticalText
        ? NSSize(width: horizontalSize.height, height: horizontalSize.width)
        : horizontalSize
      self.measuredSize = verticalText
        ? NSSize(width: textSize.width, height: textSize.height + leadingPadding)
        : NSSize(width: textSize.width + leadingPadding, height: textSize.height)
      textView.textContentStorage?.attributedString = line.attributedString
      textView.setLayoutOrientation(verticalText ? .vertical : .horizontal)
      textView.textContainer?.maximumNumberOfLines = 1
      isHidden = false
      invalidateIntrinsicContentSize()
      needsLayout = true
    }

    func clear() {
      itemIndex = nil
      sourceLine = nil
      measuredSize = .zero
      textSize = .zero
      labelPrefixExtent = 0
      leadingPadding = 0
      verticalText = false
      textView.textContentStorage?.attributedString = NSAttributedString()
      isHidden = true
      invalidateIntrinsicContentSize()
      needsLayout = true
    }

    override var intrinsicContentSize: NSSize { measuredSize }

    func displaySelectionLabel(_ number: Int?) {
      guard let line = sourceLine, line.labelRange.length == 1 else { return }
      let text = NSMutableAttributedString(attributedString: line.attributedString)
      if let number {
        text.replaceCharacters(in: line.labelRange, with: String(number))
      } else {
        text.addAttribute(.foregroundColor, value: NSColor.clear, range: line.labelRange)
      }
      textView.textContentStorage?.attributedString = text
    }

    override func layout() {
      super.layout()
      let padding = min(
        leadingPadding,
        max(0, (verticalText ? bounds.height : bounds.width) - 1))
      let size = verticalText
        ? NSSize(
          width: min(bounds.width, textSize.width),
          height: min(max(1, bounds.height - padding), textSize.height))
        : NSSize(
          width: min(max(1, bounds.width - padding), textSize.width),
          height: min(bounds.height, textSize.height))
      textView.frame = NSRect(
        x: bounds.minX + (verticalText ? 0 : padding),
        y: verticalText ? bounds.minY + padding : bounds.midY - size.height / 2,
        width: size.width,
        height: size.height)
      textView.textContainer?.size = size
    }

    func geometry(in target: NSView) -> CellGeometry? {
      guard let itemIndex, !isHidden else { return nil }
      return CellGeometry(
        itemIndex: itemIndex,
        cellFrame: target.convert(bounds, from: self),
        textFrame: target.convert(textView.bounds, from: textView))
    }

    static func width(of text: NSAttributedString) -> CGFloat {
      text.boundingRect(
        with: NSSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      ).width
    }
  }

  private var cellPool: [CandidateCellView] = []
  private var placements: [Placement] = []
  private var displayedPlacements: [Placement] = []
  private var columnCount = 0
  private var itemCount = 0
  private var highlighted = 0
  private var firstVisibleRow = 0
  private var maximumRows = 3
  private var columnSpacing: CGFloat = 0
  private var rowSpacing: CGFloat = 0
  private var gridSize: NSSize = .zero

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isHidden = true
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize { gridSize }
  override var fittingSize: NSSize { gridSize }

  func publish(
    columns: Int,
    maximumRows: Int,
    lines: [LinnetCandidatePresentation.CandidateLine],
    highlighted: Int,
    verticalText: Bool,
    columnSpacing: CGFloat,
    rowSpacing: CGFloat
  ) {
    let columnCount = min(columns, lines.count)
    guard columnCount > 0,
      lines.count <= LinnetCandidatePresentation.maximumExpandedCandidateCount
    else {
      clear()
      return
    }
    if cellPool.isEmpty {
      cellPool = (0..<LinnetCandidatePresentation.maximumExpandedCandidateCount)
        .map { _ in CandidateCellView() }
      cellPool.forEach { addSubview($0) }
    }
    self.columnCount = columnCount
    self.maximumRows = max(1, maximumRows)
    if itemCount != lines.count { firstVisibleRow = 0 }
    self.itemCount = lines.count
    self.highlighted = highlighted
    self.columnSpacing = max(0, columnSpacing)
    self.rowSpacing = max(0, rowSpacing)
    // macOS keeps a stable label slot: rows without selection keys start
    // their candidate text on the same column line as the numbered row.
    let labelGutter = lines.map {
      CandidateCellView.width(of: $0.labelPrefix)
    }.max().map(ceil) ?? 0
    for index in cellPool.indices {
      guard lines.indices.contains(index) else {
        cellPool[index].clear()
        continue
      }
      cellPool[index].publish(
        itemIndex: index, line: lines[index],
        labelGutter: labelGutter, verticalText: verticalText)
    }
    isHidden = false
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  func clear() {
    cellPool.forEach { $0.clear() }
    placements = []
    displayedPlacements = []
    itemCount = 0
    firstVisibleRow = 0
    gridSize = .zero
    isHidden = true
    frame = .zero
    invalidateIntrinsicContentSize()
  }

  /// Each column fits its visible words, with one shared origin for all rows.
  /// Whole words determine column widths; a narrow window uses fewer columns.
  func fitColumns(to maximumWidth: CGFloat?) {
    guard itemCount > 0, columnCount > 0 else { return }
    let widths = cellPool.prefix(itemCount).map(\.intrinsicContentSize.width)
    let spacing = columnSpacing * CGFloat(columnCount - 1)
    let layout = LinnetCandidatePresentation.expandedGrid(
      widths: widths, columns: columnCount, spacing: columnSpacing,
      maximumWidth: maximumWidth ?? ((widths.max() ?? 1) * CGFloat(columnCount) + spacing),
      visibleRows: firstVisibleRow..<(firstVisibleRow + maximumRows), highlighted: highlighted)
    let packed = layout.placements
    let visibleRows = layout.visibleRows
    firstVisibleRow = visibleRows.lowerBound
    let selectedRow = packed[highlighted].row
    placements = packed
    let activeItems = packed.filter { $0.row == selectedRow }.map(\.item)
    for placement in packed {
      cellPool[placement.item].displaySelectionLabel(
        activeItems.firstIndex(of: placement.item).map { $0 + 1 })
    }
    let visible = packed.filter { visibleRows.contains($0.row) }
    displayedPlacements = visible
    for cell in cellPool { cell.isHidden = true }
    let rowHeights = (firstVisibleRow...(visible.last?.row ?? firstVisibleRow)).map { row in
      visible.filter { $0.row == row }.map {
        cellPool[$0.item].isHidden = false
        return cellPool[$0.item].intrinsicContentSize.height
      }.max() ?? 1
    }
    let usedColumns = visible.map { $0.column + 1 }.max() ?? 1
    gridSize = NSSize(
      width: layout.columnWidths.prefix(usedColumns).reduce(0, +) + columnSpacing * CGFloat(usedColumns - 1),
      height: rowHeights.reduce(0, +) + rowSpacing * CGFloat(rowHeights.count - 1))
    var top = gridSize.height
    for (offset, height) in rowHeights.enumerated() {
      for placement in visible where placement.row == offset + firstVisibleRow {
        cellPool[placement.item].frame = NSRect(
          x: layout.columnOffset(placement.column, spacing: columnSpacing),
          y: top - height,
          width: layout.columnWidths[placement.column],
          height: height)
      }
      top -= height + rowSpacing
    }
    needsLayout = true
    layoutSubtreeIfNeeded()
    invalidateIntrinsicContentSize()
  }

  func adjacentItem(from index: Int, up towardPreviousRow: Bool) -> Int? {
    guard let current = placements.first(where: { $0.item == index }) else { return nil }
    let targetRow = current.row + (towardPreviousRow ? -1 : 1)
    return placements.filter { $0.row == targetRow }.min {
      abs($0.column - current.column) < abs($1.column - current.column)
    }?.item
  }

  func itemForSelectionNumber(_ number: Int) -> Int? {
    guard let row = placements.first(where: { $0.item == highlighted })?.row,
      number > 0 else { return nil }
    let items = placements.filter { $0.row == row }
    return items.indices.contains(number - 1) ? items[number - 1].item : nil
  }

  func geometries(in target: NSView) -> [CellGeometry] {
    guard !isHidden else { return [] }
    return displayedPlacements
      .compactMap { cellPool[$0.item].geometry(in: target) }
      .sorted { $0.itemIndex < $1.itemIndex }
  }
}
