//
//  LinnetCandidateGridView.swift
//  Linnet
//
//  Native expanded-candidate grid. Rime owns candidate state; this view owns
//  only the real AppKit cells and their resulting layout geometry.
//

import AppKit

final class LinnetCandidateGridView: NSGridView {
  private struct GridShape: Equatable {
    let rows: Int
    let columns: Int
  }

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

    init() {
      super.init(frame: .zero)
      textView.drawsBackground = false
      textView.isEditable = false
      textView.isSelectable = false
      textView.isHorizontallyResizable = false
      textView.isVerticallyResizable = false
      textView.textContainerInset = .zero
      textView.textContainer?.lineFragmentPadding = 0
      textView.textContainer?.maximumNumberOfLines = 1
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
      isHidden = false
      invalidateIntrinsicContentSize()
      needsLayout = true
    }

    func clear() {
      itemIndex = nil
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
  private var gridShape: GridShape?
  private var naturalColumnWidths: [CGFloat] = []
  private var naturalRowHeights: [CGFloat] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    xPlacement = .fill
    yPlacement = .fill
    isHidden = true
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  func publish(
    rows: [[Int]],
    lines: [LinnetCandidatePresentation.CandidateLine],
    verticalText: Bool,
    columnSpacing: CGFloat,
    rowSpacing: CGFloat
  ) {
    guard !rows.isEmpty else {
      clear()
      return
    }
    let columnCount = rows.map(\.count).max() ?? 0
    guard columnCount > 0,
      rows.count <= LinnetCandidatePresentation.maximumExpandedCandidateCount / columnCount
    else {
      clear()
      return
    }
    if cellPool.isEmpty {
      cellPool = (0..<LinnetCandidatePresentation.maximumExpandedCandidateCount)
        .map { _ in CandidateCellView() }
    }
    ensureGrid(rows: rows.count, columns: columnCount)

    self.columnSpacing = max(0, columnSpacing)
    self.rowSpacing = max(0, rowSpacing)
    // macOS keeps a stable label slot: rows without selection keys start
    // their candidate text on the same column line as the numbered row.
    let labelGutter = lines.map {
      CandidateCellView.width(of: $0.labelPrefix)
    }.max().map(ceil) ?? 0
    for (rowIndex, row) in rows.enumerated() {
      for column in 0..<columnCount {
        let cell = cellPool[rowIndex * columnCount + column]
        guard row.indices.contains(column), lines.indices.contains(row[column]) else {
          cell.clear()
          continue
        }
        cell.publish(
          itemIndex: row[column], line: lines[row[column]],
          labelGutter: labelGutter, verticalText: verticalText)
      }
    }
    let visibleCells = cellPool.prefix(rows.count * columnCount).filter { !$0.isHidden }
    let columnWidth = visibleCells.map(\.intrinsicContentSize.width).max() ?? 1
    let rowHeight = visibleCells.map(\.intrinsicContentSize.height).max() ?? 1
    naturalColumnWidths = Array(repeating: columnWidth, count: columnCount)
    naturalRowHeights = Array(repeating: rowHeight, count: rows.count)
    fitColumns(to: nil)
    isHidden = false
    invalidateIntrinsicContentSize()
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  func clear() {
    cellPool.forEach { $0.clear() }
    naturalColumnWidths = []
    naturalRowHeights = []
    isHidden = true
    frame = .zero
    invalidateIntrinsicContentSize()
  }

  /// NSGridView does not reliably promote a changed child intrinsic width
  /// after pooled cells are republished. Own the column guides explicitly so
  /// labels and candidates stay on one line; only an actual screen-width cap
  /// is allowed to truncate a cell.
  func fitColumns(to maximumWidth: CGFloat?) {
    guard !naturalColumnWidths.isEmpty else { return }
    let spacing = columnSpacing * CGFloat(max(0, naturalColumnWidths.count - 1))
    let naturalWidth = naturalColumnWidths[0]
    let width = maximumWidth.map {
      min(naturalWidth, max(1, ($0 - spacing) / CGFloat(naturalColumnWidths.count)))
    } ?? naturalWidth
    for index in naturalColumnWidths.indices {
      column(at: index).width = width
    }
    for (index, height) in naturalRowHeights.enumerated() {
      row(at: index).height = height
    }
    invalidateIntrinsicContentSize()
  }

  private func ensureGrid(rows: Int, columns: Int) {
    let shape = GridShape(rows: rows, columns: columns)
    guard gridShape != shape else { return }
    while numberOfRows > 0 { removeRow(at: 0) }
    for row in 0..<rows {
      let start = row * columns
      addRow(with: Array(cellPool[start..<(start + columns)]))
    }
    gridShape = shape
  }

  func geometries(in target: NSView) -> [CellGeometry] {
    guard !isHidden else { return [] }
    layoutSubtreeIfNeeded()
    return cellPool
      .compactMap { $0.geometry(in: target) }
      .sorted { $0.itemIndex < $1.itemIndex }
  }
}
