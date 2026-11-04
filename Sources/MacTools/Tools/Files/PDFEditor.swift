import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PDFTool: String, CaseIterable, Identifiable {
    case select, text, note, pen, rectangle, ellipse, line, arrow, highlightArea, whiteout, image, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .text: return "Text"
        case .note: return "Note"
        case .pen: return "Pen / Sign"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .highlightArea: return "Highlight"
        case .whiteout: return "White-out"
        case .image: return "Image"
        case .eraser: return "Eraser"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .note: return "note.text"
        case .pen: return "scribble"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .highlightArea: return "highlighter"
        case .whiteout: return "rectangle.fill"
        case .image: return "photo"
        case .eraser: return "eraser"
        }
    }

    var hint: String {
        switch self {
        case .select: return "Select text to highlight, underline or copy it. Fill in PDF forms directly."
        case .text: return "Type your text in the box above, then click on the page to place it."
        case .note: return "Click on the page to add a sticky note with the note text."
        case .pen: return "Drag to draw freehand – great for signatures."
        case .rectangle, .ellipse, .line, .arrow: return "Drag on the page to draw the shape."
        case .highlightArea: return "Drag over an area to highlight it."
        case .whiteout: return "Drag over content to cover it with white, then add new text on top."
        case .image: return "Choose an image (e.g. a signature or logo), then click on the page to place it."
        case .eraser: return "Click an annotation to remove it."
        }
    }
}

/// Draws an image on the page (used for signatures, logos and stamps).
final class ImageStampAnnotation: PDFAnnotation {
    var stampImage: NSImage?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image = stampImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            super.draw(with: box, in: context)
            return
        }
        context.saveGState()
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}

/// PDFView subclass that turns mouse input into annotations for the active tool.
final class EditablePDFView: PDFView {
    var tool: PDFTool = .select
    var strokeColor: NSColor = .systemRed
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 16
    var textToPlace = "Text"
    var noteText = "Note"
    var stampImage: NSImage?
    var onAdd: ((PDFPage, PDFAnnotation) -> Void)?
    var onRemove: ((PDFPage, PDFAnnotation) -> Void)?

    /// Real on-page rectangles of shapes whose annotation bounds cover the whole page.
    var shapeRects: [ObjectIdentifier: CGRect] = [:]

    private var dragStart: CGPoint?
    private var dragPage: PDFPage?
    private var inkPoints: [CGPoint] = []
    private var preview: PDFAnnotation?

    override func mouseDown(with event: NSEvent) {
        guard tool != .select else {
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return }
        let point = convert(viewPoint, to: page)

        switch tool {
        case .text:
            addText(at: point, on: page)
        case .note:
            let note = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 24, width: 24, height: 24), forType: .text, withProperties: nil)
            note.contents = noteText
            note.color = NSColor.systemYellow
            note.iconType = .note
            commit(note, on: page)
        case .image:
            addImage(at: point, on: page)
        case .eraser:
            erase(at: point, on: page)
        default:
            dragStart = point
            dragPage = page
            inkPoints = [point]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let page = dragPage else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        if tool == .pen { inkPoints.append(point) }
        if let old = preview { page.removeAnnotation(old) }
        let annotation = makeShape(from: start, to: point, on: page)
        preview = annotation
        if let annotation = annotation { page.addAnnotation(annotation) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil, let page = dragPage else {
            super.mouseUp(with: event)
            return
        }
        if let annotation = preview {
            onAdd?(page, annotation)
        }
        preview = nil
        dragStart = nil
        dragPage = nil
        inkPoints = []
    }

    private func commit(_ annotation: PDFAnnotation, on page: PDFPage) {
        page.addAnnotation(annotation)
        onAdd?(page, annotation)
    }

    /// Rectangle covering the page from the origin, so page space and annotation space agree.
    private func fullBounds(_ page: PDFPage) -> CGRect {
        let box = page.bounds(for: .mediaBox)
        return CGRect(x: 0, y: 0, width: max(box.maxX, 1), height: max(box.maxY, 1))
    }

    private func makeShape(from start: CGPoint, to end: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let border = PDFBorder()
        border.lineWidth = lineWidth
        switch tool {
        case .rectangle, .ellipse:
            guard rect.width > 1 || rect.height > 1 else { return nil }
            let a = PDFAnnotation(bounds: rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2),
                                  forType: tool == .rectangle ? .square : .circle, withProperties: nil)
            a.color = strokeColor
            a.border = border
            return a
        case .whiteout:
            guard rect.width > 1 || rect.height > 1 else { return nil }
            let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            a.color = NSColor.white
            a.interiorColor = NSColor.white
            let thin = PDFBorder()
            thin.lineWidth = 0
            a.border = thin
            return a
        case .highlightArea:
            guard rect.width > 1 || rect.height > 1 else { return nil }
            let a = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            a.color = strokeColor.withAlphaComponent(0.45)
            return a
        case .line, .arrow:
            let a = PDFAnnotation(bounds: fullBounds(page), forType: .line, withProperties: nil)
            a.startPoint = start
            a.endPoint = end
            a.color = strokeColor
            a.interiorColor = strokeColor
            a.border = border
            a.startLineStyle = .none
            a.endLineStyle = tool == .arrow ? .closedArrow : .none
            shapeRects[ObjectIdentifier(a)] = rect
            return a
        case .pen:
            guard inkPoints.count > 1 else { return nil }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: inkPoints[0])
            for p in inkPoints.dropFirst() { path.line(to: p) }
            let a = PDFAnnotation(bounds: fullBounds(page), forType: .ink, withProperties: nil)
            a.color = strokeColor
            a.border = border
            a.add(path)
            shapeRects[ObjectIdentifier(a)] = path.bounds
            return a
        default:
            return nil
        }
    }

    private func addText(at point: CGPoint, on page: PDFPage) {
        let text = textToPlace.isEmpty ? "Text" : textToPlace
        let font = NSFont.systemFont(ofSize: fontSize)
        let size = (text as NSString).boundingRect(with: CGSize(width: 2000, height: 2000),
                                                   options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: font]).size
        let rect = CGRect(x: point.x, y: point.y - size.height - 6, width: ceil(size.width) + 12, height: ceil(size.height) + 8)
        let a = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = strokeColor
        a.color = NSColor.clear
        let border = PDFBorder()
        border.lineWidth = 0
        a.border = border
        commit(a, on: page)
    }

    private func addImage(at point: CGPoint, on page: PDFPage) {
        guard let image = stampImage else {
            NSSound.beep()
            return
        }
        let maxWidth: CGFloat = 180
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        let a = ImageStampAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
        a.stampImage = image
        commit(a, on: page)
    }

    private func erase(at point: CGPoint, on page: PDFPage) {
        for annotation in page.annotations.reversed() {
            let rect = shapeRects[ObjectIdentifier(annotation)] ?? annotation.bounds
            if rect.insetBy(dx: -6, dy: -6).contains(point) {
                page.removeAnnotation(annotation)
                onRemove?(page, annotation)
                return
            }
        }
        NSSound.beep()
    }
}

/// Hosts an existing AppKit view inside SwiftUI.
struct HostedNSView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class PDFEditorModel: ObservableObject {
    static let shared = PDFEditorModel()

    let pdfView = EditablePDFView()
    let thumbnails = PDFThumbnailView()

    @Published private(set) var document: PDFDocument?
    @Published private(set) var fileURL: URL?
    @Published private(set) var pageCount = 0
    @Published private(set) var pageIndex = 0
    @Published private(set) var edited = false
    @Published private(set) var locked = false
    @Published var status = ""

    @Published var tool: PDFTool = .select { didSet { pdfView.tool = tool } }
    @Published var color: Color = .red { didSet { pdfView.strokeColor = NSColor(color) } }
    @Published var lineWidth: Double = 2 { didSet { pdfView.lineWidth = CGFloat(lineWidth) } }
    @Published var fontSize: Double = 16 { didSet { pdfView.fontSize = CGFloat(fontSize) } }
    @Published var textToPlace = "Your text here" { didSet { pdfView.textToPlace = textToPlace } }
    @Published var noteText = "Note" { didSet { pdfView.noteText = noteText } }
    @Published private(set) var stampName = ""

    @Published var searchText = ""
    @Published private(set) var searchResults: [PDFSelection] = []
    @Published private(set) var searchIndex = 0

    private var undoStack: [(PDFPage, PDFAnnotation)] = []

    private init() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor.windowBackgroundColor
        pdfView.strokeColor = NSColor(color)
        pdfView.textToPlace = textToPlace
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 96, height: 124)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.backgroundColor = NSColor.controlBackgroundColor
        pdfView.onAdd = { [weak self] page, annotation in
            self?.undoStack.append((page, annotation))
            self?.markEdited()
        }
        pdfView.onRemove = { [weak self] _, _ in self?.markEdited() }
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.syncPage()
        }
    }

    var currentPage: PDFPage? { pdfView.currentPage }

    var canUndo: Bool { !undoStack.isEmpty }

    private func markEdited() {
        edited = true
        objectWillChange.send()
    }

    private func syncPage() {
        guard let doc = document, let page = pdfView.currentPage else { return }
        pageIndex = doc.index(for: page)
        pageCount = doc.pageCount
    }

    private func refreshLayout(goTo index: Int? = nil) {
        guard let doc = document else { return }
        pageCount = doc.pageCount
        pdfView.layoutDocumentView()
        if let index = index, let page = doc.page(at: max(0, min(index, doc.pageCount - 1))) {
            pdfView.go(to: page)
        }
        syncPage()
        markEdited()
    }

    // MARK: Opening & saving

    func openPanel() {
        if let url = Panels.chooseFiles(multiple: false, types: [.pdf]).first { open(url) }
    }

    func open(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            status = "Couldn't open \(url.lastPathComponent)."
            return
        }
        load(doc, url: url)
        status = "Opened \(url.lastPathComponent)"
    }

    func newBlank() {
        let doc = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        doc.insert(page, at: 0)
        load(doc, url: nil)
        status = "New blank document"
    }

    func newFromImages() {
        let urls = Panels.chooseFiles(multiple: true, types: [.image])
        guard !urls.isEmpty else { return }
        let doc = PDFDocument()
        for url in urls {
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0 else { return }
        load(doc, url: nil)
        edited = true
        status = "Created a PDF from \(doc.pageCount) images"
    }

    private func load(_ doc: PDFDocument, url: URL?) {
        document = doc
        fileURL = url
        locked = doc.isLocked
        pdfView.document = doc
        pdfView.shapeRects = [:]
        undoStack = []
        edited = false
        searchResults = []
        pageCount = doc.pageCount
        pageIndex = 0
    }

    func unlock(_ password: String) {
        guard let doc = document else { return }
        if doc.unlock(withPassword: password) {
            locked = false
            pdfView.document = nil
            pdfView.document = doc
            pageCount = doc.pageCount
            status = "Unlocked"
        } else {
            status = "Wrong password"
            NSSound.beep()
        }
    }

    func save() {
        guard let url = fileURL else {
            saveAs()
            return
        }
        write(to: url, options: nil)
    }

    func saveAs(password: String? = nil) {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        guard let url = Panels.saveFile(name: name + (password == nil ? "" : " (protected)") + ".pdf", types: [.pdf]) else { return }
        var options: [PDFDocumentWriteOption: Any]?
        if let password = password, !password.isEmpty {
            options = [.userPasswordOption: password, .ownerPasswordOption: password]
        }
        write(to: url, options: options)
        if password == nil { fileURL = url }
    }

    private func write(to url: URL, options: [PDFDocumentWriteOption: Any]?) {
        guard let doc = document else { return }
        let ok: Bool
        if let options = options {
            ok = doc.write(to: url, withOptions: options)
        } else {
            ok = doc.write(to: url)
        }
        if ok {
            edited = false
            status = "Saved \(url.lastPathComponent)"
        } else {
            status = "Couldn't save to \(url.path)"
            NSSound.beep()
        }
    }

    /// Renders every page (with its annotations and images) into a brand new PDF.
    func exportFlattened() {
        guard let doc = document,
              let url = Panels.saveFile(name: (fileURL?.deletingPathExtension().lastPathComponent ?? "Document") + " (flattened).pdf", types: [.pdf]) else { return }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return }
        var firstBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let sideways = page.rotation % 180 != 0
            var box = CGRect(x: 0, y: 0,
                             width: sideways ? bounds.height : bounds.width,
                             height: sideways ? bounds.width : bounds.height)
            context.beginPage(mediaBox: &box)
            page.draw(with: .mediaBox, to: context)
            context.endPage()
        }
        context.closePDF()
        do {
            try (data as Data).write(to: url)
            status = "Exported \(url.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    func exportImages() {
        guard let doc = document, let folder = Panels.chooseFolder(message: "Choose where to save the page images") else { return }
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Page"
        var saved = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
            if let data = QRTools.pngData(image) {
                let url = folder.appendingPathComponent("\(base) \(i + 1).png")
                if (try? data.write(to: url)) != nil { saved += 1 }
            }
        }
        status = "Saved \(saved) page images"
        NSWorkspace.shared.open(folder)
    }

    func exportText() {
        guard let doc = document else { return }
        let text = doc.string ?? ""
        guard let url = Panels.saveFile(name: (fileURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".txt", types: [.plainText]) else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved text (\(text.count) characters)"
        } catch {
            status = "Couldn't save text"
        }
    }

    func copyAllText() {
        ClipboardHelper.copy(document?.string ?? "")
        status = "Copied all text"
    }

    func extractCurrentPage() {
        guard let doc = document, let page = pdfView.currentPage, let copy = page.copy() as? PDFPage else { return }
        let index = doc.index(for: page)
        let out = PDFDocument()
        out.insert(copy, at: 0)
        guard let url = Panels.saveFile(name: "Page \(index + 1).pdf", types: [.pdf]) else { return }
        status = out.write(to: url) ? "Saved page \(index + 1)" : "Couldn't save page"
    }

    func splitIntoPages() {
        guard let doc = document, let folder = Panels.chooseFolder(message: "Choose where to save the separate pages") else { return }
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Page"
        var saved = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            if single.write(to: folder.appendingPathComponent("\(base) - page \(i + 1).pdf")) { saved += 1 }
        }
        status = "Saved \(saved) single-page PDFs"
        NSWorkspace.shared.open(folder)
    }

    // MARK: Pages

    func rotate(_ degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        refreshLayout(goTo: pageIndex)
    }

    func rotateAll(_ degrees: Int) {
        guard let doc = document else { return }
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = ((page.rotation + degrees) % 360 + 360) % 360 }
        }
        refreshLayout(goTo: pageIndex)
    }

    func deletePage() {
        guard let doc = document, doc.pageCount > 1, let page = pdfView.currentPage else {
            status = "A PDF needs at least one page."
            return
        }
        let index = doc.index(for: page)
        doc.removePage(at: index)
        undoStack.removeAll { $0.0 == page }
        refreshLayout(goTo: index)
    }

    func duplicatePage() {
        guard let doc = document, let page = pdfView.currentPage, let copy = page.copy() as? PDFPage else { return }
        let index = doc.index(for: page)
        doc.insert(copy, at: index + 1)
        refreshLayout(goTo: index + 1)
    }

    func movePage(by offset: Int) {
        guard let doc = document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        let target = index + offset
        guard target >= 0, target < doc.pageCount else { return }
        doc.exchangePage(at: index, withPageAt: target)
        refreshLayout(goTo: target)
    }

    func insertBlankPage() {
        guard let doc = document else { return }
        let index = pdfView.currentPage.map { doc.index(for: $0) } ?? (doc.pageCount - 1)
        let blank = PDFPage()
        let bounds = pdfView.currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        blank.setBounds(bounds, for: .mediaBox)
        doc.insert(blank, at: index + 1)
        refreshLayout(goTo: index + 1)
    }

    func insertPDF() {
        guard let doc = document, let url = Panels.chooseFiles(multiple: false, types: [.pdf]).first,
              let other = PDFDocument(url: url) else { return }
        var index = pdfView.currentPage.map { doc.index(for: $0) + 1 } ?? doc.pageCount
        let first = index
        for i in 0..<other.pageCount {
            if let page = other.page(at: i)?.copy() as? PDFPage {
                doc.insert(page, at: index)
                index += 1
            }
        }
        status = "Inserted \(other.pageCount) pages from \(url.lastPathComponent)"
        refreshLayout(goTo: first)
    }

    func insertImages() {
        guard let doc = document else { return }
        var index = pdfView.currentPage.map { doc.index(for: $0) + 1 } ?? doc.pageCount
        let first = index
        for url in Panels.chooseFiles(multiple: true, types: [.image]) {
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                doc.insert(page, at: index)
                index += 1
            }
        }
        refreshLayout(goTo: first)
    }

    func goToPage(_ index: Int) {
        guard let doc = document, let page = doc.page(at: max(0, min(index, doc.pageCount - 1))) else { return }
        pdfView.go(to: page)
    }

    // MARK: Annotations

    func chooseStampImage() {
        guard let url = Panels.chooseFiles(multiple: false, types: [.image]).first,
              let image = NSImage(contentsOf: url) else { return }
        pdfView.stampImage = image
        stampName = url.lastPathComponent
        tool = .image
    }

    func markupSelection(_ type: PDFAnnotationSubtype) {
        guard let selection = pdfView.currentSelection else {
            status = "Select some text first (with the Select tool)."
            NSSound.beep()
            return
        }
        var added = 0
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0 else { continue }
                let a = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                switch type {
                case .highlight: a.color = NSColor.systemYellow.withAlphaComponent(0.5)
                case .underline: a.color = NSColor.systemBlue
                default: a.color = NSColor.systemRed
                }
                page.addAnnotation(a)
                undoStack.append((page, a))
                added += 1
            }
        }
        pdfView.clearSelection()
        if added > 0 { markEdited() }
    }

    func undoAnnotation() {
        guard let (page, annotation) = undoStack.popLast() else { return }
        page.removeAnnotation(annotation)
        markEdited()
    }

    func removeAllAnnotationsOnPage() {
        guard let page = pdfView.currentPage else { return }
        for annotation in page.annotations where annotation.type != "Widget" {
            page.removeAnnotation(annotation)
        }
        undoStack.removeAll { $0.0 == page }
        markEdited()
    }

    func addWatermark(_ text: String, size: Double, opacity: Double) {
        guard let doc = document, !text.isEmpty else { return }
        let font = NSFont.boldSystemFont(ofSize: CGFloat(size))
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let rect = CGRect(x: box.midX - textSize.width / 2 - 8, y: box.midY - textSize.height / 2,
                              width: textSize.width + 16, height: textSize.height + 8)
            let a = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            a.contents = text
            a.font = font
            a.fontColor = NSColor.gray.withAlphaComponent(CGFloat(opacity))
            a.color = NSColor.clear
            a.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            a.border = border
            page.addAnnotation(a)
            undoStack.append((page, a))
        }
        markEdited()
        status = "Added watermark to \(doc.pageCount) pages"
    }

    func addPageNumbers(format: String, position: Int, size: Double) {
        guard let doc = document else { return }
        let font = NSFont.systemFont(ofSize: CGFloat(size))
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = format.replacingOccurrences(of: "{n}", with: "\(i + 1)").replacingOccurrences(of: "{total}", with: "\(doc.pageCount)")
            let box = page.bounds(for: .cropBox)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let width = textSize.width + 16
            let x: CGFloat
            switch position {
            case 0: x = box.minX + 36
            case 2: x = box.maxX - 36 - width
            default: x = box.midX - width / 2
            }
            let rect = CGRect(x: x, y: box.minY + 20, width: width, height: textSize.height + 6)
            let a = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            a.contents = text
            a.font = font
            a.fontColor = NSColor.black
            a.color = NSColor.clear
            a.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            a.border = border
            page.addAnnotation(a)
            undoStack.append((page, a))
        }
        markEdited()
        status = "Numbered \(doc.pageCount) pages"
    }

    // MARK: Search

    func search() {
        guard let doc = document, !searchText.isEmpty else {
            searchResults = []
            pdfView.highlightedSelections = nil
            return
        }
        searchResults = doc.findString(searchText, withOptions: [.caseInsensitive])
        pdfView.highlightedSelections = searchResults
        searchIndex = 0
        showSearchResult()
        status = searchResults.isEmpty ? "No matches" : "\(searchResults.count) matches"
    }

    func nextResult(_ step: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + step + searchResults.count) % searchResults.count
        showSearchResult()
    }

    private func showSearchResult() {
        guard searchResults.indices.contains(searchIndex) else { return }
        let selection = searchResults[searchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    // MARK: Metadata

    func metadata() -> (title: String, author: String, subject: String, keywords: String) {
        let attrs = document?.documentAttributes ?? [:]
        let keywords: String
        if let list = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            keywords = list.joined(separator: ", ")
        } else {
            keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? String ?? ""
        }
        return (attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "",
                attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "",
                attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? "",
                keywords)
    }

    func setMetadata(title: String, author: String, subject: String, keywords: String) {
        guard let doc = document else { return }
        var attrs = doc.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.titleAttribute] = title
        attrs[PDFDocumentAttribute.authorAttribute] = author
        attrs[PDFDocumentAttribute.subjectAttribute] = subject
        attrs[PDFDocumentAttribute.keywordsAttribute] = keywords.split(separator: ",").map { String($0).trimmed }
        doc.documentAttributes = attrs
        markEdited()
        status = "Updated document info"
    }

    // MARK: View

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func zoomToFit() { pdfView.autoScales = true }

    func setTwoPages(_ twoUp: Bool) {
        pdfView.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
    }
}

private enum PDFSheet: String, Identifiable {
    case watermark, pageNumbers, metadata, password
    var id: String { rawValue }
}

struct PDFEditorView: View {
    @ObservedObject private var model = PDFEditorModel.shared
    @State private var sheet: PDFSheet?
    @State private var unlockPassword = ""

    var body: some View {
        ToolPage(tool: .pdfEditor, scrolls: false) {
            fileBar
            if model.document != nil {
                toolBar
                if model.locked {
                    lockedView
                } else {
                    HStack(spacing: 0) {
                        HostedNSView(view: model.thumbnails)
                            .frame(width: 130)
                        Divider()
                        HostedNSView(view: model.pdfView)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 420, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
                    .acceptsFileDrops { urls in
                        if let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) { model.open(url) }
                    }
                }
            } else {
                emptyState
            }
        }
        .sheet(item: $sheet) { kind in
            PDFSheetView(kind: kind) { sheet = nil }
        }
    }

    private var fileBar: some View {
        HStack(spacing: 8) {
            Button {
                model.openPanel()
            } label: {
                Label("Open…", systemImage: "folder")
            }
            Menu {
                Button("Blank Page") { model.newBlank() }
                Button("From Images…") { model.newFromImages() }
            } label: {
                Label("New", systemImage: "doc.badge.plus")
            }
            .frame(width: 90)
            Button {
                model.save()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(model.document == nil)
            Button("Save As…") { model.saveAs() }
                .disabled(model.document == nil)
            Menu("Export") {
                Button("Flattened PDF (bake in annotations & images)…") { model.exportFlattened() }
                Button("Pages as PNG Images…") { model.exportImages() }
                Button("Text (.txt)…") { model.exportText() }
                Button("Copy All Text") { model.copyAllText() }
                Divider()
                Button("Current Page as PDF…") { model.extractCurrentPage() }
                Button("Split into Single Pages…") { model.splitIntoPages() }
                Divider()
                Button("Password-Protected Copy…") { sheet = .password }
            }
            .frame(width: 90)
            .disabled(model.document == nil)
            Menu("Document") {
                Button("Add Watermark…") { sheet = .watermark }
                Button("Add Page Numbers…") { sheet = .pageNumbers }
                Button("Title, Author & Keywords…") { sheet = .metadata }
            }
            .frame(width: 110)
            .disabled(model.document == nil)
            Spacer()
            if model.document != nil {
                if model.edited {
                    Text("Edited").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                }
                Text(model.fileURL?.lastPathComponent ?? "Untitled")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(PDFTool.allCases) { tool in
                    Button {
                        model.tool = tool
                        if tool == .image && model.stampName.isEmpty { model.chooseStampImage() }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tool.icon)
                            Text(tool.title).font(.system(size: 10)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(TileButtonStyle(selected: model.tool == tool))
                }
            }
            HStack(spacing: 12) {
                ColorPicker("Colour", selection: $model.color)
                    .frame(width: 90)
                if [.pen, .rectangle, .ellipse, .line, .arrow].contains(model.tool) {
                    Text("Width")
                    Slider(value: $model.lineWidth, in: 0.5...12).frame(width: 110)
                }
                if model.tool == .text {
                    TextField("Text to place", text: $model.textToPlace)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Stepper("Size \(Int(model.fontSize))", value: $model.fontSize, in: 6...96)
                }
                if model.tool == .note {
                    TextField("Note text", text: $model.noteText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if model.tool == .image {
                    Button("Choose Image…") { model.chooseStampImage() }
                    Text(model.stampName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.tool == .select {
                    Button("Highlight") { model.markupSelection(.highlight) }
                    Button("Underline") { model.markupSelection(.underline) }
                    Button("Strike Out") { model.markupSelection(.strikeOut) }
                }
                Spacer()
                Button {
                    model.undoAnnotation()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: [.command])
            }
            Text(model.tool.hint).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    Button { model.rotate(-90) } label: { Image(systemName: "rotate.left") }.help("Rotate page left")
                    Button { model.rotate(90) } label: { Image(systemName: "rotate.right") }.help("Rotate page right")
                    Button { model.movePage(by: -1) } label: { Image(systemName: "arrow.up") }.help("Move page up")
                    Button { model.movePage(by: 1) } label: { Image(systemName: "arrow.down") }.help("Move page down")
                    Button { model.duplicatePage() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate page")
                    Button { model.deletePage() } label: { Image(systemName: "trash") }.help("Delete page")
                }
                Menu("Insert") {
                    Button("Blank Page") { model.insertBlankPage() }
                    Button("Pages from Another PDF…") { model.insertPDF() }
                    Button("Images as Pages…") { model.insertImages() }
                }
                .frame(width: 80)
                Menu("More") {
                    Button("Rotate All Pages Right") { model.rotateAll(90) }
                    Button("Remove Annotations on This Page") { model.removeAllAnnotationsOnPage() }
                    Divider()
                    Button("Single Page View") { model.setTwoPages(false) }
                    Button("Two Page View") { model.setTwoPages(true) }
                }
                .frame(width: 70)
                Divider().frame(height: 18)
                Group {
                    Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    Button("Fit") { model.zoomToFit() }
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Group {
                    Button { model.goToPage(model.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.pageIndex <= 0)
                    Text("Page \(model.pageIndex + 1) of \(model.pageCount)").monospacedDigit()
                    Button { model.goToPage(model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.pageIndex >= model.pageCount - 1)
                }
                Spacer()
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { model.search() }
                if !model.searchResults.isEmpty {
                    Text("\(model.searchIndex + 1)/\(model.searchResults.count)").font(.caption).monospacedDigit()
                    Button { model.nextResult(-1) } label: { Image(systemName: "chevron.up") }
                    Button { model.nextResult(1) } label: { Image(systemName: "chevron.down") }
                }
            }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lockedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("This PDF is password protected").font(.title3.bold())
            HStack {
                SecureField("Password", text: $unlockPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { model.unlock(unlockPassword) }
                Button("Unlock") { model.unlock(unlockPassword) }
                    .buttonStyle(.borderedProminent)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Open a PDF to edit it").font(.title2.bold())
            Text("Add text, notes, signatures, shapes and images · highlight · rotate, reorder, insert and delete pages · merge and split · watermarks and page numbers · password-protect")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack {
                Button("Open PDF…") { model.openPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("New Blank PDF") { model.newBlank() }
                    .controlSize(.large)
                Button("PDF from Images…") { model.newFromImages() }
                    .controlSize(.large)
            }
            Text("…or drop a PDF file here").font(.caption).foregroundStyle(.secondary)
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .acceptsFileDrops { urls in
            if let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) { model.open(url) }
        }
    }
}

private struct PDFSheetView: View {
    let kind: PDFSheet
    let dismiss: () -> Void
    @ObservedObject private var model = PDFEditorModel.shared

    @State private var watermark = "CONFIDENTIAL"
    @State private var watermarkSize = 60.0
    @State private var watermarkOpacity = 0.25
    @State private var numberFormat = "Page {n} of {total}"
    @State private var numberPosition = 1
    @State private var numberSize = 10.0
    @State private var title = ""
    @State private var author = ""
    @State private var subject = ""
    @State private var keywords = ""
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch kind {
            case .watermark:
                Text("Add Watermark").font(.title2.bold())
                TextField("Watermark text", text: $watermark).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Size")
                    Slider(value: $watermarkSize, in: 12...140)
                    Text("\(Int(watermarkSize))").monospacedDigit().frame(width: 34)
                }
                HStack {
                    Text("Opacity")
                    Slider(value: $watermarkOpacity, in: 0.05...1)
                    Text("\(Int(watermarkOpacity * 100))%").monospacedDigit().frame(width: 44)
                }
                buttons("Add to All Pages") {
                    model.addWatermark(watermark, size: watermarkSize, opacity: watermarkOpacity)
                }
            case .pageNumbers:
                Text("Add Page Numbers").font(.title2.bold())
                TextField("Format", text: $numberFormat).textFieldStyle(.roundedBorder)
                Text("{n} = page number, {total} = number of pages").font(.caption).foregroundStyle(.secondary)
                Picker("Position", selection: $numberPosition) {
                    Text("Bottom left").tag(0)
                    Text("Bottom center").tag(1)
                    Text("Bottom right").tag(2)
                }
                .pickerStyle(.segmented)
                Stepper("Font size \(Int(numberSize))", value: $numberSize, in: 6...24)
                buttons("Add Numbers") {
                    model.addPageNumbers(format: numberFormat, position: numberPosition, size: numberSize)
                }
            case .metadata:
                Text("Document Info").font(.title2.bold())
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                TextField("Author", text: $author).textFieldStyle(.roundedBorder)
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                TextField("Keywords (comma separated)", text: $keywords).textFieldStyle(.roundedBorder)
                buttons("Save Info") {
                    model.setMetadata(title: title, author: author, subject: subject, keywords: keywords)
                }
            case .password:
                Text("Password-Protected Copy").font(.title2.bold())
                Text("Saves a copy that needs this password to open.").foregroundStyle(.secondary)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder)
                if !password.isEmpty && password != confirm {
                    Text("Passwords don't match").font(.caption).foregroundColor(.red)
                }
                buttons("Save Protected Copy…", disabled: password.isEmpty || password != confirm) {
                    let pw = password
                    DispatchQueue.main.async { model.saveAs(password: pw) }
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            if kind == .metadata {
                let info = model.metadata()
                title = info.title
                author = info.author
                subject = info.subject
                keywords = info.keywords
            }
        }
    }

    private func buttons(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button(title) {
                action()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
        }
    }
}
