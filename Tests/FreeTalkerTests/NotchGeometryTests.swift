import CoreGraphics
import Testing
@testable import FreeTalker

@Suite("Notch geometry")
struct NotchGeometryTests {
    /// Synthetic MacBook-like built-in: 1512×982, 38pt safe top, notch ~180pt wide.
    private let macBookFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let safeAreaTop: CGFloat = 38
    private let auxHeight: CGFloat = 38
    private let notchWidth: CGFloat = 180
    private let leftAuxWidth: CGFloat = 666
    private let rightAuxWidth: CGFloat = 666

    private var leftAux: CGRect {
        CGRect(
            x: macBookFrame.minX,
            y: macBookFrame.maxY - auxHeight,
            width: leftAuxWidth,
            height: auxHeight
        )
    }

    private var rightAux: CGRect {
        CGRect(
            x: macBookFrame.maxX - rightAuxWidth,
            y: macBookFrame.maxY - auxHeight,
            width: rightAuxWidth,
            height: auxHeight
        )
    }

    private func validBuiltin(
        displayID: CGDirectDisplayID = 1,
        frame: CGRect? = nil,
        safeAreaTop: CGFloat? = nil,
        left: CGRect? = .some(CGRect.null), // .null sentinel → use default leftAux
        right: CGRect? = .some(CGRect.null)
    ) -> NotchScreenDescriptor {
        let resolvedLeft: CGRect? = {
            guard let left else { return nil }
            return left.isNull ? leftAux : left
        }()
        let resolvedRight: CGRect? = {
            guard let right else { return nil }
            return right.isNull ? rightAux : right
        }()
        return NotchScreenDescriptor(
            displayID: displayID,
            frame: frame ?? macBookFrame,
            isBuiltin: true,
            safeAreaTop: safeAreaTop ?? self.safeAreaTop,
            auxiliaryTopLeft: resolvedLeft,
            auxiliaryTopRight: resolvedRight
        )
    }

    // MARK: - Rejection matrix

    @Test func rejectsNonBuiltin() {
        let external = NotchScreenDescriptor(
            displayID: 99,
            frame: macBookFrame,
            isBuiltin: false,
            safeAreaTop: safeAreaTop,
            auxiliaryTopLeft: leftAux,
            auxiliaryTopRight: rightAux
        )
        #expect(NotchGeometryResolver.evaluate(external) == .failure(.notBuiltin))
        #expect(NotchGeometryResolver.resolve(screens: [external]) == nil)
    }

    @Test func rejectsZeroSafeAreaTop() {
        let screen = validBuiltin(safeAreaTop: 0)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.noSafeAreaTop))
        #expect(NotchGeometryResolver.resolve(screens: [screen]) == nil)
    }

    @Test func rejectsNegativeSafeAreaTop() {
        let screen = validBuiltin(safeAreaTop: -1)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.noSafeAreaTop))
    }

    @Test func rejectsMissingLeftAuxiliary() {
        let missingLeft = validBuiltin(left: nil)
        #expect(NotchGeometryResolver.evaluate(missingLeft) == .failure(.missingAuxiliaryAreas))
        #expect(NotchGeometryResolver.resolve(screens: [missingLeft]) == nil)
    }

    @Test func rejectsMissingRightAuxiliary() {
        let missingRight = validBuiltin(right: nil)
        #expect(NotchGeometryResolver.evaluate(missingRight) == .failure(.missingAuxiliaryAreas))
        #expect(NotchGeometryResolver.resolve(screens: [missingRight]) == nil)
    }

    @Test func rejectsBothMissingAuxiliaries() {
        let missing = NotchScreenDescriptor(
            displayID: 1,
            frame: macBookFrame,
            isBuiltin: true,
            safeAreaTop: safeAreaTop,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        #expect(NotchGeometryResolver.evaluate(missing) == .failure(.missingAuxiliaryAreas))
    }

    @Test func rejectsInvertedGap() {
        // Swap left/right so left.maxX > right.minX
        let inverted = validBuiltin(left: rightAux, right: leftAux)
        #expect(NotchGeometryResolver.evaluate(inverted) == .failure(.invalidNotchGap))
        #expect(NotchGeometryResolver.resolve(screens: [inverted]) == nil)
    }

    @Test func rejectsTouchingAuxiliariesNoGap() {
        let left = CGRect(x: 0, y: macBookFrame.maxY - auxHeight, width: 756, height: auxHeight)
        let right = CGRect(x: 756, y: macBookFrame.maxY - auxHeight, width: 756, height: auxHeight)
        let screen = validBuiltin(left: left, right: right)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.invalidNotchGap))
    }

    @Test func rejectsEmptyAuxiliary() {
        let empty = CGRect(x: 0, y: macBookFrame.maxY, width: 0, height: 0)
        let screen = validBuiltin(left: empty)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.invalidNotchGap))
    }

    @Test func rejectsAuxiliaryOutsideFrame() {
        let outside = CGRect(
            x: -100,
            y: macBookFrame.maxY - auxHeight,
            width: leftAuxWidth,
            height: auxHeight
        )
        let screen = validBuiltin(left: outside)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.invalidNotchGap))
    }

    @Test func rejectsAuxiliaryNotTopAligned() {
        let lowered = CGRect(
            x: leftAux.minX,
            y: leftAux.minY - 10,
            width: leftAux.width,
            height: leftAux.height
        )
        let screen = validBuiltin(left: lowered)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.invalidNotchGap))
    }

    @Test func rejectsNonFiniteAuxiliary() {
        let nanRect = CGRect(x: .nan, y: macBookFrame.maxY - auxHeight, width: 100, height: auxHeight)
        let screen = validBuiltin(left: nanRect)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.invalidNotchGap))
    }

    @Test func rejectsNonFiniteSafeAreaTop() {
        let screen = validBuiltin(safeAreaTop: .nan)
        #expect(NotchGeometryResolver.evaluate(screen) == .failure(.noSafeAreaTop))
    }

    // MARK: - Valid geometry

    @Test func acceptsSyntheticMacBookGeometry() throws {
        let screen = validBuiltin(displayID: 42)
        let geometry = try #require(NotchGeometryResolver.resolve(screens: [screen]))

        #expect(geometry.displayID == 42)
        #expect(geometry.screenFrame == macBookFrame)
        #expect(geometry.safeAreaTop == safeAreaTop)
        #expect(geometry.notchFrame.width == notchWidth)
        #expect(geometry.notchFrame.minX == leftAux.maxX)
        #expect(geometry.notchFrame.maxX == rightAux.minX)
        #expect(geometry.notchFrame.maxY == macBookFrame.maxY)
        #expect(macBookFrame.contains(geometry.notchFrame))

        // No width fallback: width is exactly the measured gap.
        #expect(geometry.notchFrame.width == rightAux.minX - leftAux.maxX)
    }

    @Test func evaluateSuccessMatchesResolve() throws {
        let screen = validBuiltin()
        let result = NotchGeometryResolver.evaluate(screen)
        let resolved = try #require(NotchGeometryResolver.resolve(screens: [screen]))
        guard case .success(let geometry) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(geometry == resolved)
    }

    // MARK: - Multi-screen selection

    @Test func selectsBuiltinEvenWhenExternalListedFirst() throws {
        let external = NotchScreenDescriptor(
            displayID: 100,
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            isBuiltin: false,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        // Spoof an external that *looks* notched if someone only checked insets.
        let externalLookingNotched = NotchScreenDescriptor(
            displayID: 101,
            frame: CGRect(x: 1512, y: 0, width: 1512, height: 982),
            isBuiltin: false,
            safeAreaTop: safeAreaTop,
            auxiliaryTopLeft: leftAux.offsetBy(dx: 1512, dy: 0),
            auxiliaryTopRight: rightAux.offsetBy(dx: 1512, dy: 0)
        )
        let builtin = validBuiltin(displayID: 1)

        let geometry = try #require(
            NotchGeometryResolver.resolve(screens: [external, externalLookingNotched, builtin])
        )
        #expect(geometry.displayID == 1)
        #expect(geometry.notchFrame.width == notchWidth)
    }

    @Test func returnsNilWhenOnlyExternalsPresent() {
        let external = NotchScreenDescriptor(
            displayID: 7,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isBuiltin: false,
            safeAreaTop: 25,
            auxiliaryTopLeft: CGRect(x: 0, y: 1055, width: 800, height: 25),
            auxiliaryTopRight: CGRect(x: 1120, y: 1055, width: 800, height: 25)
        )
        #expect(NotchGeometryResolver.resolve(screens: [external]) == nil)
    }

    @Test func returnsNilForEmptyScreenList() {
        #expect(NotchGeometryResolver.resolve(screens: []) == nil)
    }

    @Test func neverUsesScreensFirstWithoutValidation() {
        // First screen is a builtin without valid notch geometry.
        let invalidBuiltin = NotchScreenDescriptor(
            displayID: 1,
            frame: macBookFrame,
            isBuiltin: true,
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        let valid = validBuiltin(displayID: 2)
        let geometry = NotchGeometryResolver.resolve(screens: [invalidBuiltin, valid])
        #expect(geometry?.displayID == 2)
    }

    // MARK: - Placement helpers

    @Test func contentSitsBelowSafeAreaStrip() throws {
        let geometry = try #require(NotchGeometryResolver.resolve(screens: [validBuiltin()]))
        let panelHeight: CGFloat = 44

        #expect(geometry.contentMaxY == macBookFrame.maxY - safeAreaTop)
        #expect(geometry.contentOriginY(panelHeight: panelHeight) == geometry.contentMaxY - panelHeight)

        let panelFrame = CGRect(
            x: geometry.notchFrame.midX - 230,
            y: geometry.contentOriginY(panelHeight: panelHeight),
            width: 460,
            height: panelHeight
        )
        #expect(panelFrame.maxY <= geometry.contentMaxY)
        #expect(panelFrame.maxY <= macBookFrame.maxY - safeAreaTop)
    }

    @Test func connectorMatchesNotchWidthInSafeAreaStrip() throws {
        let geometry = try #require(NotchGeometryResolver.resolve(screens: [validBuiltin()]))
        let connector = geometry.connectorFrame

        #expect(connector.width == geometry.notchFrame.width)
        #expect(connector.minX == geometry.notchFrame.minX)
        #expect(connector.height == safeAreaTop)
        #expect(connector.minY == geometry.contentMaxY)
        #expect(connector.maxY == macBookFrame.maxY)
    }

    // MARK: - No width fallback

    @Test func noFallbackWidthWhenGapInvalid() {
        // Builtin + safe area present, but gap inverted — must be nil, not a default width.
        let bad = validBuiltin(left: rightAux, right: leftAux)
        #expect(NotchGeometryResolver.resolve(screens: [bad]) == nil)

        let missingAux = NotchScreenDescriptor(
            displayID: 1,
            frame: macBookFrame,
            isBuiltin: true,
            safeAreaTop: safeAreaTop,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
        #expect(NotchGeometryResolver.resolve(screens: [missingAux]) == nil)
    }
}
